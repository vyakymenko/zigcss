# ZigCSS benchmark status

> **Performance claims are withdrawn.** The historical measurements previously stored in this file are not semantically equivalent comparisons and must not be cited as product evidence.

The old benchmark path timed compiler outputs before proving that each tool accepted equivalent input and produced equivalent CSS semantics. It also compared a local native executable with some tools launched through `npx`, which mixed process and package-runner overhead into compiler timing. The legacy ZigCSS optimizer used by those runs is now disabled because audit fixtures demonstrate corruption, invalid emission, unsafe reordering, and crash paths.

Historical raw data remains in repository history for auditability, but it is intentionally not presented as a current result.

## Requirements for a future report

A benchmark sample is valid only when all of the following pass first:

- every tool receives a documented equivalent workload;
- output parses successfully and passes semantic/cascade comparison;
- unsupported cases are excluded explicitly rather than silently dropped;
- warmup, iteration count, environment, tool versions, and commands are recorded;
- cold-start and steady-state results are reported separately;
- peak memory and output size accompany elapsed time;
- raw samples and summary statistics are generated reproducibly;
- comparisons use validated release artifacts, not an unsafe internal transform path.

The benchmark implementation and publication gates are defined by `BENCH-001` through `BENCH-005` in `DEVELOPMENT_PLAN.md`.
