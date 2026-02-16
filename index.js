#!/usr/bin/env node

const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');

const binPath = path.join(__dirname, 'bin', process.platform === 'win32' ? 'zigcss.exe' : 'zigcss');

if (!fs.existsSync(binPath)) {
  console.error('zigcss binary not found. Please run: npm install');
  process.exit(1);
}

const args = process.argv.slice(2);
const child = spawn(binPath, args, {
  stdio: 'inherit',
  cwd: process.cwd()
});

child.on('exit', (code) => {
  process.exit(code || 0);
});

child.on('error', (err) => {
  console.error(`Failed to start zigcss: ${err.message}`);
  process.exit(1);
});
