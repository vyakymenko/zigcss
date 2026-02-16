# Installation

zigcss can be installed via multiple methods depending on your platform and preferences.

## Package Managers

### npm (Node.js)

```bash
npm install -g zigcss
```

The npm package automatically downloads the appropriate binary for your platform during installation.

### Homebrew (macOS)

```bash
brew tap vyakymenko/zigcss
brew install zigcss
```

Or install from source:

```bash
brew install --build-from-source Formula/zigcss.rb
```

## From Source

**Requirements:**
- Zig 0.15.2 or later
- C compiler (for linking)

```bash
git clone https://github.com/vyakymenko/zigcss.git
cd zigcss
zig build -Doptimize=ReleaseFast
```

The binary will be available at `zig-out/bin/zigcss`.

## Pre-built Binaries

Pre-built binaries are available for all supported platforms on the [releases page](https://github.com/vyakymenko/zigcss/releases).

**Supported Platforms:**
- Linux (x86_64, aarch64)
- macOS (x86_64, aarch64)
- Windows (x86_64)

### Quick Install (Linux/macOS)

```bash
# Download and extract
wget https://github.com/vyakymenko/zigcss/releases/download/v0.1.0/zigcss-0.1.0-x86_64-linux.tar.gz
tar -xzf zigcss-0.1.0-x86_64-linux.tar.gz

# Make executable and move to PATH
chmod +x zigcss
sudo mv zigcss /usr/local/bin/
```

### Quick Install (Windows)

```powershell
# Download and extract
Invoke-WebRequest -Uri "https://github.com/vyakymenko/zigcss/releases/download/v0.1.0/zigcss-0.1.0-x86_64-windows.zip" -OutFile "zigcss.zip"
Expand-Archive -Path zigcss.zip -DestinationPath .

# Add to PATH (PowerShell as Administrator)
$env:Path += ";C:\path\to\zigcss"
[Environment]::SetEnvironmentVariable("Path", $env:Path, [EnvironmentVariableTarget]::Machine)
```

## Verify Installation

After installation, verify that zigcss is working:

```bash
zigcss --version
```

You should see the version number printed.

## Next Steps

- [Quick Start](/guide/quick-start) — Learn how to use zigcss
- [Examples](/examples/css-nesting) — See examples of zigcss features
