# npm Package Publishing Guide

ZigCSS packages are published only by the tag-triggered GitHub release workflow. Do not run `npm publish` manually from a workstation.

## Stable promotion

Stable `zigcss@0.6.0` is published on npm `latest` as an immutable version, with provenance, from protected tag `v0.6.0` at commit `6786655d66ca65c5a06421c8ed70d84183722dce`. The same workflow created matching non-prerelease GitHub Release `372291445` only after the stable machine contract, exact `origin/main`, version/tag availability, five-target artifacts, and consumer gates passed. That historical GitHub Release predates Immutable Releases and reads back `immutable: false`. A failed tag remains closed evidence and is never retried by moving or recreating it.

The existing npm `next` tag remains bound to `0.6.0-rc.2`. Stable publication does not delete, overwrite, or republish that package, and it does not publish Homebrew, editor-extension, container, service, or other npm channels.

The stable tag was admitted only after these checks passed:

```bash
npm run test:stable-release
npm run check:stable-release
npm run test:npm-publication
```

Release run `32130950531` completed successfully on attempt 1. Exact `0.6.0`, `dist-tags.latest`, retained `dist-tags.next`, provenance, the 25-asset GitHub inventory, and anonymous five-syntax installation are recorded in the maintained `release/stable-promotion.json` machine contract.

Every future tag-triggered publication must first prove, through the bounded GitHub Actions API preflight, that the exact tagged commit has a successful same-repository `main` push run of the exact `Build` workflow at `.github/workflows/build.yml`. The same preflight requires default-setup CodeQL results for that exact commit in all three repository categories—Actions, JavaScript/TypeScript, and Ruby—with no error or warning status and zero open CodeQL alerts; it uses only `security-events: read`. Those proofs run before npm identity, registry-version, package, artifact, attestation, or publication authority is admitted.

## Next candidate admission

`release/next-release.json` selects exact candidate `0.7.0-rc.1`, tag `v0.7.0-rc.1`, npm channel `next`, and GitHub prerelease delivery under a separate fail-closed contract. It is currently `planned` with `candidateReady: false`; this selection does not authorize creating the tag or publishing either release surface.

The release workflow first revalidates the closed 0.6.0 evidence, then routes every attempted tag through the candidate admission gate. Historical tags at or below 0.6.0 are protected, permanently closed identities and cannot be admitted again. A tag newer than 0.6.0 is rejected unless it is exactly `v0.7.0-rc.1`. Even that exact tag remains rejected until all seven ordered pre-tag gates carry evidence, the active package and native-integrity identities agree on `0.7.0-rc.1`, and the contract is explicitly changed to `candidate-ready` with `candidateReady: true`. Candidate-ready hosted and origin evidence records run IDs, timestamps, and policy results but deliberately stores no candidate commit hash, so the contract can itself be committed. At tag admission, runtime arguments bind the peeled tag commit to a fresh exact `origin/main` readback, and the workflow API gates bind same-commit Build and CodeQL results to that exact runtime commit.

Do not mark `hosted-validation` verified from local results. It requires a successful same-repository `main` Build run plus the same-commit default-setup CodeQL proof for Actions, JavaScript/TypeScript, and Ruby at a recorded pre-admission checkpoint, with clean error/warning status and zero open alerts. The static candidate-ready evidence stores the Build run ID and observation times without a commit hash; the tag workflow independently rechecks both services against its exact runtime commit immediately before candidate admission. When publication closes, `publicationEvidence.finalBuildEvidence` must bind the exact `Build` name, tag commit, run ID, attempt, successful conclusion, and completion time, and the terminal hosted evidence must name that same run ID and commit. `tag-workflow-publication` must remain pending until the protected tag workflow has actually completed, so no local state can claim publication in advance.

The candidate workflow is draft-first. It rejects any published release identity; an authenticated exact-tag draft targeting the same commit may be resumed and its expected asset names reconciled with overwrite enabled. The workflow validates the exact 25 local files, uploads only that closed inventory, re-reads every GitHub asset name, size, and SHA-256 while the release is still private, and only then publishes the draft. Overwrite authority is confined to exact-tag draft reconciliation and never applies to an immutable published asset; missing or extra draft assets still fail closed. Publication must read back `immutable: true` and pass GitHub's cryptographic release-attestation verification before npm publication can start. `v0.7.0-rc.1` must be the first true immutable GitHub Release.

The whole `create-release` job waits on GitHub Environment `immutable-release` (environment ID `21234930544`). Its only required reviewer is user `vyakymenko` (ID `7300673`), `prevent_self_review` is `false`, administrator bypass is disabled, it contains no secrets, and its only deployment policy is `v*` with type `tag` and policy ID `59095548`. Actions stores no repository-administration credential: `GITHUB_TOKEN` cannot prove the Immutable Releases setting because that endpoint requires repository Administration read.

Immediately before the one allowed lightweight tag is pushed, an administrator must live-read the repository Immutable Releases setting and record exact `enabled=true`, `enforced_by_owner=false`; `scripts/verify-github-release-assets.mjs --phase setting` validates the saved JSON. The same pre-tag check re-reads repository ruleset 22261144 (`Protect release tags`) as active for target `tag`, including `refs/tags/v*`, with exact `update` and `deletion` rules, `bypass_actors: []`, and `current_user_can_bypass: never`. After the tag workflow reaches the waiting `immutable-release` deployment, the required reviewer repeats both live readbacks immediately before approving it in GitHub. Do not approve if the environment policy, setting, or ruleset differs. The workflow then independently requires its published release to read back `immutable: true` before npm.

If the tag workflow reaches a terminal non-success conclusion, do not label the attempt `closed` or claim success. Move the machine contract to schema 3 `publication-failed`, set `candidateReady: false`, record the exact tag and final Build identities plus the observed GitHub (`absent`, `draft`, or `immutable-published`) and npm (`absent` or `published-exact`) surfaces, then select a new candidate version. Never move, recreate, or reuse the failed tag/package identity.

## Published release-candidate evidence

Protected historical tag `v0.6.0-rc.2` points to release-ready commit `b63e190f7edeccd829abe34bfb96d9e1a8a320e2`. Its automatic workflow completed successfully on attempt 1, created GitHub prerelease `369856953` with the exact 25-asset inventory, and published immutable npm version `zigcss@0.6.0-rc.2` with provenance on `next`. The GitHub prerelease predates Immutable Releases and reads back `immutable: false`. At that RC publication, npm `latest` remained `0.3.0`; today `latest` is stable `0.6.0` while `next` still preserves the RC. The tag and package version must never be moved, recreated, reused, or republished.

Before any release asset was built, the workflow:

1. checks the tag against every versioned surface;
2. authenticates the repository-owned npm token against explicit `https://registry.npmjs.org/` with `npm whoami` without logging the account identity, using at most four 30-second attempts with five seconds between attempts;
3. obtains the explicit canonical registry's complete immutable `zigcss` version inventory, also using at most four 30-second attempts with five seconds between attempts and accepting only a complete successful readback; and
4. failed unless the selected candidate version was absent and the registry response was valid.

All five native jobs then built and executed architecture-matched archives, validated the npm install path offline, generated checksums and SPDX SBOMs, signed provenance and SBOM attestations, and uploaded the closed release inventory. GitHub Release creation occurred only after every native job passed.

The npm job published with:

```bash
npm publish --tag next --registry=https://registry.npmjs.org/ --provenance
```

The explicit `next` channel prevented the experimental release candidate from replacing stable `latest`. OIDC-backed npm provenance was retained in the registry metadata. The workflow read back both the immutable version and `dist-tags.next`; both matched on its first bounded attempt.

Any later candidate requires a new version and tag identity plus the complete release gate. Do not rerun this publication as a substitute for a new candidate.

## Required repository authority

- The `NPM_TOKEN` GitHub Actions secret must identify an npm principal allowed to publish `zigcss`.
- The npm package remains public.
- The release workflow alone receives the token, and only its preflight and publish jobs use it.
- The publish job alone receives the OIDC permission needed for npm provenance.

## Anonymous post-publication delivery terminal

Every future tag workflow ends with `anonymous-public-delivery` only after `publish-npm` has published and read back the exact version. This final Linux job has only `contents: read`; checkout does not persist its credential, Node setup does not configure a registry credential, and no npm token, GitHub token, OIDC permission, package permission, or secret enters the smoke process.

The terminal invokes `scripts/smoke-public-delivery.mjs` directly rather than through npm. Before any network request, the script rejects known authentication variables, inherited `NPM_CONFIG_*` state, Node injection options, ZigCSS binary overrides, malformed versions, and unsafe paths. It then gives npm a minimal allowlisted environment, empty temporary user and global configuration files, a fresh cache, the canonical `https://registry.npmjs.org/` endpoint, and exact `zigcss@<tag-version>`. Lifecycle scripts remain enabled: the test therefore exercises the public package tarball, `install.js`, the matching public GitHub native archive, its checksum, executable architecture, and the committed five-target integrity inventory as an ordinary anonymous consumer sees them.

After installation, the terminal requires the exact package and CLI version, bounded regular non-symlink files, an executable native binary, and fixed limits for time, process output, file count, and installed bytes. It compiles CSS, SCSS, indented Sass, Less, and Stylus through the installed CLI, then compiles all five inputs with both synchronous and asynchronous APIs through both CommonJS and ESM package resolution. A prerelease must also emit the exact release-candidate warning; a stable build must remain quiet.

This is deliberately a post-publication assertion, not permission to publish. Failure leaves the release run failed for investigation; it never authorizes moving or recreating a tag, overwriting a package version, or bypassing the next-version admission contract.

## Consumer behavior

The seven-file npm package contains metadata, notices, the JavaScript wrapper, and installer—not a bundled native executable. During installation, `install.js` selects one of the five release targets, downloads only the matching GitHub Release archive and checksum manifest, verifies SHA-256 and executable architecture, extracts exactly one executable, and replaces the local binary only after every check passes.

Install the published stable release:

```bash
npm install --global zigcss
zigcss --version
```

The historical RC remains an immutable npm version installable with `zigcss@next` for comparison; the stable workflow never moves that tag.

The ordinary `npm install --global zigcss` command resolves to the verified `0.6.0` bytes through `latest`. Source builds remain the fallback documented in `README.md` and the public build guide. Stable publication does not expand executable-plugin, editor, service, or other experimental boundaries and does not authorize comparative performance claims.
