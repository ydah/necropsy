# ADR-0001: No shadowed-definition classification

Status: No-go
Date: 2026-08-12
Legacy-ID: #44
Review-items: #44
Superseded-by: None

## Context

Ruby method activation depends on load order, conditional reopens,
`remove_method`, `undef_method`, and `eval`. A later definition can therefore
shadow an earlier physical definition without making the earlier body safe to
delete. A name-only classification would hide that ambiguity.

## Decision

Necropsy does not emit a `shadowed_definition` removal classification. Duplicate
and reopened definitions remain physical review units and stay blocked unless a
closed activation witness proves which definition is active.

## Consequences

Reports may contain more than one definition for the same logical method name.
Reviewers receive the ambiguity instead of an attractive but unsafe deletion
recommendation. Load and activation evidence remains available as scoped
diagnostics.

## Reconsideration gate

Reconsider this classification only after an activation-oracle corpus covers
load order, conditional reopen, `remove_method`, `undef_method`, and `eval`, with
zero known-positive target losses across the corpus.
