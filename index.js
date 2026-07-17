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

const combinedHelp = `ZigCSS 0.5 development snapshot — EXPERIMENTAL, evaluate before production

Five languages in. One deterministic compiler out.

Usage: zigcss <input> [-o <output.css|->] [options]
       zigcss <input1> <input2> ... -o <output-dir> --output-dir [options]
       zigcss --lsp          Start the experimental CSS Language Server

Canonical input languages:
  --syntax <css|scss|sass|less|stylus>
  CSS                       Native ZigCSS parser and emitter
  SCSS / indented Sass      Dart Sass 1.101.0
  Less                      Less 4.6.7
  Stylus                    Stylus 0.64.0

Common options:
  -o, --output <path|->     Output file/stdout, or directory with --output-dir
  --output-dir              Require batch output under the -o directory
  --minify                  Emit compact whitespace
  --optimize                Run the closed verified optimizer preset
  --watch                   Watch one input and its confined local dependencies
  -V, --version             Show the package version
  -h, --help                Show this help

Preprocessor options:
  --load-path <directory>   Add one explicit confined import root (repeatable)
  --source-map              Embed a deterministic composed source map

Native CSS-only options:
  --profile                 Report API stages and requested memory bytes
  --lsp                     Start the experimental CSS Language Server

Security boundary:
  Canonical providers run at exact package versions behind a confined host. ZigCSS
  does not enable arbitrary project plugins, custom functions, custom importers, or JavaScript.

Exit status: 0 success/info, 1 compilation or I/O failure, 2 usage error.
`;

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
  if (args.length === 1 && (args[0] === '--help' || args[0] === '-h')) {
    process.stdout.write(combinedHelp);
    return;
  }

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

module.exports = { combinedHelp, shouldUseProductCli };
