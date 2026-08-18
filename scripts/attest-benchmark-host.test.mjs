import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'

import {
  evaluateBenchmarkHostSnapshot,
  notRequestedHostAttestation,
  repositoryRoot,
  validateBenchmarkHostAttestation,
  validateBenchmarkHostContract,
} from './attest-benchmark-host.mjs'

function bareMetalSnapshot() {
  return {
    platform: 'linux',
    architecture: 'x64',
    detectorExecutable: '/usr/bin/systemd-detect-virt',
    detectorVersion: {
      status: 0,
      signal: null,
      stdout: 'systemd 255 (255.4-1)\n+PAM +AUDIT\n',
      stderr: '',
    },
    vmDetection: {
      status: 1,
      signal: null,
      stdout: 'none\n',
      stderr: '',
    },
    containerDetection: {
      status: 1,
      signal: null,
      stdout: 'none\n',
      stderr: '',
    },
    cpuInfo: 'processor : 0\nflags : fpu vme de pse tsc msr\n',
    sysHypervisorType: null,
    containerMarkerFiles: [],
    cgroup: '0::/init.scope\n',
    containerEnvironment: null,
    dmi: {
      systemVendor: 'Example Systems',
      productName: 'Dedicated Benchmark Host',
      boardVendor: 'Example Boards',
    },
  }
}

test('bare-metal host snapshot produces a bounded public attestation', () => {
  const attestation = evaluateBenchmarkHostSnapshot(bareMetalSnapshot())
  assert.deepEqual(attestation, {
    schemaVersion: 1,
    status: 'verified-bare-metal',
    detector: {
      executable: '/usr/bin/systemd-detect-virt',
      version: 'systemd 255 (255.4-1)',
      vm: 'none',
      container: 'none',
    },
    cpuHypervisorFlag: false,
    sysHypervisorType: 'none',
    containerMarkers: [],
    dmi: {
      systemVendor: 'Example Systems',
      productName: 'Dedicated Benchmark Host',
      boardVendor: 'Example Boards',
    },
  })
  assert.equal(validateBenchmarkHostAttestation(attestation, { controlledRequired: true }), true)
})

test('host attestation rejects virtual machines, containers, and ambiguous evidence', () => {
  const virtualMachine = bareMetalSnapshot()
  virtualMachine.vmDetection = { status: 0, signal: null, stdout: 'kvm\n', stderr: '' }
  assert.throws(() => evaluateBenchmarkHostSnapshot(virtualMachine), /virtual machine.*kvm/i)

  const hypervisorFlag = bareMetalSnapshot()
  hypervisorFlag.cpuInfo = 'flags : fpu hypervisor tsc\n'
  assert.throws(() => evaluateBenchmarkHostSnapshot(hypervisorFlag), /hypervisor CPU flag/i)

  const hypervisorType = bareMetalSnapshot()
  hypervisorType.sysHypervisorType = 'xen\n'
  assert.throws(() => evaluateBenchmarkHostSnapshot(hypervisorType), /sysfs hypervisor/i)

  const marker = bareMetalSnapshot()
  marker.containerMarkerFiles = ['/.dockerenv']
  assert.throws(() => evaluateBenchmarkHostSnapshot(marker), /container marker/i)

  const cgroup = bareMetalSnapshot()
  cgroup.cgroup = '0::/docker/0123456789abcdef\n'
  assert.throws(() => evaluateBenchmarkHostSnapshot(cgroup), /container cgroup/i)

  const missingDmi = bareMetalSnapshot()
  missingDmi.dmi.productName = ''
  assert.throws(() => evaluateBenchmarkHostSnapshot(missingDmi), /DMI productName/i)

  const virtualDmi = bareMetalSnapshot()
  virtualDmi.dmi.productName = 'KVM Virtual Machine'
  assert.throws(() => evaluateBenchmarkHostSnapshot(virtualDmi), /DMI identity.*virtualization marker/i)
})

test('host attestation rejects wrong platforms and detector failures', () => {
  const wrongPlatform = bareMetalSnapshot()
  wrongPlatform.platform = 'darwin'
  assert.throws(() => evaluateBenchmarkHostSnapshot(wrongPlatform), /platform must be linux/i)

  const wrongArchitecture = bareMetalSnapshot()
  wrongArchitecture.architecture = 'arm64'
  assert.throws(() => evaluateBenchmarkHostSnapshot(wrongArchitecture), /architecture must be x64/i)

  const unavailable = bareMetalSnapshot()
  unavailable.detectorVersion.status = 127
  assert.throws(() => evaluateBenchmarkHostSnapshot(unavailable), /detector version check failed/i)

  const ambiguous = bareMetalSnapshot()
  ambiguous.vmDetection = { status: 1, signal: null, stdout: '', stderr: '' }
  assert.throws(() => evaluateBenchmarkHostSnapshot(ambiguous), /virtual-machine detector result is ambiguous/i)
})

test('ordinary local reports are explicit and cannot enter a controlled archive', () => {
  const attestation = notRequestedHostAttestation()
  assert.deepEqual(attestation, { schemaVersion: 1, status: 'not-requested' })
  assert.equal(validateBenchmarkHostAttestation(attestation), true)
  assert.throws(
    () => validateBenchmarkHostAttestation(attestation, { controlledRequired: true }),
    /verified bare-metal attestation/i,
  )
})

test('host contract is canonical and symlink substitution fails closed', t => {
  const contract = validateBenchmarkHostContract(repositoryRoot)
  assert.equal(contract.requiredPlatform, 'linux')
  assert.equal(contract.requiredArchitecture, 'x64')
  assert.equal(contract.attestationStatus, 'verified-bare-metal')

  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-benchmark-host-'))
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  fs.mkdirSync(path.join(root, 'benchmarks'))
  fs.copyFileSync(path.join(repositoryRoot, 'package.json'), path.join(root, 'package.json'))
  const source = path.join(repositoryRoot, 'benchmarks', 'host.json')
  const target = path.join(root, 'benchmarks', 'host.json')
  fs.symlinkSync(source, target)
  assert.throws(() => validateBenchmarkHostContract(root), /regular non-symlink file/i)
})
