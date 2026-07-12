import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const expectedRelease = process.env.NEOVIM_TEST_VERSION || '0.12.4'
const expectedVersion = `NVIM v${expectedRelease}`
const nvim = process.env.NVIM || 'nvim'

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

const version = run(nvim, ['--version'])
if (version.status !== 0) {
  throw new Error(`Neovim version check failed:\n${version.stderr}`)
}
const versionLine = version.stdout.split(/\r?\n/, 1)[0]
if (versionLine !== expectedVersion) {
  throw new Error(`expected ${expectedVersion}, received ${versionLine}`)
}

const configuredZigcss = process.env.ZIGCSS_LSP_PATH ||
  path.join(repositoryRoot, 'zig-out', 'bin', process.platform === 'win32' ? 'zigcss.exe' : 'zigcss')
const zigcss = fs.realpathSync(configuredZigcss)
if (!fs.statSync(zigcss).isFile()) throw new Error(`not a regular ZigCSS executable: ${zigcss}`)
if (process.platform !== 'win32') fs.accessSync(zigcss, fs.constants.X_OK)

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
