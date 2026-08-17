# ADR-0003: Physical definition as the review unit

Status: Accepted
Date: 2026-08-12
Legacy-ID: #69, #70, #72
Review-items: #69, #70, #72
Superseded-by: None

## Context

Logical names can refer to reopened or repeated physical definitions. Baselines,
quarantine annotations, SARIF locations, and source edits all need to identify
the body that is actually being reviewed. Collapsing cycles or same-name
definitions into a cluster can hide one member with a different risk profile.

## Decision

The physical definition remains the primary review identity. `why-not` exposes
witnesses, incoming sites, blockers, and suggested next evidence per physical
definition. Typed load evidence and unrooted-load diagnostics represent
activation without introducing a second mutable activation graph.

## Consequences

Duplicate and reopened methods remain independently actionable or blocked.
Cluster and frontier presentation is not part of the removal contract, and load
evidence stays attributable to the source definition and call site.

## Reconsideration gate

Reconsider cluster or frontier presentation only after a review-time study shows
at least a 20% reduction in median triage time with zero missed mixed-risk
definitions. Add a separate activation graph only when a new analysis requires
state that typed load evidence cannot represent.
