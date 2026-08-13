# npm Package Publishing Guide

ZigCSS packages are published only by the tag-triggered GitHub release workflow. Do not run `npm publish` manually from a workstation.

## Published release-candidate evidence

Immutable tag `v0.6.0-rc.2` points to release-ready commit `b63e190f7edeccd829abe34bfb96d9e1a8a320e2`. Its automatic workflow completed successfully on attempt 1, created the GitHub prerelease with the exact 25-asset inventory, and published `zigcss@0.6.0-rc.2` with provenance on npm `next`. npm `latest` remains 0.3.0. The tag and package version must never be moved, recreated, reused, or republished.

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

The five-file npm package contains the JavaScript wrapper and installer, not a bundled native executable. During installation, `install.js` selects one of the five release targets, downloads only the matching GitHub Release archive and checksum manifest, verifies SHA-256 and executable architecture, extracts exactly one executable, and replaces the local binary only after every check passes.

Use the prerelease explicitly:

```bash
npm install --global zigcss@next
zigcss --version
```

Source builds remain the fallback documented in `README.md` and the public build guide. Publication does not expand the experimental feature boundary or authorize performance claims.
