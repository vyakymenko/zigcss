# Installation

zcss can be installed via multiple methods depending on your platform and preferences.

## Package Managers

### npm (Node.js)

```bash
npm install -g zcss
```

The npm package automatically downloads the appropriate binary for your platform during installation.

### Homebrew (macOS)

```bash
brew tap vyakymenko/zcss
brew install zcss
```

Or install from source:

```bash
brew install --build-from-source Formula/zcss.rb
```

## From Source

**Requirements:**
- Zig 0.15.2 or later
- C compiler (for linking)

```bash
git clone https://github.com/vyakymenko/zcss.git
cd zcss
zig build -Doptimize=ReleaseFast
```

The binary will be available at `zig-out/bin/zcss`.

## Pre-built Binaries

Pre-built binaries are available for all supported platforms on the [releases page](https://github.com/vyakymenko/zcss/releases).

**Supported Platforms:**
- Linux (x86_64, aarch64)
- macOS (x86_64, aarch64)
- Windows (x86_64)

### Quick Install (Linux/macOS)

```bash
# Download and extract
wget https://github.com/vyakymenko/zcss/releases/download/v0.1.0/zcss-0.1.0-x86_64-linux.tar.gz
tar -xzf zcss-0.1.0-x86_64-linux.tar.gz

# Make executable and move to PATH
chmod +x zcss
sudo mv zcss /usr/local/bin/
```

### Quick Install (Windows)

```powershell
# Download and extract
Invoke-WebRequest -Uri "https://github.com/vyakymenko/zcss/releases/download/v0.1.0/zcss-0.1.0-x86_64-windows.zip" -OutFile "zcss.zip"
Expand-Archive -Path zcss.zip -DestinationPath .

# Add to PATH (PowerShell as Administrator)
$env:Path += ";C:\path\to\zcss"
[Environment]::SetEnvironmentVariable("Path", $env:Path, [EnvironmentVariableTarget]::Machine)
```

## Verify Installation

After installation, verify that zcss is working:

```bash
zcss --version
```

You should see the version number printed.

## Next Steps

- [Quick Start](/guide/quick-start) — Learn how to use zcss
- [Examples](/examples/css-nesting) — See examples of zcss features
