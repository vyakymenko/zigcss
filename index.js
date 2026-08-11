#!/usr/bin/env node

const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');

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
  const binaryPath = path.join(__dirname, 'bin', process.platform === 'win32' ? 'zigcss.exe' : 'zigcss');
  if (!fs.existsSync(binaryPath)) {
    console.error('zigcss binary not found. Please run: npm install');
    process.exitCode = 1;
    return;
  }

  runNative(binaryPath, args);
}

if (require.main === module) {
  main();
}
