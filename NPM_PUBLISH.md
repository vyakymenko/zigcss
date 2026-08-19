# npm Package Publishing Guide

ZigCSS packages are published only by the tag-triggered GitHub release workflow. Do not run `npm publish` manually from a workstation.

## Stable promotion

Stable `zigcss@0.6.0` is published on npm `latest`, with provenance, from exact immutable tag `v0.6.0` at commit `6786655d66ca65c5a06421c8ed70d84183722dce`. The same workflow created matching non-prerelease GitHub Release `372291445` only after the stable machine contract, exact `origin/main`, version/tag availability, five-target artifacts, and consumer gates passed. A failed tag remains immutable evidence and is never retried by moving or recreating it.

The existing npm `next` tag remains bound to `0.6.0-rc.2`. Stable publication does not delete, overwrite, or republish that package, and it does not publish Homebrew, editor-extension, container, service, or other npm channels.

The stable tag was admitted only after these checks passed:

```bash
npm run test:stable-release
npm run check:stable-release
npm run test:npm-publication
```

Release run `32130950531` completed successfully on attempt 1. Exact `0.6.0`, `dist-tags.latest`, retained `dist-tags.next`, provenance, the 25-asset GitHub inventory, and anonymous five-syntax installation are recorded in the maintained `release/stable-promotion.json` machine contract.

## Published release-candidate evidence

Immutable tag `v0.6.0-rc.2` points to release-ready commit `b63e190f7edeccd829abe34bfb96d9e1a8a320e2`. Its automatic workflow completed successfully on attempt 1, created the GitHub prerelease with the exact 25-asset inventory, and published `zigcss@0.6.0-rc.2` with provenance on npm `next`. At that RC publication, npm `latest` remained `0.3.0`; today `latest` is stable `0.6.0` while `next` still preserves the RC. The tag and package version must never be moved, recreated, reused, or republished.

Before any release asset was built, the workflow:

1. checks the tag against every versioned surface;
2. authenticates the repository-owned npm token with `npm whoami`;
3. obtains the registry's complete immutable `zigcss` version inventory; and
4. failed unless the selected candidate version was absent and the registry response was valid.

All five native jobs then built and executed architecture-matched archives, validated the npm install path offline, generated checksums and SPDX SBOMs, signed provenance and SBOM attestations, and uploaded the closed release inventory. GitHub Release creation occurred only after every native job passed.

The npm job published with:

```bash
npm publish --tag next --provenance
```

The explicit `next` channel prevented the experimental release candidate from replacing stable `latest`. OIDC-backed npm provenance was retained in the registry metadata. The workflow read back both the immutable version and `dist-tags.next`; both matched on its first bounded attempt.

Any later candidate requires a new version and tag identity plus the complete release gate. Do not rerun this publication as a substitute for a new immutable candidate.

## Required repository authority

- The `NPM_TOKEN` GitHub Actions secret must identify an npm principal allowed to publish `zigcss`.
- The npm package remains public.
- The release workflow alone receives the token, and only its preflight and publish jobs use it.
- The publish job alone receives the OIDC permission needed for npm provenance.

## Consumer behavior

The seven-file npm package contains metadata, notices, the JavaScript wrapper, and installer—not a bundled native executable. During installation, `install.js` selects one of the five release targets, downloads only the matching GitHub Release archive and checksum manifest, verifies SHA-256 and executable architecture, extracts exactly one executable, and replaces the local binary only after every check passes.

Install the published stable release:

```bash
npm install --global zigcss
zigcss --version
```

The immutable RC can still be installed explicitly with `zigcss@next` for historical comparison; the stable workflow never moves that tag.

The ordinary `npm install --global zigcss` command resolves to the verified `0.6.0` bytes through `latest`. Source builds remain the fallback documented in `README.md` and the public build guide. Stable publication does not expand executable-plugin, editor, service, or other experimental boundaries and does not authorize comparative performance claims.
