# Architecture decision records

These ADRs are living maintainer documents. Each file contains exactly one
decision and uses the required fields: `Status`, `Date`, `Legacy-ID`,
`Review-items`, and `Superseded-by`. Status is one of `Accepted`, `No-go`,
`Superseded`, or `Reconsidering`.

| ID | Decision | Status | Date | Reconsideration gate |
|---|---|---|---|---|
| [ADR-0001](0001-no-shadowed-definition-classification.md) | No shadowed-definition classification | No-go | 2026-08-12 | Activation oracle with zero known-positive loss |
| [ADR-0002](0002-non-pruning-rta-by-default.md) | Non-pruning RTA by default | Accepted | 2026-08-12 | 10% blocked-candidate reduction on two corpora |
| [ADR-0003](0003-physical-definition-as-review-unit.md) | Physical definition as review unit | Accepted | 2026-08-12 | 20% median triage reduction with no mixed-risk misses |
| [ADR-0004](0004-no-template-format-parsers.md) | No generic template format parsers | No-go | 2026-08-12 | Two corpora with zero known-positive false negatives |
| [ADR-0005](0005-no-generic-presenter-convention.md) | No generic presenter convention | No-go | 2026-08-12 | Named gem fixture corpus with zero known-positive misses |
| [ADR-0006](0006-normalize-legacy-analyzer-version.md) | Normalize legacy analyzer versions | Accepted | 2026-08-12 | 100% legacy fixture compatibility before a major break |
| [ADR-0007](0007-phase-profiler-and-digest-cache.md) | Phase profiler and digest cache | Accepted | 2026-08-12 | 100% parity across cache safety fixtures |
| [ADR-0008](0008-no-per-file-fact-cache.md) | No per-file fact cache | No-go | 2026-08-12 | 40% scan share and 20% warm-run improvement |
| [ADR-0009](0009-no-process-parallel-parsing.md) | No process-parallel parsing | No-go | 2026-08-12 | 25% cold-run improvement on two corpora |
| [ADR-0010](0010-no-template-reference-cache.md) | No template/reference fact cache | No-go | 2026-08-12 | 20% p95 reference share on two corpora |
| [ADR-0011](0011-no-external-type-providers.md) | No external type providers | No-go | 2026-08-12 | Two RBS and two Sorbet corpora with preserved recall |

Cross-references use the ADR number and a relative link. When a decision is
replaced, update `Superseded-by` in the old file and keep the old file in place.
Do not copy implementation facts from `schema/`, `bench/`, or `CHANGELOG.md`;
link to those source-of-truth artifacts instead.
