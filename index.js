#!/usr/bin/env node

const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');

const preprocessorExtensions = ['.scss', '.sass', '.less', '.styl'];
const valueOptions = new Set([
  '-o',
  '--output',
  '--load-path',
  '--browsers',
  '--critical-classes',
  '--critical-ids',
  '--critical-elements',
]);

function shouldUseProductCli(args) {
  for (let index = 0; index < args.length; index += 1) {
    const argument = args[index];
    if (argument === '--syntax') {
      const syntax = args[index + 1];
      if (syntax === 'scss' || syntax === 'sass' || syntax === 'less' || syntax === 'stylus') {
        return true;
      }
      index += 1;
      continue;
    }
    if (valueOptions.has(argument)) {
      index += 1;
      continue;
    }
    if (argument === '-' || argument.startsWith('-')) continue;
    if (argument.endsWith('.module.css')) continue;
    if (preprocessorExtensions.some(extension => argument.endsWith(extension))) return true;
  }
  return false;
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

async function main(args = process.argv.slice(2)) {
  const binaryPath = path.join(__dirname, 'bin', process.platform === 'win32' ? 'zigcss.exe' : 'zigcss');
  if (!fs.existsSync(binaryPath)) {
    console.error('zigcss binary not found. Please run: npm install');
    process.exitCode = 1;
    return;
  }

  if (shouldUseProductCli(args)) {
    const { mainProductCli } = await import('./preprocessor/product-cli.mjs');
    await mainProductCli(args);
    return;
  }
  runNative(binaryPath, args);
}

if (require.main === module) {
  main().catch(error => {
    console.error(`Failed to start zigcss: ${error?.message ?? 'unknown launcher error'}`);
    process.exitCode = 1;
  });
}

module.exports = { shouldUseProductCli };
