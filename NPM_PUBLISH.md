# npm Package Publishing Guide

ZigCSS packages are published only by the tag-triggered GitHub release workflow. Do not run `npm publish` manually from a workstation.

## Release-candidate contract

The `v0.4.0-rc.3` tag must point at the exact integrated `main` commit whose synchronized version, release metadata, consumers, native targets, and workflow policy are green.

Before any release asset is built, the workflow:

1. checks the tag against every versioned surface;
2. authenticates the repository-owned npm token with `npm whoami`;
3. obtains the registry's complete immutable `zigcss` version inventory; and
4. fails if `0.4.0-rc.3` already exists or the registry response is malformed.

All five native jobs then build and execute architecture-matched archives, validate the npm install path offline, generate checksums and SPDX SBOMs, sign provenance and SBOM attestations, and upload the closed release inventory. GitHub Release creation occurs only after every native job passes.

The npm job publishes with:

```bash
npm publish --tag next --provenance
```

The explicit `next` channel prevents an experimental release candidate from replacing stable `latest`. OIDC-backed npm provenance is mandatory. The workflow finally reads back both the immutable version and `dist-tags.next`; any mismatch fails the release run.

## Required repository authority

- The `NPM_TOKEN` GitHub Actions secret must identify an npm principal allowed to publish `zigcss`.
- The npm package remains public.
- The release workflow alone receives the token, and only its preflight and publish jobs use it.
- The publish job alone receives the OIDC permission needed for npm provenance.

## Consumer behavior

The five-file npm package contains the JavaScript wrapper and installer, not a bundled native executable. During installation, `install.js` selects one of the five release targets, downloads only the matching GitHub Release archive and checksum manifest, verifies SHA-256 and executable architecture, extracts exactly one executable, and replaces the local binary only after every check passes.

Use the prerelease explicitly:

```bash
npm install --global zigcss@next
zigcss --version
```

Source builds remain the fallback documented in `README.md` and the public build guide. Publication does not expand the experimental feature boundary or authorize performance claims.
