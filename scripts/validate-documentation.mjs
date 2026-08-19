import { spawnSync } from 'node:child_process'
import crypto from 'node:crypto'
import fs from 'node:fs'
import { createRequire } from 'node:module'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const scriptPath = fileURLToPath(import.meta.url)
const require = createRequire(import.meta.url)
const { transform: parseCss } = require('lightningcss')
export const repositoryRoot = path.resolve(path.dirname(scriptPath), '..')
export const policyPath = path.join(repositoryRoot, 'docs', 'documentation-validation.json')

const executableLanguages = new Set(['bash', 'css', 'scss', 'json', 'lua', 'vim', 'zig'])
const presentationLanguages = new Set(['mermaid', 'text'])
const siteRoutes = new Set(['/', '/docs', '/features', '/getting-started', '/playground'])

function fail(message) {
  throw new Error(`documentation validation: ${message}`)
}

function sha256(value) {
  return crypto.createHash('sha256').update(value).digest('hex')
}

function literalElementIds(value) {
  return new Set([...value.matchAll(/\bid\s*=\s*["']([^"']+)["']/g)].map(match => match[1]))
}

function siteElementIds(root) {
  const componentRoot = path.join(root, 'docs', 'src', 'app', 'components')
  if (!fs.existsSync(componentRoot)) return new Set()
  const ids = new Set()
  const visit = directory => {
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
      const entryPath = path.join(directory, entry.name)
      if (entry.isDirectory()) visit(entryPath)
      else if (entry.isFile() && /\.[jt]sx?$/.test(entry.name)) {
        for (const id of literalElementIds(fs.readFileSync(entryPath, 'utf8'))) ids.add(id)
      }
    }
  }
  visit(componentRoot)
  return ids
}

function read(relativePath, root = repositoryRoot) {
  return fs.readFileSync(path.join(root, relativePath), 'utf8')
}

function assertInside(root, target, label) {
  const relative = path.relative(root, target)
  if (relative.startsWith('..') || path.isAbsolute(relative)) fail(`${label} escapes the repository`)
}

function run(command, args, options, label) {
  const result = spawnSync(command, args, {
    encoding: 'utf8',
    maxBuffer: 4 * 1024 * 1024,
    timeout: 15_000,
    ...options,
  })
  if (result.error) fail(`${label}: ${result.error.message}`)
  if (result.status !== 0) {
    fail(`${label} exited ${result.status}: ${(result.stderr || result.stdout).trim()}`)
  }
  return result
}

export function trackedMarkdownFiles(root = repositoryRoot) {
  const result = run(
    'git',
    ['ls-files', '-z', '--cached', '--others', '--exclude-standard', '--', '*.md'],
    { cwd: root },
    'Markdown inventory',
  )
  return [...new Set(result.stdout.split('\0').filter(relativePath => (
    relativePath.length !== 0 && fs.existsSync(path.join(root, relativePath))
  )))].sort()
}

export function extractFences(content, source = '<memory>') {
  const lines = content.split(/\r?\n/)
  const fences = []
  for (let index = 0; index < lines.length; index += 1) {
    const opening = /^ {0,3}(`{3,}|~{3,})(.*)$/.exec(lines[index])
    if (!opening) continue
    const marker = opening[1][0]
    const minimumLength = opening[1].length
    const language = opening[2].trim().split(/\s+/, 1)[0].toLowerCase()
    const body = []
    const startLine = index + 1
    let closed = false
    for (index += 1; index < lines.length; index += 1) {
      const closing = new RegExp(`^ {0,3}${marker}{${minimumLength},}\\s*$`)
      if (closing.test(lines[index])) {
        closed = true
        break
      }
      body.push(lines[index])
    }
    if (!closed) fail(`${source}:${startLine} has an unterminated fence`)
    const fenceContent = body.join('\n')
    fences.push({
      source,
      language,
      content: fenceContent,
      sha256: sha256(fenceContent),
      startLine,
      endLine: index + 1,
    })
  }
  return fences
}

function stripInlineCode(line) {
  let output = ''
  for (let index = 0; index < line.length;) {
    if (line[index] !== '`') {
      output += line[index]
      index += 1
      continue
    }
    let count = 1
    while (line[index + count] === '`') count += 1
    const marker = '`'.repeat(count)
    const end = line.indexOf(marker, index + count)
    if (end === -1) {
      output += line.slice(index)
      break
    }
    output += ' '.repeat(end + count - index)
    index = end + count
  }
  return output
}

function inlineDestinations(line) {
  const destinations = []
  for (let index = 0; index < line.length - 1; index += 1) {
    if (line[index] !== ']' || line[index + 1] !== '(' || line[index - 1] === '\\') continue
    let cursor = index + 2
    while (/\s/.test(line[cursor] ?? '')) cursor += 1
    if (line[cursor] === '<') {
      const end = line.indexOf('>', cursor + 1)
      if (end === -1) fail('link destination has an unterminated angle bracket')
      destinations.push(line.slice(cursor + 1, end))
      index = end
      continue
    }
    const start = cursor
    let depth = 1
    for (; cursor < line.length; cursor += 1) {
      const character = line[cursor]
      if (character === '\\') {
        cursor += 1
        continue
      }
      if (character === '(') depth += 1
      if (character === ')') {
        depth -= 1
        if (depth === 0) break
      }
      if (/\s/.test(character) && depth === 1) break
    }
    const destination = line.slice(start, cursor)
    if (destination.length !== 0) destinations.push(destination)
    index = cursor
  }
  return destinations
}

export function extractLinks(content, source = '<memory>') {
  const fencedLines = new Set()
  for (const fence of extractFences(content, source)) {
    for (let line = fence.startLine; line <= fence.endLine; line += 1) fencedLines.add(line)
  }
  const lines = content.split(/\r?\n/)
  const definitions = new Map()
  for (const [index, original] of lines.entries()) {
    if (fencedLines.has(index + 1)) continue
    const line = stripInlineCode(original)
    const reference = /^ {0,3}\[([^\]]+)\]:\s*(?:<([^>]+)>|(\S+))/.exec(line)
    if (!reference) continue
    const label = reference[1].trim().replace(/\s+/g, ' ').toLowerCase()
    if (definitions.has(label)) fail(`${source}:${index + 1} repeats reference link label '${label}'`)
    definitions.set(label, { destination: reference[2] ?? reference[3], line: index + 1 })
  }

  const links = []
  const usedDefinitions = new Set()
  for (const [index, original] of lines.entries()) {
    const lineNumber = index + 1
    if (fencedLines.has(lineNumber)) continue
    const line = stripInlineCode(original)
    if (!/^ {0,3}\[[^\]]+\]:/.test(line)) {
      for (const match of line.matchAll(/!?\[([^\]]+)\]\[([^\]]*)\]/g)) {
        const label = (match[2] || match[1]).trim().replace(/\s+/g, ' ').toLowerCase()
        const definition = definitions.get(label)
        if (definition === undefined) fail(`${source}:${lineNumber} references missing link label '${label}'`)
        usedDefinitions.add(label)
        links.push({ source, line: lineNumber, destination: definition.destination })
      }
    }
    for (const destination of inlineDestinations(line)) {
      links.push({ source, line: lineNumber, destination })
    }
    for (const match of line.matchAll(/\b(?:href|src)\s*=\s*["']([^"']+)["']/gi)) {
      links.push({ source, line: lineNumber, destination: match[1] })
    }
  }
  for (const [label, definition] of definitions) {
    if (!usedDefinitions.has(label)) links.push({ source, line: definition.line, destination: definition.destination })
  }
  return links
}

function headingAnchors(content) {
  const anchors = new Set()
  const duplicates = new Map()
  const fencedLines = new Set()
  for (const fence of extractFences(content)) {
    for (let line = fence.startLine; line <= fence.endLine; line += 1) fencedLines.add(line)
  }
  for (const [index, line] of content.split(/\r?\n/).entries()) {
    if (fencedLines.has(index + 1)) continue
    const heading = /^ {0,3}#{1,6}\s+(.+?)\s*#*\s*$/.exec(line)
    if (!heading) continue
    const base = heading[1]
      .replace(/<[^>]*>/g, '')
      .replace(/\[([^\]]+)\]\([^)]*\)/g, '$1')
      .replace(/[`*_~]/g, '')
      .toLowerCase()
      .replace(/[^\p{L}\p{N}\s_-]/gu, '')
      .trim()
      .replace(/\s+/g, '-')
    const count = duplicates.get(base) ?? 0
    duplicates.set(base, count + 1)
    anchors.add(count === 0 ? base : `${base}-${count}`)
  }
  for (const match of content.matchAll(/\b(?:id|name)=["']([^"']+)["']/gi)) anchors.add(match[1])
  return anchors
}

function isExternal(destination) {
  return destination.startsWith('//') || /^[a-z][a-z0-9+.-]*:/i.test(destination)
}

function splitDestination(destination) {
  const hashIndex = destination.indexOf('#')
  const rawPath = hashIndex === -1 ? destination : destination.slice(0, hashIndex)
  const fragment = hashIndex === -1 ? '' : destination.slice(hashIndex + 1)
  const queryIndex = rawPath.indexOf('?')
  return {
    pathname: queryIndex === -1 ? rawPath : rawPath.slice(0, queryIndex),
    fragment,
  }
}

function documentationRoute(pathname) {
  if (pathname.startsWith('/guide/')) return `docs/src/content/docs${pathname}.md`
  if (pathname.startsWith('/docs/guide/')) return `docs/src/content/docs/${pathname.slice('/docs/'.length)}.md`
  return null
}

export function validateInternalLink(link, root = repositoryRoot) {
  if (link.destination.length === 0 || isExternal(link.destination)) return false
  let pathname
  let fragment
  try {
    const split = splitDestination(link.destination)
    pathname = decodeURI(split.pathname)
    fragment = decodeURIComponent(split.fragment)
  } catch {
    fail(`${link.source}:${link.line} has malformed URL encoding: ${link.destination}`)
  }

  const routeTarget = documentationRoute(pathname)
  if (pathname.startsWith('/') && routeTarget === null) {
    if (!siteRoutes.has(pathname.replace(/\/$/, '') || '/')) {
      fail(`${link.source}:${link.line} references an unknown site route: ${pathname}`)
    }
    if (fragment.length !== 0 && !siteElementIds(root).has(fragment)) {
      fail(`${link.source}:${link.line} has a missing site element id: #${fragment}`)
    }
    return true
  }

  const lexicalRoot = path.resolve(root)
  const canonicalRoot = fs.realpathSync(lexicalRoot)
  const target = routeTarget === null
    ? path.resolve(lexicalRoot, path.dirname(link.source), pathname || path.basename(link.source))
    : path.resolve(lexicalRoot, routeTarget)
  assertInside(lexicalRoot, target, `${link.source}:${link.line} link`)
  if (!fs.existsSync(target)) fail(`${link.source}:${link.line} has a missing target: ${link.destination}`)
  const canonicalTarget = fs.realpathSync(target)
  assertInside(canonicalRoot, canonicalTarget, `${link.source}:${link.line} link`)
  if (fragment.length !== 0) {
    const stat = fs.statSync(canonicalTarget)
    if (!stat.isFile()) {
      fail(`${link.source}:${link.line} has a fragment on a non-Markdown target`)
    }
    const targetContent = fs.readFileSync(canonicalTarget, 'utf8')
    if (canonicalTarget.endsWith('.md')) {
      if (!headingAnchors(targetContent).has(fragment)) {
        fail(`${link.source}:${link.line} has a missing heading fragment: #${fragment}`)
      }
    } else if (/\.(?:html|[jt]sx?)$/.test(canonicalTarget)) {
      const localIds = literalElementIds(targetContent)
      if (!localIds.has(fragment) && !siteElementIds(root).has(fragment)) {
        fail(`${link.source}:${link.line} has a missing element id: #${fragment}`)
      }
    } else {
      fail(`${link.source}:${link.line} has a fragment on a non-Markdown target`)
    }
  }
  return true
}

function recursiveFiles(directory, extension) {
  return fs.readdirSync(directory, { withFileTypes: true }).flatMap(entry => {
    const entryPath = path.join(directory, entry.name)
    if (entry.isDirectory()) return recursiveFiles(entryPath, extension)
    return entryPath.endsWith(extension) ? [entryPath] : []
  })
}

function decodeHtmlCode(value) {
  return value
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&amp;', '&')
}

export function extractSiteCodeFences(root = repositoryRoot) {
  const fences = []
  const appRoot = path.join(root, 'docs', 'src', 'app')
  for (const file of recursiveFiles(appRoot, '.tsx')) {
    if (file.endsWith('.test.tsx')) continue
    const source = path.relative(root, file)
    const content = fs.readFileSync(file, 'utf8')
    for (const pre of content.matchAll(/<pre\b[^>]*>[\s\S]*?<\/pre>/g)) {
      const code = /<code\b([^>]*)>([\s\S]*?)<\/code>/.exec(pre[0])
      if (!code) fail(`${source} has a <pre> without one <code> example`)
      const language = /\bdata-language=["']([^"']+)["']/.exec(code[1])?.[1]?.toLowerCase()
      if (!language) fail(`${source} has an unclassified rendered code example`)
      const template = /^\s*\{`([\s\S]*?)`\}\s*$/.exec(code[2])
      if (template?.[1].includes('${')) fail(`${source} has a dynamic rendered code example`)
      const fenceContent = template?.[1] ?? decodeHtmlCode(code[2]).trim()
      const startLine = content.slice(0, pre.index).split('\n').length
      fences.push({
        source,
        language,
        content: fenceContent,
        sha256: sha256(fenceContent),
        startLine,
        endLine: startLine + pre[0].split('\n').length - 1,
      })
    }
  }
  return fences
}

export function validateLiteralSiteRoutes(root = repositoryRoot) {
  let count = 0
  const appRoot = path.join(root, 'docs', 'src', 'app')
  for (const file of recursiveFiles(appRoot, '.tsx')) {
    if (file.endsWith('.test.tsx')) continue
    const relative = path.relative(root, file)
    const content = fs.readFileSync(file, 'utf8')
    const expressions = [
      ...content.matchAll(/\bto\s*=\s*["']([^"']+)["']/g),
      ...content.matchAll(/\blink\s*:\s*["']([^"']+)["']/g),
      ...content.matchAll(/\bhref\s*=\s*["']([^"']+)["']/g),
    ]
    for (const match of expressions) {
      let destination = match[1]
      if (!destination.startsWith('/') && relative === 'docs/src/app/routes.tsx') destination = `/docs/${destination}`
      if (validateInternalLink({ source: relative, line: content.slice(0, match.index).split('\n').length, destination }, root)) count += 1
    }
  }
  return count
}

export function loadPolicy(root = repositoryRoot) {
  return JSON.parse(read('docs/documentation-validation.json', root))
}

function policyFile(root, relativePath, label) {
  if (typeof relativePath !== 'string' || relativePath.length === 0 || path.isAbsolute(relativePath) || relativePath.split(/[\\/]/).includes('..')) {
    fail(`${label} must be a repository-relative path`)
  }
  const lexicalRoot = path.resolve(root)
  const lexicalPath = path.resolve(lexicalRoot, relativePath)
  assertInside(lexicalRoot, lexicalPath, label)
  const canonicalRoot = fs.realpathSync(lexicalRoot)
  const canonicalPath = fs.realpathSync(lexicalPath)
  assertInside(canonicalRoot, canonicalPath, label)
  if (!fs.statSync(canonicalPath).isFile()) fail(`${label} is not a regular file`)
  return canonicalPath
}

export function validateFencePolicy(fences, root = repositoryRoot) {
  const policy = loadPolicy(root)
  if (policy.schemaVersion !== 1) fail('documentation policy schemaVersion must be 1')
  if (!Array.isArray(policy.executableZigExamples) || !Array.isArray(policy.cssModuleDocuments) || !Array.isArray(policy.nonExecutableFences)) {
    fail('documentation policy arrays are missing')
  }
  if (new Set(policy.executableZigExamples).size !== policy.executableZigExamples.length) fail('documentation policy repeats a Zig example')
  if (new Set(policy.cssModuleDocuments).size !== policy.cssModuleDocuments.length) fail('documentation policy repeats a CSS Modules document')
  const exampleContent = new Map(policy.executableZigExamples.map(relativePath => [
    relativePath,
    fs.readFileSync(policyFile(root, relativePath, `Zig example ${relativePath}`), 'utf8').trim(),
  ]))
  for (const relativePath of policy.cssModuleDocuments) policyFile(root, relativePath, `CSS Modules document ${relativePath}`)
  const usedExamples = new Set()
  const usedExceptions = new Set()
  for (const fence of fences) {
    if (!executableLanguages.has(fence.language) && !presentationLanguages.has(fence.language)) {
      fail(`${fence.source}:${fence.startLine} has unsupported fence language '${fence.language || '<empty>'}'`)
    }
    if (fence.content.trim().length === 0) fail(`${fence.source}:${fence.startLine} has an empty fence`)
    if (fence.language !== 'zig') continue
    const example = [...exampleContent].find(([, content]) => content === fence.content.trim())
    if (example) {
      usedExamples.add(example[0])
      continue
    }
    const exceptionIndex = policy.nonExecutableFences.findIndex(exception =>
      exception.path === fence.source && exception.language === fence.language && exception.sha256 === fence.sha256)
    if (exceptionIndex === -1) fail(`${fence.source}:${fence.startLine} is an uncompiled Zig example`)
    const exception = policy.nonExecutableFences[exceptionIndex]
    if (typeof exception.reason !== 'string' || exception.reason.length < 20) fail('non-executable fence needs a concrete reason')
    usedExceptions.add(exceptionIndex)
  }
  for (const relativePath of exampleContent.keys()) {
    if (!usedExamples.has(relativePath)) fail(`canonical Zig example is not published: ${relativePath}`)
  }
  for (const index of policy.nonExecutableFences.keys()) {
    if (!usedExceptions.has(index)) fail(`stale non-executable fence exception at index ${index}`)
  }
  for (const relativePath of policy.cssModuleDocuments) {
    if (!fences.some(fence => fence.source === relativePath && fence.language === 'css')) {
      fail(`CSS Modules document has no CSS example: ${relativePath}`)
    }
  }
  const build = read('build.zig', root)
  for (const relativePath of exampleContent.keys()) {
    if (!build.includes(relativePath)) fail(`canonical Zig example has no build step: ${relativePath}`)
  }
  if (!build.includes('test-documentation-examples')) fail('build.zig has no test-documentation-examples step')
  if (!/test_step\.dependOn\(documentation_examples_step\)/.test(build)) {
    fail('the main Zig test step does not run documentation examples')
  }
  return policy
}

function validateBash(fence) {
  run(process.env.BASH ?? 'bash', ['-n'], { input: fence.content }, `${fence.source}:${fence.startLine} bash syntax`)
}

function validateJson(fence) {
  try {
    JSON.parse(fence.content)
  } catch (error) {
    fail(`${fence.source}:${fence.startLine} JSON syntax: ${error.message}`)
  }
}

function executablePath(root, name) {
  const suffix = process.platform === 'win32' ? '.exe' : ''
  return path.join(root, 'zig-out', 'bin', `${name}${suffix}`)
}

function explicitExecutable(value, label) {
  if (typeof value !== 'string' || !path.isAbsolute(value) || value.includes('\0')) {
    fail(`${label} must be an explicit absolute executable path`)
  }
  try {
    const canonical = fs.realpathSync(value)
    if (!fs.statSync(canonical).isFile()) fail(`${label} is not a regular file`)
    fs.accessSync(canonical, fs.constants.X_OK)
    return canonical
  } catch (error) {
    fail(`${label} is not an accessible executable: ${error.message}`)
  }
}

function documentationNeovim(value) {
  const executable = explicitExecutable(value, 'NVIM')
  const versionOutput = run(executable, ['--version'], {}, 'Neovim version check').stdout
  const version = /^NVIM v(\d+)\.(\d+)\.(\d+)/.exec(versionOutput)
  if (!version) fail('NVIM returned an unrecognized version')
  const current = version.slice(1).map(Number)
  const minimum = [0, 11, 7]
  for (let index = 0; index < minimum.length; index += 1) {
    if (current[index] > minimum[index]) break
    if (current[index] < minimum[index]) fail('NVIM must be Neovim 0.11.7 or later')
  }
  return executable
}

function validateEmittedCss(css, label) {
  if (typeof css !== 'string' || css.length === 0) fail(`${label} emitted no CSS`)
  try {
    parseCss({
      filename: 'documentation-example.css',
      code: Buffer.from(css),
      errorRecovery: false,
      minify: false,
    })
  } catch (error) {
    fail(`${label} emitted invalid CSS: ${error.message}`)
  }
}

function validateStylesheet(fence, policy, root, tempRoot) {
  const syntax = fence.language
  const label = `${fence.source}:${fence.startLine} ${syntax.toUpperCase()} example`
  const input = path.join(tempRoot, `${sha256(`${fence.source}:${fence.startLine}`).slice(0, 16)}.${syntax}`)
  fs.writeFileSync(input, fence.content)
  if (syntax === 'css' && policy.cssModuleDocuments.includes(fence.source)) {
    const driver = executablePath(root, 'zigcss-css-modules-test-driver')
    const result = run(driver, [input, `documentation/${path.basename(input)}`, '--minify'], {}, `${fence.source}:${fence.startLine} CSS Modules example`)
    let output
    try {
      output = JSON.parse(result.stdout)
    } catch (error) {
      fail(`${fence.source}:${fence.startLine} CSS Modules driver returned invalid JSON: ${error.message}`)
    }
    if (typeof output.css !== 'string' || !Array.isArray(output.exports)) fail('CSS Modules driver returned an invalid contract')
    validateEmittedCss(output.css, `${fence.source}:${fence.startLine} CSS Modules example`)
    return
  }
  const compiler = executablePath(root, 'zigcss')
  const result = run(compiler, [input, '--syntax', syntax, '-o', '-'], {}, label)
  validateEmittedCss(result.stdout, label)
}

function validateLua(fence, nvim, tempRoot) {
  const source = path.join(tempRoot, `snippet-${fence.startLine}.lua`)
  fs.writeFileSync(source, fence.content)
  const harness = path.join(tempRoot, `lua-harness-${fence.startLine}.lua`)
  fs.writeFileSync(harness, [
    `local chunk, err = loadfile(${luaString(source)})`,
    'if not chunk then',
    '  io.stderr:write(err .. "\\n")',
    '  vim.cmd("cquit 1")',
    'end',
    'vim.cmd("qa")',
  ].join('\n'))
  run(nvim, ['--clean', '--headless', '-u', 'NONE', '-i', 'NONE', '-l', harness], {}, `${fence.source}:${fence.startLine} Lua syntax`)
}

function luaString(value) {
  return JSON.stringify(value).replaceAll('\\u2028', '\\u{2028}').replaceAll('\\u2029', '\\u{2029}')
}

function validateVim(fence, nvim, tempRoot) {
  const commands = fence.content.split(/\r?\n/).map(line => line.trim()).filter(Boolean).map(line => line.replace(/^:/, ''))
  const harness = path.join(tempRoot, `vim-snippet-${fence.startLine}.lua`)
  const source = [
    `local commands = { ${commands.map(luaString).join(', ')} }`,
    'for _, command in ipairs(commands) do',
    '  local ok, parsed = pcall(vim.api.nvim_parse_cmd, command, {})',
    '  if not ok or type(parsed) ~= "table" then',
    '    io.stderr:write(tostring(parsed) .. "\\n")',
    '    vim.cmd("cquit 1")',
    '  end',
    'end',
    'vim.cmd("qa")',
  ].join('\n')
  fs.writeFileSync(harness, source)
  run(nvim, ['--clean', '--headless', '-u', 'NONE', '-i', 'NONE', '-l', harness], {}, `${fence.source}:${fence.startLine} Vim command syntax`)
}

export function validateExecutableFences(fences, policy, root = repositoryRoot) {
  const needsNeovim = fences.some(fence => fence.language === 'lua' || fence.language === 'vim')
  const nvim = needsNeovim ? documentationNeovim(process.env.NVIM) : null
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-documentation-'))
  try {
    for (const fence of fences) {
      if (fence.language === 'bash') validateBash(fence)
      if (fence.language === 'json') validateJson(fence)
      if (fence.language === 'css' || fence.language === 'scss') {
        validateStylesheet(fence, policy, root, tempRoot)
      }
      if (fence.language === 'lua') validateLua(fence, nvim, tempRoot)
      if (fence.language === 'vim') validateVim(fence, nvim, tempRoot)
    }
  } finally {
    fs.rmSync(tempRoot, { recursive: true, force: true })
  }
}

export function validateRepositoryDocumentation(root = repositoryRoot, { execute = false } = {}) {
  const markdownFiles = trackedMarkdownFiles(root)
  const markdownFences = markdownFiles.flatMap(source => extractFences(read(source, root), source))
  const siteFences = extractSiteCodeFences(root)
  const fences = [...markdownFences, ...siteFences]
  const links = markdownFiles.flatMap(source => extractLinks(read(source, root), source))
  const internalLinks = links.filter(link => validateInternalLink(link, root)).length
  const literalRoutes = validateLiteralSiteRoutes(root)
  const policy = validateFencePolicy(fences, root)
  if (execute) validateExecutableFences(fences, policy, root)
  return {
    markdownFiles: markdownFiles.length,
    fences: fences.length,
    internalLinks,
    literalRoutes,
    executableFences: fences.filter(fence => executableLanguages.has(fence.language)).length,
    siteFences: siteFences.length,
  }
}

function main() {
  if (process.argv.length !== 3 || !['--check', '--execute'].includes(process.argv[2])) {
    throw new Error('usage: node scripts/validate-documentation.mjs --check|--execute')
  }
  const summary = validateRepositoryDocumentation(repositoryRoot, { execute: process.argv[2] === '--execute' })
  process.stdout.write(
    `Documentation verified: ${summary.markdownFiles} Markdown files, ${summary.fences} code/presentation fences (${summary.executableFences} executable; ${summary.siteFences} rendered by the site), ${summary.internalLinks} internal Markdown links, ${summary.literalRoutes} literal site routes.\n`,
  )
}

if (process.argv[1] !== undefined && path.resolve(process.argv[1]) === scriptPath) main()
