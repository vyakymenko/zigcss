#!/usr/bin/env node

const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');

function containsLocalPath(root, candidate) {
  const relative = path.relative(root, candidate);
  return relative === '' || (
    relative !== '..' &&
    !relative.startsWith(`..${path.sep}`) &&
    !path.isAbsolute(relative)
  );
}

function regularExecutable(filename) {
  try {
    const stat = fs.lstatSync(filename);
    if (!stat.isFile() || stat.isSymbolicLink() ||
        (process.platform !== 'win32' && (stat.mode & 0o111) === 0)) {
      return null;
    }
    return fs.realpathSync(filename);
  } catch {
    return null;
  }
}

function sourceCheckoutBinary(root, binaryName) {
  for (const marker of ['build.zig', path.join('src', 'node_protocol.zig')]) {
    try {
      const stat = fs.lstatSync(path.join(root, marker));
      if (!stat.isFile() || stat.isSymbolicLink()) return null;
    } catch {
      return null;
    }
  }
  const candidate = regularExecutable(path.join(root, 'zig-out', 'bin', binaryName));
  return candidate !== null && containsLocalPath(root, candidate) ? candidate : null;
}

function resolveBinaryPath() {
  const binaryName = process.platform === 'win32' ? 'zigcss.exe' : 'zigcss';
  let root;
  try {
    root = fs.realpathSync(__dirname);
  } catch {
    return null;
  }
  const sourceBinary = sourceCheckoutBinary(root, binaryName);
  if (sourceBinary !== null) return sourceBinary;
  const packagedBinary = regularExecutable(path.join(root, 'bin', binaryName));
  return packagedBinary !== null && containsLocalPath(root, packagedBinary) ? packagedBinary : null;
}

function runNative(binaryPath, args) {
  const child = spawn(binaryPath, args, {
    stdio: 'inherit',
    cwd: process.cwd(),
  });

  child.on('exit', (code, signal) => {
    if (signal) {
      try {
        process.kill(process.pid, signal);
      } catch {
        process.exit(1);
      }
      return;
    }
    process.exit(code ?? 1);
  });

  child.on('error', (err) => {
    console.error(`Failed to start zigcss: ${err.message}`);
    process.exit(1);
  });
}

function main(args = process.argv.slice(2)) {
  const binaryPath = resolveBinaryPath();
  if (binaryPath === null) {
    console.error('zigcss binary is missing or not executable. Lifecycle scripts may have been disabled.');
    console.error('Run zigcss-install, allow this package\'s install script, or build ZigCSS from source.');
    process.exitCode = 1;
    return;
  }

  runNative(binaryPath, args);
}

if (require.main === module) {
  main();
}
