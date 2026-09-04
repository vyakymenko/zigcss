import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const scriptPath = fileURLToPath(import.meta.url)
const repositoryRoot = path.resolve(path.dirname(scriptPath), '..')
const maximumExecutableBytes = 512 * 1024 * 1024

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    encoding: 'utf8',
    maxBuffer: 1024 * 1024,
    ...options,
  })
  if (result.error) {
    result.error.message += `\nstdout:\n${result.stdout || ''}\nstderr:\n${result.stderr || ''}`
    throw result.error
  }
  return result
}

export function expectedNeovimRelease(configured = process.env.NEOVIM_TEST_VERSION) {
  switch (configured) {
    case undefined:
    case '0.12.4':
      return '0.12.4'
    case '0.11.7':
      return '0.11.7'
    default:
      throw new Error('NEOVIM_TEST_VERSION must be exactly 0.11.7 or 0.12.4')
  }
}

export function neovimCommand(configured = process.env.NVIM, release = expectedNeovimRelease()) {
  if (configured === undefined || configured === '' || configured === 'nvim') return 'nvim'
  const candidates = release === '0.11.7'
    ? [
        '/usr/bin/nvim',
        '/usr/local/bin/nvim',
        '/opt/homebrew/bin/nvim',
        '/opt/local/bin/nvim',
        '/nix/var/nix/profiles/default/bin/nvim',
        '/home/runner/work/_temp/nvim-0.11.7/bin/nvim',
        '/Users/runner/work/_temp/nvim-0.11.7/bin/nvim',
        'D:\\a\\_temp\\nvim-0.11.7\\bin\\nvim.exe',
        'C:\\Program Files\\Neovim\\bin\\nvim.exe',
      ]
    : release === '0.12.4'
      ? [
          '/usr/bin/nvim',
          '/usr/local/bin/nvim',
          '/opt/homebrew/bin/nvim',
          '/opt/local/bin/nvim',
          '/nix/var/nix/profiles/default/bin/nvim',
          '/home/runner/work/_temp/nvim-0.12.4/bin/nvim',
          '/Users/runner/work/_temp/nvim-0.12.4/bin/nvim',
          'D:\\a\\_temp\\nvim-0.12.4\\bin\\nvim.exe',
          'C:\\Program Files\\Neovim\\bin\\nvim.exe',
        ]
      : []
  for (const candidate of candidates) {
    if (configured === candidate) return candidate
  }
  throw new Error('NVIM must select the PATH command or a finite reviewed Neovim installation')
}

export function neovimZigcssPath(root = repositoryRoot, configured = process.env.ZIGCSS_LSP_PATH) {
  const expected = path.join(root, 'zig-out', 'bin', process.platform === 'win32' ? 'zigcss.exe' : 'zigcss')
  if (configured !== undefined && configured !== '' && configured !== expected) {
    throw new Error('ZIGCSS_LSP_PATH must identify the repository ReleaseFast binary')
  }
  return expected
}

function sameFileIdentity(left, right) {
  return left.dev === right.dev && left.ino === right.ino && left.size === right.size &&
    left.mtimeNs === right.mtimeNs && left.ctimeNs === right.ctimeNs
}

function stableExecutable(filename, label) {
  let descriptor
  try {
    const canonical = fs.realpathSync(filename)
    descriptor = fs.openSync(
      canonical,
      fs.constants.O_RDONLY |
        (fs.constants.O_NOFOLLOW ?? 0) |
        (fs.constants.O_NONBLOCK ?? 0) |
        (fs.constants.O_CLOEXEC ?? 0),
    )
    const opened = fs.fstatSync(descriptor, { bigint: true })
    const pathStat = fs.lstatSync(canonical, { bigint: true })
    if (
      !opened.isFile() || !pathStat.isFile() || pathStat.isSymbolicLink() ||
      !sameFileIdentity(opened, pathStat) || opened.size <= 0n ||
      opened.size > BigInt(maximumExecutableBytes)
    ) throw new Error(`${label} is not a bounded stable regular file`)
    if (process.platform !== 'win32' && (opened.mode & 0o111n) === 0n) {
      throw new Error(`${label} is not executable`)
    }
    return canonical
  } finally {
    if (descriptor !== undefined) fs.closeSync(descriptor)
  }
}

export function main() {
  const expectedRelease = expectedNeovimRelease()
  const expectedVersion = `NVIM v${expectedRelease}`
  const nvim = neovimCommand(process.env.NVIM, expectedRelease)
  const version = run(nvim, ['--version'])
  if (version.status !== 0) {
    throw new Error(`Neovim version check failed:\n${version.stderr}`)
  }
  const versionLine = version.stdout.split(/\r?\n/, 1)[0]
  if (versionLine !== expectedVersion) {
    throw new Error(`expected ${expectedVersion}, received ${versionLine}`)
  }

  const zigcss = stableExecutable(neovimZigcssPath(), 'ZigCSS LSP executable')
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-neovim-'))
  try {
    const fixture = path.join(temporary, 'smoke.css')
    fs.writeFileSync(fixture, '.a { color: red; }\n')
    for (const directory of ['config', 'data', 'state', 'cache', 'home']) {
      fs.mkdirSync(path.join(temporary, directory))
    }

    const isolatedEnvironment = {
      ...process.env,
      HOME: path.join(temporary, 'home'),
      XDG_CONFIG_HOME: path.join(temporary, 'config'),
      XDG_DATA_HOME: path.join(temporary, 'data'),
      XDG_STATE_HOME: path.join(temporary, 'state'),
      XDG_CACHE_HOME: path.join(temporary, 'cache'),
      NVIM_LOG_FILE: path.join(temporary, 'state', 'nvim.log'),
      ZIGCSS_NEOVIM_CONFIG_ROOT: path.join(repositoryRoot, 'neovim-config'),
    }
    delete isolatedEnvironment.NVIM
    delete isolatedEnvironment.NVIM_APPNAME
    delete isolatedEnvironment.ZIGCSS_LSP_PATH
    delete isolatedEnvironment.ZIGCSS_NEOVIM_SMOKE_SCRIPT

    const rejection = run(nvim, [
      '--headless',
      '-u', path.join(repositoryRoot, 'neovim-config', 'test', 'rejection.lua'),
      '-i', 'NONE',
      '-n',
    ], {
      cwd: temporary,
      timeout: 5000,
      env: isolatedEnvironment,
    })
    const rejectionOutput = `${rejection.stdout}${rejection.stderr}`
    if (rejection.status !== 0 || !rejectionOutput.includes('NEOVIM_REJECTION_PASS')) {
      throw new Error(`relative-path rejection failed with status ${rejection.status}:\n${rejectionOutput}`)
    }

    const result = run(nvim, [
      '--headless',
      '-u', path.join(repositoryRoot, 'neovim-config', 'test', 'init.lua'),
      '-i', 'NONE',
      '-n',
      fixture,
    ], {
      cwd: temporary,
      timeout: 20000,
      env: {
        ...isolatedEnvironment,
        ZIGCSS_LSP_PATH: zigcss,
        ZIGCSS_NEOVIM_SMOKE_SCRIPT: path.join(
          repositoryRoot,
          'neovim-config',
          'test',
          'integration.lua',
        ),
      },
    })
    const output = `${result.stdout}${result.stderr}`
    if (result.status !== 0) {
      throw new Error(`headless Neovim smoke failed with status ${result.status}:\n${output}`)
    }
    if (!output.includes('NEOVIM_SMOKE_PASS')) {
      throw new Error(`headless Neovim smoke emitted no success marker:\n${output}`)
    }
    process.stdout.write(
      `Neovim ${expectedRelease} integration verified: ${rejectionOutput.match(/NEOVIM_REJECTION_PASS[^\r\n]*/)[0]}; ${output.match(/NEOVIM_SMOKE_PASS[^\r\n]*/)[0]}\n`,
    )
  } finally {
    fs.rmSync(temporary, { force: true, recursive: true })
  }
}

if (process.argv[1] !== undefined && path.resolve(process.argv[1]) === scriptPath) main()
