# ADR-0005: No generic presenter convention

Status: No-go
Date: 2026-08-12
Legacy-ID: #85
Review-items: #85
Superseded-by: None

## Context

ActiveModelSerializers, Blueprinter, and ViewComponent have named runtime
contracts and can use the shared convention rule schema. A generic `*Presenter`
rule has no gem-independent invocation contract and would root methods merely
because of their name.

## Decision

Necropsy does not root every public presenter method. Projects may declare their
actual hook ancestry through `implicit_callers`, and built-in rules remain tied
to named libraries with documented dispatch behavior.

## Consequences

Presenter-like methods without a declared runtime contract can remain review
candidates. Named framework support remains explicit and testable rather than
being broadened by a naming convention.

## Reconsideration gate

Add a built-in presenter rule only for a named gem with documented dispatch
semantics, a versioned fixture corpus, and zero known-positive misses in that
corpus.
