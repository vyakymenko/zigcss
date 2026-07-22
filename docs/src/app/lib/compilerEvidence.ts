export function utf8Bytes(value: string): number {
  return new TextEncoder().encode(value).byteLength;
}

export function deterministicDigest(value: string): string {
  let hash = 0x811c9dc5;
  for (const byte of new TextEncoder().encode(value)) {
    hash ^= byte;
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return `fnv1a:${hash.toString(16).padStart(8, "0")}`;
}

export function reductionPercent(input: string, output: string): number {
  const inputBytes = utf8Bytes(input);
  if (inputBytes === 0) return 0;
  return Math.round((1 - utf8Bytes(output) / inputBytes) * 100);
}
