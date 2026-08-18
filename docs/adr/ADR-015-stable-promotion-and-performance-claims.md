# ADR-015: Stable promotion and performance claims

- Status: Accepted
- Date: 2026-08-18
- Decision owner: project owner

## Context

The fully native `0.6.0-rc.2` candidate passed its local, hosted, five-target artifact, provenance, consumer, GitHub prerelease, and npm `next` gates. The npm package root nevertheless still resolves `latest` to the older `0.3.0` package. That immutable package renders an obsolete README with unsupported superlative performance copy and sends its homepage link to the repository README instead of the deployed package site.

The project owner has now requested a proper stable release, an updated public website and documentation set, search-indexing readiness, and evidence that supports any speed claim. This expands the earlier prerelease-only authority, but it does not justify moving an existing tag, bypassing release checks, weakening the controlled benchmark contract, or presenting a shared or emulated runner as dedicated hardware.

## Decision

1. The stable native promotion uses exact version `0.6.0` and one new immutable tag, `v0.6.0`. The project must not move, delete, or recreate `v0.6.0-rc.2`; its GitHub prerelease, npm `next` package, assets, attestations, and ledger evidence remain historical facts.
2. Stable promotion is a separate finite machine contract layered on the closed native prerelease evidence. It requires owner authorization, an unused exact version and tag, the already-verified native terminal, complete local and hosted validation, package and release-policy validation, documentation/SEO validation, exact `origin/main` identity, and one post-tag publication readback.
3. Publication occurs only through the repository's fail-closed tag workflow. A stable tag creates a non-draft, non-prerelease GitHub Release with the exact five-target asset set and publishes npm with provenance on npm `latest`. The existing npm `next` tag may continue pointing to `0.6.0-rc.2`; the workflow must not delete or rewrite it.
4. The existing GitHub Pages deployment is the canonical package website. The owner authorizes deployment from an exact green `main` commit. The site must ship a canonical URL, crawl policy, sitemap, route-specific indexable metadata, social metadata, and structured software metadata. Search Console ownership tokens or account actions remain operator-owned and are not invented or committed.
5. Stable release readiness and comparative performance publication are separate gates. `0.6.0` may be released while the benchmark report remains explicitly unavailable, provided every public surface contains no timing, ranking, ratio, or superlative performance claim.
6. A comparative claim may be generated only from the retained archive accepted by `BENCH-007`: correctness-admitted outputs, pinned tools and corpora, all raw samples and statistics, and controlled non-emulated Linux x64 provenance. Shared GitHub-hosted runners, macOS calibration, virtualized or emulated x64, and manually copied measurements do not satisfy that gate.
7. The claim “world's fastest” is prohibited unless the generated controlled report supports it across the exact named modes, corpora, competitors, versions, and statistical rule. Even then, the claim must name that scope and link directly to the archived methodology and raw evidence; it may not be generalized beyond the measurement.
8. This decision authorizes the repository branch push, exact-main integration, GitHub Pages deployment, one immutable GitHub stable release, and npm `latest` publication required for `0.6.0` after their gates pass. It does not authorize Homebrew, editor-extension, container-registry, service, or unrelated infrastructure publication.

## Consequences

- npm's default package page can move from obsolete `0.3.0` copy to the current zero-production-dependency native package without rewriting any published npm version.
- The stable tag and package remain fail-closed: a failed attempt is preserved and requires a new owner-approved identity rather than a rerun that changes public history.
- Website, README, release notes, npm metadata, and benchmark copy share one conservative claims policy. Hype comes from demonstrable compiler properties and linked evidence, not an unsupported multiplier.
- Google indexing receives stable canonical pages, `robots.txt`, and `sitemap.xml`; the project owner can submit the sitemap after deployment without granting repository code access to Search Console.
- The missing controlled runner can still block `BENCH-007` and the strongest speed claim without blocking a truthful stable `0.6.0` release.
