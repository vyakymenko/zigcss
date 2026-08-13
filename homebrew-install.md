# Homebrew Installation

The checked-in formula is frozen verification evidence for the unpublished provider-backed `0.5.0-rc.1` reference candidate. It pins both that immutable source archive with its SHA-256 digest and Homebrew's `zig@0.15` build dependency; the authorized native `0.6.0-rc.2` release does not include a Homebrew publication.

No Homebrew tap has been published. From a trusted ZigCSS checkout, install the reviewed formula directly:

```bash
brew install --build-from-source Formula/zigcss.rb
```

Run the formula's compiler smoke test after installation:

```bash
brew test zigcss
```

The formula is not a native publication claim. Tap installation and upgrades remain unavailable unless a later authorization separately verifies that distribution path.
