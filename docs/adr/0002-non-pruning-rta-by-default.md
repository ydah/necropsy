# ADR-0002: Non-pruning RTA by default

Status: Accepted
Date: 2026-08-12
Legacy-ID: #52, #53
Review-items: #52, #53
Superseded-by: None

## Context

Rapid type analysis can provide useful ranking hints, but inferred allocation
evidence does not prove that broader static call edges are impossible. Removing
those edges would turn a heuristic into negative evidence. The legacy pruning
mode also makes analysis health invalid when it is used as a degraded exception.

## Decision

RTA is rank-only by default and never prunes static name-resolution or CHA
edges. Legacy pruning remains an explicit compatibility option, but an analysis
using it is unhealthy and cannot pass a safety gate.

## Consequences

RTA can improve ordering and explanations without reducing the reachable graph.
The default behavior is monotonic: adding allocation or root evidence cannot
create a dead-code candidate by deleting an edge. Projects migrating from the
legacy mode must review the changed candidate set explicitly.

## Reconsideration gate

Reconsider a pruning experiment only when two reviewed corpora demonstrate at
least a 10% reduction in blocked candidates with unchanged known-positive recall.
