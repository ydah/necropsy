# Performance profiling and cache decision

## Decision

Necropsy exposes an opt-in phase profiler through `Necropsy.analyze(profile: true)` and
records wall time, allocations, RSS, graph counts, resolution-cache hits, and report/index
size. The benchmark runner remains the release source for pinned corpus budgets.

The existing scan cache now keys every input file by SHA-256 content digest and writes through
a temporary file followed by rename. A same-size or restored-mtime edit therefore cannot reuse
stale facts, and an interrupted/corrupt write falls back to a fresh scan.

## PERF-02 no-go for now

The first measurement on the maintained sample fixture showed the analyzer phases dominating
the run (name resolution, CHA, and RTA) while the scan phase was smaller. That does not justify
the complexity and invalidation surface of a per-file fact store yet. The current cache keeps a
single deterministic scan result; a per-file cache should be proposed only after a pinned,
representative corpus demonstrates parse/scan as a material cost.

## Reconsideration threshold

Revisit per-file facts when the benchmark profile shows parse/scan as the largest phase or at
least 40% of wall time across two representative corpora, with a warm-run improvement target of
20% and no fresh-scan parity differences.
