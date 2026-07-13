# ZigCSS benchmark status

> **Performance claims are withdrawn.** The historical measurements previously stored in this file are not semantically equivalent comparisons and must not be cited as product evidence.

The old benchmark path timed compiler outputs before proving that each tool accepted equivalent input and produced equivalent CSS semantics. It also compared a local native executable with some tools launched through `npx`, which mixed process and package-runner overhead into compiler timing. The legacy ZigCSS optimizer used by those runs is disabled because audit fixtures demonstrate corruption, invalid emission, unsafe reordering, and crash paths.

Historical raw data remains in repository history for auditability, but it is intentionally not presented as a current result.

## Current evidence state

The reproducible corpus, pinned competitor binaries, semantics-first output admission, separated execution modes, complete raw statistics, and controlled scheduled archive contracts are implemented under `BENCH-001` through `BENCH-006`. No controlled scheduled archive has been selected for `BENCH-007`, so ZigCSS publishes no current timing, memory, throughput, ranking, or ratio claim.

## Publication gate

`scripts/publish-benchmark-report.mjs` accepts only the exact two-file archive created by the controlled schedule. It revalidates all 43 ordered series and 860 retained raw observations, report and hardware identity, source/run provenance, artifact link, and archive digest before rendering deterministic Markdown. The repository remains on this exact withdrawal notice until a retained scheduled artifact is explicitly reviewed, committed under `benchmarks/publications/`, selected by `benchmarks/publication.json`, and reproduced byte-for-byte by the publication gate.

Any future report must keep cold and warm CLI comparisons separate, label ZigCSS-only API, allocator-memory, and throughput metrics as non-comparative, link the retained raw archive, and state the controlled-host and corpus limits. A generated report is benchmark evidence for the exact archived run, not a production-readiness claim.
