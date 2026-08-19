# ADR-016: Open-source completion and optional controlled benchmarks

- Status: Accepted
- Date: 2026-08-19
- Decision owner: project owner

## Context

ZigCSS `0.6.0` is published as a stable self-contained native release. The compiler, five syntax frontends, package, cross-platform artifacts, provenance, documentation, website, SEO, and release gates are verified. The repository also contains the complete fail-closed benchmark pipeline, including correctness admission, statistics, schedule-only collection, archive provenance, deterministic publication, and machine-verifiable bare-metal attestation.

The only missing benchmark input is a qualifying physical Linux x64 runner and its retained scheduled archive. The project has no such runner. Provisioning one solely for this evidence would introduce project-funded external infrastructure into an otherwise open-source completion path. The public report already fails closed: it contains no timing, ranking, ratio, throughput, memory, or superlative claim.

## Decision

1. The current approved autonomous development program is complete. All repository-owned product, security, correctness, release, package, documentation, website, and benchmark-pipeline work is verified.
2. The project will not provision or pay for external infrastructure solely to produce comparative benchmark evidence.
3. `BENCH-007` remains implemented but is classified `DEFERRED_EXTERNAL`, not `VERIFIED`. It is an optional evidence contribution and is not an active blocker for the current product or autonomous program.
4. `benchmarks/publication.json` remains `status: withdrawn`, and `BENCHMARK_REPORT.md` remains the generated no-claims report. No timing, ranking, ratio, “fastest”, or equivalent claim may appear without the existing controlled archive gates.
5. A future community contributor or operator may explicitly reopen section 19 by supplying eligible non-emulated Linux x64 hardware and registration authority without weakening schema v2 attestation. Paid capacity still requires a new explicit owner decision.
6. The autonomous supervisor must stop with `COMPLETE` instead of repeatedly emitting `controlled-benchmark-archive`. It may not invent substitute work, register infrastructure, or keep spending model passes on the deferred terminal.
7. Immutable `v0.6.0-rc.2`, `v0.6.0`, npm `next`, npm `latest`, GitHub Releases, assets, attestations, and Pages evidence remain unchanged.

## Consequences

- ZigCSS has a truthful stable open-source release without making an unsupported speed claim.
- The benchmark implementation remains ready for independent evidence if suitable hardware is contributed later.
- `BENCH-007` and Milestone 8 can become `VERIFIED` only through the existing controlled archive and public-readback protocol; deferral does not counterfeit that result.
- The current roadmap can close without purchasing infrastructure or treating an unavailable optional measurement as an endless development blocker.
