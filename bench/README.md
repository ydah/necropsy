# Reproducible benchmark seed

Run the version 1 corpus from the repository root:

```shell
bundle exec ruby bench/run.rb
```

The command writes normalized reports, the candidate union, and a performance summary to
`tmp/necropsy-benchmark/v1`. The normalized reports omit machine-specific roots and timing data;
the separate summary records wall time and peak RSS (or current RSS when the platform does not
expose a process high-water mark). Its `golden.status` is `match`, `drift`, or `missing`, with every
changed deterministic artifact listed under `golden.differences`.

The manifest pins five corpus roles: this repository, RuboCop 1.75.0, a plain Ruby fixture, a Rails
fixture, and a positive dynamic-evidence fixture. The small fixtures are in `spec/fixtures`; set
`NECROPSY_RUBOCOP_CORPUS` to an existing RuboCop 1.75.0 checkout to enable that external corpus.
RuboCop is fixed to tag `v1.75.0` and commit `9c2bc8eb11e269f1cf47113041a1be3ff615f68b`;
a checkout at another commit fails before analysis. Missing external corpora are recorded as
explicit skips rather than downloaded automatically, but omission causes golden drift and a
nonzero exit once the pinned RuboCop result is present in the golden set.

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
