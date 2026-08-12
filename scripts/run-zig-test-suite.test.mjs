import assert from 'node:assert/strict'
import { EventEmitter } from 'node:events'
import { PassThrough } from 'node:stream'
import test from 'node:test'
import {
  failureHeadBytes,
  runZigTestSuite,
  suiteArguments,
} from './run-zig-test-suite.mjs'

function captureStream() {
  const stream = new PassThrough()
  let output = ''
  stream.on('data', chunk => {
    output += chunk.toString('utf8')
  })
  return { stream, output: () => output }
}

function controlledSpawn({ stdout = '', stderr = '', code = 0, signal = null, error = null } = {}) {
  const calls = []
  const spawnProcess = (command, args, options) => {
    calls.push({ command, args, options })
    const child = new EventEmitter()
    child.stdout = new PassThrough()
    child.stderr = new PassThrough()
    queueMicrotask(() => {
      if (error !== null) {
        child.emit('error', error)
        return
      }
      child.stdout.end(stdout)
      child.stderr.end(stderr)
      child.emit('close', code, signal)
    })
    return child
  }
  return { calls, spawnProcess }
}

function decodedAnnotation(output) {
  const marker = '::error title=Zig test suite failed::'
  const start = output.indexOf(marker)
  assert.notEqual(start, -1)
  return output.slice(start + marker.length).trimEnd()
    .replaceAll('%0D', '\r')
    .replaceAll('%0A', '\n')
    .replaceAll('%25', '%')
}

test('suite modes map to the one complete Zig graph', () => {
  assert.deepEqual(suiteArguments('Debug'), ['build', 'test', '--summary', 'all'])
  assert.deepEqual(
    suiteArguments('ReleaseSafe'),
    ['build', 'test', '-Doptimize=ReleaseSafe', '--summary', 'all'],
  )
  assert.throws(() => suiteArguments('ReleaseFast'), /unsupported Zig test suite mode/)
})

test('a successful suite is invoked once and its output is preserved without an annotation', async () => {
  const child = controlledSpawn({ stdout: 'root tests passed\n', stderr: 'timing detail\n' })
  const stdout = captureStream()
  const stderr = captureStream()
  const annotation = captureStream()

  const exitCode = await runZigTestSuite({
    mode: 'ReleaseSafe',
    spawnProcess: child.spawnProcess,
    stdout: stdout.stream,
    stderr: stderr.stream,
    annotation: annotation.stream,
  })

  assert.equal(exitCode, 0)
  assert.deepEqual(child.calls, [{
    command: 'zig',
    args: ['build', 'test', '-Doptimize=ReleaseSafe', '--summary', 'all'],
    options: { stdio: ['inherit', 'pipe', 'pipe'], windowsHide: true },
  }])
  assert.equal(stdout.output(), 'root tests passed\n')
  assert.equal(stderr.output(), 'timing detail\n')
  assert.equal(annotation.output(), '')
})

test('a failed suite preserves its code and emits one escaped public annotation', async () => {
  const child = controlledSpawn({ stdout: 'parse 50%\n', stderr: 'failure\r\n', code: 7 })
  const stdout = captureStream()
  const stderr = captureStream()
  const annotation = captureStream()

  const exitCode = await runZigTestSuite({
    mode: 'Debug',
    spawnProcess: child.spawnProcess,
    stdout: stdout.stream,
    stderr: stderr.stream,
    annotation: annotation.stream,
  })

  assert.equal(exitCode, 7)
  assert.equal(child.calls.length, 1)
  assert.equal(stdout.output(), 'parse 50%\n')
  assert.equal(stderr.output(), 'failure\r\n')
  assert.equal(annotation.output().match(/::error /g)?.length, 1)
  assert.equal(
    decodedAnnotation(annotation.output()),
    'zig build test failed with exit code 7\nparse 50%\nfailure\r\n',
  )
  assert.match(annotation.output(), /50%25%0Afailure%0D%0A/)
})

test('failure diagnostics retain lower, terminal, and over-limit heads', async () => {
  for (const fixture of [
    { name: 'lower', output: 'x', truncated: false },
    { name: 'terminal', output: 'x'.repeat(failureHeadBytes), truncated: false },
    { name: 'over', output: `${'x'.repeat(failureHeadBytes)}discarded`, truncated: true },
  ]) {
    const child = controlledSpawn({ stderr: fixture.output, code: 1 })
    const annotation = captureStream()
    const exitCode = await runZigTestSuite({
      mode: 'Debug',
      spawnProcess: child.spawnProcess,
      stdout: captureStream().stream,
      stderr: captureStream().stream,
      annotation: annotation.stream,
    })
    const decoded = decodedAnnotation(annotation.output())

    assert.equal(exitCode, 1, fixture.name)
    assert.equal(child.calls.length, 1, fixture.name)
    assert.equal(decoded.includes('diagnostic truncated'), fixture.truncated, fixture.name)
    assert.equal(decoded.endsWith(fixture.output.slice(0, failureHeadBytes)), true, fixture.name)
    assert.equal(decoded.includes('discarded'), false, fixture.name)
  }
})

test('an over-limit public annotation retains the causal diagnostic head', async () => {
  const causalDiagnostic = 'error: InvalidRoot while opening the Windows corpus root\n'
  const terminalSummary = 'error: repeated failed-test summary\n'.repeat(failureHeadBytes)
  const child = controlledSpawn({
    stderr: `${causalDiagnostic}${terminalSummary}`,
    code: 1,
  })
  const annotation = captureStream()

  const exitCode = await runZigTestSuite({
    mode: 'ReleaseSafe',
    spawnProcess: child.spawnProcess,
    stdout: captureStream().stream,
    stderr: captureStream().stream,
    annotation: annotation.stream,
  })
  const decoded = decodedAnnotation(annotation.output())

  assert.equal(exitCode, 1)
  assert.equal(child.calls.length, 1)
  assert.match(decoded, /InvalidRoot while opening the Windows corpus root/)
  assert.equal(decoded.length <= 4096, true)
})

test('a spawn failure is fail-closed and publicly attributed', async () => {
  const child = controlledSpawn({ error: new Error('zig executable unavailable') })
  const annotation = captureStream()

  const exitCode = await runZigTestSuite({
    mode: 'Debug',
    spawnProcess: child.spawnProcess,
    stdout: captureStream().stream,
    stderr: captureStream().stream,
    annotation: annotation.stream,
  })

  assert.equal(exitCode, 1)
  assert.equal(child.calls.length, 1)
  assert.match(decodedAnnotation(annotation.output()), /could not start: zig executable unavailable/)
})
