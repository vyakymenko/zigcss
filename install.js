#!/usr/bin/env node

const fs = require('fs');
const path = require('path');
const https = require('https');
const { execSync } = require('child_process');

const VERSION = require('./package.json').version;
const PLATFORM = process.platform;
const ARCH = process.arch;

const BIN_DIR = path.join(__dirname, 'bin');
const BIN_PATH = path.join(BIN_DIR, PLATFORM === 'win32' ? 'zigcss.exe' : 'zigcss');

function getDownloadUrl() {
  const platformMap = {
    'darwin': ARCH === 'arm64' ? 'aarch64-macos' : 'x86_64-macos',
    'linux': ARCH === 'arm64' ? 'aarch64-linux' : 'x86_64-linux',
    'win32': 'x86_64-windows'
  };

  const target = platformMap[PLATFORM];
  if (!target) {
    throw new Error(`Unsupported platform: ${PLATFORM} ${ARCH}`);
  }

  const ext = PLATFORM === 'win32' ? 'zip' : 'tar.gz';
  return `https://github.com/vyakymenko/zigcss/releases/download/v${VERSION}/zigcss-${VERSION}-${target}.${ext}`;
}

function downloadFile(url, dest) {
  return new Promise((resolve, reject) => {
    const file = fs.createWriteStream(dest);
    
    https.get(url, (response) => {
      if (response.statusCode === 302 || response.statusCode === 301) {
        return downloadFile(response.headers.location, dest).then(resolve).catch(reject);
      }
      
      if (response.statusCode !== 200) {
        reject(new Error(`Failed to download: ${response.statusCode}`));
        return;
      }
      
      response.pipe(file);
      
      file.on('finish', () => {
        file.close();
        resolve();
      });
    }).on('error', (err) => {
      fs.unlinkSync(dest);
      reject(err);
    });
  });
}

function extractArchive(archivePath, destDir) {
  if (PLATFORM === 'win32') {
    try {
      execSync(`powershell -Command "Expand-Archive -Path '${archivePath}' -DestinationPath '${destDir}' -Force"`, { stdio: 'inherit' });
    } catch (err) {
      throw new Error(`Failed to extract archive: ${err.message}`);
    }
  } else {
    try {
      execSync(`tar -xzf "${archivePath}" -C "${destDir}"`, { stdio: 'inherit' });
    } catch (err) {
      throw new Error(`Failed to extract archive: ${err.message}`);
    }
  }
}

async function install() {
  if (fs.existsSync(BIN_PATH)) {
    console.log('zigcss binary already exists, skipping download');
    return;
  }

  if (!fs.existsSync(BIN_DIR)) {
    fs.mkdirSync(BIN_DIR, { recursive: true });
  }

  const url = getDownloadUrl();
  const archivePath = path.join(BIN_DIR, path.basename(url));
  const tempDir = path.join(BIN_DIR, 'temp');

  console.log(`Downloading zigcss ${VERSION} for ${PLATFORM} ${ARCH}...`);

  try {
    await downloadFile(url, archivePath);
    
    if (!fs.existsSync(tempDir)) {
      fs.mkdirSync(tempDir, { recursive: true });
    }
    
    extractArchive(archivePath, tempDir);
    
    const extractedBin = path.join(tempDir, PLATFORM === 'win32' ? 'zigcss.exe' : 'zigcss');
    if (fs.existsSync(extractedBin)) {
      fs.copyFileSync(extractedBin, BIN_PATH);
      if (PLATFORM !== 'win32') {
        fs.chmodSync(BIN_PATH, 0o755);
      }
    } else {
      throw new Error('Binary not found in archive');
    }
    
    fs.rmSync(tempDir, { recursive: true, force: true });
    fs.unlinkSync(archivePath);
    
    console.log('✓ zigcss installed successfully!');
  } catch (err) {
    if (err.message.includes('404') || err.message.includes('Failed to download')) {
      console.warn(`⚠ Pre-built binary not available for ${PLATFORM} ${ARCH}`);
      console.warn('Building from source requires Zig 0.15.2+');
      console.warn('Install Zig: https://ziglang.org/download/');
      console.warn('Then build: git clone https://github.com/vyakymenko/zigcss.git && cd zigcss && zig build');
    } else {
      console.error(`✗ Installation failed: ${err.message}`);
      console.error('You can build from source:');
      console.error('  1. Install Zig: https://ziglang.org/download/');
      console.error('  2. git clone https://github.com/vyakymenko/zigcss.git');
      console.error('  3. cd zigcss && zig build');
    }
    process.exit(1);
  }
}

if (require.main === module) {
  install().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}

module.exports = { install };
