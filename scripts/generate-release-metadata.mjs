import crypto from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { parseReleaseVersion } from './validate-release-version.mjs'
import { actionPins, validateWorkflowSource } from './validate-workflows.mjs'

const scriptPath = fileURLToPath(import.meta.url)
export const repositoryRoot = path.resolve(path.dirname(scriptPath), '..')

export const provenancePredicateType = 'https://slsa.dev/provenance/v1'
export const spdxPredicateType = 'https://spdx.dev/Document/v2.3'

const maximumArchiveBytes = 512 * 1024 * 1024
const maximumBinaryBytes = 256 * 1024 * 1024
const maximumMetadataBytes = 16 * 1024 * 1024
const maximumSourceDateEpoch = 253_402_300_799

export const releaseTargets = Object.freeze([
  Object.freeze({ target: 'x86_64-linux', os: 'ubuntu-latest', arch: 'x86_64', binaryName: 'zigcss', archiveExtension: 'tar.gz' }),
  Object.freeze({ target: 'aarch64-linux', os: 'ubuntu-24.04-arm', arch: 'aarch64', binaryName: 'zigcss', archiveExtension: 'tar.gz' }),
  Object.freeze({ target: 'x86_64-macos', os: 'macos-15-intel', arch: 'x86_64', binaryName: 'zigcss', archiveExtension: 'tar.gz' }),
  Object.freeze({ target: 'aarch64-macos', os: 'macos-15', arch: 'aarch64', binaryName: 'zigcss', archiveExtension: 'tar.gz' }),
  Object.freeze({ target: 'x86_64-windows', os: 'windows-latest', arch: 'x86_64', binaryName: 'zigcss.exe', archiveExtension: 'zip' }),
])

function fail(message) {
  throw new Error(`release metadata integrity: ${message}`)
}

function same(left, right) {
  return JSON.stringify(left) === JSON.stringify(right)
}

function canonicalJson(value) {
  if (Array.isArray(value)) return value.map(canonicalJson)
  if (value !== null && typeof value === 'object') {
    return Object.fromEntries(Object.keys(value).sort(asciiCompare).map(key => [key, canonicalJson(value[key])]))
  }
  return value
}

function sameJson(left, right) {
  return JSON.stringify(canonicalJson(left)) === JSON.stringify(canonicalJson(right))
}

function asciiCompare(left, right) {
  return left < right ? -1 : left > right ? 1 : 0
}

function targetPolicy(target) {
  const policy = releaseTargets.find(candidate => candidate.target === target)
  if (policy === undefined) fail(`unsupported release target ${JSON.stringify(target)}`)
  return policy
}

export function releaseAssetsFor(version, target) {
  parseReleaseVersion(version, 'release metadata version')
  const policy = targetPolicy(target)
  const base = `zigcss-v${version}-${target}`
  return Object.freeze({
    archive: `${base}.${policy.archiveExtension}`,
    sbom: `${base}.spdx.json`,
    checksums: `${base}.sha256`,
    provenanceBundle: `${base}.provenance.sigstore.jsonl`,
    sbomBundle: `${base}.sbom.sigstore.jsonl`,
  })
}

function canonicalRoot(root) {
  try {
    return fs.realpathSync(root)
  } catch (error) {
    fail(`release root is unavailable: ${error.message}`)
  }
}

function confinedPath(root, relativePath, label) {
  if (typeof relativePath !== 'string' || relativePath.length === 0 || relativePath.includes('\0')) {
    fail(`${label} must be a nonempty relative path without NUL bytes`)
  }
  if (path.isAbsolute(relativePath)) fail(`${label} escapes the release root`)
  const candidate = path.resolve(root, relativePath)
  const relative = path.relative(root, candidate)
  if (relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    fail(`${label} escapes the release root`)
  }
  return candidate
}

function regularFile(root, relativePath, label, maximumBytes) {
  const candidate = confinedPath(root, relativePath, label)
  let stat
  try {
    stat = fs.lstatSync(candidate)
  } catch (error) {
    fail(`${label} is missing: ${error.message}`)
  }
  if (!stat.isFile() || stat.isSymbolicLink()) fail(`${label} must be a regular non-symlink file`)
  if (stat.size > maximumBytes) fail(`${label} exceeds ${maximumBytes} bytes`)
  const canonical = fs.realpathSync(candidate)
  const relative = path.relative(root, canonical)
  if (relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    fail(`${label} escapes the release root`)
  }
  return { path: canonical, size: stat.size }
}

function regularDirectory(root, relativePath, label) {
  const candidate = confinedPath(root, relativePath, label)
  let stat
  try {
    stat = fs.lstatSync(candidate)
  } catch (error) {
    fail(`${label} is missing: ${error.message}`)
  }
  if (!stat.isDirectory() || stat.isSymbolicLink()) fail(`${label} must be a regular non-symlink directory`)
  const canonical = fs.realpathSync(candidate)
  const relative = path.relative(root, canonical)
  if (relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    fail(`${label} escapes the release root`)
  }
  return canonical
}

function hashFile(filename, algorithms) {
  const hashes = new Map(algorithms.map(algorithm => [algorithm, crypto.createHash(algorithm)]))
  const descriptor = fs.openSync(filename, 'r')
  const buffer = Buffer.allocUnsafe(64 * 1024)
  try {
    while (true) {
      const length = fs.readSync(descriptor, buffer, 0, buffer.length, null)
      if (length === 0) break
      for (const hash of hashes.values()) hash.update(buffer.subarray(0, length))
    }
  } finally {
    fs.closeSync(descriptor)
  }
  return Object.fromEntries([...hashes].map(([algorithm, hash]) => [algorithm, hash.digest('hex')]))
}

function hashText(algorithm, text) {
  return crypto.createHash(algorithm).update(text, 'utf8').digest('hex')
}

function releaseCreationTime(epoch) {
  if (!Number.isSafeInteger(epoch) || epoch < 0 || epoch > maximumSourceDateEpoch) {
    fail(`source date epoch must be an integer from 0 through ${maximumSourceDateEpoch}`)
  }
  return new Date(epoch * 1000).toISOString().replace('.000Z', 'Z')
}

function normalizedOptions(options) {
  if (options === null || typeof options !== 'object') fail('release metadata options must be an object')
  const root = canonicalRoot(options.root)
  const parsedVersion = parseReleaseVersion(options.version, 'release metadata version')
  const policy = targetPolicy(options.target)
  const assets = releaseAssetsFor(parsedVersion.value, policy.target)
  if (!/^[0-9a-f]{40}$/.test(options.commit ?? '')) {
    fail('release commit must contain 40 lowercase hexadecimal characters')
  }
  const created = releaseCreationTime(options.sourceDateEpoch)
  if (options.outputDirectory !== 'release-assets') {
    fail('release metadata output directory must be release-assets')
  }

  const expectedArchive = `release-assets/${assets.archive}`
  const expectedBinary = `zig-out/bin/${policy.binaryName}`
  if (options.archive !== expectedArchive) fail(`release archive path must be ${expectedArchive}`)
  if (options.binary !== expectedBinary) fail(`release binary path must be ${expectedBinary}`)

  const outputDirectory = regularDirectory(root, options.outputDirectory, 'release metadata output directory')
  const archive = regularFile(root, options.archive, 'release archive', maximumArchiveBytes)
  const binary = regularFile(root, options.binary, 'release binary', maximumBinaryBytes)
  return {
    root,
    version: parsedVersion.value,
    target: policy.target,
    policy,
    assets,
    commit: options.commit,
    created,
    outputDirectory,
    archive,
    binary,
  }
}

export function buildReleaseMetadata(options) {
  const normalized = normalizedOptions(options)
  const archiveHashes = hashFile(normalized.archive.path, ['sha256'])
  const binaryHashes = hashFile(normalized.binary.path, ['sha1', 'sha256'])
  const packageVerificationCode = hashText('sha1', binaryHashes.sha1)
  const binarySpdxName = `./${normalized.policy.binaryName}`

  const sbom = {
    spdxVersion: 'SPDX-2.3',
    dataLicense: 'CC0-1.0',
    SPDXID: 'SPDXRef-DOCUMENT',
    name: `${normalized.assets.sbom} for ${normalized.target}`,
    documentNamespace: `https://github.com/vyakymenko/zigcss/spdx/${normalized.version}/${normalized.target}/${normalized.commit}`,
    creationInfo: {
      created: normalized.created,
      creators: ['Tool: zigcss-release-metadata/1'],
    },
    documentDescribes: ['SPDXRef-Package-zigcss'],
    comment: `Scope: the single ${normalized.policy.binaryName} executable contained in ${normalized.assets.archive}; source and build-tool files are not runtime contents of this archive.`,
    packages: [
      {
        SPDXID: 'SPDXRef-Package-zigcss',
        name: 'zigcss',
        versionInfo: normalized.version,
        packageFileName: normalized.assets.archive,
        supplier: 'NOASSERTION',
        downloadLocation: 'NOASSERTION',
        filesAnalyzed: true,
        packageVerificationCode: {
          packageVerificationCodeValue: packageVerificationCode,
        },
        checksums: [
          { algorithm: 'SHA256', checksumValue: archiveHashes.sha256 },
        ],
        homepage: 'https://github.com/vyakymenko/zigcss',
        sourceInfo: `Built from git+https://github.com/vyakymenko/zigcss.git@${normalized.commit} for ${normalized.target}.`,
        licenseConcluded: 'NOASSERTION',
        licenseInfoFromFiles: ['NOASSERTION'],
        licenseDeclared: 'MIT',
        copyrightText: 'NOASSERTION',
        summary: 'Experimental ZigCSS recovery compiler release archive.',
        primaryPackagePurpose: 'APPLICATION',
        externalRefs: [
          {
            referenceCategory: 'PACKAGE-MANAGER',
            referenceType: 'purl',
            referenceLocator: `pkg:github/vyakymenko/zigcss@${normalized.version}`,
          },
        ],
        hasFiles: ['SPDXRef-File-zigcss'],
      },
    ],
    files: [
      {
        SPDXID: 'SPDXRef-File-zigcss',
        fileName: binarySpdxName,
        checksums: [
          { algorithm: 'SHA256', checksumValue: binaryHashes.sha256 },
          { algorithm: 'SHA1', checksumValue: binaryHashes.sha1 },
        ],
        fileTypes: ['BINARY'],
        licenseConcluded: 'NOASSERTION',
        licenseInfoInFiles: ['NOASSERTION'],
        copyrightText: 'NOASSERTION',
      },
    ],
    relationships: [
      {
        spdxElementId: 'SPDXRef-DOCUMENT',
        relationshipType: 'DESCRIBES',
        relatedSpdxElement: 'SPDXRef-Package-zigcss',
      },
      {
        spdxElementId: 'SPDXRef-Package-zigcss',
        relationshipType: 'CONTAINS',
        relatedSpdxElement: 'SPDXRef-File-zigcss',
      },
    ],
  }

  const sbomText = `${JSON.stringify(sbom, null, 2)}\n`
  if (Buffer.byteLength(sbomText) > maximumMetadataBytes) fail('generated SPDX SBOM exceeds the metadata limit')
  const sbomSha256 = hashText('sha256', sbomText)
  const checksumsText = [
    `${archiveHashes.sha256}  ${normalized.assets.archive}`,
    `${sbomSha256}  ${normalized.assets.sbom}`,
    '',
  ].join('\n')
  const checksumsSha256 = hashText('sha256', checksumsText)

  return {
    assets: normalized.assets,
    digests: {
      archiveSha256: archiveHashes.sha256,
      binarySha256: binaryHashes.sha256,
      binarySha1: binaryHashes.sha1,
      sbomSha256,
      checksumsSha256,
    },
    sbom,
    sbomText,
    checksumsText,
  }
}

function outputFile(options, asset, label) {
  const root = canonicalRoot(options.root)
  const directory = regularDirectory(root, options.outputDirectory, 'release metadata output directory')
  const candidate = path.resolve(directory, asset)
  const relative = path.relative(directory, candidate)
  if (relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    fail(`${label} escapes the metadata output directory`)
  }
  return candidate
}

function atomicWriteNewOrIdentical(filename, content, label) {
  try {
    const stat = fs.lstatSync(filename)
    if (!stat.isFile() || stat.isSymbolicLink()) fail(`${label} must be a regular non-symlink file`)
    if (stat.size > maximumMetadataBytes) fail(`${label} exceeds the metadata limit`)
    if (fs.readFileSync(filename, 'utf8') === content) return
    fail(`${label} already exists with different content`)
  } catch (error) {
    if (error.code !== 'ENOENT') throw error
  }

  const temporary = `${filename}.tmp-${process.pid}-${crypto.randomBytes(6).toString('hex')}`
  try {
    fs.writeFileSync(temporary, content, { encoding: 'utf8', flag: 'wx', mode: 0o644 })
    fs.renameSync(temporary, filename)
  } finally {
    fs.rmSync(temporary, { force: true })
  }
}

export function writeReleaseMetadata(options) {
  const result = buildReleaseMetadata(options)
  atomicWriteNewOrIdentical(
    outputFile(options, result.assets.sbom, 'SPDX SBOM'),
    result.sbomText,
    'SPDX SBOM',
  )
  atomicWriteNewOrIdentical(
    outputFile(options, result.assets.checksums, 'SHA-256 manifest'),
    result.checksumsText,
    'SHA-256 manifest',
  )
  return result
}

function readMetadataFile(options, asset, label) {
  const relative = `${options.outputDirectory}/${asset}`
  return fs.readFileSync(regularFile(canonicalRoot(options.root), relative, label, maximumMetadataBytes).path, 'utf8')
}

export function checkReleaseMetadata(options) {
  const result = buildReleaseMetadata(options)
  const actualSbom = readMetadataFile(options, result.assets.sbom, 'SPDX SBOM')
  const actualChecksums = readMetadataFile(options, result.assets.checksums, 'SHA-256 manifest')
  if (actualSbom !== result.sbomText) fail(`release metadata drift in ${result.assets.sbom}`)
  if (actualChecksums !== result.checksumsText) fail(`release metadata drift in ${result.assets.checksums}`)
  return result
}

function decodeBase64(value, label) {
  if (typeof value !== 'string' || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value)) {
    fail(`${label} is not canonical base64`)
  }
  const bytes = Buffer.from(value, 'base64')
  if (bytes.length === 0 || bytes.toString('base64') !== value) fail(`${label} is empty or noncanonical`)
  return bytes
}

function validateJsonBounds(value, label) {
  const maximumDepth = 64
  const maximumNodes = 100_000
  const stack = [{ value, depth: 0 }]
  let nodes = 0
  while (stack.length !== 0) {
    const current = stack.pop()
    nodes += 1
    if (nodes > maximumNodes) fail(`${label} exceeds ${maximumNodes} JSON nodes`)
    if (current.depth > maximumDepth) fail(`${label} exceeds JSON depth ${maximumDepth}`)
    if (current.value === null || typeof current.value !== 'object') continue
    const children = Array.isArray(current.value) ? current.value : Object.values(current.value)
    for (const child of children) stack.push({ value: child, depth: current.depth + 1 })
  }
}

function expectedSubjects(result, kind) {
  const subjects = [
    { name: result.assets.archive, digest: { sha256: result.digests.archiveSha256 } },
  ]
  if (kind === 'provenance') {
    subjects.push(
      { name: result.assets.sbom, digest: { sha256: result.digests.sbomSha256 } },
      { name: result.assets.checksums, digest: { sha256: result.digests.checksumsSha256 } },
    )
  }
  return subjects.sort((left, right) => asciiCompare(left.name, right.name))
}

function parseAttestationBundle(text, label, predicateType, expected, expectedPredicate) {
  const lines = text.split(/\r?\n/).filter(line => line.length > 0)
  if (lines.length !== 1 || !text.endsWith('\n')) fail(`${label} must contain exactly one newline-terminated Sigstore JSON bundle`)
  let bundle
  try {
    bundle = JSON.parse(lines[0])
  } catch (error) {
    fail(`${label} is not valid JSON: ${error.message}`)
  }
  validateJsonBounds(bundle, label)
  if (bundle.mediaType !== 'application/vnd.dev.sigstore.bundle.v0.3+json') {
    fail(`${label} has an unsupported Sigstore bundle media type`)
  }
  if (bundle.verificationMaterial === null || typeof bundle.verificationMaterial !== 'object') {
    fail(`${label} has no verification material`)
  }
  const certificate = bundle.verificationMaterial.certificate?.rawBytes
  const chain = bundle.verificationMaterial.x509CertificateChain?.certificates
  if (certificate === undefined && !Array.isArray(chain)) fail(`${label} has no signing certificate material`)
  if (certificate !== undefined) decodeBase64(certificate, `${label} certificate`)
  if (Array.isArray(chain)) {
    if (chain.length === 0) fail(`${label} has an empty certificate chain`)
    for (const [index, item] of chain.entries()) decodeBase64(item.rawBytes, `${label} certificate ${index}`)
  }

  const envelope = bundle.dsseEnvelope
  if (envelope?.payloadType !== 'application/vnd.in-toto+json') fail(`${label} is not an in-toto DSSE envelope`)
  if (!Array.isArray(envelope.signatures) || envelope.signatures.length === 0) fail(`${label} has no signature`)
  for (const [index, signature] of envelope.signatures.entries()) {
    decodeBase64(signature.sig, `${label} signature ${index}`)
  }

  let statement
  try {
    statement = JSON.parse(decodeBase64(envelope.payload, `${label} payload`).toString('utf8'))
  } catch (error) {
    fail(`${label} payload is not a valid in-toto statement: ${error.message}`)
  }
  validateJsonBounds(statement, `${label} statement`)
  if (statement._type !== 'https://in-toto.io/Statement/v1') fail(`${label} has an unsupported statement type`)
  if (statement.predicateType !== predicateType) fail(`${label} has an unexpected predicate type`)
  if (!Array.isArray(statement.subject)) fail(`${label} has no subject list`)
  const subjects = statement.subject.map(subject => ({ name: subject.name, digest: subject.digest }))
    .sort((left, right) => asciiCompare(left.name, right.name))
  if (!same(subjects, expected)) fail(`${label} attestation subjects do not match release metadata`)
  if (expectedPredicate !== undefined && !sameJson(statement.predicate, expectedPredicate)) {
    fail(`${label} predicate does not match the generated SPDX SBOM`)
  }
  if (predicateType === provenancePredicateType) {
    if (statement.predicate === null || typeof statement.predicate !== 'object' ||
        !Object.hasOwn(statement.predicate, 'buildDefinition') || !Object.hasOwn(statement.predicate, 'runDetails')) {
      fail(`${label} does not contain SLSA v1 build provenance`)
    }
  }
  return subjects.length
}

export function checkReleaseAttestationBundles(options) {
  const result = checkReleaseMetadata(options)
  const provenance = readMetadataFile(options, result.assets.provenanceBundle, 'provenance Sigstore bundle')
  const sbom = readMetadataFile(options, result.assets.sbomBundle, 'SBOM Sigstore bundle')
  const counts = {
    provenanceSubjects: parseAttestationBundle(
      provenance,
      'provenance Sigstore bundle',
      provenancePredicateType,
      expectedSubjects(result, 'provenance'),
    ),
    sbomSubjects: parseAttestationBundle(
      sbom,
      'SBOM Sigstore bundle',
      spdxPredicateType,
      expectedSubjects(result, 'sbom'),
      result.sbom,
    ),
  }
  const directory = regularDirectory(canonicalRoot(options.root), options.outputDirectory, 'release metadata output directory')
  const entries = fs.readdirSync(directory, { withFileTypes: true })
  const actual = entries.map(entry => entry.name).sort(asciiCompare)
  const expected = Object.values(result.assets).sort(asciiCompare)
  if (!same(actual, expected) || entries.some(entry => !entry.isFile() || entry.isSymbolicLink())) {
    fail(`release asset inventory must contain exactly ${expected.join(', ')}`)
  }
  return counts
}

function expectLiteralCount(source, literal, count, label) {
  const actual = source.split(literal).length - 1
  if (actual !== count) fail(`${label} must occur ${count} times, received ${actual}`)
}

function expectOrdered(source, labels) {
  let cursor = -1
  for (const label of labels) {
    const index = source.indexOf(label, cursor + 1)
    if (index === -1 || index <= cursor) fail(`release workflow is missing or reorders ${label}`)
    cursor = index
  }
}

function workflowTargets(source) {
  const expression = /          - os: ([^\n]+)\n            arch: ([^\n]+)\n            target: ([^\n]+)\n            archive-extension: ([^\n]+)\n            zig-version: ([^\n]+)\n            binary-name: ([^\n]+)/g
  return [...source.matchAll(expression)].map(match => ({
    os: match[1],
    arch: match[2],
    target: match[3],
    archiveExtension: match[4],
    zigVersion: match[5],
    binaryName: match[6],
  }))
}

export function validateReleaseWorkflowSource(source) {
  if (typeof source !== 'string' || source.length > 256 * 1024) fail('release workflow is missing or oversized')
  if (source.includes('continue-on-error')) fail('release workflow must fail closed without continue-on-error')
  const permissions = '    permissions:\n      attestations: write\n      contents: read\n      id-token: write'
  expectLiteralCount(source, permissions, 1, 'release attestation permissions')

  const actualTargets = workflowTargets(source)
  const expectedTargets = releaseTargets.map(target => ({
    os: target.os,
    arch: target.arch,
    target: target.target,
    archiveExtension: target.archiveExtension,
    zigVersion: '0.15.2',
    binaryName: target.binaryName,
  }))
  if (!same(actualTargets, expectedTargets)) fail('release workflow target/archive inventory changed')

  const attest = actionPins['actions/attest']
  if (attest === undefined) fail('actions/attest has no reviewed immutable pin')
  expectLiteralCount(source, `uses: actions/attest@${attest.sha} # ${attest.version}`, 2, 'pinned attestation action')
  expectLiteralCount(source, '        sbom-path: release-assets/${{ env.RELEASE_SBOM }}', 1, 'signed SBOM attestation')
  expectLiteralCount(source, 'gh attestation verify', 2, 'cryptographic verification')
  expectLiteralCount(source, '--predicate-type https://spdx.dev/Document/v2.3', 1, 'SPDX attestation verification')
  expectLiteralCount(source, '          path: release-assets/*', 1, 'closed release asset upload')
  expectLiteralCount(source, '          if-no-files-found: error', 1, 'fail-closed release asset upload')
  expectLiteralCount(source, '          retention-days: 7', 1, 'bounded release artifact retention')
  expectLiteralCount(source, '${{ steps.provenance.outputs.bundle-path }}', 1, 'preserved provenance bundle')
  expectLiteralCount(source, '${{ steps.sbom-attestation.outputs.bundle-path }}', 1, 'preserved SBOM bundle')
  expectLiteralCount(source, 'node scripts/generate-release-metadata.mjs --write', 1, 'release metadata generation')
  expectLiteralCount(source, 'node scripts/generate-release-metadata.mjs --check \\\n', 1, 'release metadata verification')
  expectLiteralCount(source, 'node scripts/generate-release-metadata.mjs --check-bundles', 1, 'local attestation binding check')
  expectLiteralCount(source, 'npm run check:release-metadata', 1, 'release workflow self-check')
  expectLiteralCount(source, '- name: Smoke Native Archive and npm Installation', 1, 'native release smoke step')
  expectLiteralCount(source, 'node scripts/smoke-release-artifact.mjs \\', 1, 'native release smoke command')

  expectOrdered(source, [
    '- name: Verify synchronized release version',
    '- name: Build Release Binary',
    '- name: Verify Target Architecture',
    '- name: Plan Release Assets',
    '- name: Create Archive',
    '- name: Generate SHA-256 Manifest and SPDX SBOM',
    '- name: Verify Release Metadata',
    '- name: Smoke Native Archive and npm Installation',
    '- name: Attest Release Provenance',
    '- name: Attest Release SBOM',
    '- name: Preserve Signed Attestation Bundles',
    '- name: Verify Signed Attestation Bundles',
    '- name: Upload Release Assets',
    '  create-release:',
    '    needs: release',
    '- name: Create Release',
  ])

  validateWorkflowSource('release.yml', source)
  return {
    targets: actualTargets.length,
    assetsPerTarget: 5,
    nativeSmokes: 1,
    attestations: 2,
    signatureVerifications: 2,
  }
}

export function validateReleaseBuildGate(source) {
  if (typeof source !== 'string' || source.length > 256 * 1024) fail('build workflow is missing or oversized')
  expectLiteralCount(source, '- name: Verify release artifact metadata policy', 1, 'release metadata CI step')
  expectLiteralCount(
    source,
    'npm run test:release-metadata && npm run check:release-metadata',
    1,
    'release metadata CI command',
  )
  expectLiteralCount(source, '- name: Test release consumer paths', 1, 'release consumer CI step')
  expectLiteralCount(source, 'npm run test:release-smoke', 1, 'release smoke policy CI command')
  expectLiteralCount(source, 'npm run test:release-consumers', 1, 'release consumer CI command')
  expectLiteralCount(source, 'npm run test:release-container', 1, 'release container CI command')
  expectLiteralCount(source, 'npm run test:release-homebrew', 1, 'Homebrew release CI command')
  expectOrdered(source, [
    '- name: Setup Node.js',
    '- name: Verify workflow security policy',
    '- name: Verify release version policy',
    '- name: Verify release artifact metadata policy',
    '- name: Test release consumer paths',
    '- name: Install independent validator',
  ])
  return true
}

export function validateReleaseWorkflow(root = repositoryRoot) {
  const canonical = canonicalRoot(root)
  const workflow = regularFile(canonical, '.github/workflows/release.yml', 'release workflow', 256 * 1024)
  const buildWorkflow = regularFile(canonical, '.github/workflows/build.yml', 'build workflow', 256 * 1024)
  validateReleaseBuildGate(fs.readFileSync(buildWorkflow.path, 'utf8'))
  return validateReleaseWorkflowSource(fs.readFileSync(workflow.path, 'utf8'))
}

function parseCliOptions(args) {
  const mode = args[0]
  if (!['--write', '--check', '--check-bundles'].includes(mode)) fail('unknown release metadata mode')
  const allowed = new Set([
    '--archive',
    '--binary',
    '--output-directory',
    '--target',
    '--version',
    '--commit',
    '--source-date-epoch',
  ])
  const values = {}
  for (let index = 1; index < args.length; index += 2) {
    const name = args[index]
    const value = args[index + 1]
    if (!allowed.has(name) || value === undefined || Object.hasOwn(values, name)) fail(`invalid or repeated option ${name}`)
    values[name] = value
  }
  if (Object.keys(values).length !== allowed.size) fail('release metadata command requires every closed option')
  if (!/^(?:0|[1-9]\d*)$/.test(values['--source-date-epoch'])) fail('source date epoch must be a decimal integer')
  return {
    mode,
    options: {
      root: repositoryRoot,
      archive: values['--archive'],
      binary: values['--binary'],
      outputDirectory: values['--output-directory'],
      target: values['--target'],
      version: values['--version'],
      commit: values['--commit'],
      sourceDateEpoch: Number(values['--source-date-epoch']),
    },
  }
}

function main() {
  const args = process.argv.slice(2)
  if (same(args, ['--check-workflow'])) {
    const result = validateReleaseWorkflow()
    process.stdout.write(
      `Release workflow metadata verified: ${result.targets} native-smoked targets, ${result.assetsPerTarget} assets each, ${result.attestations} signed attestations, ${result.signatureVerifications} cryptographic verifications.\n`,
    )
    return
  }

  const { mode, options } = parseCliOptions(args)
  const canonicalVersion = fs.readFileSync(path.join(repositoryRoot, 'VERSION'), 'utf8').trim()
  if (options.version !== canonicalVersion) fail(`release version must be ${canonicalVersion}`)
  if (mode === '--write') {
    const result = writeReleaseMetadata(options)
    process.stdout.write(`Generated ${result.assets.sbom} and ${result.assets.checksums}.\n`)
  } else if (mode === '--check') {
    const result = checkReleaseMetadata(options)
    process.stdout.write(`Verified ${result.assets.sbom} and ${result.assets.checksums}.\n`)
  } else {
    const result = checkReleaseAttestationBundles(options)
    process.stdout.write(
      `Verified local attestation binding: ${result.provenanceSubjects} provenance subjects and ${result.sbomSubjects} SBOM subject.\n`,
    )
  }
}

if (process.argv[1] !== undefined && path.resolve(process.argv[1]) === scriptPath) main()
