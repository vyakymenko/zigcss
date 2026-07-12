import assert from 'node:assert/strict'
import crypto from 'node:crypto'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import {
  buildReleaseMetadata,
  checkReleaseAttestationBundles,
  checkReleaseMetadata,
  provenancePredicateType,
  spdxPredicateType,
  validateReleaseBuildGate,
  validateReleaseWorkflow,
  validateReleaseWorkflowSource,
  writeReleaseMetadata,
} from './generate-release-metadata.mjs'

const version = '0.4.0-rc.1'
const commit = 'a'.repeat(40)
const sourceDateEpoch = 1_700_000_000

function sha(algorithm, value) {
  return crypto.createHash(algorithm).update(value).digest('hex')
}

function fixture(target = 'x86_64-linux') {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-release-metadata-'))
  const extension = target.endsWith('-windows') ? 'zip' : 'tar.gz'
  const binaryName = target.endsWith('-windows') ? 'zigcss.exe' : 'zigcss'
  const base = `zigcss-v${version}-${target}`
  fs.mkdirSync(path.join(root, 'release-assets'), { recursive: true })
  fs.mkdirSync(path.join(root, 'zig-out', 'bin'), { recursive: true })
  fs.writeFileSync(path.join(root, 'release-assets', `${base}.${extension}`), 'archive fixture\n')
  fs.writeFileSync(path.join(root, 'zig-out', 'bin', binaryName), 'binary fixture\n')
  return {
    root,
    options: {
      root,
      archive: `release-assets/${base}.${extension}`,
      binary: `zig-out/bin/${binaryName}`,
      outputDirectory: 'release-assets',
      target,
      version,
      commit,
      sourceDateEpoch,
    },
  }
}

function fakeBundle(subjects, predicateType, predicate) {
  const statement = {
    _type: 'https://in-toto.io/Statement/v1',
    subject: subjects,
    predicateType,
    predicate,
  }
  return `${JSON.stringify({
    mediaType: 'application/vnd.dev.sigstore.bundle.v0.3+json',
    verificationMaterial: {
      certificate: { rawBytes: Buffer.from('test certificate').toString('base64') },
      tlogEntries: [],
    },
    dsseEnvelope: {
      payload: Buffer.from(JSON.stringify(statement)).toString('base64'),
      payloadType: 'application/vnd.in-toto+json',
      signatures: [{ sig: Buffer.from('test signature').toString('base64') }],
    },
  })}\n`
}

test('release metadata is deterministic, bounded SPDX 2.3 with exact SHA-256 subjects', () => {
  const { root, options } = fixture()
  try {
    const first = writeReleaseMetadata(options)
    checkReleaseMetadata(options)

    assert.deepEqual(first.assets, {
      archive: 'zigcss-v0.4.0-rc.1-x86_64-linux.tar.gz',
      sbom: 'zigcss-v0.4.0-rc.1-x86_64-linux.spdx.json',
      checksums: 'zigcss-v0.4.0-rc.1-x86_64-linux.sha256',
      provenanceBundle: 'zigcss-v0.4.0-rc.1-x86_64-linux.provenance.sigstore.jsonl',
      sbomBundle: 'zigcss-v0.4.0-rc.1-x86_64-linux.sbom.sigstore.jsonl',
    })

    const archiveBytes = fs.readFileSync(path.join(root, options.archive))
    const binaryBytes = fs.readFileSync(path.join(root, options.binary))
    const sbomText = fs.readFileSync(path.join(root, 'release-assets', first.assets.sbom), 'utf8')
    const checksumsText = fs.readFileSync(path.join(root, 'release-assets', first.assets.checksums), 'utf8')
    const sbom = JSON.parse(sbomText)
    const archiveSha256 = sha('sha256', archiveBytes)
    const binarySha1 = sha('sha1', binaryBytes)

    assert.equal(sbom.spdxVersion, 'SPDX-2.3')
    assert.equal(sbom.dataLicense, 'CC0-1.0')
    assert.equal(sbom.SPDXID, 'SPDXRef-DOCUMENT')
    assert.equal(sbom.creationInfo.created, '2023-11-14T22:13:20Z')
    assert.deepEqual(sbom.creationInfo.creators, ['Tool: zigcss-release-metadata/1'])
    assert.deepEqual(sbom.documentDescribes, ['SPDXRef-Package-zigcss'])
    assert.equal(sbom.packages[0].versionInfo, version)
    assert.equal(sbom.packages[0].packageFileName, first.assets.archive)
    assert.equal(sbom.packages[0].filesAnalyzed, true)
    assert.equal(sbom.packages[0].checksums[0].algorithm, 'SHA256')
    assert.equal(sbom.packages[0].checksums[0].checksumValue, archiveSha256)
    assert.equal(
      sbom.packages[0].packageVerificationCode.packageVerificationCodeValue,
      sha('sha1', binarySha1),
    )
    assert.equal(sbom.files[0].fileName, './zigcss')
    assert.deepEqual(sbom.files[0].fileTypes, ['BINARY'])
    assert.deepEqual(sbom.relationships, [
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
    ])
    assert.equal(checksumsText, [
      `${archiveSha256}  ${first.assets.archive}`,
      `${sha('sha256', sbomText)}  ${first.assets.sbom}`,
      '',
    ].join('\n'))
    assert.doesNotMatch(sbomText, new RegExp(root.replaceAll('\\', '\\\\')))

    const firstSbom = sbomText
    const firstChecksums = checksumsText
    fs.rmSync(path.join(root, 'release-assets', first.assets.sbom))
    fs.rmSync(path.join(root, 'release-assets', first.assets.checksums))
    const second = writeReleaseMetadata(options)
    assert.deepEqual(second, first)
    assert.equal(fs.readFileSync(path.join(root, 'release-assets', first.assets.sbom), 'utf8'), firstSbom)
    assert.equal(fs.readFileSync(path.join(root, 'release-assets', first.assets.checksums), 'utf8'), firstChecksums)
  } finally {
    fs.rmSync(root, { recursive: true, force: true })
  }
})

test('metadata checks reject tampering, malformed identity, escapes, and symlinks', () => {
  const { root, options } = fixture('x86_64-windows')
  const outside = `${root}-outside`
  try {
    const result = writeReleaseMetadata(options)
    fs.appendFileSync(path.join(root, options.archive), 'tampered')
    assert.throws(() => checkReleaseMetadata(options), /release metadata drift/)

    assert.throws(
      () => buildReleaseMetadata({ ...options, target: 'riscv64-linux' }),
      /unsupported release target/,
    )
    assert.throws(
      () => buildReleaseMetadata({ ...options, version: 'v0.4.0' }),
      /canonical Semantic Versioning/,
    )
    assert.throws(
      () => buildReleaseMetadata({ ...options, commit: 'ABC' }),
      /40 lowercase hexadecimal/,
    )
    assert.throws(
      () => buildReleaseMetadata({ ...options, sourceDateEpoch: -1 }),
      /source date epoch/,
    )
    assert.throws(
      () => buildReleaseMetadata({ ...options, archive: '../outside.zip' }),
      /release archive path must be/,
    )

    fs.writeFileSync(outside, 'outside')
    const sbom = path.join(root, options.outputDirectory, result.assets.sbom)
    fs.rmSync(sbom)
    fs.symlinkSync(outside, sbom)
    assert.throws(
      () => writeReleaseMetadata(options),
      /regular non-symlink file/,
    )
    fs.rmSync(sbom)

    fs.rmSync(path.join(root, options.archive))
    fs.symlinkSync(outside, path.join(root, options.archive))
    assert.throws(
      () => buildReleaseMetadata(options),
      /regular non-symlink file/,
    )
  } finally {
    fs.rmSync(root, { recursive: true, force: true })
    fs.rmSync(outside, { force: true })
  }
})

test('local Sigstore bundles bind exact subjects and predicates before cryptographic verification', () => {
  const { root, options } = fixture()
  try {
    const result = writeReleaseMetadata(options)
    const output = path.join(root, 'release-assets')
    const subjects = [
      { name: result.assets.archive, digest: { sha256: result.digests.archiveSha256 } },
      { name: result.assets.sbom, digest: { sha256: result.digests.sbomSha256 } },
      { name: result.assets.checksums, digest: { sha256: result.digests.checksumsSha256 } },
    ]
    fs.writeFileSync(
      path.join(output, result.assets.provenanceBundle),
      fakeBundle(subjects, provenancePredicateType, { buildDefinition: {}, runDetails: {} }),
    )
    fs.writeFileSync(
      path.join(output, result.assets.sbomBundle),
      fakeBundle([subjects[0]], spdxPredicateType, result.sbom),
    )
    assert.deepEqual(checkReleaseAttestationBundles(options), {
      provenanceSubjects: 3,
      sbomSubjects: 1,
    })

    fs.writeFileSync(path.join(output, 'unexpected.txt'), 'unexpected')
    assert.throws(() => checkReleaseAttestationBundles(options), /release asset inventory must contain exactly/)
    fs.rmSync(path.join(output, 'unexpected.txt'))

    const wrong = [{ name: result.assets.archive, digest: { sha256: '0'.repeat(64) } }]
    fs.writeFileSync(
      path.join(output, result.assets.sbomBundle),
      fakeBundle(wrong, spdxPredicateType, result.sbom),
    )
    assert.throws(() => checkReleaseAttestationBundles(options), /attestation subjects do not match/)
  } finally {
    fs.rmSync(root, { recursive: true, force: true })
  }
})

test('release workflow generates, signs, verifies, and uploads the closed five-target inventory', () => {
  assert.deepEqual(validateReleaseWorkflow(), {
    targets: 5,
    assetsPerTarget: 5,
    attestations: 2,
    signatureVerifications: 2,
  })
})

test('release workflow evidence fails closed when authority or artifact steps drift', () => {
  const workflow = fs.readFileSync(new URL('../.github/workflows/release.yml', import.meta.url), 'utf8')
  const buildWorkflow = fs.readFileSync(new URL('../.github/workflows/build.yml', import.meta.url), 'utf8')

  assert.throws(
    () => validateReleaseWorkflowSource(workflow.replace('      attestations: write\n', '')),
    /attestation permissions/,
  )
  assert.throws(
    () => validateReleaseWorkflowSource(workflow.replace('        sbom-path:', '        removed-sbom-path:')),
    /signed SBOM attestation/,
  )
  assert.throws(
    () => validateReleaseWorkflowSource(workflow.replace('gh attestation verify', 'gh removed verify')),
    /cryptographic verification/,
  )
  assert.throws(
    () => validateReleaseWorkflowSource(workflow.replace('          path: release-assets/*', '          path: .')),
    /closed release asset upload/,
  )
  assert.throws(
    () => validateReleaseBuildGate(buildWorkflow.replace('- name: Verify release artifact metadata policy', '- name: Removed release metadata policy')),
    /release metadata CI step/,
  )
  assert.throws(
    () => validateReleaseBuildGate(buildWorkflow.replace('- name: Test release consumer paths', '- name: Removed release consumer paths')),
    /release consumer CI step/,
  )
})
