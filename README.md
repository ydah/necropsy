# Necropsy

Necropsy is a Ruby dead-code detector built around a unified call graph. It
collects method definitions with Prism, adds call-edge evidence from static and
optional dynamic analyzers, then runs reachability from framework and configured
entry points.

Necropsy includes:

- Prism-based method collection for ordinary, singleton, delegated, aliased, forwarded, and dynamically defined methods
- static name resolution and CHA, with rank-only RTA hints from classes instantiated in the scanned program
- Prism-backed Rails route parsing plus callback, view, component, migration, plain Ruby, and test-suite entry points
- `unreachable`, `unused`, and `test_only_reachable` classifications
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
bundle exec necropsy explain 'LegacyService#unused' --root .
```

`explain` shows every confidence score component and the final confidence
level. Missing symbol IDs return partial-match suggestions.

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

JSON and YAML omit the full call graph by default. Add `--include-graph` when
nodes, edges, evidence, and entry points are needed in machine-readable output.

Example configuration:

```yaml
analyzers:
  static: [name_resolution, cha, rta]
  dynamic:
    coverage:
      source: tmp/necropsy_coverage.yml
      min_observation_days: 30
    coverband:
      source: redis://prod-redis:6379/2?key=coverband
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
bench:
  precision_threshold: 0.85
logging:
  verbose: false
```

The scan cache is invalidated when scanned Ruby files or configuration values
change.

When a call receiver cannot be resolved exactly, Necropsy conservatively keeps
up to `resolution.ambiguity_limit` same-name candidates alive. The default of
four is based on the RuboCop 1.75.0 measurements in `MEASUREMENTS.md`.

Ruby VM hooks and common protocol methods receive lower confidence because
their callers may not appear in source. Add `implicit_callers` rules for
framework or application callbacks; `owner_ancestors` is optional.

`paths.include` narrows the source files used to construct the call graph and
can remove executables, tests, routes, and other entry points. Use
`report.include` and `report.exclude` when the full project should be analyzed
but only selected application paths should be reported. Necropsy warns when a
configured `paths.include` excludes detected entry-point files.

Dynamic inputs may provide `executed` or `nodes` entries with method IDs,
`edges` with `caller_id`/`callee_id`, and an `observation` hash. SARIF and
GitHub Actions annotations are available via `--format sarif` and
`--format github`.

Runtime evidence is positive-only: executed methods and the endpoints of
observed edges are kept alive, while an unobserved method never becomes a new
finding and never receives higher confidence. Observation duration and
environment remain informational metadata. Reports include attempted, matched,
and unmatched evidence counts plus a bounded unmatched sample.

Schema v1 payloads may omit the analyzed source revision. Their positive
evidence is accepted for liveness for compatibility, but an omitted revision is
marked `source_revision_status: unknown` and is never treated as proof that
unobserved code is dead. Use evidence recorded from the same checkout; revision
matching will require a revision-bearing payload schema.

Coverband file, Redis string, and Redis hash exports are supported. Redis URLs
may include an ACL username and password; `connect_timeout` and `read_timeout`
can be set in the Coverband analyzer configuration. Rails route
entry point detection covers common `resources`, `resource`, `namespace`,
`scope`, `controller`, `concerns`, `draw`, `mount`, `root`, and verb route
forms.

`necropsy quarantine --write` adds `# necropsy:quarantine since=YYYY-MM-DD`.
When the configured quarantine window expires and no alive evidence appears,
the finding is raised to `certain`.

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then run
`bundle exec rake` for the specs and RuboCop checks. Use `bin/console` for an
interactive prompt.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
