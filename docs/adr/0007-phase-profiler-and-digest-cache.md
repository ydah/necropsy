# ADR-0007: Phase profiler and digest cache

Status: Accepted
Date: 2026-08-12
Legacy-ID: performance-profiler-cache (pre-split)
Review-items: performance profiler and scan-cache decision
Superseded-by: None

## Context

Performance work needs measured phase data without making profiling mandatory.
The scan cache must also reject same-size edits, restored mtimes, and interrupted
writes instead of silently reusing stale facts.

## Decision

Necropsy exposes an opt-in phase profiler that records wall time, allocations,
RSS, graph counts, cache hits, and report/index size. The scan cache keys every
input by SHA-256 content digest and writes through a temporary file followed by
rename. A corrupt or interrupted cache write falls back to a fresh scan.

## Consequences

The benchmark runner remains the release source for pinned corpus budgets, while
local profiling can identify phase costs without changing normal analysis. Cache
identity is content-addressed and deterministic, at the cost of hashing input
files and invalidating more aggressively than an mtime-only cache.

## Reconsideration gate

Any cache or profiler redesign must preserve byte-identical reports and health
for 100% of cold, warm, same-size/restored-mtime, and interrupted-write fixtures
before it can replace this contract.
