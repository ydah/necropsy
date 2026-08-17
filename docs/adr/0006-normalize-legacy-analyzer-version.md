# ADR-0006: Normalize legacy analyzer versions

Status: Accepted
Date: 2026-08-12
Legacy-ID: #115
Review-items: #115
Superseded-by: None

## Context

Current analyzer producers emit concrete versions, while legacy custom
analyzers may omit one. Breaking their construction contract would not improve
the safety claim because capability validation and atomic result application
already gate complete resolution.

## Decision

Legacy custom analyzer records are normalized to the stable literal
`unversioned`. Current producers keep concrete profile versions. Model
constructors bound enums, numbers, text, and metadata, and a future major
analyzer contract may make profile versions mandatory with a v2 migration
reader.

## Consequences

Schema v2 can represent legacy producers without guessing their provenance.
Compatibility remains explicit, and a producer cannot gain complete-resolution
authority merely by supplying a numeric weight or incomplete metadata.

## Reconsideration gate

Make profile version mandatory only in a major analyzer contract after a
compatibility suite accepts 100% of the supported legacy v2 fixtures and every
current producer emits a concrete version under the new contract.
