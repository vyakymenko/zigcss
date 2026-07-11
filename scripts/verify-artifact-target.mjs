#!/usr/bin/env node

import fs from 'node:fs'
import path from 'node:path'
import { pathToFileURL } from 'node:url'

const ELF_ARCH = new Map([
  [62, 'x86_64'],
  [183, 'aarch64'],
])

const MACHO_ARCH = new Map([
  [0x01000007, 'x86_64'],
  [0x0100000c, 'aarch64'],
])

const PE_ARCH = new Map([
  [0x8664, 'x86_64'],
  [0xaa64, 'aarch64'],
])

function requireLength(binary, length, format) {
  if (binary.length < length)
    throw new Error(`${format} header is truncated`)
}

function knownArchitecture(mapping, value, format) {
  const arch = mapping.get(value)
  if (!arch)
    throw new Error(`unsupported ${format} architecture code 0x${value.toString(16)}`)
  return arch
}

export function inspectBinary(binary) {
  if (!Buffer.isBuffer(binary))
    binary = Buffer.from(binary)

  requireLength(binary, 4, 'binary')

  if (binary[0] === 0x7f && binary.subarray(1, 4).toString('ascii') === 'ELF') {
    requireLength(binary, 20, 'ELF')
    const endianness = binary[5]
    const machine = endianness === 1
      ? binary.readUInt16LE(18)
      : endianness === 2
        ? binary.readUInt16BE(18)
        : null
    if (machine === null)
      throw new Error(`unsupported ELF endianness ${endianness}`)
    return { arch: knownArchitecture(ELF_ARCH, machine, 'ELF'), format: 'elf' }
  }

  const machMagic = binary.readUInt32LE(0)
  if (machMagic === 0xfeedface || machMagic === 0xfeedfacf) {
    requireLength(binary, 8, 'Mach-O')
    const cpuType = binary.readUInt32LE(4)
    return { arch: knownArchitecture(MACHO_ARCH, cpuType, 'Mach-O'), format: 'macho' }
  }

  if (binary.subarray(0, 2).toString('ascii') === 'MZ') {
    requireLength(binary, 0x40, 'PE')
    const peOffset = binary.readUInt32LE(0x3c)
    requireLength(binary, peOffset + 6, 'PE')
    if (binary.subarray(peOffset, peOffset + 4).toString('binary') !== 'PE\0\0')
      throw new Error('invalid PE signature')
    const machine = binary.readUInt16LE(peOffset + 4)
    return { arch: knownArchitecture(PE_ARCH, machine, 'PE'), format: 'pe' }
  }

  throw new Error('unrecognized executable format')
}

export function assertArtifactMatchesTarget(binary, target) {
  const [arch, os] = target.split('-')
  const expectedFormat = {
    linux: 'elf',
    macos: 'macho',
    windows: 'pe',
  }[os]

  if (!expectedFormat)
    throw new Error(`unsupported target operating system in ${target}`)
  if (arch !== 'x86_64' && arch !== 'aarch64')
    throw new Error(`unsupported target architecture in ${target}`)

  const actual = inspectBinary(binary)
  if (actual.arch !== arch)
    throw new Error(`artifact architecture ${actual.arch} does not match target ${arch}`)
  if (actual.format !== expectedFormat)
    throw new Error(`artifact format ${actual.format} does not match ${os} format ${expectedFormat}`)
  return actual
}

function main() {
  const [artifactPath, target] = process.argv.slice(2)
  if (!artifactPath || !target || process.argv.length !== 4) {
    console.error('Usage: verify-artifact-target.mjs <artifact> <zig-target>')
    process.exit(2)
  }

  try {
    const actual = assertArtifactMatchesTarget(fs.readFileSync(artifactPath), target)
    console.log(`verified ${artifactPath}: ${actual.format}/${actual.arch} matches ${target}`)
  } catch (error) {
    console.error(`artifact verification failed: ${error.message}`)
    process.exit(1)
  }
}

const invokedPath = process.argv[1] ? pathToFileURL(path.resolve(process.argv[1])).href : null
if (invokedPath === import.meta.url)
  main()
