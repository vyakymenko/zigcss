# Build from source

Source builds are the verified installation path during recovery. Package-manager and prebuilt-release instructions are intentionally not advertised until release artifacts and installers pass their later roadmap gates.

## Requirements

- Zig 0.15.2
- Git

## Build and test

```bash
git clone https://github.com/vyakymenko/zigcss.git
cd zigcss
zig build
zig build test --summary all
zig build test-public-api --summary all
```

The executable is written to `zig-out/bin/zigcss`.

`test-public-api` compiles a separate Zig consumer against the module name `zigcss`. It verifies the current experimental foundation exports without claiming the final high-level compile facade or package-manager integration, which remain later Milestone 4 work.

The independent parser gate additionally requires Node.js. After the Zig build has produced the executable, run:

```bash
npm ci --ignore-scripts
npm run test:prefix-data
npm run check:prefix-data
npm run test:compat
npm run test:transforms
```

## Characterization example

Use a deliberately simple stylesheet while evaluating the prototype:

```css
.notice {
  color: red;
}
```

```bash
zig-out/bin/zigcss input.css -o output.css
```

The CLI writes an experimental-build warning to standard error. Treat successful output as prototype output, not as a compatibility guarantee.

- [Current status](/guide/status)
- [CSS compatibility](/guide/css-compatibility)
- [Recovery CLI](/guide/recovery-cli)
