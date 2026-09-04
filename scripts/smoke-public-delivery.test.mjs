import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import {
  assertAnonymousEnvironment,
  measureInstalledPackage,
  npmAuditSignatureArguments,
  npmInstallArguments,
  parseNpmAuditSignatures,
  parsePublicDeliveryArguments,
  publicDeliveryPolicy,
  publicDeliveryStylesheets,
  publicDeliveryTargets,
  runBoundedCommand,
  smokePublicDelivery,
  validateInstalledPublicPackage,
  validatePublicDeliveryLockfile,
} from './smoke-public-delivery.mjs'

const safePath = process.env.PATH ?? '/usr/bin:/bin'

function withTemporary(callback) {
  const temporary = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-public-delivery-test-')))
  try {
    return callback(temporary)
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }
}

function integrityFor(version) {
  return {
    version,
    archives: publicDeliveryTargets.map((item, index) => ({
      target: item.target,
      filename: 'zigcss-v' + version + '-' + item.target + '.' + item.extension,
      sha256: String(index + 1).repeat(64),
    })),
  }
}

function fixtureMap() {
  return Object.fromEntries(publicDeliveryStylesheets.map(item => [
    item.syntax,
    {
      source: item.source,
      format: item.format,
      expected: item.expected,
    },
  ]))
}

const fixtureDigestBytes = Buffer.from(Array.from({ length: 64 }, (_, index) => index))
const fixtureIntegrity = `sha512-${fixtureDigestBytes.toString('base64')}`
const fixtureSha512 = fixtureDigestBytes.toString('hex')

function lockEvidence(version) {
  return {
    integrity: fixtureIntegrity,
    resolved: `https://registry.npmjs.org/zigcss/-/zigcss-${version}.tgz`,
    sha512: fixtureSha512,
  }
}

function stageFakeLock(workspace, version, options = {}) {
  const lock = {
    name: options.lockName ?? 'zigcss-public-delivery-smoke',
    version: '0.0.0',
    lockfileVersion: options.lockfileVersion ?? 3,
    requires: true,
    packages: {
      '': {
        name: 'zigcss-public-delivery-smoke',
        version: '0.0.0',
        dependencies: {
          zigcss: options.requestedVersion ?? version,
        },
      },
      'node_modules/zigcss': {
        version: options.lockedVersion ?? version,
        resolved: options.resolved ?? `https://registry.npmjs.org/zigcss/-/zigcss-${version}.tgz`,
        integrity: options.integrity ?? fixtureIntegrity,
        hasInstallScript: options.hasInstallScript ?? true,
        bin: {
          zigcss: options.bin ?? 'index.js',
          'zigcss-install': 'install.js',
        },
      },
    },
  }
  fs.writeFileSync(path.join(workspace, 'package-lock.json'), `${JSON.stringify(lock, null, 2)}\n`)
  return lock
}

function attestationStatement(version, predicateType, sha512 = fixtureSha512) {
  return {
    _type: predicateType === publicDeliveryPolicy.publishPredicate
      ? 'https://in-toto.io/Statement/v0.1'
      : 'https://in-toto.io/Statement/v1',
    subject: [{
      name: `pkg:npm/zigcss@${version}`,
      digest: { sha512 },
    }],
    predicateType,
    predicate: {},
  }
}

function attestationBundle(version, predicateType) {
  return {
    predicateType,
    bundle: {
      mediaType: 'application/vnd.dev.sigstore.bundle+json;version=0.2',
      verificationMaterial: {},
      dsseEnvelope: {
        payload: Buffer.from(JSON.stringify(attestationStatement(version, predicateType))).toString('base64'),
        payloadType: 'application/vnd.in-toto+json',
        signatures: [{ sig: 'fixture-signature', keyid: '' }],
      },
    },
    signedAccessSignatureUrl: '',
  }
}

function auditReport(version) {
  return {
    invalid: [],
    missing: [],
    verified: [{
      name: 'zigcss',
      version,
      location: 'node_modules/zigcss',
      registry: 'https://registry.npmjs.org/',
      attestations: {
        url: `https://registry.npmjs.org/-/npm/v1/attestations/zigcss@${version}`,
        provenance: { predicateType: publicDeliveryPolicy.provenancePredicate },
      },
      attestationBundles: [
        attestationBundle(version, publicDeliveryPolicy.publishPredicate),
        attestationBundle(version, publicDeliveryPolicy.provenancePredicate),
      ],
    }],
  }
}

function successfulAudit(context) {
  return { stdout: JSON.stringify(auditReport(context.version)), stderr: '' }
}

function mutateBundleStatement(report, index, mutate) {
  const envelope = report.verified[0].attestationBundles[index].bundle.dsseEnvelope
  const statement = JSON.parse(Buffer.from(envelope.payload, 'base64').toString('utf8'))
  mutate(statement)
  envelope.payload = Buffer.from(JSON.stringify(statement)).toString('base64')
}

function stageFakePackage(workspace, version, options = {}) {
  const packageRoot = path.join(workspace, 'node_modules', 'zigcss')
  fs.mkdirSync(path.join(packageRoot, 'bin'), { recursive: true, mode: 0o700 })
  const manifest = {
    name: 'zigcss',
    version: options.manifestVersion ?? version,
    main: 'api.cjs',
    exports: {
      '.': {
        import: './api.mjs',
        require: './api.cjs',
      },
    },
    bin: {
      zigcss: 'index.js',
    },
    dependencies: {},
  }
  fs.writeFileSync(path.join(packageRoot, 'package.json'), JSON.stringify(manifest, null, 2) + '\n')
  const integrity = integrityFor(options.integrityVersion ?? version)
  if (options.badIntegrityDigest === true) integrity.archives[0].sha256 = 'not-a-digest'
  fs.writeFileSync(
    path.join(packageRoot, 'native-integrity.json'),
    JSON.stringify(integrity, null, 2) + '\n',
  )

  const cases = fixtureMap()
  const cliVersion = options.cliVersion ?? version
  const wrapperSource = [
    '#!/usr/bin/env node',
    "'use strict'",
    'const cases = ' + JSON.stringify(cases),
    'const version = ' + JSON.stringify(cliVersion),
    'const args = process.argv.slice(2)',
    "if (args.length === 1 && args[0] === '--version') {",
    "  process.stdout.write('zigcss ' + version + '\\n')",
    '} else {',
    "  const syntaxIndex = args.indexOf('--syntax')",
    '  const syntax = syntaxIndex === -1 ? undefined : args[syntaxIndex + 1]',
    '  const item = cases[syntax]',
    "  const format = args.includes('--minify') ? 'minified' : 'pretty'",
    "  if (item === undefined || item.format !== format) throw new Error('invalid fake CLI fixture')",
    '  process.stdout.write(item.expected)',
    "  if (version.includes('-')) process.stderr.write('Warning: ZigCSS ' + version + ' is an experimental release candidate; do not use it for production CSS.\\n')",
    '}',
    '',
  ].join('\n')
  fs.writeFileSync(path.join(packageRoot, 'index.js'), wrapperSource, { mode: 0o755 })

  const apiSource = [
    "'use strict'",
    'const cases = ' + JSON.stringify(cases),
    'function compileSync(source, options) {',
    '  const item = cases[options && options.syntax]',
    "  if (item === undefined || item.source !== source || item.format !== options.format) throw new Error('invalid fake API fixture')",
    '  const diagnostics = Object.freeze([])',
    '  const dependencies = Object.freeze([])',
    '  return Object.freeze({ css: item.expected, sourceMap: null, diagnostics, dependencies })',
    '}',
    'async function compile(source, options) { return compileSync(source, options) }',
    'module.exports = Object.freeze({ compile, compileSync })',
    '',
  ].join('\n')
  fs.writeFileSync(path.join(packageRoot, 'api.cjs'), apiSource)
  fs.writeFileSync(
    path.join(packageRoot, 'api.mjs'),
    [
      "import api from './api.cjs'",
      'export const compile = api.compile',
      'export const compileSync = api.compileSync',
      'export default api',
      '',
    ].join('\n'),
  )
  fs.writeFileSync(path.join(packageRoot, 'bin', 'zigcss'), 'fake native executable\n', { mode: 0o755 })
  stageFakeLock(workspace, version, options)
  return packageRoot
}

test('public delivery policy fixes the anonymous canonical-registry boundary', () => {
  assert.deepEqual(publicDeliveryPolicy, {
    registry: 'https://registry.npmjs.org/',
    packageName: 'zigcss',
    installTimeoutMs: 5 * 60 * 1000,
    auditTimeoutMs: 2 * 60 * 1000,
    commandTimeoutMs: 45 * 1000,
    totalTimeoutMs: 10 * 60 * 1000,
    installOutputBytes: 2 * 1024 * 1024,
    auditOutputBytes: 2 * 1024 * 1024,
    commandOutputBytes: 512 * 1024,
    lockfileBytes: 512 * 1024,
    attestationPayloadBytes: 512 * 1024,
    installedEntries: 4096,
    installedBytes: 384 * 1024 * 1024,
    publishPredicate: 'https://github.com/npm/attestation/tree/main/specs/publish/v0.1',
    provenancePredicate: 'https://slsa.dev/provenance/v1',
  })
  assert.deepEqual(
    publicDeliveryTargets.map(item => item.target),
    [
      'x86_64-linux',
      'aarch64-linux',
      'x86_64-macos',
      'aarch64-macos',
      'x86_64-windows',
    ],
  )
  assert.deepEqual(
    publicDeliveryStylesheets.map(item => item.syntax),
    ['css', 'scss', 'sass', 'less', 'stylus'],
  )
})

test('public delivery accepts only one exact canonical version argument', () => {
  assert.deepEqual(parsePublicDeliveryArguments(['--version', '0.7.0-rc.1']), {
    version: '0.7.0-rc.1',
  })
  assert.deepEqual(parsePublicDeliveryArguments(['--version', '0.7.0']), {
    version: '0.7.0',
  })
  for (const args of [
    [],
    ['0.7.0'],
    ['--version', 'v0.7.0'],
    ['--version', '0.7.0+build.1'],
    ['--version', '01.7.0'],
    ['--version', '0.7.0', '--registry', 'https://evil.example/'],
  ]) {
    assert.throws(() => parsePublicDeliveryArguments(args), /public delivery smoke|version/)
  }
})

test('npm install arguments force exact scripts-enabled isolated anonymous delivery', () => {
  withTemporary(workspace => {
    const paths = {
      workspace,
      userConfig: path.join(workspace, 'empty-user.npmrc'),
      globalConfig: path.join(workspace, 'empty-global.npmrc'),
      cache: path.join(workspace, 'npm-cache'),
    }
    assert.deepEqual(npmInstallArguments('0.7.0-rc.1', paths), [
      'install',
      '--package-lock=true',
      '--omit=dev',
      '--omit=optional',
      '--ignore-scripts=false',
      '--foreground-scripts',
      '--audit=false',
      '--fund=false',
      '--prefer-online',
      '--registry=https://registry.npmjs.org/',
      '--userconfig=' + paths.userConfig,
      '--globalconfig=' + paths.globalConfig,
      '--cache=' + paths.cache,
    ])
    assert.deepEqual(npmAuditSignatureArguments(paths), [
      'audit',
      'signatures',
      '--json',
      '--include-attestations',
      '--omit=dev',
      '--omit=optional',
      '--registry=https://registry.npmjs.org/',
      '--userconfig=' + paths.userConfig,
      '--globalconfig=' + paths.globalConfig,
      '--cache=' + paths.cache,
    ])
    assert.throws(
      () => npmInstallArguments('0.7.0-rc.1', {
        ...paths,
        cache: path.resolve(workspace, '..', 'escaped-cache'),
      }),
      /escapes the temporary consumer project/,
    )
    assert.throws(() => npmInstallArguments('v0.7.0', paths), /version/)
    assert.throws(() => npmInstallArguments('0.7.0', null), /isolation paths/)
    assert.throws(() => npmAuditSignatureArguments(null), /isolation paths/)
  })
})

test('anonymous environment fails closed for credentials, npm inheritance, and runtime injection', () => {
  assert.equal(assertAnonymousEnvironment({ PATH: safePath, CI: 'true' }), true)
  for (const name of [
    'GH_TOKEN',
    'GITHUB_TOKEN',
    'NODE_AUTH_TOKEN',
    'NPM_AUTH_TOKEN',
    'NPM_TOKEN',
    'npm_config_registry',
    'NPM_CONFIG_USERCONFIG',
    'PNPM_NPM_REGISTRY_SERVER',
    'YARN_NPM_REGISTRY_SERVER',
    'COREPACK_NPM_TOKEN',
    'NODE_OPTIONS',
    'NODE_PATH',
    'ZIGCSS_BINARY',
  ]) {
    assert.throws(
      () => assertAnonymousEnvironment({ PATH: safePath, [name]: 'secret-or-override' }),
      new RegExp(name, 'i'),
    )
  }
  assert.throws(() => assertAnonymousEnvironment({}), /PATH/)
  assert.throws(() => assertAnonymousEnvironment({ PATH: '' }), /PATH/)
  assert.throws(() => assertAnonymousEnvironment({ PATH: 'x'.repeat(65 * 1024) }), /PATH/)
  assert.throws(() => assertAnonymousEnvironment({ PATH: safePath, SAFE: 'bad\0value' }), /safe string/)
  assert.throws(() => assertAnonymousEnvironment(null), /environment/)
})

test('bounded child execution rejects unsafe options, timeouts, and output floods', () => {
  const base = {
    cwd: process.cwd(),
    env: process.env,
    timeoutMs: 1000,
    maximumOutputBytes: 1024,
    label: 'fixture child',
  }
  assert.deepEqual(
    runBoundedCommand(process.execPath, ['-e', "process.stdout.write('ok\\n')"], base),
    { stdout: 'ok\n', stderr: '' },
  )
  assert.throws(
    () => runBoundedCommand('node', ['--version'], base),
    /absolute path/,
  )
  assert.throws(
    () => runBoundedCommand(process.execPath, [], base),
    /arguments/,
  )
  assert.throws(
    () => runBoundedCommand(process.execPath, ['--version'], { ...base, timeoutMs: 0 }),
    /resource limits/,
  )
  assert.throws(
    () => runBoundedCommand(process.execPath, ['-e', "process.stdout.write('x'.repeat(8192))"], base),
    /output limit/,
  )
  assert.throws(
    () => runBoundedCommand(
      process.execPath,
      ['-e', 'setInterval(() => {}, 1000)'],
      { ...base, timeoutMs: 50 },
    ),
    /timed out/,
  )
  assert.throws(
    () => runBoundedCommand(
      process.execPath,
      ['-e', "process.stderr.write('untrusted-secret-output'); process.exit(9)"],
      { ...base, label: 'npm signature audit', includeFailureOutput: false },
    ),
    error => {
      assert.match(error.message, /npm signature audit failed with exit 9/)
      assert.doesNotMatch(error.message, /untrusted-secret-output/)
      return true
    },
  )
})

test('package lock validation binds one canonical exact registry artifact and integrity', () => {
  withTemporary(workspace => {
    stageFakeLock(workspace, '0.7.0-rc.1')
    const evidence = validatePublicDeliveryLockfile(workspace, '0.7.0-rc.1')
    assert.equal(evidence.integrity, fixtureIntegrity)
    assert.equal(evidence.sha512, fixtureSha512)
    assert.equal(evidence.resolved, 'https://registry.npmjs.org/zigcss/-/zigcss-0.7.0-rc.1.tgz')
    assert.equal(evidence.bytes > 0 && evidence.bytes <= publicDeliveryPolicy.lockfileBytes, true)
    assert.equal(Object.isFrozen(evidence), true)
  })

  for (const options of [
    { lockName: 'other' },
    { lockfileVersion: 2 },
    { requestedVersion: '0.7.0' },
    { lockedVersion: '0.7.0' },
    { resolved: 'https://evil.example/zigcss.tgz' },
    { integrity: 'sha512-not-base64' },
    { hasInstallScript: false },
    { bin: 'other.js' },
  ]) {
    withTemporary(workspace => {
      stageFakeLock(workspace, '0.7.0-rc.1', options)
      assert.throws(
        () => validatePublicDeliveryLockfile(workspace, '0.7.0-rc.1'),
        /public delivery smoke/,
      )
    })
  }

  withTemporary(workspace => {
    fs.writeFileSync(
      path.join(workspace, 'package-lock.json'),
      Buffer.alloc(publicDeliveryPolicy.lockfileBytes + 1, 0x20),
    )
    assert.throws(
      () => validatePublicDeliveryLockfile(workspace, '0.7.0-rc.1'),
      /bounded stable regular non-symlink file/,
    )
  })
})

test('package lock validation rejects links before reading', {
  skip: process.platform === 'win32',
}, () => {
  withTemporary(workspace => {
    stageFakeLock(workspace, '0.7.0-rc.1')
    const lockPath = path.join(workspace, 'package-lock.json')
    fs.renameSync(lockPath, path.join(workspace, 'lock-target.json'))
    fs.symlinkSync('lock-target.json', lockPath)
    assert.throws(
      () => validatePublicDeliveryLockfile(workspace, '0.7.0-rc.1'),
      /could not be opened safely|non-symlink/,
    )
  })

  withTemporary(workspace => {
    stageFakeLock(workspace, '0.7.0-rc.1')
    fs.linkSync(path.join(workspace, 'package-lock.json'), path.join(workspace, 'second-lock.json'))
    assert.throws(
      () => validatePublicDeliveryLockfile(workspace, '0.7.0-rc.1'),
      /bounded stable regular non-symlink file/,
    )
  })
})

test('npm signature audit parser requires the exact package, registry, and two verified attestations', () => {
  const version = '0.7.0-rc.1'
  const result = parseNpmAuditSignatures(
    JSON.stringify(auditReport(version)),
    version,
    lockEvidence(version),
  )
  assert.deepEqual(result, {
    attestationPredicates: [
      publicDeliveryPolicy.publishPredicate,
      publicDeliveryPolicy.provenancePredicate,
    ].sort(),
    provenanceVerified: true,
    registrySignature: true,
  })
  assert.equal(Object.isFrozen(result), true)
  assert.equal(Object.isFrozen(result.attestationPredicates), true)
})

test('npm signature audit parser fails closed on schema, identity, signature, and provenance ambiguity', () => {
  const version = '0.7.0-rc.1'
  const cases = [
    report => { report.extra = true },
    report => { report.invalid.push({ name: 'zigcss' }) },
    report => { report.missing.push({ name: 'zigcss' }) },
    report => { report.verified = [] },
    report => { report.verified.push(structuredClone(report.verified[0])) },
    report => { report.verified[0].name = 'other' },
    report => { report.verified[0].version = '0.7.0' },
    report => { report.verified[0].location = 'node_modules/other' },
    report => { report.verified[0].registry = 'https://evil.example/' },
    report => { report.verified[0].extra = true },
    report => { report.verified[0].attestations.url = 'https://evil.example/' },
    report => { report.verified[0].attestations.provenance.predicateType = 'https://slsa.dev/provenance/v0.2' },
    report => { report.verified[0].attestationBundles.pop() },
    report => { report.verified[0].attestationBundles[1].predicateType = publicDeliveryPolicy.publishPredicate },
    report => { report.verified[0].attestationBundles[0].extra = true },
    report => { report.verified[0].attestationBundles[0].signedAccessSignatureUrl = 'https://evil.example/' },
    report => { report.verified[0].attestationBundles[0].bundle.mediaType = 'application/json' },
    report => { report.verified[0].attestationBundles[0].bundle.verificationMaterial = null },
    report => { report.verified[0].attestationBundles[0].bundle.dsseEnvelope.payloadType = 'text/plain' },
    report => { report.verified[0].attestationBundles[0].bundle.dsseEnvelope.signatures = [] },
    report => { delete report.verified[0].attestationBundles[0].bundle.dsseEnvelope.signatures[0].keyid },
    report => { report.verified[0].attestationBundles[0].bundle.dsseEnvelope.payload = '%' },
    report => mutateBundleStatement(report, 0, statement => { statement._type = 'other' }),
    report => mutateBundleStatement(report, 0, statement => { statement.predicateType = 'other' }),
    report => mutateBundleStatement(report, 0, statement => { statement.predicate = null }),
    report => mutateBundleStatement(report, 0, statement => { statement.subject.push(structuredClone(statement.subject[0])) }),
    report => mutateBundleStatement(report, 0, statement => { statement.subject[0].name = 'pkg:npm/other@0.7.0-rc.1' }),
    report => mutateBundleStatement(report, 0, statement => { statement.subject[0].digest.sha512 = '0'.repeat(128) }),
    report => mutateBundleStatement(report, 0, statement => { statement.subject[0].digest.sha256 = '0'.repeat(64) }),
  ]
  for (const mutate of cases) {
    const report = auditReport(version)
    mutate(report)
    assert.throws(
      () => parseNpmAuditSignatures(JSON.stringify(report), version, lockEvidence(version)),
      /public delivery smoke/,
    )
  }

  for (const source of [
    '',
    '{',
    '\uFFFD',
    ' '.repeat(publicDeliveryPolicy.auditOutputBytes + 1),
  ]) {
    assert.throws(
      () => parseNpmAuditSignatures(source, version, lockEvidence(version)),
      /public delivery smoke/,
    )
  }
  assert.throws(
    () => parseNpmAuditSignatures(
      JSON.stringify(auditReport(version)),
      version,
      { ...lockEvidence(version), resolved: 'https://evil.example/zigcss.tgz' },
    ),
    /lock evidence/,
  )
  assert.throws(
    () => parseNpmAuditSignatures(
      JSON.stringify(auditReport(version)),
      version,
      { ...lockEvidence(version), sha512: '0'.repeat(128) },
    ),
    /lock evidence/,
  )
})

test('npm signature audit parser bounds each decoded attestation statement', () => {
  const version = '0.7.0-rc.1'
  const report = auditReport(version)
  report.verified[0].attestationBundles[0].bundle.dsseEnvelope.payload = Buffer
    .alloc(publicDeliveryPolicy.attestationPayloadBytes + 1)
    .toString('base64')
  assert.throws(
    () => parseNpmAuditSignatures(JSON.stringify(report), version, lockEvidence(version)),
    /bounded canonical base64 payload/,
  )
})

test('installed package validation binds manifest, five-target integrity, files, and size', () => {
  withTemporary(workspace => {
    const packageRoot = stageFakePackage(workspace, '0.7.0-rc.1')
    const result = validateInstalledPublicPackage(workspace, '0.7.0-rc.1')
    assert.equal(result.packageRoot, packageRoot)
    assert.equal(result.entries > 0, true)
    assert.equal(result.bytes > 0, true)

    const integrityPath = path.join(packageRoot, 'native-integrity.json')
    const integrity = JSON.parse(fs.readFileSync(integrityPath, 'utf8'))
    integrity.archives[0].filename = 'wrong.tar.gz'
    fs.writeFileSync(integrityPath, JSON.stringify(integrity))
    assert.throws(
      () => validateInstalledPublicPackage(workspace, '0.7.0-rc.1'),
      /archive 0 changed identity/,
    )
  })

  withTemporary(workspace => {
    stageFakePackage(workspace, '0.7.0-rc.1', { manifestVersion: '0.7.0' })
    assert.throws(
      () => validateInstalledPublicPackage(workspace, '0.7.0-rc.1'),
      /manifest identity/,
    )
  })

  withTemporary(workspace => {
    const packageRoot = stageFakePackage(workspace, '0.7.0-rc.1')
    fs.chmodSync(path.join(packageRoot, 'bin', 'zigcss'), 0o600)
    assert.throws(
      () => validateInstalledPublicPackage(workspace, '0.7.0-rc.1'),
      /not executable/,
    )
  })

  withTemporary(workspace => {
    const packageRoot = stageFakePackage(workspace, '0.7.0-rc.1')
    fs.rmSync(path.join(packageRoot, 'api.mjs'))
    fs.symlinkSync('api.cjs', path.join(packageRoot, 'api.mjs'))
    assert.throws(
      () => validateInstalledPublicPackage(workspace, '0.7.0-rc.1'),
      /non-symlink file/,
    )
  })

  withTemporary(workspace => {
    fs.writeFileSync(path.join(workspace, 'large'), 'xx')
    assert.throws(
      () => measureInstalledPackage(workspace, { installedEntries: 1, installedBytes: 1 }),
      /byte limit/,
    )
  })
})

test('end-to-end smoke proves prerelease CLI and both installed Node module systems', () => {
  let temporary
  let installEnvironment
  let installNpmCli
  const result = smokePublicDelivery('0.7.0-rc.1', {
    platform: 'linux',
    environment: { PATH: safePath },
    install(context) {
      temporary = context.workspace
      assert.equal(context.version, '0.7.0-rc.1')
      assert.equal(context.arguments[0], 'install')
      assert.equal(context.arguments.includes('zigcss@0.7.0-rc.1'), false)
      assert.equal(context.arguments.includes('--ignore-scripts=false'), true)
      assert.equal(context.environment.NODE_AUTH_TOKEN, undefined)
      assert.equal(context.environment.NPM_TOKEN, undefined)
      assert.equal(context.environment.NPM_CONFIG_REGISTRY, publicDeliveryPolicy.registry)
      assert.equal(fs.readFileSync(context.isolation.userConfig, 'utf8'), '')
      assert.equal(fs.readFileSync(context.isolation.globalConfig, 'utf8'), '')
      assert.deepEqual(JSON.parse(fs.readFileSync(path.join(context.workspace, 'package.json'), 'utf8')), {
        name: 'zigcss-public-delivery-smoke',
        version: '0.0.0',
        private: true,
        dependencies: { zigcss: '0.7.0-rc.1' },
      })
      assert.equal(path.isAbsolute(context.npmCli), true)
      installEnvironment = context.environment
      installNpmCli = context.npmCli
      stageFakePackage(context.workspace, context.version)
    },
    audit(context) {
      assert.equal(context.npmCli, installNpmCli)
      assert.equal(context.environment, installEnvironment)
      assert.deepEqual(context.arguments.slice(0, 5), [
        'audit',
        'signatures',
        '--json',
        '--include-attestations',
        '--omit=dev',
      ])
      assert.equal(context.lockfile.integrity, fixtureIntegrity)
      assert.equal(context.lockfile.sha512, fixtureSha512)
      return successfulAudit(context)
    },
  })
  assert.deepEqual(
    {
      version: result.version,
      registry: result.registry,
      cliCompilations: result.cliCompilations,
      nodeApiModules: result.nodeApiModules,
      nodeApiCompilations: result.nodeApiCompilations,
      provenanceVerified: result.provenanceVerified,
      registrySignature: result.registrySignature,
    },
    {
      version: '0.7.0-rc.1',
      registry: 'https://registry.npmjs.org/',
      cliCompilations: 5,
      nodeApiModules: ['cjs', 'esm'],
      nodeApiCompilations: 20,
      provenanceVerified: true,
      registrySignature: true,
    },
  )
  assert.equal(result.installedEntries > 0, true)
  assert.equal(result.installedBytes > 0, true)
  assert.equal(fs.existsSync(temporary), false)
})

test('stable public delivery requires a quiet compiler contract', () => {
  const result = smokePublicDelivery('0.7.0', {
    platform: 'linux',
    environment: { PATH: safePath },
    install(context) {
      stageFakePackage(context.workspace, context.version)
    },
    audit: successfulAudit,
  })
  assert.equal(result.version, '0.7.0')
  assert.equal(result.cliCompilations, 5)
})

test('end-to-end smoke rejects malformed or unbounded npm signature audit callback results', () => {
  const run = audit => smokePublicDelivery('0.7.0-rc.1', {
    platform: 'linux',
    environment: { PATH: safePath },
    install(context) {
      stageFakePackage(context.workspace, context.version)
    },
    audit,
  })
  assert.throws(() => run(() => null), /invalid result/)
  assert.throws(() => run(() => Promise.resolve(successfulAudit({ version: '0.7.0-rc.1' }))), /invalid result/)
  assert.throws(
    () => run(() => ({ stdout: JSON.stringify(auditReport('0.7.0-rc.1')), stderr: 'warning' })),
    /unexpected diagnostic output/,
  )
  assert.throws(
    () => run(() => ({ stdout: 'x'.repeat(publicDeliveryPolicy.auditOutputBytes + 1), stderr: '' })),
    /output limit/,
  )
  assert.throws(
    () => run(() => ({ stdout: '{', stderr: '' })),
    /not valid JSON/,
  )
})

test('end-to-end smoke fails closed on platform, environment, and installed version drift', () => {
  assert.throws(
    () => smokePublicDelivery('0.7.0-rc.1', {
      platform: 'darwin',
      environment: { PATH: safePath },
    }),
    /requires Linux/,
  )
  assert.throws(
    () => smokePublicDelivery('0.7.0-rc.1', {
      platform: 'linux',
      environment: { PATH: safePath, NODE_AUTH_TOKEN: 'must-not-leak' },
    }),
    /NODE_AUTH_TOKEN/,
  )
  let temporary
  assert.throws(
    () => smokePublicDelivery('0.7.0-rc.1', {
      platform: 'linux',
      environment: { PATH: safePath },
      install(context) {
        temporary = context.workspace
        stageFakePackage(context.workspace, context.version, { manifestVersion: '0.7.0' })
      },
    }),
    /manifest identity/,
  )
  assert.equal(fs.existsSync(temporary), false)
})

test('end-to-end smoke rejects a CLI that reports a different public version', () => {
  assert.throws(
    () => smokePublicDelivery('0.7.0-rc.1', {
      platform: 'linux',
      environment: { PATH: safePath },
      install(context) {
        stageFakePackage(context.workspace, context.version, { cliVersion: '0.7.0' })
      },
      audit: successfulAudit,
    }),
    /unexpected version contract/,
  )
})
