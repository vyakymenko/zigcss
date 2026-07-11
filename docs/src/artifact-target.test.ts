// @vitest-environment node

import { describe, expect, test } from 'vitest'
import {
  assertArtifactMatchesTarget,
  inspectBinary,
} from '../../scripts/verify-artifact-target.mjs'

function elf(machine: number): Buffer {
  const binary = Buffer.alloc(64)
  binary.set([0x7f, 0x45, 0x4c, 0x46])
  binary[5] = 1
  binary.writeUInt16LE(machine, 18)
  return binary
}

function machO(cpuType: number): Buffer {
  const binary = Buffer.alloc(32)
  binary.writeUInt32LE(0xfeedfacf, 0)
  binary.writeUInt32LE(cpuType, 4)
  return binary
}

function pe(machine: number): Buffer {
  const binary = Buffer.alloc(256)
  binary.write('MZ', 0, 'ascii')
  binary.writeUInt32LE(0x80, 0x3c)
  binary.write('PE\0\0', 0x80, 'binary')
  binary.writeUInt16LE(machine, 0x84)
  return binary
}

describe('native artifact target inspection', () => {
  test.each([
    [elf(62), { arch: 'x86_64', format: 'elf' }],
    [elf(183), { arch: 'aarch64', format: 'elf' }],
    [machO(0x01000007), { arch: 'x86_64', format: 'macho' }],
    [machO(0x0100000c), { arch: 'aarch64', format: 'macho' }],
    [pe(0x8664), { arch: 'x86_64', format: 'pe' }],
    [pe(0xaa64), { arch: 'aarch64', format: 'pe' }],
  ] as const)('reads binary headers', (binary, expected) => {
    expect(inspectBinary(binary)).toEqual(expected)
  })

  test('matches both architecture and operating-system format', () => {
    expect(assertArtifactMatchesTarget(elf(183), 'aarch64-linux')).toEqual({
      arch: 'aarch64',
      format: 'elf',
    })
    expect(() => assertArtifactMatchesTarget(pe(0x8664), 'aarch64-windows')).toThrow(/architecture/)
    expect(() => assertArtifactMatchesTarget(elf(62), 'x86_64-macos')).toThrow(/format/)
  })
})
