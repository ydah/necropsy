# ADR-0009: No process-parallel parsing

Status: No-go
Date: 2026-08-12
Legacy-ID: PERF-03, #128
Review-items: PERF-03, #128
Superseded-by: None

## Context

Process-parallel Prism parsing adds worker startup, serialization, deterministic
ordinal merging, crash recovery, and cache invalidation paths. The profiled scan
phase is not currently dominant, and thread parallelism does not provide the
same execution guarantees across supported Ruby engines.

## Decision

Keep parsing in the current deterministic execution model. Do not introduce
worker processes for removal analysis while the scan-share gate is unmet.

## Consequences

Cold scans may leave parallel hardware unused, but reports, health, and physical
identities do not depend on worker scheduling or partial worker recovery.

## Reconsideration gate

Reconsider only after [ADR-0008](0008-no-per-file-fact-cache.md)'s 40% scan
threshold is met and a prototype produces at least 25% cold-run improvement on
two corpora with byte-identical reports and health under worker failure.
