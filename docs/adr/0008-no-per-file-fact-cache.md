# ADR-0008: No per-file fact cache

Status: No-go
Date: 2026-08-12
Legacy-ID: PERF-02, #117
Review-items: PERF-02, #117
Superseded-by: None

## Context

The maintained sample fixture showed name resolution, CHA, and RTA dominating
the run while parse/scan was smaller. A per-file fact store would add
invalidation and consistency surface without a measured safety or performance
benefit.

## Decision

Keep one deterministic scan result in the content-addressed cache. Do not add a
per-file fact cache to the removal decision until profiling demonstrates that
scan cost is material on representative projects.

## Consequences

The cache is simpler to invalidate and reason about, but large projects do not
receive speculative per-file reuse. Performance work stays tied to pinned
corpora rather than intuition.

## Reconsideration gate

Reconsider when parse/scan is the largest phase or at least 40% of wall time
across two representative corpora, with a warm-run improvement target of at
least 20% and no fresh-scan parity differences.
