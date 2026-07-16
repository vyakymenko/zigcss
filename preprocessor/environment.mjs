const inheritedKeys = ['SystemRoot', 'WINDIR', 'TMP', 'TEMP', 'TMPDIR']
const runtimeKeys = new Set(['LANG', 'LC_ALL', 'TZ', ...inheritedKeys])

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
  for (const key of Object.keys(environment)) {
    if (!runtimeKeys.has(key)) delete environment[key]
  }
  environment.LANG = 'C'
  environment.LC_ALL = 'C'
  environment.TZ = 'UTC'
  return environment
}
