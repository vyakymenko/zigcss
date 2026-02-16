# npm Package Publishing Guide

## Prerequisites

1. **npm account** with access to publish `zcss` package
2. **GitHub releases** set up (binaries must be available)
3. **Version** updated in `package.json`

## Publishing Steps

### 1. Update Version

```bash
# Update version in package.json (e.g., 0.1.0 -> 0.1.1)
npm version patch|minor|major
```

### 2. Create GitHub Release

```bash
# Create and push tag
git tag v0.1.1
git push origin v0.1.1
```

GitHub Actions will automatically:
- Build binaries for all platforms
- Create GitHub release with assets

### 3. Wait for Release

Wait for GitHub Actions to complete and create the release with binaries.

### 4. Publish to npm

```bash
# Make sure you're logged in
npm login

# Publish
npm publish
```

## Testing Before Publishing

### Test Install Script Locally

```bash
# Test install.js
node install.js

# Verify binary works
./bin/zcss --version
```

### Test Package Locally

```bash
# Create a test package
npm pack

# In another directory, install the tarball
npm install /path/to/zcss-0.1.0.tgz

# Test the binary
zcss --version
```

### Test npm link

```bash
# In zcss directory
npm link

# In another project
npm link zcss
zcss input.css -o output.css
```

## Package Contents

The published package includes:
- `index.js` - Node.js wrapper script
- `install.js` - Post-install binary downloader
- `package.json` - Package metadata
- `README.md` - Documentation
- `LICENSE` - License file
- `bin/` - Created during install (not in package)

## Binary Distribution

Binaries are downloaded from GitHub Releases during `npm install`:
- Automatically detects platform (darwin/linux/win32)
- Downloads appropriate binary
- Extracts and makes executable
- Falls back gracefully if binary unavailable

## Troubleshooting

### Binary Download Fails

- Check GitHub Releases exist for the version
- Verify platform/arch mapping in `install.js`
- Check network connectivity

### Build from Source

If binary unavailable, users can build:
```bash
git clone https://github.com/vyakymenko/zcss.git
cd zcss
zig build -Doptimize=ReleaseFast
```
