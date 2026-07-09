# Necropsy

Necropsy is a Ruby dead-code detector built around a unified call graph. It
collects method definitions with Prism, adds call-edge evidence from static and
optional dynamic analyzers, then runs reachability from framework and configured
entry points.

The first implementation includes:

- Prism-based method collection for `def`, `define_method`, `attr_*`, and `delegate`
- static name resolution, CHA, and RTA-style filtering over instantiated classes
- Rails route/callback/view-helper/component, plain Ruby, and test-suite entry point providers
- `unreachable`, `unused`, and `test_only_reachable` classifications
- confidence levels, JSON/YAML/human/SARIF/GitHub reports, baseline/check guardrails, quarantine suggestions, TracePoint recording, and a bench evaluator

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
```

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
    - "MyCompany::GraphqlEntryAnalyzer"
cache:
  enabled: true
  path: .necropsy_cache/scan.yml
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
```

The scan cache is invalidated when scanned Ruby files or configuration values
change.

Dynamic inputs may provide `executed` or `nodes` entries with method IDs,
`edges` with `caller_id`/`callee_id`, and an `observation` hash. SARIF and
GitHub Actions annotations are available via `--format sarif` and
`--format github`.

Coverband file, Redis string, and Redis hash exports are supported. Rails route
entry point detection covers common `resources`, `resource`, `namespace`,
`scope`, `controller`, `concerns`, `draw`, `mount`, `root`, and verb route
forms.

`necropsy quarantine --write` adds `# necropsy:quarantine since=YYYY-MM-DD`.
When the configured quarantine window expires and no alive evidence appears,
the finding is raised to `certain`.

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
