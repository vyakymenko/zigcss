import assert from 'node:assert/strict'
import crypto from 'node:crypto'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import {
  nativeSmokeTargets,
  nativeTargetEvidence,
} from './smoke-release-artifact.mjs'
import {
  parseNativePackageEvidenceArguments,
  validateNativePackageEvidence,
  validateNativePackageEvidenceWorkflow,
  writeNativePackageEvidence,
} from './validate-native-package-evidence.mjs'

const commit = '0123456789abcdef0123456789abcdef01234567'
const version = '0.6.0-rc.2'

function sha256(value) {
  return crypto.createHash('sha256').update(value).digest('hex')
}

function makeFixture() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-native-package-evidence-'))
  const artifacts = path.join(root, 'native-target-artifacts')
  fs.mkdirSync(artifacts)

  for (const [index, policy] of nativeSmokeTargets.entries()) {
    const artifact = path.join(artifacts, `zigcss-${policy.target}`)
    const receipts = path.join(artifact, 'native-target-evidence')
    const binaries = path.join(artifact, 'zig-out', 'bin')
    const binary = Buffer.from(`binary fixture ${policy.target}\n`)
    fs.mkdirSync(receipts, { recursive: true })
    fs.mkdirSync(binaries, { recursive: true })
    fs.writeFileSync(path.join(binaries, policy.binaryName), binary)

    const evidence = nativeTargetEvidence({
      target: policy.target,
      archiveSha256: sha256(`archive ${policy.target}`),
      binarySha256: sha256(binary),
      checksumsSha256: sha256(`checksums ${policy.target}`),
      installedBytes: 3_500_000 + index,
      installedEntries: 10,
      npmPackage: `zigcss-${version}.tgz`,
      directStylesheetSmokes: 5,
      offlinePackageStylesheetSmokes: 5,
      directRuntimeTrace: {
        invocations: 6,
        nativeSpawns: 6,
        networkAttempts: 0,
        deniedProcessAttempts: 0,
      },
      offlinePackageRuntimeTrace: {
        invocations: 6,
        nativeSpawns: 6,
        networkAttempts: 0,
        deniedProcessAttempts: 0,
      },
      offlineNodeApiSmokes: 2,
      offlineNodeApiOptionRejections: 1,
      offlineNodeApiRuntimeTrace: {
        invocations: 3,
        nativeSpawns: 3,
        networkAttempts: 0,
        deniedProcessAttempts: 0,
      },
    }, {
      commit,
      version,
      platform: policy.nodePlatform,
      arch: policy.nodeArch,
    })
    fs.writeFileSync(
      path.join(receipts, `${policy.target}.json`),
      `${JSON.stringify(evidence, null, 2)}\n`,
    )
  }

  return {
    root,
    options: {
      root,
      artifacts: 'native-target-artifacts',
      commit,
      version,
    },
    cleanup() {
      fs.rmSync(root, { recursive: true, force: true })
    },
  }
}

function receiptPath(fixture, target) {
  return path.join(
    fixture.root,
    fixture.options.artifacts,
    `zigcss-${target}`,
    'native-target-evidence',
    `${target}.json`,
  )
}

test('native smoke validates one closed commit-bound receipt set across every release target', () => {
  const fixture = makeFixture()
  try {
    const evidence = validateNativePackageEvidence(fixture.options)
    assert.equal(evidence.schemaVersion, 1)
    assert.equal(evidence.commit, commit)
    assert.equal(evidence.version, version)
    assert.deepEqual(evidence.languages, ['css', 'scss', 'sass', 'less', 'stylus'])
    assert.deepEqual(evidence.distributionForms, [
      'direct-archive',
      'offline-installed-package',
    ])
    assert.deepEqual(evidence.terminalCounts, {
      targets: 5,
      languages: 5,
      distributionForms: 2,
      stylesheetCompilations: 50,
      tracedInvocations: 60,
      nativeSpawns: 60,
      networkAttempts: 0,
      deniedProcessAttempts: 0,
    })
    assert.deepEqual(
      evidence.targets.map(target => ({
        target: target.target,
        runner: target.runner,
        host: target.host,
      })),
      nativeSmokeTargets.map(target => ({
        target: target.target,
        runner: target.runner,
        host: {
          platform: target.nodePlatform,
          arch: target.nodeArch,
        },
      })),
    )
    assert.equal(new Set(evidence.targets.map(target => target.receiptSha256)).size, 5)

    assert.equal(
      writeNativePackageEvidence(fixture.root, 'native-package-evidence.json', evidence),
      'native-package-evidence.json',
    )
    assert.equal(
      fs.readFileSync(path.join(fixture.root, 'native-package-evidence.json'), 'utf8'),
      `${JSON.stringify(evidence, null, 2)}\n`,
    )
    assert.throws(
      () => writeNativePackageEvidence(fixture.root, 'native-package-evidence.json', evidence),
      /already exists/,
    )
    assert.throws(
      () => writeNativePackageEvidence(fixture.root, '../native-package-evidence.json', evidence),
      /output path/,
    )
  } finally {
    fixture.cleanup()
  }
})

test('native package evidence rejects lower, over-limit, drifted, and substituted target sets', () => {
  for (const mutate of [
    fixture => fs.rmSync(path.join(
      fixture.root,
      fixture.options.artifacts,
      `zigcss-${nativeSmokeTargets.at(-1).target}`,
    ), { recursive: true }),
    fixture => fs.mkdirSync(path.join(
      fixture.root,
      fixture.options.artifacts,
      'zigcss-riscv64-linux',
    )),
    fixture => {
      const filename = receiptPath(fixture, nativeSmokeTargets[0].target)
      const evidence = JSON.parse(fs.readFileSync(filename, 'utf8'))
      evidence.commit = 'f'.repeat(40)
      fs.writeFileSync(filename, `${JSON.stringify(evidence, null, 2)}\n`)
    },
    fixture => fs.appendFileSync(path.join(
      fixture.root,
      fixture.options.artifacts,
      `zigcss-${nativeSmokeTargets[1].target}`,
      'zig-out',
      'bin',
      nativeSmokeTargets[1].binaryName,
    ), 'tampered'),
    fixture => {
      const filename = receiptPath(fixture, nativeSmokeTargets[2].target)
      fs.writeFileSync(filename, ` ${fs.readFileSync(filename, 'utf8')}`)
    },
    fixture => {
      const filename = receiptPath(fixture, nativeSmokeTargets[3].target)
      const evidence = JSON.parse(fs.readFileSync(filename, 'utf8'))
      evidence.offlineInstalledPackage.nodeApi.optionRejections = 0
      fs.writeFileSync(filename, `${JSON.stringify(evidence, null, 2)}\n`)
    },
  ]) {
    const fixture = makeFixture()
    try {
      mutate(fixture)
      assert.throws(
        () => validateNativePackageEvidence(fixture.options),
        /native package evidence integrity/,
      )
    } finally {
      fixture.cleanup()
    }
  }

  const fixture = makeFixture()
  const outside = `${fixture.root}-outside`
  try {
    fs.mkdirSync(outside)
    const target = nativeSmokeTargets[3].target
    const directory = path.dirname(receiptPath(fixture, target))
    fs.rmSync(directory, { recursive: true })
    fs.symlinkSync(outside, directory)
    assert.throws(
      () => validateNativePackageEvidence(fixture.options),
      /regular non-symlink directory/,
    )
  } finally {
    fixture.cleanup()
    fs.rmSync(outside, { recursive: true, force: true })
  }
})

test('native package evidence CLI owns one exact finite input and create-only output contract', () => {
  assert.deepEqual(parseNativePackageEvidenceArguments([
    '--artifacts', 'native-target-artifacts',
    '--commit', commit,
    '--version', version,
    '--output', 'native-package-evidence.json',
  ]), {
    artifacts: 'native-target-artifacts',
    commit,
    version,
    output: 'native-package-evidence.json',
  })

  for (const invalid of [
    [],
    ['--artifacts', 'native-target-artifacts'],
    ['--artifacts', '../artifacts', '--commit', commit, '--version', version, '--output', 'native-package-evidence.json'],
    ['--artifacts', 'native-target-artifacts', '--commit', commit.toUpperCase(), '--version', version, '--output', 'native-package-evidence.json'],
    ['--artifacts', 'native-target-artifacts', '--commit', commit, '--version', version, '--output', '../evidence.json'],
    ['--artifacts', 'native-target-artifacts', '--commit', commit, '--version', version, '--output', 'native-package-evidence.json', '--extra', 'value'],
  ]) {
    assert.throws(
      () => parseNativePackageEvidenceArguments(invalid),
      /native package evidence integrity/,
    )
  }
})

test('build aggregates every matching runner receipt before package verification', () => {
  const workflow = fs.readFileSync(new URL('../.github/workflows/build.yml', import.meta.url), 'utf8')
  const expected = {
    targets: 5,
    downloadedArtifacts: 5,
    aggregateReceipts: 5,
  }
  assert.deepEqual(validateNativePackageEvidenceWorkflow(workflow), expected)

  const provenanceDependency = [
    '  native-provenance-evidence:',
    '    name: Native Provenance ${{ matrix.target }}',
    "    if: github.event_name == 'push' && github.ref == 'refs/heads/main'",
    '    needs: build',
  ].join('\n')
  const aggregateDependency = [
    '  native-package-evidence:',
    '    name: Native Package Evidence',
    '    needs: build',
  ].join('\n')
  assert.equal(workflow.split(provenanceDependency).length, 2)
  assert.equal(workflow.split(aggregateDependency).length, 2)
  assert.deepEqual(
    validateNativePackageEvidenceWorkflow(workflow.replace(
      provenanceDependency,
      provenanceDependency.replace('    needs: build', '    needs: test'),
    )),
    expected,
  )

  for (const changed of [
    workflow.replace(
      aggregateDependency,
      aggregateDependency.replace('    needs: build', '    needs: test'),
    ),
    workflow.replace('          pattern: zigcss-*', '          pattern: zigcss-x86_64-linux'),
    workflow.replace(
      '            --output native-package-evidence.json',
      '            --output missing-evidence.json',
    ),
    workflow.replace('          path: native-package-evidence.json', '          path: .'),
  ]) {
    assert.throws(
      () => validateNativePackageEvidenceWorkflow(changed),
      /native package evidence integrity/,
    )
  }
})
