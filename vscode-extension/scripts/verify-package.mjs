import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { createRequire } from 'node:module'
import { fileURLToPath } from 'node:url'

const extensionRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const require = createRequire(import.meta.url)
const vsceManifestPath = require.resolve('@vscode/vsce/package.json')
const vsceManifest = JSON.parse(fs.readFileSync(vsceManifestPath, 'utf8'))
const vscePath = path.join(path.dirname(vsceManifestPath), vsceManifest.bin.vsce)
const expectedFiles = [
  'LICENSE',
  'README.md',
  'THIRD_PARTY_NOTICES.md',
  'dist/extension.js',
  'package.json',
]

function runVsce(args) {
  return execFileSync(process.execPath, [vscePath, ...args], {
    cwd: extensionRoot,
    encoding: 'utf8',
    env: { ...process.env, NO_COLOR: '1' },
  })
}

const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-vscode-'))
try {
  const listed = runVsce(['ls', '--no-dependencies'])
    .split(/\r?\n/)
    .map(file => file.trim())
    .filter(Boolean)
    .sort()
  if (JSON.stringify(listed) !== JSON.stringify(expectedFiles)) {
    throw new Error(
      `unexpected VSIX file list\nexpected: ${expectedFiles.join(', ')}\nactual: ${listed.join(', ')}`,
    )
  }

  const packagePath = path.join(temporary, 'zigcss-language-server.vsix')
  runVsce([
    'package',
    '--no-dependencies',
    '--pre-release',
    '--out',
    packagePath,
  ])
  const packageBytes = fs.readFileSync(packagePath)
  if (packageBytes.length < 64 * 1024 || packageBytes.length > 2 * 1024 * 1024) {
    throw new Error(`unexpected VSIX size: ${packageBytes.length} bytes`)
  }
  if (!packageBytes.subarray(0, 4).equals(Buffer.from([0x50, 0x4b, 0x03, 0x04]))) {
    throw new Error('VSIX does not begin with a ZIP local-file signature')
  }

  process.stdout.write(
    `VS Code package verified: ${expectedFiles.length} extension files, ${packageBytes.length} VSIX bytes.\n`,
  )
} finally {
  fs.rmSync(temporary, { force: true, recursive: true })
  for (const directory of ['out', 'dist']) {
    fs.rmSync(path.join(extensionRoot, directory), { force: true, recursive: true })
  }
}
