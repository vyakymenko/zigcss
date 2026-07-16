export function makeRequest(overrides = {}) {
  return {
    protocol: 'zigcss-preprocessor-v1',
    requestId: 'request-001',
    operation: 'compile',
    provider: 'dart-sass',
    syntax: 'scss',
    source: '$color: red;\n.card { color: $color; }\n',
    sourceUrl: 'file:///workspace/input.scss',
    options: {
      style: 'expanded',
      sourceMap: true,
      loadPaths: [],
      providerOptions: {
        charset: true,
        quietDeps: false,
        verbose: false,
      },
      ...(overrides.options ?? {}),
    },
    ...overrides,
  }
}
