# Necropsy

Necropsy is a Ruby dead-code detector built around a unified call graph. It
collects method definitions with Prism, adds call-edge evidence from static and
optional dynamic analyzers, then runs reachability from framework and configured
entry points.

Machine-readable JSON reports use schema v2. The published contract is
[`schema/necropsy-report-v2.schema.json`](schema/necropsy-report-v2.schema.json).

Necropsy includes:

- Prism-based method collection for ordinary, singleton, delegated, aliased, forwarded, and dynamically defined methods
- static name resolution and CHA, with rank-only RTA hints from classes instantiated in the scanned program
- Prism-backed Rails route parsing plus callback, view, component, migration, plain Ruby, and test-suite entry points
- `unreachable`, `unused`, `blocked`, and `test_only_reachable` classifications
- confidence levels, compact JSON/YAML reports, SARIF/GitHub output, CI guardrails, dynamic collectors, and benchmarking

## Installation

Add the gem to the development/test group:

```ruby
gem "necropsy", require: false
```

## Usage

Create a baseline:

```bash
bundle exec necropsy baseline --root .
```

New baselines use schema v2 and identify each physical method definition. Existing
schema v1 baselines remain readable. `necropsy check` migrates matches in exact ID,
body digest, then symbol/path-hint order; if any mapping has multiple candidates it
fails closed with a review report instead of silently accepting one definition.

Run a report:

```bash
bundle exec necropsy analyze --root . --format human
bundle exec necropsy analyze --root . --min-confidence low # include exploratory findings
bundle exec necropsy --version
```

Reports omit `low` confidence findings by default. Pass `--min-confidence low`
to retain the pre-0.2 behavior.

Inspect why a symbol is alive or dead, including the shortest evidenced path,
nearby alive node, and unresolved dispatch notes:

```bash
bundle exec necropsy why 'MyService#call' --root .
bundle exec necropsy why 'MyService#call' --root . --format json
bundle exec necropsy why-not 'LegacyService#unused' --root .
bundle exec necropsy why-not 'LegacyService#unused' --root . --format json
bundle exec necropsy explain 'LegacyService#unused' --root .
```

`explain` shows every confidence score component and the final confidence
level. `why-not` emits a refutable `necropsy.why-not.v1` artifact for candidates,
blocked findings, and test-only definitions. It includes examined call sites and
resolution statuses, rejected targets, blockers, world/root policy, non-Ruby
matches, parse/analyzer failures, enabled analyzers and type providers, artifact
digests, assumptions, risk flags, the recommended review action, and the next
evidence to collect. Every diagnostic collection reports total, returned, and
truncated counts, and nested metadata is bounded as well. Missing IDs return
partial-match suggestions. When a logical symbol ID matches multiple physical
definitions, all three diagnostic commands list every source location and an
executable command using its full definition ID.

For compatibility, the existing logical `id` and `fingerprint` remain stable.
Reports add `logical_fingerprint` and `physical_fingerprint`, while SARIF retains
the `necropsy` partial fingerprint and adds `necropsyPhysicalDefinition`. Reports
also include `symbol_id` and `definition_id`; human, GitHub, and SARIF findings
display or expose the full physical definition ID so reopened or duplicate methods
can be distinguished.

Runtime artifacts remain backward compatible: collectors keep the legacy
`nodes` and `edges` fields while adding structured `node_references` and edge
endpoint references with `definition_id`, `symbol_id`, `file`, and `line` when
available. Importers prefer structured references and continue to accept v1
logical-ID artifacts.

Fail CI only for new high-confidence findings:

```bash
bundle exec necropsy check --root . --fail-on high
```

Record dynamic evidence from a Ruby script:

```bash
bundle exec necropsy record --root . --output tmp/necropsy_trace_point.yml -- script/runner.rb
bundle exec necropsy coverage --root . --output tmp/necropsy_coverage.yml -- script/runner.rb
```

Record Ruby Coverage while running an external command:

```bash
bundle exec necropsy coverage --root . --output tmp/necropsy_coverage.yml -- bundle exec rspec
```

Child Ruby processes inherit the collector and are merged into the same output
for that run.

Evaluate against a gold standard:

```bash
bundle exec necropsy bench --root . --gold-standard gold.yml --ablation
```

Benchmark JSON keeps the existing logical-ID metrics and adds `identity_views`.
The legacy view groups by `symbol_id`; the physical view lists every
`definition_id` and both fingerprints, so duplicate definitions cannot disappear
from review totals.

Benchmark precision is measured from actionable `unreachable`/`unused` findings only.
`blocked` and `test_only_reachable` remain visible diagnostics but are not removal candidates.
The additive `quality` and `by_category` objects report candidate precision/count/LOC,
known-positive recall, blocked and unknown rates, and rule/risk counts. A run with zero
candidates fails the evaluator's `candidate_yield` release check instead of receiving perfect
precision. The legacy `Report#dead_methods` API is unchanged; integrations that need the stricter
set can use `Report#actionable_candidates`.

Non-analyzer features can be compared with the same evaluator by supplying already analyzed
on/off reports. This keeps feature configuration outside the metric engine while producing a
physical-definition candidate diff and metric deltas:

```ruby
Necropsy::Bench::Evaluator.new(
  report: feature_on_report,
  gold_standard_path: 'gold.yml',
  feature_ablation: {
    'receiver_flow' => { on: feature_on_report, off: feature_off_report }
  }
).call
```

JSON and YAML omit the full call graph by default. Add `--include-graph` when
nodes, edges, evidence, and entry points are needed in machine-readable output.

Example configuration:

```yaml
analysis:
  world: application # application | library
  load_roots: known # known | all
analyzers:
  static: [name_resolution, cha, rta]
  dynamic:
    coverage:
      source: tmp/necropsy_coverage.yml
      min_observation_days: 30
    coverband:
      source: rediss://prod-redis:6379/2?key=coverband
      connect_timeout: 5
      read_timeout: 5
      total_timeout: 15
      max_response_bytes: 16777216
      max_bulk_bytes: 8388608
      max_array_elements: 100000
      max_resp_depth: 16
      max_keys: 1000
      max_payload_depth: 64
    trace_point:
      source: tmp/necropsy_trace_point.yml
  custom:
    - class: "MyCompany::GraphqlEntryAnalyzer"
      require: "config/necropsy/graphql_entry_analyzer"
rta:
  pruning: rank_only # use legacy only for temporary compatibility with pre-0.2.1 edge pruning
cache:
  enabled: true
  path: .necropsy_cache/scan.json
resolution:
  ambiguity_limit: 4 # use "unlimited" to retain every same-name candidate
implicit_callers:
  - name_pattern: "^on_"
    owner_ancestors: ["RuboCop::Cop::Base"]
    reason: "RuboCop Commissioner callback"
paths:
  analyze: ["**/*.rb", "Rakefile", "**/*.rake", "bin/*", "exe/*", "*.gemspec"]
  reference: ["**/*"]
  exclude: ["app/legacy/**/*.rb"]
report:
  include: ["app/**", "lib/**"]
  exclude: ["lib/generated/**"]
entry_points:
  extra:
    - "PublicApi::*"
ci:
  fail_on: high
  baseline: .necropsy_baseline.yml
quarantine:
  days: 30
  expiry: warn # warn | fail | ignore
bench:
  precision_threshold: 0.85
logging:
  verbose: false
```

The scan cache is invalidated when analyzed Ruby files, reference files, or
configuration values change.

`analysis.world: application` uses executable, framework, and configured roots.
Use `library` when callers may live outside the repository: every non-test
public or protected method becomes an `external` root, while private methods
remain eligible for review. `analysis.load_roots: all` is an opt-in conservative
mode that treats every non-test Ruby file top level as a runtime root when load
status cannot be established. Root domain, reason, and provenance are included
in graph JSON and `why` paths.

When a call receiver cannot be resolved exactly, Necropsy conservatively keeps
up to `resolution.ambiguity_limit` same-name candidates alive. The default of
four is based on the RuboCop 1.75.0 measurements in `MEASUREMENTS.md`. If a
runtime call has more candidates, Necropsy records a message- and owner-scoped
blocker instead of treating the empty target set as proof of deadness. Matching
definitions are reported as `blocked` with the call site, scope, and reason;
they never receive `high` or `certain` confidence. Unresolved calls found only
in test files remain diagnostic evidence and do not block production candidates.

Ruby VM hooks and common protocol methods receive lower confidence because
their callers may not appear in source. Add `implicit_callers` rules for
framework or application callbacks; `owner_ancestors` is optional.

Source discovery has three independent scopes. `paths.analyze` selects Ruby
definitions eligible for findings. `paths.reference` defaults to the whole
repository and keeps Ruby callers outside the analysis scope in the graph;
definitions found only there are never reported as dead-code findings. It also
inventories non-Ruby files for conservative reference checks. `report.include`
and `report.exclude` only filter output and never remove graph nodes or edges.
When `paths.analyze` is omitted, the existing conventional Ruby source set
(`*.rb`, `*.rake`, the root `Rakefile` and gem specifications, and Ruby
executables directly under `bin/` or `exe/`) remains the analysis scope.

`paths.exclude` continues to remove files from the analysis scope, while the
legacy `paths.include` key remains an alias for `paths.analyze`. Narrowing the
analysis scope can hide entry points, so reports include scope diagnostics and
Necropsy warns when detected executables, tests, routes, or task files are left
outside it. Repository discovery rejects symlinks and paths that resolve outside
the project root. If `paths.reference` excludes non-test Ruby files that may
contain callers, findings are conservatively `blocked` and the report lists the
excluded count and sample until the reference scope is expanded.

For otherwise actionable candidates, Necropsy also scans reference-scope files
that are not Ruby. Unexplained method names in templates, YAML, GraphQL SDL, and
scheduler configuration become `unparsed_external_reference` blockers with the
matching file, line, and snippet. Common names such as `call` or `run` require a
review more often because safety takes precedence over yield; benchmark results
identify formats that merit a dedicated parser. The scanner is a portable Ruby
fallback with no `rg` dependency. It ignores comments, generated/tool metadata,
binary formats, and files larger than 1 MiB; bounded skip counts and samples
remain visible in report diagnostics.

Dynamic inputs may provide `executed` or `nodes` entries with method IDs,
`edges` with `caller_id`/`callee_id`, and an `observation` hash. SARIF and
GitHub Actions annotations are available via `--format sarif` and
`--format github`.

Reports retain logical method names while the graph distinguishes repeated or
reopened definitions with physical `definition_id` values. Graph consumers and
custom analyzer authors upgrading to the structured resolution model should
follow the [0.3.0 migration guide](docs/migrations/0.3.0.md).

The graph keeps one interned evidence store and derives `exact`, `conservative`,
and scope-filtered `observed` edge views on demand. Normal analysis and the
serialized `edges` view use the conservative projection, preserving legacy
reachability. Serialized edges retain nested `evidences` and additionally
reference the top-level `evidence_records` through stable `evidence_ids`.

Runtime evidence is positive-only: executed methods and the endpoints of
observed edges are kept alive, while an unobserved method never becomes a new
finding and never receives higher confidence. Observation duration and
environment remain informational metadata. `min_observation_days` is a
read-compatibility no-op and cannot change candidates, classifications, or
confidence. The `unused` state remains only for reading and aggregating legacy
schemas; positive-only analysis does not produce new `unused` findings. Reports
include attempted, matched, and unmatched evidence counts plus a bounded
unmatched sample.

Schema v1 payloads may omit the analyzed source revision. Their positive
evidence is accepted for liveness for compatibility, but an omitted revision is
marked `source_revision_status: unknown` and is never treated as proof that
unobserved code is dead. When `source_revision` is supplied, it is retained in
the evidence scope so an exact projection can require a matching revision. Use
evidence recorded from the same checkout.

Coverband file, Redis string, and Redis hash exports are supported. Redis URLs
may include an ACL username and password. `rediss://` uses the system CA store,
TLS peer verification, SNI, and post-connect hostname verification; URI
credentials are redacted from loader errors. Connect, read, and total timeouts,
response and bulk bytes, RESP array size/depth, key count, and payload depth all
have the bounded defaults shown above and can be set in the Coverband analyzer
configuration. Rails route
entry point detection covers common `resources`, `resource`, `namespace`,
`scope`, `controller`, `concerns`, `draw`, `mount`, `root`, and verb route
forms.

`necropsy quarantine --write` adds
`# necropsy:quarantine since=YYYY-MM-DD fingerprint=PHYSICAL_FINGERPRINT`.
The annotation applies only to the immediately following physical definition
when its fingerprint matches. Legacy annotations without a fingerprint require
review and can be upgraded in place with `quarantine --write`.
Use `--as-of YYYY-MM-DD` or `SOURCE_DATE_EPOCH` to make quarantine expiry,
annotation dates, and baseline timestamps reproducible.
Expiry never changes a finding's classification, score, or confidence. Instead,
the finding receives a `quarantine_review_required` diagnostic. The `check`
command warns by default; set `quarantine.expiry` to `fail` to make an expired
annotation fail CI, or to `ignore` to suppress the operational check. An invalid
`since` date is reported as `quarantine_invalid_date` without changing deadness.

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then run
`bundle exec rake` for the specs and RuboCop checks. Use `bin/console` for an
interactive prompt.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
