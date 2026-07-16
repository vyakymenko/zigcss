# Homebrew Installation

The checked-in formula is an experimental source build for the verified `0.4.0-rc.3` recovery checkpoint. It pins both an immutable source archive with its SHA-256 digest and Homebrew's `zig@0.15` build dependency.

No Homebrew tap has been published. From a trusted ZigCSS checkout, install the reviewed formula directly:

```bash
brew install --build-from-source Formula/zigcss.rb
```

Run the formula's compiler smoke test after installation:

```bash
brew test zigcss
```

The formula is not a publication claim. Tap installation and upgrades remain unavailable until an authorized release publishes and verifies that distribution path.
