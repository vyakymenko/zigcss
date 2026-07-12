import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const extensionRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
for (const directory of ['out', 'dist']) {
  fs.rmSync(path.join(extensionRoot, directory), { force: true, recursive: true })
}
