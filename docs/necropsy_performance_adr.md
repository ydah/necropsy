# Performance profiling and cache decision

## Decision

Necropsy exposes an opt-in phase profiler through `Necropsy.analyze(profile: true)` and
records wall time, allocations, RSS, graph counts, resolution-cache hits, and report/index
size. The benchmark runner remains the release source for pinned corpus budgets.

The existing scan cache now keys every input file by SHA-256 content digest and writes through
a temporary file followed by rename. A same-size or restored-mtime edit therefore cannot reuse
stale facts, and an interrupted/corrupt write falls back to a fresh scan.

## PERF-02 no-go for now: per-file facts

The first measurement on the maintained sample fixture showed the analyzer phases dominating
the run (name resolution, CHA, and RTA) while the scan phase was smaller. That does not justify
the complexity and invalidation surface of a per-file fact store yet. The current cache keeps a
single deterministic scan result; a per-file cache should be proposed only after a pinned,
representative corpus demonstrates parse/scan as a material cost.

## Reconsideration threshold

Revisit per-file facts when the benchmark profile shows parse/scan as the largest phase or at
least 40% of wall time across two representative corpora, with a warm-run improvement target of
20% and no fresh-scan parity differences.

## PERF-03 no-go for now: process-parallel parsing

Process-parallel Prism parsing adds worker startup, serialization, deterministic ordinal merge,
crash recovery, and cache invalidation surfaces while the profiled scan phase is not dominant.
Thread parallelism is not a substitute because the supported Ruby engines do not provide the same
execution guarantees. Reconsider only after PERF-02's 40% scan threshold is met and a prototype
shows at least 25% cold-run improvement on two corpora with byte-identical reports and identical
health under worker failure.

## PERF-04 no-go for now: template/reference fact cache

Reference files already participate in the source snapshot and scan-cache key, but the conservative
reference barrier intentionally reruns after candidate generation. Persisting candidate-specific
matches would couple cache entries to physical identities, thresholds, parser policy, and ignored
artifact paths. Reconsider when reference/template analysis is at least 20% of p95 wall time on two
corpora and a prototype demonstrates byte-identical blockers across edits, budget exhaustion, and
generated-file policy changes.
