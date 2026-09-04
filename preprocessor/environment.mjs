const inheritedKeys = ['SystemRoot', 'WINDIR', 'TMP', 'TEMP', 'TMPDIR']
export function sanitizedHostEnvironment(source = process.env) {
  const environment = {
    LANG: 'C',
    LC_ALL: 'C',
    TZ: 'UTC',
  }
  for (const key of inheritedKeys) {
    const value = source[key]
    if (
      typeof value === 'string' &&
      value.length > 0 &&
      Buffer.byteLength(value) <= 4096 &&
      !/[\u0000\r\n]/.test(value)
    ) {
      environment[key] = value
    }
  }
  return environment
}

export function sanitizeRuntimeEnvironment(environment = process.env) {
  // Return a new allowlisted object instead of deleting attacker-controlled
  // property names from the supplied object. Callers replace process.env as a
  // single value before invoking any provider code.
  return sanitizedHostEnvironment(environment)
}
