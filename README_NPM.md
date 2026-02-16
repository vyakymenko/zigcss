# npm Package Setup

## Publishing to npm

1. **Update version** in `package.json`
2. **Create a git tag**: `git tag v0.1.0`
3. **Push tag**: `git push origin v0.1.0`
4. **GitHub Actions** will automatically:
   - Build binaries for all platforms
   - Create a GitHub release with binaries
5. **Publish to npm**: `npm publish`

## Testing npm package locally

```bash
# Test install script
node install.js

# Test binary
./bin/zigcss --version

# Test via npm link (in project directory)
npm link

# In another directory
npm link zigcss
zigcss --version
```

## Package Structure

```
zigcss/
├── bin/              # Platform-specific binaries (created by install.js)
│   ├── zigcss          # macOS/Linux binary
│   └── zigcss.exe      # Windows binary
├── index.js          # Node.js wrapper script
├── install.js        # Post-install script to download binaries
├── package.json      # npm package configuration
└── README.md         # Package documentation
```

## Binary Distribution

Binaries are downloaded from GitHub Releases:
- Format: `zigcss-{version}-{platform}.{ext}`
- Platforms: `x86_64-linux`, `aarch64-linux`, `x86_64-macos`, `aarch64-macos`, `x86_64-windows`
- Extensions: `.tar.gz` (Unix), `.zip` (Windows)

## Fallback Behavior

If binary download fails:
1. Shows helpful error message
2. Provides instructions to build from source
3. Links to Zig installation guide
