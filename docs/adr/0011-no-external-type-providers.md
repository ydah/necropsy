# ADR-0011: No external type providers

Status: No-go
Date: 2026-08-12
Legacy-ID: TYPE-01, #61-68
Review-items: TYPE-01, #61-68
Superseded-by: None

## Context

Necropsy has a small `TypeFact` value object and an empty provider profile so
optional type evidence has a stable boundary. Existing `.rbs` syntax fixtures
are not a reviewed type corpus: they do not label receiver facts, expected call
targets, stale signatures, conflicting reopenings, or generated RBI/RBS
behavior. The same open-world uncertainty affects points-to, return/argument
propagation, constructor ivar summaries, and cross-load-unit constant facts.

## Decision

Do not enable Sorbet/RBI or RBS providers by default, and do not let external or
interprocedural type facts remove a conservative target. Hints and conflicting
facts remain explanatory evidence. Complete resolution still requires an
explicitly authoritative and complete provider record; local finite flow stays
bounded and fails closed.

## Consequences

Type-aware projects do not receive speculative removal candidates from an
unreviewed provider. Experiments can add ranking evidence, but provider output
cannot silently change actionability until its stale, mutation, aliasing, and
load-order behavior is measured.

## Reconsideration gate

Pin at least two reviewed RBS projects and two reviewed Sorbet projects. Label
static targets and stale/conflicting declarations at physical-definition
granularity, then compare provider on/off precision, known-positive recall,
blocked reduction, wall time, p95 RSS, and failure health. Complete resolution
requires every known-positive target to survive adversarial stale-signature,
dynamic-reopen, and load-order mutations.
