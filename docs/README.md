# Documentation

This directory separates documents by reader and by lifetime. User-facing
migration guidance lives under [`migrations/`](migrations/README.md). Maintainer
decisions live under [`adr/`](adr/README.md). Point-in-time review evidence is
preserved under [`reviews/`](reviews/2026-08-12-adversarial-review-148.md).

## User documentation

- [`migrations/`](migrations/README.md) — version-specific compatibility and
  upgrade guidance. Migration paths are kept stable for external links.

## Maintainer documentation

- [`adr/`](adr/README.md) — one architectural or safety decision per file,
  including its status, date, legacy references, and measurable reconsideration
  gate.

## Frozen records

- [`reviews/2026-08-12-adversarial-review-148.md`](reviews/2026-08-12-adversarial-review-148.md)
  — the 148-item adversarial review as reviewed on 2026-08-12. It is a record,
  not a living implementation checklist.

## Source-of-truth boundaries

Documentation explains why a decision was made and how a user migrates. It does
not copy facts owned by other artifacts:

- [`schema/`](../schema/) owns machine-readable report contracts.
- [`bench/`](../bench/) owns corpus definitions, golden output, measurements,
  and benchmark audit artifacts.
- [`CHANGELOG.md`](../CHANGELOG.md) owns the release history.
- [`MEASUREMENTS.md`](../MEASUREMENTS.md) remains the high-visibility summary
  of published measurements; benchmark evidence stays under `bench/`.

If a document needs a fact from one of these sources, link to it instead of
duplicating the value.

## Adding or changing documentation

- Choose the reader first: user guidance belongs in `migrations/`; maintainer
  rationale belongs in `adr/`; dated evidence belongs in `reviews/`.
- Use kebab-case filenames without a `necropsy_` prefix.
- Give every ADR one decision, an ID, a status, a date, a legacy reference,
  and a measurable reconsideration gate.
- Use relative links with the ADR number for cross-references.
- Update the relevant index when adding a document.
