#!/usr/bin/env node

/**
 * ZigCSS Dev Server
 *
 * Orchestrates two things in parallel:
 *   1. Watches src/*.zig for changes → runs `zig build` → copies binary to bin/
 *   2. Runs the Vite dev server for the docs website with live-reload
 *
 * When the Zig engine is rebuilt the Vite server is notified so the browser
 * does a full page reload, picking up the new binary for playground compilations.
 *
 * Usage:  node dev.js          (or `npm run dev` from repo root)
 *         node dev.js --no-zig  (skip Zig watcher, website-only)
 */

const { spawn, execSync } = require('child_process');
const fs = require('fs');
const path = require('path');

// ─── Configuration ──────────────────────────────────────────────────────────

const ROOT = __dirname;
const DOCS_DIR = path.join(ROOT, 'docs');
const SRC_DIR = path.join(ROOT, 'src');
const BIN_PATH = path.join(ROOT, 'bin', 'zigcss');
const ZIG_OUT_BIN = path.join(ROOT, 'zig-out', 'bin', 'zigcss');
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

function rebuildZig() {
  if (zigBuildInProgress) {
    pendingRebuild = true;
    return;
  }

  zigBuildInProgress = true;
  log('zig', 'Rebuilding zigcss…');

  const start = Date.now();
  const child = spawn('zig', ['build'], {
    cwd: ROOT,
    stdio: ['ignore', 'pipe', 'pipe'],
  });

  let stderr = '';
  child.stderr.on('data', (d) => { stderr += d.toString(); });
  child.stdout.on('data', (d) => { process.stdout.write(d); });

  child.on('close', (code) => {
    zigBuildInProgress = false;
    const elapsed = Date.now() - start;

    if (code === 0) {
      // Copy the built binary into bin/
      try {
        fs.mkdirSync(path.dirname(BIN_PATH), { recursive: true });
        fs.copyFileSync(ZIG_OUT_BIN, BIN_PATH);
        fs.chmodSync(BIN_PATH, 0o755);
        log('zig', `\x1b[32m✓ Rebuilt in ${elapsed}ms\x1b[0m`);
      } catch (err) {
        logError('zig', `Built OK but failed to copy binary: ${err.message}`);
      }
    } else {
      logError('zig', `Build failed (${elapsed}ms):`);
      if (stderr) console.error(stderr);
    }

    if (pendingRebuild) {
      pendingRebuild = false;
      rebuildZig();
    }
  });

  child.on('error', (err) => {
    zigBuildInProgress = false;
    if (err.code === 'ENOENT') {
      logError('zig', 'Zig compiler not found. Install with: brew install zig');
      logError('zig', 'Continuing with website-only mode…');
    } else {
      logError('zig', `Failed to start zig build: ${err.message}`);
    }
  });
}

// ─── Zig File Watcher ───────────────────────────────────────────────────────

function startZigWatcher() {
  let debounceTimer = null;

  log('zig', `Watching ${path.relative(ROOT, SRC_DIR)}/ for .zig changes…`);

  // Do an initial build
  rebuildZig();

  try {
    const watcher = fs.watch(SRC_DIR, { recursive: true }, (_event, filename) => {
      if (!filename || !filename.endsWith('.zig')) return;

      // Debounce rapid changes
      if (debounceTimer) clearTimeout(debounceTimer);
      debounceTimer = setTimeout(() => {
        log('zig', `Changed: ${filename}`);
        rebuildZig();
      }, DEBOUNCE_MS);
    });

    watcher.on('error', (err) => {
      logError('zig', `Watcher error: ${err.message}`);
    });

    return watcher;
  } catch (err) {
    logError('zig', `Failed to start watcher: ${err.message}`);
    return null;
  }
}

// ─── Vite Dev Server ────────────────────────────────────────────────────────

function startVite() {
  log('vite', 'Starting docs dev server…');

  const vite = spawn('npm', ['run', 'dev'], {
    cwd: DOCS_DIR,
    stdio: 'inherit',
    env: {
      ...process.env,
      // Tell the Vite plugin where the binary lives (absolute path)
      ZIGCSS_BIN: BIN_PATH,
    },
  });

  vite.on('error', (err) => {
    logError('vite', `Failed to start: ${err.message}`);
    logError('vite', 'Run `cd docs && npm install` first.');
    process.exit(1);
  });

  return vite;
}

// ─── Main ───────────────────────────────────────────────────────────────────

function main() {
  console.log();
  console.log('  \x1b[1m\x1b[36m⚡ ZigCSS Dev Server\x1b[0m');
  console.log('  \x1b[90m─────────────────────\x1b[0m');
  console.log();

  let zigWatcher = null;
  if (!skipZig) {
    zigWatcher = startZigWatcher();
  } else {
    log('zig', 'Zig watcher skipped (--no-zig)');
  }

  const viteProcess = startVite();

  // Graceful shutdown
  function cleanup() {
    console.log();
    log('dev', 'Shutting down…');
    if (zigWatcher) zigWatcher.close();
    if (viteProcess && !viteProcess.killed) {
      viteProcess.kill('SIGTERM');
    }
    process.exit(0);
  }

  process.on('SIGINT', cleanup);
  process.on('SIGTERM', cleanup);

  viteProcess.on('close', (code) => {
    log('vite', `Vite exited with code ${code}`);
    cleanup();
  });
}

main();
