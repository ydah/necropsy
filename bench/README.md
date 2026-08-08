# Reproducible benchmark seed

Run the version 1 corpus from the repository root:

```shell
bundle exec ruby bench/run.rb
```

The command writes normalized reports, the candidate union, and a performance summary to
`tmp/necropsy-benchmark/v1`. The normalized reports omit machine-specific roots and timing data;
the separate summary records wall time, phase allocations, resolution-cache counts, and peak RSS
(or current RSS when the platform does not expose a process high-water mark). Its `golden.status` is `match`, `drift`, or `missing`, with every
changed deterministic artifact listed under `golden.differences`.

The manifest pins five corpus roles: this repository, RuboCop 1.75.0, a plain Ruby fixture, a Rails
fixture, and a positive dynamic-evidence fixture. The small fixtures are in `spec/fixtures`; set
`NECROPSY_RUBOCOP_CORPUS` to an existing RuboCop 1.75.0 checkout to enable that external corpus.
RuboCop is fixed to tag `v1.75.0` and commit `9c2bc8eb11e269f1cf47113041a1be3ff615f68b`;
a checkout at another commit fails before analysis. Missing external corpora are recorded as
explicit skips rather than downloaded automatically, but omission causes golden drift and a
nonzero exit once the pinned RuboCop result is present in the golden set. All five manifest entries
are required for golden updates; an incomplete run raises an error before touching existing golden
files. Pinned Git corpora must also have no tracked working-tree changes.

The comparison-tool YAML files are versioned review seeds, not claims from a fresh tool execution.
They exercise the candidate-union schema for Necropsy, Debride, Spoom, and a type-aware analyzer
without requiring those tools to be installed. Replace them with pinned output snapshots when a
comparison is rerun. A missing snapshot and executable produces an explicit skipped tool result.

Deterministic golden files live in `bench/golden/v1`. Drift is printed and exits nonzero. Updating
them requires an audit reason; `metadata.json` binds that reason to every artifact digest:

```shell
bundle exec ruby bench/run.rb --update-golden 'explain the intentional finding drift'
```

Review `candidate_union.json` before accepting drift. Labels use `dead`, `alive`, `external`, or
`unknown`, and every reviewed label includes a rationale. A label that does not match an actual
candidate from a generated Necropsy report or a versioned comparison snapshot is rejected.

Normalized report schema version 1 remains compatible and now has additive measurement fields.
Each finding declares `candidate` versus `diagnostic`, physical `definition_id`, LOC, category,
unknown status, rule hits, risks, and blockers. The `quality` object provides the corresponding
counts and rates. Report include/exclude scope is applied before these fields are aggregated.
Blocked and test-only findings never become Necropsy candidates in `candidate_union.json`, though
they remain available under `summary.necropsy_diagnostics`.

`summary.tool_metrics` separates candidate-union precision from known-positive recall and reports
candidate count and measured LOC overall and by category. Add an optional `category` to reviewed
labels to define stable error strata. A separate top-level `known_positives` list in the labels
file may include methods missed by every tool; when omitted, reviewed `dead` labels are the
backward-compatible recall set. Each known positive requires its own rationale. `unknown` labels
are not treated as either true or false
positives. When a tool produces no candidates, precision is `null` with
`precision_status: no_candidates`; yield remains zero, so an empty result cannot claim 100%
precision. External snapshots without LOC remain valid and expose `candidate_loc_measured_count`
instead of inventing a method size.

## 0.2.1 safety release audit

The release audit compares all five current corpus reports with the first integrity-bound
five-corpus snapshot, reviews deterministic Rails/RuboCop differences, runs the dynamic, parse,
ambiguity, and remote-input adversarial suites, and enforces wall-time and RSS budgets:

```shell
NECROPSY_RUBOCOP_CORPUS=/path/to/rubocop-1.75.0 \
  bundle exec ruby bench/audit.rb
```

Run it from a clean worktree. The command binds generated reports to the exact Git revision and to
the benchmark manifest and audit-config digests. It also records Ruby, OS, command, and RSS
measurement provenance, and fails closed when those values are incompatible with the saved
baseline. `--skip-benchmark` is intended only for an immediate rerun: it verifies the saved report
digests and all source provenance before accepting existing output. `--skip-adversarial` records
the suites as not run and cannot pass the release gate.

The reviewed input policy and baseline performance measurement live under
`bench/audits/0.2.1`. A passing run writes `audit.json` and `audit.md` there; neither an empty policy
nor an unknown review outcome is accepted.
