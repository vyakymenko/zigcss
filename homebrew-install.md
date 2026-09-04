# Homebrew Installation

The checked-in formula builds stable ZigCSS `0.6.0` from one immutable commit archive. It pins that archive's SHA-256 digest and Homebrew's `zig@0.15` build dependency, then verifies the installed compiler's version and CSS output.

No Homebrew tap has been published. From a trusted ZigCSS checkout, install the reviewed formula directly:

```bash
brew install --formula ./Formula/zigcss.rb
```

Run the formula's compiler smoke test after installation:

```bash
brew test zigcss
```

This is the reviewed stable `0.6.0` checkout installation path, not a claim that a public Homebrew tap exists. Tap installation and upgrades remain unavailable unless that distribution path is published and verified separately.
