import fs from 'node:fs'
import path from 'node:path'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

const scriptPath = fileURLToPath(import.meta.url)
export const repositoryRoot = path.resolve(path.dirname(scriptPath), '..')

const contract = {
  schemaVersion: 1,
  requiredPlatform: 'linux',
  requiredArchitecture: 'x64',
  attestationStatus: 'verified-bare-metal',
  detectorExecutable: '/usr/bin/systemd-detect-virt',
  requiredDetectorResults: {
    vm: 'none',
    container: 'none',
  },
  requiredChecks: [
    'systemd-detect-virt-vm',
    'systemd-detect-virt-container',
    'cpu-hypervisor-flag-absent',
    'sys-hypervisor-type-absent',
    'container-marker-files-absent',
    'container-cgroup-markers-absent',
    'dmi-identity-present',
    'dmi-virtualization-markers-absent',
  ],
  publicDmiFields: ['systemVendor', 'productName', 'boardVendor'],
}

const packageScripts = {
  'check:benchmark-host': 'node scripts/attest-benchmark-host.mjs --check',
  'test:benchmark-host': 'node --test scripts/attest-benchmark-host.test.mjs',
}

const snapshotFields = [
  'platform',
  'architecture',
  'detectorExecutable',
  'detectorVersion',
  'vmDetection',
  'containerDetection',
  'cpuInfo',
  'sysHypervisorType',
  'containerMarkerFiles',
  'cgroup',
  'containerEnvironment',
  'dmi',
]
const commandResultFields = ['status', 'signal', 'stdout', 'stderr']
const containerCgroupPattern = /(?:^|[\/:.-])(?:docker|containerd|kubepods|libpod|lxc|podman)(?:[\/:.-]|$)/im
const virtualDmiPattern = /(?:kvm|qemu|vmware|virtualbox|virtual machine|xen|bochs|parallels|openstack|bhyve|hyper-v|hvm domu|google compute engine|digitalocean|droplet|linode)/i

function fail(message) {
  throw new Error(`benchmark host attestation: ${message}`)
}

function same(left, right) {
  return JSON.stringify(left) === JSON.stringify(right)
}

function exactKeys(value, expected, label) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    fail(`${label} must be an object`)
  }
  const actual = Object.keys(value).sort()
  const wanted = [...expected].sort()
  if (!same(actual, wanted)) fail(`${label} fields drifted`)
}

function requireRegularFile(file, label) {
  let stat
  try {
    stat = fs.lstatSync(file)
  } catch (error) {
    fail(`${label} is unavailable: ${error.message}`)
  }
  if (!stat.isFile() || stat.isSymbolicLink()) fail(`${label} must be a regular non-symlink file`)
  return stat
}

function readJson(file, label) {
  requireRegularFile(file, label)
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'))
  } catch (error) {
    fail(`${label} is not valid JSON: ${error.message}`)
  }
}

function boundedText(value, label, maximumBytes = 512) {
  if (
    typeof value !== 'string' ||
    value.length === 0 ||
    Buffer.byteLength(value, 'utf8') > maximumBytes ||
    /[\0-\x08\x0b\x0c\x0e-\x1f\x7f]/.test(value)
  ) {
    fail(`${label} must be bounded nonempty text`)
  }
  return value
}

function canonicalIdentity(value, label) {
  if (typeof value !== 'string') fail(`${label} must be text`)
  const normalized = value.replace(/\0/g, '').trim()
  boundedText(normalized, label, 256)
  if (/[\r\n\t]/.test(normalized)) fail(`${label} must be single-line text`)
  return normalized
}

function validateCommandResult(value, label) {
  exactKeys(value, commandResultFields, label)
  if (!Number.isInteger(value.status) || value.status < 0 || value.status > 255) {
    fail(`${label} status is invalid`)
  }
  if (value.signal !== null) fail(`${label} terminated by ${value.signal}`)
  if (typeof value.stdout !== 'string' || Buffer.byteLength(value.stdout, 'utf8') > 64 * 1024) {
    fail(`${label} stdout is invalid`)
  }
  if (typeof value.stderr !== 'string' || Buffer.byteLength(value.stderr, 'utf8') > 64 * 1024) {
    fail(`${label} stderr is invalid`)
  }
}

function detectorNone(result, label) {
  validateCommandResult(result, label)
  const stdout = result.stdout.trim()
  if (result.status === 0 && stdout !== 'none') {
    fail(`${label === 'virtual-machine detector' ? 'virtual machine' : 'container'} detected: ${stdout || 'unknown'}`)
  }
  if (result.status !== 1 || stdout !== 'none' || result.stderr !== '') {
    fail(`${label} result is ambiguous`)
  }
  return 'none'
}

export function notRequestedHostAttestation() {
  return { schemaVersion: 1, status: 'not-requested' }
}

export function validateBenchmarkHostAttestation(attestation, options = {}) {
  if (attestation?.status === 'not-requested') {
    exactKeys(attestation, ['schemaVersion', 'status'], 'host attestation')
    if (attestation.schemaVersion !== 1) fail('host attestation schema version drifted')
    if (options.controlledRequired === true) {
      fail('controlled archive requires a verified bare-metal attestation')
    }
    return true
  }

  exactKeys(
    attestation,
    [
      'schemaVersion',
      'status',
      'detector',
      'cpuHypervisorFlag',
      'sysHypervisorType',
      'containerMarkers',
      'dmi',
    ],
    'host attestation',
  )
  if (attestation.schemaVersion !== 1 || attestation.status !== contract.attestationStatus) {
    fail('host attestation does not identify verified bare metal')
  }
  exactKeys(attestation.detector, ['executable', 'version', 'vm', 'container'], 'host detector')
  if (attestation.detector.executable !== contract.detectorExecutable) {
    fail('host detector executable drifted')
  }
  boundedText(attestation.detector.version, 'host detector version', 256)
  if (!/^systemd [1-9][0-9]*(?:\s|$)/.test(attestation.detector.version)) {
    fail('host detector version is invalid')
  }
  if (
    attestation.detector.vm !== contract.requiredDetectorResults.vm ||
    attestation.detector.container !== contract.requiredDetectorResults.container
  ) {
    fail('host detector did not prove a non-virtualized non-container environment')
  }
  if (attestation.cpuHypervisorFlag !== false) fail('host attestation contains a hypervisor CPU flag')
  if (attestation.sysHypervisorType !== 'none') fail('host attestation contains a sysfs hypervisor')
  if (!Array.isArray(attestation.containerMarkers) || attestation.containerMarkers.length !== 0) {
    fail('host attestation contains a container marker')
  }
  exactKeys(attestation.dmi, contract.publicDmiFields, 'host DMI identity')
  for (const field of contract.publicDmiFields) {
    if (canonicalIdentity(attestation.dmi[field], `DMI ${field}`) !== attestation.dmi[field]) {
      fail(`DMI ${field} must use canonical text`)
    }
  }
  if (virtualDmiPattern.test(Object.values(attestation.dmi).join('\0'))) {
    fail('host DMI identity contains a virtualization marker')
  }
  return true
}

export function evaluateBenchmarkHostSnapshot(snapshot) {
  exactKeys(snapshot, snapshotFields, 'host snapshot')
  if (snapshot.platform !== contract.requiredPlatform) {
    fail(`platform must be ${contract.requiredPlatform}`)
  }
  if (snapshot.architecture !== contract.requiredArchitecture) {
    fail(`architecture must be ${contract.requiredArchitecture}`)
  }
  if (snapshot.detectorExecutable !== contract.detectorExecutable) {
    fail('detector executable drifted')
  }

  validateCommandResult(snapshot.detectorVersion, 'detector version check')
  if (snapshot.detectorVersion.status !== 0 || snapshot.detectorVersion.stderr !== '') {
    fail('detector version check failed')
  }
  const detectorVersion = snapshot.detectorVersion.stdout.split(/\r?\n/, 1)[0].trim()
  boundedText(detectorVersion, 'detector version', 256)
  if (!/^systemd [1-9][0-9]*(?:\s|$)/.test(detectorVersion)) {
    fail('detector version check failed')
  }

  const vm = detectorNone(snapshot.vmDetection, 'virtual-machine detector')
  const container = detectorNone(snapshot.containerDetection, 'container detector')

  boundedText(snapshot.cpuInfo, 'Linux CPU information', 4 * 1024 * 1024)
  const flagLines = [...snapshot.cpuInfo.matchAll(/^flags\s*:\s*(.*)$/gmi)]
  if (flagLines.length === 0) fail('Linux CPU flags are unavailable')
  const cpuHypervisorFlag = flagLines.some(match => (
    match[1].split(/\s+/).includes('hypervisor')
  ))
  if (cpuHypervisorFlag) fail('hypervisor CPU flag is present')

  if (snapshot.sysHypervisorType !== null && typeof snapshot.sysHypervisorType !== 'string') {
    fail('sysfs hypervisor evidence is invalid')
  }
  const sysHypervisorType = snapshot.sysHypervisorType?.trim() || 'none'
  if (sysHypervisorType !== 'none') fail(`sysfs hypervisor detected: ${sysHypervisorType}`)

  if (!Array.isArray(snapshot.containerMarkerFiles) || snapshot.containerMarkerFiles.some(value => typeof value !== 'string')) {
    fail('container marker evidence is invalid')
  }
  if (snapshot.containerMarkerFiles.length !== 0) {
    fail(`container marker detected: ${snapshot.containerMarkerFiles.join(', ')}`)
  }
  boundedText(snapshot.cgroup, 'PID 1 cgroup evidence', 1024 * 1024)
  if (containerCgroupPattern.test(snapshot.cgroup)) fail('container cgroup marker detected')
  if (snapshot.containerEnvironment !== null) {
    const value = canonicalIdentity(snapshot.containerEnvironment, 'container environment marker')
    fail(`container environment marker detected: ${value}`)
  }

  exactKeys(snapshot.dmi, contract.publicDmiFields, 'host DMI snapshot')
  const dmi = Object.fromEntries(contract.publicDmiFields.map(field => [
    field,
    canonicalIdentity(snapshot.dmi[field], `DMI ${field}`),
  ]))
  if (virtualDmiPattern.test(Object.values(dmi).join('\0'))) {
    fail('host DMI identity contains a virtualization marker')
  }
  const attestation = {
    schemaVersion: 1,
    status: contract.attestationStatus,
    detector: {
      executable: contract.detectorExecutable,
      version: detectorVersion,
      vm,
      container,
    },
    cpuHypervisorFlag: false,
    sysHypervisorType: 'none',
    containerMarkers: [],
    dmi,
  }
  validateBenchmarkHostAttestation(attestation, { controlledRequired: true })
  return attestation
}

function readBoundedFile(file, label, maximumBytes) {
  let value
  try {
    value = fs.readFileSync(file, 'utf8')
  } catch (error) {
    fail(`${label} is unavailable: ${error.message}`)
  }
  if (Buffer.byteLength(value, 'utf8') > maximumBytes) fail(`${label} exceeds its byte limit`)
  return value
}

function optionalBoundedFile(file, label, maximumBytes) {
  let value
  try {
    value = fs.readFileSync(file, 'utf8')
  } catch (error) {
    if (error.code === 'ENOENT') return null
    fail(`${label} is unavailable: ${error.message}`)
  }
  if (Buffer.byteLength(value, 'utf8') > maximumBytes) fail(`${label} exceeds its byte limit`)
  return value
}

function runDetector(argumentsList) {
  const result = spawnSync(contract.detectorExecutable, argumentsList, {
    encoding: 'utf8',
    env: { PATH: '/usr/bin:/bin', LANG: 'C', LC_ALL: 'C' },
    maxBuffer: 64 * 1024,
    timeout: 10_000,
  })
  if (result.error) fail(`detector execution failed: ${result.error.message}`)
  return {
    status: result.status,
    signal: result.signal,
    stdout: result.stdout,
    stderr: result.stderr,
  }
}

export function collectBenchmarkHostAttestation() {
  if (process.platform !== contract.requiredPlatform) fail(`platform must be ${contract.requiredPlatform}`)
  if (process.arch !== contract.requiredArchitecture) fail(`architecture must be ${contract.requiredArchitecture}`)
  const detector = requireRegularFile(contract.detectorExecutable, 'virtualization detector')
  if ((detector.mode & 0o111) === 0) fail('virtualization detector must be executable')

  const markerFiles = ['/.dockerenv', '/run/.containerenv'].filter(file => fs.existsSync(file))
  const containerEnvironment = typeof process.env.container === 'string' && process.env.container.trim() !== ''
    ? process.env.container
    : null
  const snapshot = {
    platform: process.platform,
    architecture: process.arch,
    detectorExecutable: contract.detectorExecutable,
    detectorVersion: runDetector(['--version']),
    vmDetection: runDetector(['--vm']),
    containerDetection: runDetector(['--container']),
    cpuInfo: readBoundedFile('/proc/cpuinfo', 'Linux CPU information', 4 * 1024 * 1024),
    sysHypervisorType: optionalBoundedFile('/sys/hypervisor/type', 'sysfs hypervisor type', 4096),
    containerMarkerFiles: markerFiles,
    cgroup: readBoundedFile('/proc/1/cgroup', 'PID 1 cgroup evidence', 1024 * 1024),
    containerEnvironment,
    dmi: {
      systemVendor: readBoundedFile('/sys/class/dmi/id/sys_vendor', 'DMI system vendor', 4096),
      productName: readBoundedFile('/sys/class/dmi/id/product_name', 'DMI product name', 4096),
      boardVendor: readBoundedFile('/sys/class/dmi/id/board_vendor', 'DMI board vendor', 4096),
    },
  }
  return evaluateBenchmarkHostSnapshot(snapshot)
}

export function validateBenchmarkHostContract(root = repositoryRoot) {
  const file = path.join(root, 'benchmarks', 'host.json')
  const actual = readJson(file, 'benchmarks/host.json')
  if (fs.readFileSync(file, 'utf8') !== `${JSON.stringify(contract, null, 2)}\n`) {
    fail('host contract does not match the closed bare-metal policy')
  }
  const packageJson = readJson(path.join(root, 'package.json'), 'package.json')
  for (const [name, command] of Object.entries(packageScripts)) {
    if (packageJson.scripts?.[name] !== command) fail(`package.json is missing the exact ${name} command`)
  }
  return actual
}

function main() {
  if (!same(process.argv.slice(2), ['--check'])) {
    fail('usage: node scripts/attest-benchmark-host.mjs --check')
  }
  validateBenchmarkHostContract(repositoryRoot)
  process.stdout.write('Benchmark host policy verified: controlled archives require fail-closed bare-metal Linux x64 attestation.\n')
}

if (process.argv[1] !== undefined && path.resolve(process.argv[1]) === scriptPath) main()
