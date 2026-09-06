import assert from 'node:assert/strict'
import crypto from 'node:crypto'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawnSync } from 'node:child_process'
import test from 'node:test'
import { fileURLToPath } from 'node:url'
import { releaseAssetsFor, releaseTargets } from './generate-release-metadata.mjs'
import { verifyGitHubReleaseAssets } from './verify-github-release-assets.mjs'

const version = '0.7.0-rc.1'
const stableVersion = '0.7.0'
const commit = 'a'.repeat(40)
const repository = 'vyakymenko/zigcss'
const releaseId = 91
const script = fileURLToPath(new URL('./verify-github-release-assets.mjs', import.meta.url))

function sha256(bytes) {
  return crypto.createHash('sha256').update(bytes).digest('hex')
}

function releaseAttestationStatement(selectedVersion, assets) {
  const tag = `v${selectedVersion}`
  const purl = `pkg:github/${repository}@${tag}`
  return {
    _type: 'https://in-toto.io/Statement/v1',
    subject: [
      { uri: purl, digest: { sha1: commit } },
      ...assets.map(asset => ({
        name: asset.name,
        digest: { sha256: asset.digest.slice('sha256:'.length) },
      })),
    ],
    predicateType: 'https://in-toto.io/attestation/release/v0.2',
    predicate: {
      databaseId: String(releaseId),
      ownerId: '1',
      packageId: '2',
      purl,
      repository,
      repositoryId: '2',
      tag,
    },
  }
}

function releaseAttestationOutput(statement, verifiedStatement = statement) {
  return {
    attestation: {
      bundle: {
        mediaType: 'application/vnd.dev.sigstore.bundle.v0.3+json',
        verificationMaterial: {},
        dsseEnvelope: {
          payload: Buffer.from(JSON.stringify(statement), 'utf8').toString('base64'),
          payloadType: 'application/vnd.in-toto+json',
          signatures: [{ sig: Buffer.from('verified-signature', 'utf8').toString('base64') }],
        },
      },
      bundle_url: '',
      initiator: '',
    },
    verificationResult: {
      mediaType: 'application/vnd.dev.sigstore.verificationresult+json;version=0.1',
      signature: {
        certificate: {
          certificateIssuer: 'CN=fixture',
          subjectAlternativeName: 'https://dotcom.releases.github.com',
        },
      },
      statement: verifiedStatement,
      verifiedTimestamps: [],
    },
  }
}

function createFixture(selectedVersion = version) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-github-release-'))
  const assetsDirectory = path.join(root, 'artifacts')
  fs.mkdirSync(assetsDirectory)
  const assets = []
  let counter = 0
  for (const target of releaseTargets) {
    const targetDirectory = path.join(assetsDirectory, `zigcss-${target.target}`)
    fs.mkdirSync(targetDirectory)
    for (const name of Object.values(releaseAssetsFor(selectedVersion, target.target))) {
      counter += 1
      const bytes = Buffer.from(`fixture ${counter}: ${name}\n`)
      const filename = path.join(targetDirectory, name)
      fs.writeFileSync(filename, bytes)
      assets.push({ name, state: 'uploaded', size: bytes.length, digest: `sha256:${sha256(bytes)}` })
    }
  }
  assert.equal(assets.length, 25)

  const releaseJson = path.join(root, 'release.json')
  const latestJson = path.join(root, 'latest.json')
  const attestationJson = path.join(root, 'attestation.json')
  const tagRefJson = path.join(root, 'tag-ref.json')
  const githubOutput = path.join(root, 'github-output.txt')
  const release = {
    tag_name: `v${selectedVersion}`,
    target_commitish: 'main',
    prerelease: selectedVersion.includes('-'),
    draft: true,
    immutable: false,
    assets: [...assets].reverse(),
  }
  fs.writeFileSync(releaseJson, `${JSON.stringify(release)}\n`)
  fs.writeFileSync(latestJson, `${JSON.stringify({
    id: releaseId,
    tag_name: `v${selectedVersion}`,
    draft: false,
    prerelease: false,
    immutable: true,
  })}\n`)
  const attestationStatement = releaseAttestationStatement(selectedVersion, assets)
  fs.writeFileSync(attestationJson, `${JSON.stringify(releaseAttestationOutput(attestationStatement))}\n`)
  fs.writeFileSync(githubOutput, '')
  fs.writeFileSync(tagRefJson, `${JSON.stringify({
    ref: `refs/tags/v${selectedVersion}`,
    object: { type: 'commit', sha: commit },
  })}\n`)
  return {
    root,
    assetsDirectory,
    releaseJson,
    latestJson,
    attestationJson,
    attestationStatement,
    tagRefJson,
    githubOutput,
    release,
    options: { releaseJson, assetsDirectory, version: selectedVersion, phase: 'draft' },
    publishedOptions: {
      releaseJson,
      assetsDirectory,
      tagRefJson,
      version: selectedVersion,
      commit,
      phase: 'published',
    },
    tagOptions: { tagRefJson, version: selectedVersion, commit, phase: 'tag' },
    attestationOptions: {
      attestationJson,
      assetsDirectory,
      repository,
      releaseId: String(releaseId),
      version: selectedVersion,
      commit,
      phase: 'attestation',
    },
    latestOptions: {
      releaseJson: latestJson,
      releaseId: String(releaseId),
      version: selectedVersion,
      phase: 'latest',
    },
  }
}

function writeRelease(fixture, release) {
  fs.writeFileSync(fixture.releaseJson, `${JSON.stringify(release)}\n`)
}

function writeTagRef(fixture, tagRef) {
  fs.writeFileSync(fixture.tagRefJson, `${JSON.stringify(tagRef)}\n`)
}

function writeAttestation(fixture, statement, verifiedStatement = statement) {
  fs.writeFileSync(
    fixture.attestationJson,
    `${JSON.stringify(releaseAttestationOutput(statement, verifiedStatement))}\n`,
  )
}

function expectedFile(fixture, name) {
  for (const target of releaseTargets) {
    const candidate = path.join(fixture.assetsDirectory, `zigcss-${target.target}`, name)
    if (fs.existsSync(candidate)) return candidate
  }
  throw new Error(`fixture asset not found: ${name}`)
}

test('accepts exact draft and immutable published inventories with deterministic summary', t => {
  const fixture = createFixture()
  t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }))

  const draft = verifyGitHubReleaseAssets(fixture.options)
  assert.deepEqual(draft, {
    version,
    tag: `v${version}`,
    phase: 'draft',
    prerelease: true,
    immutable: false,
    assetCount: 25,
    totalBytes: fixture.release.assets.reduce((total, asset) => total + asset.size, 0),
    inventorySha256: draft.inventorySha256,
  })
  assert.match(draft.inventorySha256, /^[0-9a-f]{64}$/)

  const local = verifyGitHubReleaseAssets({
    assetsDirectory: fixture.assetsDirectory,
    version,
    phase: 'local',
  })
  assert.deepEqual(local, {
    version,
    phase: 'local',
    assetCount: 25,
    totalBytes: draft.totalBytes,
    inventorySha256: draft.inventorySha256,
  })

  writeRelease(fixture, { ...fixture.release, draft: false, immutable: true })
  const published = verifyGitHubReleaseAssets(fixture.publishedOptions)
  assert.equal(published.inventorySha256, draft.inventorySha256)
  assert.equal(published.immutable, true)
  assert.equal(published.commit, commit)

  assert.deepEqual(verifyGitHubReleaseAssets(fixture.tagOptions), {
    version,
    tag: `v${version}`,
    ref: `refs/tags/v${version}`,
    commit,
    phase: 'tag',
    lightweight: true,
  })

  const stable = createFixture(stableVersion)
  t.after(() => fs.rmSync(stable.root, { recursive: true, force: true }))
  writeRelease(stable, { ...stable.release, prerelease: false, draft: false, immutable: true })
  assert.equal(
    verifyGitHubReleaseAssets(stable.publishedOptions).prerelease,
    false,
  )
})

test('accepts one signature-verified release attestation with the exact tag and 25 asset subjects', t => {
  const fixture = createFixture()
  t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }))

  const result = verifyGitHubReleaseAssets(fixture.attestationOptions)
  assert.deepEqual(result, {
    version,
    phase: 'attestation',
    assetCount: 25,
    totalBytes: fixture.release.assets.reduce((total, asset) => total + asset.size, 0),
    inventorySha256: result.inventorySha256,
    repository,
    tag: `v${version}`,
    commit,
    releaseId,
    predicateType: 'https://in-toto.io/attestation/release/v0.2',
    attestedAssetCount: 25,
  })
  assert.match(result.inventorySha256, /^[0-9a-f]{64}$/u)
})

test('release attestation rejects identity, predicate, subject, digest, and verified-payload drift', async t => {
  const statementCases = [
    ['repository', statement => { statement.predicate.repository = 'other/zigcss' }, /repository must be/],
    ['purl', statement => { statement.predicate.purl = 'pkg:github/other/zigcss@v0.7.0-rc.1' }, /purl must be/],
    ['tag', statement => { statement.predicate.tag = 'v9.9.9' }, /tag must be/],
    ['release ID', statement => { statement.predicate.databaseId = '92' }, /databaseId must be/],
    ['predicate type', statement => { statement.predicateType = 'https://example.invalid/release' }, /predicateType must be/],
    ['statement type', statement => { statement._type = 'https://in-toto.io/Statement/v0.1' }, /unsupported _type/],
    ['owner ID', statement => { statement.predicate.ownerId = '01' }, /ownerId must be a canonical positive decimal integer/],
    ['repository ID binding', statement => { statement.predicate.packageId = '3' }, /packageId must equal repositoryId/],
    ['tag commit', statement => { statement.subject[0].digest.sha1 = 'b'.repeat(40) }, /tag subject must bind exact commit/],
    ['asset digest', statement => { statement.subject[1].digest.sha256 = '0'.repeat(64) }, /does not match local SHA-256/],
    ['missing asset', statement => { statement.subject.pop() }, /exactly one tag and 25 asset subjects/],
    ['extra asset', statement => { statement.subject.push({ name: 'extra', digest: { sha256: '0'.repeat(64) } }) }, /exactly one tag and 25 asset subjects/],
    ['duplicate asset', statement => { statement.subject[1] = structuredClone(statement.subject[2]) }, /duplicate release attestation asset subject/],
    ['extra digest', statement => { statement.subject[1].digest.sha512 = '0'.repeat(128) }, /must contain exactly sha256/],
  ]

  for (const [name, mutate, expression] of statementCases) {
    await t.test(name, t => {
      const fixture = createFixture()
      t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }))
      const statement = structuredClone(fixture.attestationStatement)
      mutate(statement)
      writeAttestation(fixture, statement)
      assert.throws(() => verifyGitHubReleaseAssets(fixture.attestationOptions), expression)
    })
  }

  await t.test('verified statement differs from DSSE payload', t => {
    const fixture = createFixture()
    t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }))
    const verified = structuredClone(fixture.attestationStatement)
    verified.predicate.tag = 'v9.9.9'
    writeAttestation(fixture, fixture.attestationStatement, verified)
    assert.throws(
      () => verifyGitHubReleaseAssets(fixture.attestationOptions),
      /DSSE payload must equal the signature-verified statement/,
    )
  })

  for (const [name, mutate, expression] of [
    ['bundle media type', output => { output.attestation.bundle.mediaType = 'application/json' }, /bundle has an unsupported mediaType/],
    ['payload type', output => { output.attestation.bundle.dsseEnvelope.payloadType = 'text/plain' }, /payloadType/],
    ['verification result media type', output => { output.verificationResult.mediaType = 'application/json' }, /verification result has an unsupported mediaType/],
    ['missing signature', output => { output.attestation.bundle.dsseEnvelope.signatures = [] }, /exactly one signature/],
    ['noncanonical signature base64', output => { output.attestation.bundle.dsseEnvelope.signatures[0].sig = '!!!!' }, /signature must be canonical bounded base64/],
    ['noncanonical payload base64', output => { output.attestation.bundle.dsseEnvelope.payload = '!!!!' }, /canonical bounded base64/],
    ['oversized payload', output => { output.attestation.bundle.dsseEnvelope.payload = Buffer.alloc((512 * 1024) + 1).toString('base64') }, /payload must decode to 1 through 524288 bytes/],
    ['wrong verified signer', output => { output.verificationResult.signature.certificate.subjectAlternativeName = 'https://example.invalid' }, /verified signer must be GitHub Releases/],
  ]) {
    await t.test(name, t => {
      const fixture = createFixture()
      t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }))
      const output = releaseAttestationOutput(fixture.attestationStatement)
      mutate(output)
      fs.writeFileSync(fixture.attestationJson, `${JSON.stringify(output)}\n`)
      assert.throws(() => verifyGitHubReleaseAssets(fixture.attestationOptions), expression)
    })
  }

  await t.test('oversized attestation JSON', t => {
    const fixture = createFixture()
    t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }))
    fs.truncateSync(fixture.attestationJson, (2 * 1024 * 1024) + 1)
    assert.throws(
      () => verifyGitHubReleaseAssets(fixture.attestationOptions),
      /release attestation JSON must contain 1 through 2097152 bytes/,
    )
  })
})

test('latest phase accepts only the exact immutable stable release ID and tag', async t => {
  const stable = createFixture(stableVersion)
  t.after(() => fs.rmSync(stable.root, { recursive: true, force: true }))
  assert.deepEqual(verifyGitHubReleaseAssets(stable.latestOptions), {
    version: stableVersion,
    tag: `v${stableVersion}`,
    releaseId,
    phase: 'latest',
    latest: true,
    immutable: true,
  })

  for (const [name, changes, expression] of [
    ['wrong id', { id: 92 }, /latest release id must be/],
    ['wrong tag', { tag_name: 'v9.9.9' }, /latest release tag_name must be/],
    ['draft', { draft: true }, /published stable release/],
    ['prerelease', { prerelease: true }, /published stable release/],
    ['mutable', { immutable: false }, /immutable=true/],
  ]) {
    await t.test(name, () => {
      fs.writeFileSync(stable.latestJson, `${JSON.stringify({
        id: releaseId,
        tag_name: `v${stableVersion}`,
        draft: false,
        prerelease: false,
        immutable: true,
        ...changes,
      })}\n`)
      assert.throws(() => verifyGitHubReleaseAssets(stable.latestOptions), expression)
    })
  }

  const prerelease = createFixture()
  t.after(() => fs.rmSync(prerelease.root, { recursive: true, force: true }))
  assert.throws(() => verifyGitHubReleaseAssets(prerelease.latestOptions), /requires a stable version/)
  assert.throws(
    () => verifyGitHubReleaseAssets({ ...stable.latestOptions, releaseId: '091' }),
    /canonical positive decimal integer/,
  )
})

test('rejects local tampering, missing, extra, duplicate, empty, and oversized assets', async t => {
  await t.test('tampering', t => {
    const fixture = createFixture()
    t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }))
    const asset = fixture.release.assets[0]
    const filename = expectedFile(fixture, asset.name)
    const bytes = fs.readFileSync(filename)
    bytes[0] ^= 0xff
    fs.writeFileSync(filename, bytes)
    assert.throws(() => verifyGitHubReleaseAssets(fixture.options), /digest does not match local SHA-256/)
  })

  await t.test('missing file', t => {
    const fixture = createFixture()
    t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }))
    fs.rmSync(expectedFile(fixture, fixture.release.assets[0].name))
    assert.throws(() => verifyGitHubReleaseAssets(fixture.options), /missing release assets/)
  })

  await t.test('extra file', t => {
    const fixture = createFixture()
    t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }))
    fs.writeFileSync(path.join(fixture.assetsDirectory, 'unexpected.txt'), 'unexpected')
    assert.throws(() => verifyGitHubReleaseAssets(fixture.options), /unexpected release asset/)
  })

  await t.test('duplicate basename', t => {
    const fixture = createFixture()
    t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }))
    const name = fixture.release.assets[0].name
    const duplicateDirectory = path.join(fixture.assetsDirectory, 'duplicate')
    fs.mkdirSync(duplicateDirectory)
    fs.copyFileSync(expectedFile(fixture, name), path.join(duplicateDirectory, name))
    assert.throws(() => verifyGitHubReleaseAssets(fixture.options), /duplicate release asset basename/)
  })

  await t.test('empty file', t => {
    const fixture = createFixture()
    t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }))
    fs.truncateSync(expectedFile(fixture, fixture.release.assets[0].name), 0)
    assert.throws(() => verifyGitHubReleaseAssets(fixture.options), /must contain 1 through/)
  })

  await t.test('oversized metadata', t => {
    const fixture = createFixture()
    t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }))
    const metadata = fixture.release.assets.find(asset => asset.name.endsWith('.spdx.json'))
    fs.truncateSync(expectedFile(fixture, metadata.name), (16 * 1024 * 1024) + 1)
    assert.throws(() => verifyGitHubReleaseAssets(fixture.options), /must contain 1 through 16777216 bytes/)
  })

  await t.test('bounded directory iteration', t => {
    const fixture = createFixture()
    t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }))
    for (let index = 0; index < 129; index += 1) {
      fs.mkdirSync(path.join(fixture.assetsDirectory, `bounded-${String(index).padStart(3, '0')}`))
    }
    assert.throws(() => verifyGitHubReleaseAssets(fixture.options), /assets directory exceeds 128 entries/)
  })
})

test('rejects GitHub asset digest, size, state, missing, extra, duplicate, and unsafe names', async t => {
  const cases = [
    ['digest', release => { release.assets[0].digest = `sha256:${'0'.repeat(64)}` }, /digest does not match local SHA-256/],
    ['size', release => { release.assets[0].size += 1 }, /does not match local size/],
    ['zero size', release => { release.assets[0].size = 0 }, /size must be an integer from 1 through/],
    ['fractional size', release => { release.assets[0].size = 1.5 }, /size must be an integer from 1 through/],
    ['oversized size', release => { release.assets[0].size = Number.MAX_SAFE_INTEGER }, /size must be an integer from 1 through/],
    ['state', release => { release.assets[0].state = 'new' }, /state must be uploaded/],
    ['missing', release => { release.assets.pop() }, /exactly 25 assets/],
    ['extra', release => { release.assets.push({ name: 'extra', state: 'uploaded', size: 1, digest: `sha256:${'0'.repeat(64)}` }) }, /exactly 25 assets/],
    ['duplicate', release => { release.assets[0].name = release.assets[1].name }, /duplicate GitHub release asset name/],
    ['URL-like name', release => { release.assets[0].name = 'https://example.invalid/asset' }, /unexpected GitHub release asset name/],
  ]

  for (const [name, mutate, expression] of cases) {
    await t.test(name, t => {
      const fixture = createFixture()
      t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }))
      mutate(fixture.release)
      writeRelease(fixture, fixture.release)
      assert.throws(() => verifyGitHubReleaseAssets(fixture.options), expression)
    })
  }
})

test('rejects mismatched release identity, channel, lifecycle, and immutability', async t => {
  const cases = [
    ['tag', { tag_name: 'v9.9.9' }, 'draft', /tag_name must be/],
    ['prerelease', { prerelease: false }, 'draft', /prerelease must be true/],
    ['draft phase', { draft: false }, 'draft', /draft must be true/],
    ['published phase', { draft: true, immutable: true }, 'published', /draft must be false/],
    ['published mutable', { draft: false, immutable: false }, 'published', /immutable=true/],
    ['draft marked immutable', { immutable: true }, 'draft', /immutable must be false or absent/],
    ['draft null immutable', { immutable: null }, 'draft', /immutable must be false or absent/],
  ]

  for (const [name, changes, phase, expression] of cases) {
    await t.test(name, t => {
      const fixture = createFixture()
      t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }))
      writeRelease(fixture, { ...fixture.release, ...changes })
      assert.throws(
        () => verifyGitHubReleaseAssets(phase === 'published' ? fixture.publishedOptions : fixture.options),
        expression,
      )
    })
  }

  const fixture = createFixture()
  t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }))
  const noImmutable = { ...fixture.release }
  delete noImmutable.immutable
  writeRelease(fixture, noImmutable)
  assert.equal(verifyGitHubReleaseAssets(fixture.options).immutable, false)
  writeRelease(fixture, { ...fixture.release, target_commitish: 'main' })
  assert.equal(verifyGitHubReleaseAssets(fixture.options).tag, `v${version}`)
})

test('binds the exact lightweight tag ref to the workflow commit before and after publication', async t => {
  const cases = [
    ['wrong ref', { ref: 'refs/tags/v9.9.9', object: { type: 'commit', sha: commit } }, /tag ref must be/],
    ['annotated tag', { ref: `refs/tags/v${version}`, object: { type: 'tag', sha: commit } }, /lightweight-tag release contract/],
    ['wrong commit', { ref: `refs/tags/v${version}`, object: { type: 'commit', sha: 'b'.repeat(40) } }, /must be exact commit/],
    ['missing object', { ref: `refs/tags/v${version}` }, /tag ref object must be a JSON object/],
  ]

  for (const [name, tagRef, expression] of cases) {
    await t.test(name, t => {
      const fixture = createFixture()
      t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }))
      writeTagRef(fixture, tagRef)
      assert.throws(() => verifyGitHubReleaseAssets(fixture.tagOptions), expression)
    })
  }

  const fixture = createFixture()
  t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }))
  writeRelease(fixture, { ...fixture.release, draft: false, immutable: true })
  writeTagRef(fixture, {
    ref: `refs/tags/v${version}`,
    object: { type: 'commit', sha: 'b'.repeat(40) },
  })
  assert.throws(
    () => verifyGitHubReleaseAssets(fixture.publishedOptions),
    /tag ref object.sha must be exact commit/,
  )
})

test('rejects local file and directory symlinks, including paths that escape the root', async t => {
  await t.test('file symlink', t => {
    const fixture = createFixture()
    t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }))
    const filename = expectedFile(fixture, fixture.release.assets[0].name)
    const outside = path.join(fixture.root, 'outside')
    fs.writeFileSync(outside, 'outside')
    fs.rmSync(filename)
    fs.symlinkSync(outside, filename)
    assert.throws(() => verifyGitHubReleaseAssets(fixture.options), /must not be a symlink/)
  })

  await t.test('directory symlink escape', t => {
    const fixture = createFixture()
    t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }))
    const outside = path.join(fixture.root, 'outside-directory')
    fs.mkdirSync(outside)
    fs.symlinkSync(outside, path.join(fixture.assetsDirectory, 'linked-directory'))
    assert.throws(() => verifyGitHubReleaseAssets(fixture.options), /must not be a symlink/)
  })

  await t.test('release JSON symlink', t => {
    const fixture = createFixture()
    t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }))
    const realJson = path.join(fixture.root, 'real-release.json')
    fs.renameSync(fixture.releaseJson, realJson)
    fs.symlinkSync(realJson, fixture.releaseJson)
    assert.throws(() => verifyGitHubReleaseAssets(fixture.options), /release JSON must be a regular non-symlink file/)
  })
})

test('rejects malformed, non-object, and oversized release JSON plus invalid closed options', () => {
  const fixture = createFixture()
  try {
    fs.writeFileSync(fixture.releaseJson, '{')
    assert.throws(() => verifyGitHubReleaseAssets(fixture.options), /not valid JSON/)
    fs.writeFileSync(fixture.releaseJson, '[]')
    assert.throws(() => verifyGitHubReleaseAssets(fixture.options), /must be a JSON object/)
    fs.truncateSync(fixture.releaseJson, (2 * 1024 * 1024) + 1)
    assert.throws(() => verifyGitHubReleaseAssets(fixture.options), /must contain 1 through 2097152 bytes/)

    assert.throws(
      () => verifyGitHubReleaseAssets({ ...fixture.tagOptions, commit: 'ABC' }),
      /40 lowercase hexadecimal/,
    )
    assert.throws(
      () => verifyGitHubReleaseAssets({ ...fixture.options, phase: 'ready' }),
      /phase must be absent, attestation, discovery, draft, latest, local, published, setting, or tag/,
    )
    for (const phase of ['__proto__', 'constructor', 'published\nlocal', new String('published')]) {
      assert.throws(
        () => verifyGitHubReleaseAssets({ ...fixture.publishedOptions, phase }),
        /phase must be absent, attestation, discovery, draft, latest, local, published, setting, or tag/,
      )
    }
    assert.throws(
      () => verifyGitHubReleaseAssets({ ...fixture.options, version: 'v0.7.0' }),
      /canonical Semantic Versioning/,
    )
    assert.throws(
      () => verifyGitHubReleaseAssets({ ...fixture.options, extra: true }),
      /options must contain exactly/,
    )
  } finally {
    fs.rmSync(fixture.root, { recursive: true, force: true })
  }
})

test('CLI requires every closed option once and emits one compact JSON summary', () => {
  const fixture = createFixture()
  const stable = createFixture(stableVersion)
  try {
    const result = spawnSync(process.execPath, [
      script,
      '--release-json', fixture.releaseJson,
      '--assets-directory', fixture.assetsDirectory,
      '--version', version,
      '--phase', 'draft',
    ], { encoding: 'utf8' })
    assert.equal(result.status, 0, result.stderr)
    assert.equal(result.stderr, '')
    assert.equal(result.stdout.split('\n').length, 2)
    assert.deepEqual(JSON.parse(result.stdout), {
      version,
      tag: `v${version}`,
      phase: 'draft',
      prerelease: true,
      immutable: false,
      assetCount: 25,
      totalBytes: fixture.release.assets.reduce((total, asset) => total + asset.size, 0),
      inventorySha256: JSON.parse(result.stdout).inventorySha256,
    })

    const local = spawnSync(process.execPath, [
      script,
      '--assets-directory', fixture.assetsDirectory,
      '--version', version,
      '--phase', 'local',
    ], { encoding: 'utf8' })
    assert.equal(local.status, 0, local.stderr)
    assert.equal(JSON.parse(local.stdout).phase, 'local')

    const attestation = spawnSync(process.execPath, [
      script,
      '--attestation-json', fixture.attestationJson,
      '--assets-directory', fixture.assetsDirectory,
      '--repository', repository,
      '--release-id', String(releaseId),
      '--version', version,
      '--commit', commit,
      '--phase', 'attestation',
    ], { encoding: 'utf8' })
    assert.equal(attestation.status, 0, attestation.stderr)
    assert.equal(JSON.parse(attestation.stdout).attestedAssetCount, 25)

    const latest = spawnSync(process.execPath, [
      script,
      '--release-json', stable.latestJson,
      '--release-id', String(releaseId),
      '--version', stableVersion,
      '--phase', 'latest',
    ], { encoding: 'utf8' })
    assert.equal(latest.status, 0, latest.stderr)
    assert.equal(JSON.parse(latest.stdout).latest, true)

    writeRelease(fixture, [])
    const absent = spawnSync(process.execPath, [
      script,
      '--release-json', fixture.releaseJson,
      '--version', version,
      '--phase', 'absent',
    ], { encoding: 'utf8' })
    assert.equal(absent.status, 0, absent.stderr)
    assert.equal(JSON.parse(absent.stdout).matchingReleases, 0)

    writeRelease(fixture, { data: { repository: { release: null } } })
    const discovery = spawnSync(process.execPath, [
      script,
      '--release-json', fixture.releaseJson,
      '--github-output', fixture.githubOutput,
      '--version', version,
      '--phase', 'discovery',
    ], { encoding: 'utf8' })
    assert.equal(discovery.status, 0, discovery.stderr)
    assert.equal(JSON.parse(discovery.stdout).mode, 'create')

    writeRelease(fixture, { enabled: true, enforced_by_owner: false })
    const setting = spawnSync(process.execPath, [
      script,
      '--release-json', fixture.releaseJson,
      '--phase', 'setting',
    ], { encoding: 'utf8' })
    assert.equal(setting.status, 0, setting.stderr)
    assert.deepEqual(JSON.parse(setting.stdout), {
      phase: 'setting',
      immutableReleasesEnabled: true,
      enforcedByOwner: false,
    })

    writeTagRef(fixture, {
      ref: `refs/tags/v${version}`,
      object: { type: 'commit', sha: commit },
    })
    const tag = spawnSync(process.execPath, [
      script,
      '--tag-ref-json', fixture.tagRefJson,
      '--version', version,
      '--commit', commit,
      '--phase', 'tag',
    ], { encoding: 'utf8' })
    assert.equal(tag.status, 0, tag.stderr)
    assert.equal(JSON.parse(tag.stdout).commit, commit)

    const incomplete = spawnSync(process.execPath, [script, '--phase', 'draft'], { encoding: 'utf8' })
    assert.equal(incomplete.status, 1)
    assert.match(incomplete.stderr, /command options must exactly match phase/)

    const repeated = spawnSync(process.execPath, [
      script,
      '--phase', 'draft',
      '--phase', 'published',
      '--release-json', fixture.releaseJson,
      '--assets-directory', fixture.assetsDirectory,
      '--tag-ref-json', fixture.tagRefJson,
      '--version', version,
      '--commit', commit,
    ], { encoding: 'utf8' })
    assert.equal(repeated.status, 1)
    assert.match(repeated.stderr, /invalid or repeated command option/)

    const forgedPhase = spawnSync(process.execPath, [
      script,
      '--release-json', fixture.releaseJson,
      '--assets-directory', fixture.assetsDirectory,
      '--version', version,
      '--phase', 'published\nlocal',
    ], { encoding: 'utf8' })
    assert.equal(forgedPhase.status, 1)
    assert.match(forgedPhase.stderr, /release phase must be absent, attestation, discovery, draft, latest, local, published, setting, or tag/)
    assert.equal(forgedPhase.stderr.split('\n').length, 2)
  } finally {
    fs.rmSync(fixture.root, { recursive: true, force: true })
    fs.rmSync(stable.root, { recursive: true, force: true })
  }
})

test('absent phase rejects stale draft or published exact-tag releases in flat and paginated listings', async t => {
  await t.test('accepts an authenticated paginated listing without the tag', t => {
    const fixture = createFixture()
    t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }))
    writeRelease(fixture, [[
      { tag_name: 'v0.6.0', draft: false },
      { tag_name: 'v0.7.0-rc.0', draft: true },
    ], [{ tag_name: 'v0.5.0', draft: false }]])
    assert.deepEqual(verifyGitHubReleaseAssets({
      releaseJson: fixture.releaseJson,
      version,
      phase: 'absent',
    }), {
      version,
      tag: `v${version}`,
      phase: 'absent',
      inspectedReleases: 3,
      matchingReleases: 0,
    })
  })

  for (const [name, listing] of [
    ['stale draft', [{ tag_name: `v${version}`, draft: true }]],
    ['stale published', [[{ tag_name: `v${version}`, draft: false }]]],
  ]) {
    await t.test(name, t => {
      const fixture = createFixture()
      t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }))
      writeRelease(fixture, listing)
      assert.throws(() => verifyGitHubReleaseAssets({
        releaseJson: fixture.releaseJson,
        version,
        phase: 'absent',
      }), /release tag .* already exists in the authenticated listing/)
    })
  }
})

test('discovery phase safely selects create, draft-resume, or immutable-published resume', async t => {
  for (const [name, release, mode, releaseId] of [
    ['create', null, 'create', 0],
    ['draft', { databaseId: 91, tagName: `v${version}`, isDraft: true, isPrerelease: true }, 'draft', 91],
    ['published', { databaseId: 92, tagName: `v${version}`, isDraft: false, isPrerelease: true }, 'published', 92],
  ]) {
    await t.test(name, t => {
      const fixture = createFixture()
      t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }))
      writeRelease(fixture, { data: { repository: { release } } })
      const result = verifyGitHubReleaseAssets({
        releaseJson: fixture.releaseJson,
        githubOutput: fixture.githubOutput,
        version,
        phase: 'discovery',
      })
      assert.deepEqual(result, {
        version,
        tag: `v${version}`,
        phase: 'discovery',
        inspectedReleases: release === null ? 0 : 1,
        mode,
        releaseId,
      })
      assert.equal(
        fs.readFileSync(fixture.githubOutput, 'utf8'),
        `release-mode=${mode}\nrelease-id=${releaseId}\n`,
      )
    })
  }
})

test('discovery rejects malformed, identity-wrong, or channel-wrong GraphQL responses', async t => {
  const exact = { databaseId: 91, tagName: `v${version}`, isDraft: true, isPrerelease: true }
  const cases = [
    ['GraphQL error', { data: { repository: { release: exact } }, errors: [{ message: 'denied' }] }, /must not contain GraphQL errors/],
    ['wrong tag', { data: { repository: { release: { ...exact, tagName: 'v9.9.9' } } } }, /tagName must be/],
    ['invalid id', { data: { repository: { release: { ...exact, databaseId: 0 } } } }, /positive safe integer id/],
    ['wrong channel', { data: { repository: { release: { ...exact, isPrerelease: false } } } }, /prerelease must be true/],
    ['invalid draft state', { data: { repository: { release: { ...exact, isDraft: 'yes' } } } }, /isDraft must be boolean/],
    ['missing repository', { data: {} }, /release discovery repository must be a JSON object/],
  ]
  for (const [name, response, expression] of cases) {
    await t.test(name, t => {
      const fixture = createFixture()
      t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }))
      writeRelease(fixture, response)
      assert.throws(() => verifyGitHubReleaseAssets({
        releaseJson: fixture.releaseJson,
        githubOutput: fixture.githubOutput,
        version,
        phase: 'discovery',
      }), expression)
    })
  }
})

test('absent phase rejects malformed and oversized authenticated release listings', () => {
  const fixture = createFixture()
  try {
    for (const malformed of [
      {},
      [[[]]],
      [[{ draft: true }]],
      [[{ tag_name: 'v0.6.0' }], { tag_name: 'v0.5.0' }],
    ]) {
      writeRelease(fixture, malformed)
      assert.throws(() => verifyGitHubReleaseAssets({
        releaseJson: fixture.releaseJson,
        version,
        phase: 'absent',
      }), /release listing/)
    }
    fs.writeFileSync(fixture.releaseJson, '{')
    assert.throws(() => verifyGitHubReleaseAssets({
      releaseJson: fixture.releaseJson,
      version,
      phase: 'absent',
    }), /not valid JSON/)
    fs.truncateSync(fixture.releaseJson, (2 * 1024 * 1024) + 1)
    assert.throws(() => verifyGitHubReleaseAssets({
      releaseJson: fixture.releaseJson,
      version,
      phase: 'absent',
    }), /must contain 1 through 2097152 bytes/)
  } finally {
    fs.rmSync(fixture.root, { recursive: true, force: true })
  }
})

test('setting phase requires exact enabled=true and enforced_by_owner=false readback', () => {
  const fixture = createFixture()
  try {
    writeRelease(fixture, { enabled: true, enforced_by_owner: false })
    assert.deepEqual(verifyGitHubReleaseAssets({
      releaseJson: fixture.releaseJson,
      phase: 'setting',
    }), {
      phase: 'setting',
      immutableReleasesEnabled: true,
      enforcedByOwner: false,
    })

    for (const disabled of [
      { enabled: false, enforced_by_owner: false },
      { enabled: true, enforced_by_owner: true },
      { enabled: true },
      { enabled: true, enforced_by_owner: 'false' },
      { enabled: true, enforced_by_owner: false, unexpected: true },
      {},
      [],
      null,
    ]) {
      writeRelease(fixture, disabled)
      assert.throws(() => verifyGitHubReleaseAssets({
        releaseJson: fixture.releaseJson,
        phase: 'setting',
      }), /immutable releases setting|enabled=true|enforced_by_owner/)
    }
    fs.writeFileSync(fixture.releaseJson, '{')
    assert.throws(() => verifyGitHubReleaseAssets({
      releaseJson: fixture.releaseJson,
      phase: 'setting',
    }), /not valid JSON/)
    fs.truncateSync(fixture.releaseJson, (2 * 1024 * 1024) + 1)
    assert.throws(() => verifyGitHubReleaseAssets({
      releaseJson: fixture.releaseJson,
      phase: 'setting',
    }), /must contain 1 through 2097152 bytes/)
  } finally {
    fs.rmSync(fixture.root, { recursive: true, force: true })
  }
})
