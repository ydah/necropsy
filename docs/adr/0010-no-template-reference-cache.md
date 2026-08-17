# ADR-0010: No template/reference fact cache

Status: No-go
Date: 2026-08-12
Legacy-ID: PERF-04, #129
Review-items: PERF-04, #129
Superseded-by: None

## Context

Reference files participate in the source snapshot and scan-cache key, but the
conservative reference barrier reruns after candidate generation. Persisting
candidate-specific matches would couple cache entries to physical identities,
thresholds, parser policy, and ignored artifact paths.

## Decision

Do not persist candidate-specific template/reference facts. Recompute the
barrier from the current bounded input and retain its deterministic diagnostics
in the report.

## Consequences

Reference analysis may repeat work, but stale blockers cannot survive changes to
physical definitions, thresholds, parser policy, budgets, or generated-file
rules.

## Reconsideration gate

Reconsider when reference/template analysis is at least 20% of p95 wall time on
two representative corpora and a prototype produces byte-identical blockers
under source edits, budget exhaustion, and generated-file policy changes.
