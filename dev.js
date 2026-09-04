#!/usr/bin/env node

/**
 * ZigCSS Dev Server
 *
 * Orchestrates two things in parallel:
 *   1. Watches src/*.zig for changes → runs `zig build` → copies binary to bin/
 *   2. Runs the Vite dev server for the docs website with live-reload
 *
 * When the Zig engine is rebuilt the Vite server is notified so the browser
 * does a full page reload while local compiler work is in progress.
 *
 * Usage:  node dev.js          (or `npm run dev` from repo root)
 *         node dev.js --no-zig  (skip Zig watcher, website-only)
 */

const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

// ─── Configuration ──────────────────────────────────────────────────────────

const ROOT = __dirname;
const DOCS_DIR = path.join(ROOT, 'docs');
const SRC_DIR = path.join(ROOT, 'src');
const BINARY_NAME = process.platform === 'win32' ? 'zigcss.exe' : 'zigcss';
const BIN_PATH = path.join(ROOT, 'bin', BINARY_NAME);
const ZIG_OUT_BIN = path.join(ROOT, 'zig-out', 'bin', BINARY_NAME);
const READY_PATH = path.join(ROOT, 'bin', '.zigcss-dev-ready');
const DEBOUNCE_MS = 300;

const skipZig = process.argv.includes('--no-zig');

// ─── Helpers ────────────────────────────────────────────────────────────────

function log(tag, msg) {
  const time = new Date().toLocaleTimeString();
  console.log(`\x1b[90m${time}\x1b[0m \x1b[36m[${tag}]\x1b[0m ${msg}`);
}

function logError(tag, msg) {
  const time = new Date().toLocaleTimeString();
  console.error(`\x1b[90m${time}\x1b[0m \x1b[31m[${tag}]\x1b[0m ${msg}`);
}

// ─── Zig Rebuild ────────────────────────────────────────────────────────────

let zigBuildInProgress = false;
let pendingRebuild = false;
let currentBuild = null;
let activeZigProcess = null;
let shutdownRequested = false;

function removeReadyMarker() {
  fs.rmSync(READY_PATH, { force: true });
}

function removeReadyMarkerForShutdown() {
  try {
    removeReadyMarker();
  } catch (err) {
    logError('zig', `Failed to clear readiness marker during shutdown: ${err.message}`);
  }
}

function containsPath(root, candidate) {
  const relative = path.relative(root, candidate);
  return relative === '' || (
    relative !== '..' &&
    !relative.startsWith(`..${path.sep}`) &&
    !path.isAbsolute(relative)
  );
}

function publishBuiltBinary() {
  const sourceStat = fs.lstatSync(ZIG_OUT_BIN);
  if (!sourceStat.isFile() || sourceStat.isSymbolicLink()) {
    throw new Error('zig-out binary is not a regular non-symlink file');
  }
  if (process.platform !== 'win32' && (sourceStat.mode & 0o111) === 0) {
    throw new Error('zig-out binary is not executable');
  }

  const canonicalRoot = fs.realpathSync(ROOT);
  const canonicalSource = fs.realpathSync(ZIG_OUT_BIN);
  if (!containsPath(canonicalRoot, canonicalSource)) {
    throw new Error('zig-out binary escapes the source checkout');
  }

  const binDirectory = path.dirname(BIN_PATH);
  fs.mkdirSync(binDirectory, { recursive: true });
  const binStat = fs.lstatSync(binDirectory);
  if (!binStat.isDirectory() || binStat.isSymbolicLink()) {
    throw new Error('bin destination is not a regular directory');
  }

  const temporaryBinary = path.join(
    binDirectory,
    `.zigcss-${process.pid}-${Date.now()}.tmp`,
  );
  const temporaryMarker = `${READY_PATH}.${process.pid}-${Date.now()}.tmp`;
  try {
    fs.copyFileSync(canonicalSource, temporaryBinary, fs.constants.COPYFILE_EXCL);
    fs.chmodSync(temporaryBinary, 0o755);
    if (process.platform === 'win32') fs.rmSync(BIN_PATH, { force: true });
    fs.renameSync(temporaryBinary, BIN_PATH);
    fs.writeFileSync(temporaryMarker, 'ready\n', { encoding: 'utf8', flag: 'wx', mode: 0o644 });
    fs.renameSync(temporaryMarker, READY_PATH);
  } finally {
    fs.rmSync(temporaryBinary, { force: true });
    fs.rmSync(temporaryMarker, { force: true });
  }
}

function rebuildZig() {
  if (zigBuildInProgress) {
    pendingRebuild = true;
    return currentBuild;
  }

  zigBuildInProgress = true;
  removeReadyMarker();
  log('zig', 'Rebuilding zigcss…');

  const start = Date.now();
  currentBuild = new Promise((resolve) => {
    const child = spawn('zig', ['build'], {
      cwd: ROOT,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    activeZigProcess = child;
    let settled = false;
    let stderr = '';

    const finish = (result) => {
      if (settled) return;
      settled = true;
      zigBuildInProgress = false;
      currentBuild = null;
      activeZigProcess = null;
      resolve(result);
      if (pendingRebuild && !shutdownRequested) {
        pendingRebuild = false;
        void rebuildZig();
      } else if (shutdownRequested) {
        pendingRebuild = false;
      }
    };

    child.stderr.on('data', (data) => { stderr += data.toString(); });
    child.stdout.on('data', (data) => { process.stdout.write(data); });

    child.on('close', (code, signal) => {
      const elapsed = Date.now() - start;
      if (code === 0 && signal === null && !shutdownRequested) {
        try {
          publishBuiltBinary();
          log('zig', `\x1b[32m✓ Rebuilt in ${elapsed}ms\x1b[0m`);
          finish({ ok: true, code: 0 });
          return;
        } catch (err) {
          logError('zig', `Built OK but failed to publish binary: ${err.message}`);
        }
      } else {
        logError('zig', `Build failed (${elapsed}ms${signal ? `, signal ${signal}` : ''}):`);
        if (stderr) console.error(stderr);
      }
      removeReadyMarker();
      finish({ ok: false, code: Number.isInteger(code) && code > 0 ? code : 1 });
    });

    child.on('error', (err) => {
      if (err.code === 'ENOENT') {
        logError('zig', 'Zig compiler not found. Install Zig 0.15.2 or use --no-zig for website-only mode.');
      } else {
        logError('zig', `Failed to start zig build: ${err.message}`);
      }
      removeReadyMarker();
      finish({ ok: false, code: 1 });
    });
  });

  return currentBuild;
}

// ─── Zig File Watcher ───────────────────────────────────────────────────────

function startZigWatcher(onFatal) {
  let debounceTimer = null;
  const watchers = [];
  const watchedFiles = [];

  log('zig', 'Watching src/ and root build inputs for Zig changes…');

  const schedule = (filename) => {
    if (debounceTimer) clearTimeout(debounceTimer);
    debounceTimer = setTimeout(() => {
      log('zig', `Changed: ${filename}`);
      void rebuildZig();
    }, DEBOUNCE_MS);
  };

  const fail = (err) => {
    removeReadyMarkerForShutdown();
    logError('zig', `Watcher error: ${err.message}`);
    onFatal();
  };

  try {
    const sourceWatcher = fs.watch(SRC_DIR, { recursive: true }, (_event, filename) => {
      if (!filename || !filename.endsWith('.zig')) return;
      schedule(path.join('src', filename));
    });
    watchers.push(sourceWatcher);

    // These inputs may be symlinks in the development container. Watching the
    // parent directory does not reliably report changes to a symlink target, so
    // poll each resolved file directly and keep the exact listener for cleanup.
    for (const filename of ['build.zig', 'build.zig.zon', 'build_helpers.zig']) {
      const inputPath = path.join(ROOT, filename);
      const listener = (current, previous) => {
        if (
          current.mtimeMs === previous.mtimeMs &&
          current.size === previous.size &&
          current.ino === previous.ino
        ) return;
        schedule(filename);
      };
      fs.watchFile(inputPath, { interval: 500, persistent: true }, listener);
      watchedFiles.push({ inputPath, listener });
    }

    for (const watcher of watchers) watcher.on('error', fail);

    return {
      close() {
        if (debounceTimer) clearTimeout(debounceTimer);
        for (const watcher of watchers) watcher.close();
        for (const { inputPath, listener } of watchedFiles) {
          fs.unwatchFile(inputPath, listener);
        }
      },
    };
  } catch (err) {
    logError('zig', `Failed to start watcher: ${err.message}`);
    for (const watcher of watchers) watcher.close();
    for (const { inputPath, listener } of watchedFiles) {
      fs.unwatchFile(inputPath, listener);
    }
    return null;
  }
}

// ─── Vite Dev Server ────────────────────────────────────────────────────────

function startVite() {
  log('vite', 'Starting docs dev server…');

  const vite = spawn(process.platform === 'win32' ? 'npm.cmd' : 'npm', ['run', 'dev'], {
    cwd: DOCS_DIR,
    stdio: 'inherit',
    env: process.env,
  });

  return vite;
}

// ─── Main ───────────────────────────────────────────────────────────────────

async function main() {
  console.log();
  console.log('  \x1b[1m\x1b[36m⚡ ZigCSS Dev Server\x1b[0m');
  console.log('  \x1b[90m─────────────────────\x1b[0m');
  console.log();

  // A website-only run must never inherit compiler readiness from a previous
  // container or an unclean local shutdown.
  removeReadyMarker();

  let zigWatcher = null;
  let viteProcess = null;
  let shuttingDown = false;

  function cleanup(code = 0, terminateVite = true) {
    if (shuttingDown) return;
    shuttingDown = true;
    shutdownRequested = true;
    console.log();
    log('dev', 'Shutting down…');
    removeReadyMarkerForShutdown();
    if (zigWatcher) zigWatcher.close();
    if (activeZigProcess && !activeZigProcess.killed) {
      activeZigProcess.kill('SIGTERM');
    }
    if (terminateVite && viteProcess && !viteProcess.killed) {
      viteProcess.kill('SIGTERM');
    }
    process.exitCode = code;
  }

  process.on('SIGINT', () => cleanup(0));
  process.on('SIGTERM', () => cleanup(0));

  if (!skipZig) {
    zigWatcher = startZigWatcher(() => cleanup(1));
    if (zigWatcher === null) {
      cleanup(1, false);
      return;
    }
    let initialBuild;
    try {
      initialBuild = await rebuildZig();
    } catch (err) {
      logError('dev', `Initial Zig readiness gate failed: ${err.message}`);
      cleanup(1, false);
      return;
    }
    if (!initialBuild.ok) {
      logError('dev', 'Initial Zig build failed; docs server was not started. Use --no-zig explicitly for website-only mode.');
      cleanup(initialBuild.code, false);
      return;
    }
  } else {
    log('zig', 'Zig watcher skipped (--no-zig)');
  }

  if (shuttingDown) return;
  viteProcess = startVite();

  viteProcess.on('error', (err) => {
    logError('vite', `Failed to start: ${err.message}`);
    logError('vite', 'Run `cd docs && npm ci --ignore-scripts` first.');
    cleanup(1, false);
  });

  viteProcess.on('close', (code, signal) => {
    const exitCode = Number.isInteger(code) ? code : 1;
    log('vite', `Vite exited with ${signal ? `signal ${signal}` : `code ${exitCode}`}`);
    cleanup(exitCode, false);
  });
}

main().catch((err) => {
  removeReadyMarkerForShutdown();
  logError('dev', err?.stack || err?.message || String(err));
  process.exitCode = 1;
});
