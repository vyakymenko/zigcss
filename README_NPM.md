# npm package recovery status

The ZigCSS npm wrapper is experimental and package publication is not currently authorized.

Do not publish from the recovery branch. Publication remains gated on the release packages in `DEVELOPMENT_PLAN.md`, including synchronized versions, verified native artifacts, checksums, installer smoke tests, and an explicit owner authorization.

## Local wrapper checks

After building a local binary, place it under the package's ignored `bin/` directory and verify the wrapper without publishing:

```bash
zig build
mkdir -p bin
cp zig-out/bin/zigcss bin/zigcss
node index.js --help
npm pack --dry-run --ignore-scripts
```

The current wrapper and installer are legacy packaging surfaces. Their presence does not imply that a matching release asset exists or that package-manager installation is a supported recovery path.

## Future publication gate

Before any release is authorized:

1. synchronize versions across Zig, npm, release workflows, containers, editor integration, and formula metadata;
2. build, inspect, and smoke-test every advertised target;
3. verify archive names against installer lookup paths;
4. generate integrity and provenance artifacts required by the roadmap;
5. update the public capability table from passing tests;
6. obtain explicit authorization to publish.
