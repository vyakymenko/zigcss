import assert from 'node:assert/strict'
import crypto from 'node:crypto'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawnSync } from 'node:child_process'
import test from 'node:test'
import { fileURLToPath } from 'node:url'
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

const version = '0.6.0-rc.2'
const commit = 'a'.repeat(40)
const sourceDateEpoch = 1_700_000_000
const script = fileURLToPath(new URL('./generate-release-metadata.mjs', import.meta.url))

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
      archive: 'zigcss-v0.6.0-rc.2-x86_64-linux.tar.gz',
      sbom: 'zigcss-v0.6.0-rc.2-x86_64-linux.spdx.json',
      checksums: 'zigcss-v0.6.0-rc.2-x86_64-linux.sha256',
      provenanceBundle: 'zigcss-v0.6.0-rc.2-x86_64-linux.provenance.sigstore.jsonl',
      sbomBundle: 'zigcss-v0.6.0-rc.2-x86_64-linux.sbom.sigstore.jsonl',
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
    assert.deepEqual(writeReleaseMetadata(options), first)
    fs.writeFileSync(path.join(root, 'release-assets', first.assets.sbom), 'different metadata\n')
    assert.throws(() => writeReleaseMetadata(options), /already exists with different content/)
    fs.writeFileSync(path.join(root, 'release-assets', first.assets.sbom), firstSbom)
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

test('release metadata CLI rejects repeated and non-allowlisted property names', () => {
  for (const args of [
    ['--write', '--archive', 'first', '--archive', 'second'],
    ['--write', '--__proto__', 'polluted'],
    ['--write', '--constructor', 'polluted'],
  ]) {
    const result = spawnSync(process.execPath, [script, ...args], { encoding: 'utf8' })
    assert.notEqual(result.status, 0)
    assert.match(result.stderr, /invalid or repeated option/)
  }
})

test('metadata writing rejects an identical symlink when O_NOFOLLOW is unavailable', t => {
  const { root, options } = fixture()
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const result = writeReleaseMetadata(options)
  const sbom = path.join(fs.realpathSync(root), options.outputDirectory, result.assets.sbom)
  const identical = path.join(root, 'identical-sbom.json')
  fs.writeFileSync(identical, fs.readFileSync(sbom))
  fs.rmSync(sbom)
  fs.symlinkSync(identical, sbom)

  const originalOpen = fs.openSync
  let followedSymlinks = 0
  t.mock.method(fs, 'openSync', (filename, flags, ...args) => {
    if (filename === sbom && typeof flags === 'number') {
      followedSymlinks += 1
      return originalOpen(filename, flags & ~(fs.constants.O_NOFOLLOW ?? 0), ...args)
    }
    return originalOpen(filename, flags, ...args)
  })

  assert.throws(() => writeReleaseMetadata(options), /regular non-symlink file/)
  assert.equal(followedSymlinks, 1)
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
    nativeSmokes: 1,
    attestations: 2,
    signatureVerifications: 2,
    npmPreflight: true,
    npmChannels: ['next', 'latest'],
    githubReleaseMode: 'immutable-semver',
    githubApprovalEnvironment: 'immutable-release',
    githubReleaseAttestation: true,
    npmProvenance: true,
  })
})

test('workflow validation normalizes Windows CRLF and rejects bare carriage returns', () => {
  const workflow = fs.readFileSync(new URL('../.github/workflows/release.yml', import.meta.url), 'utf8')
  const buildWorkflow = fs.readFileSync(new URL('../.github/workflows/build.yml', import.meta.url), 'utf8')
  const expected = {
    targets: 5,
    assetsPerTarget: 5,
    nativeSmokes: 1,
    attestations: 2,
    signatureVerifications: 2,
    npmPreflight: true,
    npmChannels: ['next', 'latest'],
    githubReleaseMode: 'immutable-semver',
    githubApprovalEnvironment: 'immutable-release',
    githubReleaseAttestation: true,
    npmProvenance: true,
  }

  assert.deepEqual(validateReleaseWorkflowSource(workflow.replaceAll('\n', '\r\n')), expected)
  assert.deepEqual(validateReleaseBuildGate(buildWorkflow.replaceAll('\n', '\r\n')), {
    targets: 5,
    assetsPerTarget: 5,
    attestations: 2,
    signatureVerifications: 2,
  })
  assert.throws(() => validateReleaseWorkflowSource(`${workflow}\r`), /bare carriage return/)
  assert.throws(() => validateReleaseBuildGate(`${buildWorkflow}\r`), /bare carriage return/)

  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-release-workflow-crlf-'))
  try {
    fs.mkdirSync(path.join(root, '.github', 'workflows'), { recursive: true })
    fs.writeFileSync(path.join(root, '.github', 'workflows', 'release.yml'), workflow.replaceAll('\n', '\r\n'))
    fs.writeFileSync(path.join(root, '.github', 'workflows', 'build.yml'), buildWorkflow.replaceAll('\n', '\r\n'))
    assert.deepEqual(validateReleaseWorkflow(root), expected)
  } finally {
    fs.rmSync(root, { recursive: true, force: true })
  }
})

test('release workflow evidence fails closed when authority or artifact steps drift', () => {
  const workflow = fs.readFileSync(new URL('../.github/workflows/release.yml', import.meta.url), 'utf8')
  const buildWorkflow = fs.readFileSync(new URL('../.github/workflows/build.yml', import.meta.url), 'utf8')

  assert.throws(
    () => validateReleaseWorkflowSource(workflow.replace('      attestations: write\n', '')),
    /attestation permissions/,
  )
  assert.throws(
    () => validateReleaseWorkflowSource(workflow.replace('  cancel-in-progress: false', '  cancel-in-progress: true')),
    /immutable release concurrency policy/,
  )
  assert.throws(
    () => validateReleaseWorkflowSource(workflow.replace(
      'concurrency:\n  group: zigcss-release-${{ github.ref }}\n  cancel-in-progress: false',
      'concurrency:\n  group: zigcss-release-${{ github.ref }}\n  cancel-in-progress: false\n\n'
        + 'concurrency:\n  group: zigcss-release-${{ github.ref }}\n  cancel-in-progress: false',
    )),
    /single release concurrency policy/,
  )
  assert.throws(
    () => validateReleaseWorkflowSource(workflow.replace(
      'node scripts/create-release-archive.mjs',
      'node scripts/removed-release-archive.mjs',
    )),
    /reproducible release archive step/,
  )
  assert.throws(
    () => validateReleaseWorkflowSource(workflow.replace(
      '--source-date-epoch "$SOURCE_DATE_EPOCH"',
      '--source-date-epoch "$GITHUB_RUN_ID"',
    )),
    /reproducible release archive step/,
  )
  assert.throws(
    () => validateReleaseWorkflowSource(workflow.replace(
      'epoch="$(node scripts/validate-native-integrity.mjs --print-source-date-epoch --version "$version")"',
      'epoch="$GITHUB_RUN_ID"',
    )),
    /manifest-owned release source date epoch/,
  )
  assert.throws(
    () => validateReleaseWorkflowSource(workflow.replace(
      '- name: Verify Committed Native Integrity',
      '- name: Removed Committed Native Integrity',
    )),
    /committed native integrity gate/,
  )
  assert.throws(
    () => validateReleaseWorkflowSource(workflow.replace(
      'node scripts/validate-native-integrity.mjs --check',
      'node scripts/validate-native-integrity.mjs --removed-check',
    )),
    /pre-pack native integrity check/,
  )
  assert.throws(
    () => validateReleaseWorkflowSource(workflow.replace(
      '--archive "release-assets/$RELEASE_ARCHIVE" \\\n            --target "${{ matrix.target }}"',
      '--archive "release-assets/$RELEASE_CHECKSUMS" \\\n            --target "${{ matrix.target }}"',
    )),
    /committed native integrity gate/,
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
    () => validateReleaseWorkflowSource(workflow.replace(
      '--signer-workflow "$GITHUB_REPOSITORY/.github/workflows/release.yml"',
      '--signer-workflow "$GITHUB_REPOSITORY/.github/workflows/build.yml"',
    )),
    /release signer workflow verification/,
  )
  assert.throws(
    () => validateReleaseWorkflowSource(workflow.replace(
      '--signer-digest "$GITHUB_SHA"',
      '--signer-digest "$GITHUB_REF"',
    )),
    /release signer digest verification/,
  )
  assert.throws(
    () => validateReleaseWorkflowSource(workflow.replace(
      '--source-ref "refs/tags/$GITHUB_REF_NAME"',
      '--source-ref refs/heads/main',
    )),
    /release source tag verification/,
  )
  assert.throws(
    () => validateReleaseWorkflowSource(workflow.replace(
      '--source-digest "$GITHUB_SHA"',
      '--source-digest "$GITHUB_REF"',
    )),
    /release source digest verification/,
  )
  const identityFlagsReboundToOnlyOneBundle = workflow
    .replace('            --source-ref "refs/tags/$GITHUB_REF_NAME" \\\n', '')
    .replace(
      '            --source-ref "refs/tags/$GITHUB_REF_NAME" \\\n            --source-digest "$GITHUB_SHA"\n\n      - name: Upload Release Assets',
      '            --source-ref "refs/tags/$GITHUB_REF_NAME" \\\n'
        + '            --source-ref "refs/tags/$GITHUB_REF_NAME" \\\n'
        + '            --source-digest "$GITHUB_SHA"\n\n      - name: Upload Release Assets',
    )
  assert.throws(
    () => validateReleaseWorkflowSource(identityFlagsReboundToOnlyOneBundle),
    /release provenance attestation verification/,
  )
  assert.throws(
    () => validateReleaseWorkflowSource(workflow.replace(
      '--source-ref "refs/tags/$GITHUB_REF_NAME"',
      '--source-ref "$GITHUB_REF" \\\n            --source-ref "refs/tags/$GITHUB_REF_NAME"',
    )),
    /release source ref option inventory/,
  )
  assert.throws(
    () => validateReleaseWorkflowSource(workflow.replace('- name: Smoke Native Archive and npm Installation', '- name: Removed native smoke')),
    /native release smoke step/,
  )
  assert.throws(
    () => validateReleaseWorkflowSource(workflow.replace('          path: release-assets/*', '          path: .')),
    /closed release asset upload/,
  )
  assert.throws(
    () => validateReleaseWorkflowSource(workflow.replace('- name: Verify npm publication authority', '- name: Removed npm publication authority')),
    /npm publication preflight/,
  )
  for (const [current, replacement] of [
    ['timeout 30s npm whoami --registry=https://registry.npmjs.org/ >/dev/null 2>&1', 'timeout 30s npm whoami >/dev/null 2>&1'],
    ['timeout 30s npm view zigcss versions --json --registry=https://registry.npmjs.org/', 'timeout 30s npm view zigcss versions --json'],
    ['          for attempt in 1 2 3 4; do', '          for attempt in 1 2 3; do'],
    ['            sleep 5', '            sleep 30'],
    ['>/dev/null 2>&1', ''],
  ]) {
    const changed = workflow.replace(current, replacement)
    assert.notEqual(changed, workflow, current)
    assert.throws(() => validateReleaseWorkflowSource(changed), /bounded npm publication authority preflight/)
  }
  assert.throws(
    () => validateReleaseWorkflowSource(workflow.replace('npm pack --ignore-scripts --json', 'npm pack --json')),
    /single lifecycle-disabled npm pack/,
  )
  assert.throws(
    () => validateReleaseWorkflowSource(workflow.replace(
      'name: npm-publication-${{ github.sha }}',
      'name: mutable-npm-publication',
    )),
    /immutable npm package artifact handoff/,
  )
  assert.throws(
    () => validateReleaseWorkflowSource(workflow.replace('pattern: zigcss-*', 'pattern: *')),
    /closed GitHub release artifact selection/,
  )
  for (const [current, replacement, expected] of [
    ['    environment:\n      name: immutable-release', '    environment:\n      name: release', /mandatory immutable-release approval environment/],
    ['    environment:\n      name: immutable-release', '    environment:\n      name: immutable-release\n    env:\n      ADMIN_TOKEN: ${{ secrets.IMMUTABLE_RELEASES_READ_TOKEN }}', /stored immutable-releases administration credential/],
    ['          draft: true', '          draft: false', /draft-first GitHub release/],
    ['          overwrite_files: true', '          overwrite_files: false', /controlled draft GitHub release asset reconciliation/],
    ['          fail_on_unmatched_files: true', '          fail_on_unmatched_files: false', /fail-closed GitHub release file glob/],
    ['          target_commitish: ${{ github.sha }}', '          target_commitish: main', /exact GitHub release commit/],
    ['              -F draft=false \\', '              -F draft=true \\', /point of no return/],
    ['--phase published', '--phase draft', /GitHub release draft verification|GitHub release published verification/],
    ['--phase tag', '--phase draft', /lightweight tag binding|GitHub release tag verification/],
    ['--phase attestation', '--phase latest', /stable GitHub Latest identity verification|GitHub release latest verification|GitHub release attestation verification/],
    ["        if: needs.npm-preflight.outputs.github-make-latest == 'true'", "        if: needs.npm-preflight.outputs.github-make-latest == 'false'", /stable-only GitHub Latest readback/],
    ['          timeout 60s gh api graphql \\', '          gh api graphql \\', /bounded exact release discovery/],
    ["        if: steps.npm-policy.outputs.already_published == 'true'", "        if: steps.npm-policy.outputs.already_published == 'false'", /npm resume gate|existing npm publication condition/],
    ['timeout 30s gh release verify', 'gh release verify', /bounded immutable release attestation verification/],
  ]) {
    const changed = workflow.replace(current, replacement)
    assert.notEqual(changed, workflow, current)
    assert.throws(() => validateReleaseWorkflowSource(changed), expected)
  }
  assert.throws(
    () => validateReleaseWorkflowSource(workflow.replace(
      'node scripts/npm-package-artifact.mjs verify',
      'node scripts/npm-package-artifact.mjs removed',
    )),
    /exact npm package handoff verification/,
  )
  assert.throws(
    () => validateReleaseWorkflowSource(workflow.replace(
      'npm publish "$NPM_PACKAGE_ARCHIVE" --tag "$RELEASE_CHANNEL" --registry=https://registry.npmjs.org/ --provenance',
      'npm publish "$NPM_PACKAGE_ARCHIVE" --provenance',
    )),
    /channel-aware npm publication/,
  )
  assert.throws(
    () => validateReleaseWorkflowSource(workflow.replace('node scripts/verify-npm-publication.mjs', 'node scripts/removed-readback.mjs')),
    /npm publication readbacks/,
  )
  assert.throws(
    () => validateReleaseWorkflowSource(workflow.replace(
      '- name: Publish to npm',
      '- name: Rewrite package version\n        run: npm version 0.6.0-rc.2 --no-git-tag-version\n\n      - name: Publish to npm',
    )),
    /npm package version mutation/,
  )
  assert.throws(
    () => validateReleaseBuildGate(buildWorkflow.replace('- name: Verify release artifact metadata policy', '- name: Removed release metadata policy')),
    /release metadata CI step/,
  )
  assert.throws(
    () => validateReleaseBuildGate(buildWorkflow.replace(
      'node scripts/create-release-archive.mjs',
      'node scripts/removed-release-archive.mjs',
    )),
    /reproducible native smoke archive step/,
  )
  assert.throws(
    () => validateReleaseBuildGate(buildWorkflow.replace(
      'epoch="$(node scripts/validate-native-integrity.mjs --print-source-date-epoch --version "$version")"',
      'epoch="$GITHUB_RUN_ID"',
    )),
    /Build native release asset plan/,
  )
  assert.throws(
    () => validateReleaseBuildGate(buildWorkflow.replace(
      'echo "SOURCE_DATE_EPOCH=$epoch" >> "$GITHUB_ENV"',
      'echo "SOURCE_DATE_EPOCH=$(git show -s --format=%ct "$GITHUB_SHA")" >> "$GITHUB_ENV"',
    )),
    /Build native release asset plan|commit-derived native source date epoch/,
  )
  assert.throws(
    () => validateReleaseBuildGate(buildWorkflow.replace(
      '      - name: Generate Native Smoke Metadata',
      '      - name: Development digest comparison\n'
        + '        run: |\n'
        + '          node scripts/validate-native-integrity.mjs \\\n'
        + '            --archive "release-assets/$RELEASE_ARCHIVE"\n\n'
        + '      - name: Generate Native Smoke Metadata',
    )),
    /development archive digest comparison/,
  )
  assert.throws(
    () => validateReleaseBuildGate(buildWorkflow.replace('      attestations: write\n', '')),
    /native provenance attestation permissions/,
  )
  assert.throws(
    () => validateReleaseBuildGate(buildWorkflow.replace('- name: Attest Native Provenance', '- name: Removed native provenance')),
    /native provenance attestation/,
  )
  assert.throws(
    () => validateReleaseBuildGate(buildWorkflow.replace('gh attestation verify', 'gh removed verify')),
    /native provenance cryptographic verification/,
  )
  assert.throws(
    () => validateReleaseBuildGate(buildWorkflow.replace('--source-digest "$GITHUB_SHA"', '--source-digest "$GITHUB_REF"')),
    /native provenance source digest verification/,
  )
  assert.throws(
    () => validateReleaseBuildGate(buildWorkflow.replace(
      '          name: native-release-${{ matrix.target }}',
      '          name: missing-native-release-${{ matrix.target }}',
    )),
    /closed native release input upload/,
  )
  assert.throws(
    () => validateReleaseBuildGate(buildWorkflow.replace(
      '          echo "RELEASE_CHECKSUMS=$base.sha256" >> "$GITHUB_ENV"',
      '          echo "REMOVED_RELEASE_CHECKSUMS=$base.sha256" >> "$GITHUB_ENV"',
    )),
    /Build native release asset plan/,
  )
  assert.throws(
    () => validateReleaseBuildGate(buildWorkflow.replace(
      "  native-provenance-evidence:\n    name: Native Provenance ${{ matrix.target }}\n    if: github.event_name == 'push' && github.ref == 'refs/heads/main'",
      "  native-provenance-evidence:\n    name: Native Provenance ${{ matrix.target }}\n    if: github.event_name == 'push'",
    )),
    /native provenance exact-main authority gate/,
  )
  assert.throws(
    () => validateReleaseBuildGate(buildWorkflow.replace(
      '    permissions:\n      contents: read\n    strategy:',
      '    permissions:\n      attestations: write\n      contents: read\n      id-token: write\n    strategy:',
    )),
    /unprivileged Build permissions/,
  )
  assert.throws(
    () => validateReleaseBuildGate(buildWorkflow.replace(
      '          - target: x86_64-linux\n            archive-extension: tar.gz\n            binary-name: zigcss\n',
      '',
    )),
    /native provenance target\/archive inventory changed/,
  )
  assert.throws(
    () => validateReleaseBuildGate(buildWorkflow.replace(
      '          - target: x86_64-windows\n            archive-extension: zip\n            binary-name: zigcss.exe',
      '          - target: x86_64-windows\n            archive-extension: zip\n            binary-name: zigcss.exe\n'
        + '          - target: x86_64-freebsd\n            archive-extension: tar.gz\n            binary-name: zigcss',
    )),
    /native provenance target\/archive inventory changed/,
  )
  assert.throws(
    () => validateReleaseBuildGate(buildWorkflow.replace(
      '            release-assets/${{ env.RELEASE_BASE }}.sbom.sigstore.jsonl',
      '            release-assets/${{ env.RELEASE_BASE }}.missing.sigstore.jsonl',
    )),
    /closed native provenance evidence upload/,
  )
  assert.throws(
    () => validateReleaseBuildGate(buildWorkflow.replace('- name: Test release smoke', '- name: Removed release smoke')),
    /Test release smoke CI step/,
  )
  assert.throws(
    () => validateReleaseBuildGate(buildWorkflow.replace('npm run test:release-smoke', 'npm run removed:release-smoke')),
    /Test release smoke CI command/,
  )
  assert.throws(
    () => validateReleaseBuildGate(buildWorkflow.replace('npm run test:npm-publication', 'npm run removed:npm-publication')),
    /release metadata CI command/,
  )
  assert.throws(
    () => validateReleaseBuildGate(buildWorkflow.replace(
      'node --test scripts/validate-native-integrity.test.mjs',
      'node --test scripts/removed-native-integrity.test.mjs',
    )),
    /release metadata CI command with native integrity/,
  )
  assert.throws(
    () => validateReleaseBuildGate(buildWorkflow.replace('npm run test:release-container', 'npm run removed:release-container')),
    /release container CI command/,
  )
  assert.throws(
    () => validateReleaseBuildGate(buildWorkflow.replace('npm run test:release-homebrew', 'npm run removed:release-homebrew')),
    /Test release Homebrew CI command/,
  )
  assert.throws(
    () => validateReleaseBuildGate(buildWorkflow.replace('          fetch-depth: 0', '          fetch-depth: 1')),
    /release consumer full-history checkout/,
  )
})
