# Necropsy

[![CI](https://github.com/ydah/necropsy/actions/workflows/main.yml/badge.svg)](https://github.com/ydah/necropsy/actions/workflows/main.yml)
[![Gem Version](https://img.shields.io/gem/v/necropsy)](https://rubygems.org/gems/necropsy)
[![Ruby](https://img.shields.io/badge/ruby-%3E%3D3.2-ruby.svg)](https://www.ruby-lang.org/)
[![License](https://img.shields.io/github/license/ydah/necropsy)](LICENSE.txt)

A safety-first dead-code detector for Ruby projects.

Necropsy builds a unified call graph from Ruby definitions, static call-site
evidence, framework entry points, and optional runtime observations. It reports
code that may be removable while keeping unresolved dispatch, incomplete scans,
and external references visible as blockers.

## Features

- Prism-based analysis of ordinary, singleton, delegated, aliased, forwarded,
  reopened, and dynamically defined methods
- Physical-definition identities so duplicate and reopened methods remain
  independently reviewable
- Static name resolution, CHA, rank-only RTA hints, and conservative Ruby value
  flow
- Rails routes, callbacks, views, components, migrations, plain Ruby, and test
  entry points
- Optional positive runtime evidence from TracePoint, Ruby Coverage, and
  Coverband-compatible artifacts
- `unreachable`, `blocked`, and `test_only_reachable` classifications with
  confidence, actionability, and analysis-health metadata
- Human, JSON, YAML, NDJSON, SARIF, and GitHub Actions output
- Baselines, quarantine annotations, causal diffs, isolated removal plans, and
  CI guardrails

## Installation

Add Necropsy to the development or test group in your `Gemfile`:

```ruby
group :development, :test do
  gem "necropsy", require: false
end
```

Install the bundle and verify the CLI:

```bash
bundle install
bundle exec necropsy --version
```

### Requirements

- Ruby 3.2 or newer
- Prism 1.x (installed through the gem dependency)

## Quick Start

Generate a physical-definition baseline:

```bash
bundle exec necropsy baseline --root .
```

Run an interactive report:

```bash
bundle exec necropsy analyze --root . --format human
```

The default report shows medium-and-higher confidence findings. Include
exploratory findings explicitly when needed:

```bash
bundle exec necropsy analyze --root . --min-confidence low
```

Check for new actionable candidates in CI:

```bash
bundle exec necropsy check --root .
```

The check uses `.necropsy_baseline.yml` by default. A new candidate requires
review and causes a non-zero exit status; incomplete analysis health fails closed
instead of silently approving the result.

## Investigate a Finding

Use `why` to see an evidenced reachability path:

```bash
bundle exec necropsy why 'MyService#call' --root .
```

Use `why-not` when a candidate needs a refutable explanation:

```bash
bundle exec necropsy why-not 'LegacyService#unused' --root . --format json
```

Use `explain` to inspect confidence components, blockers, assumptions, and the
recommended next evidence:

```bash
bundle exec necropsy explain 'LegacyService#unused' --root .
```

Logical symbols that resolve to multiple physical definitions are reported as
ambiguous. Pass the complete `definition_id` shown by the diagnostic output to
review one definition at a time.

## Safe Removal Workflow

Compare reports or analyze only files changed since a Git revision:

```bash
bundle exec necropsy diff --base tmp/base.json --head tmp/head.json
bundle exec necropsy diff --root . --base origin/main
```

Create an isolated removal proof and run the project's test command in the
temporary checkout:

```bash
bundle exec necropsy plan \
  --report tmp/head.json \
  --candidate 'def:v1:...' \
  --output tmp/removal-proof.json

bundle exec necropsy verify \
  --root . \
  --report tmp/head.json \
  --candidate 'def:v1:...' \
  -- bundle exec rspec
```

`confidence` ranks evidence; it does not prove that removal is safe. The
actionability and analysis-health fields distinguish review candidates from
blocked or incomplete results.

## Runtime Evidence

Runtime observations are positive-only: observed execution can keep a method
alive, but the absence of an observation is never treated as proof that a method
is dead.

Record TracePoint or Coverage evidence while running a script or command:

```bash
bundle exec necropsy record \
  --root . \
  --output tmp/necropsy_trace_point.yml \
  -- script/runner.rb

bundle exec necropsy coverage \
  --root . \
  --output tmp/necropsy_coverage.yml \
  -- bundle exec rspec
```

Compare static findings with observed targets or export positive runtime
fixtures:

```bash
bundle exec necropsy feedback compare \
  --report tmp/static.json \
  --observed tmp/runtime-targets.json

bundle exec necropsy feedback export-fixtures \
  --report tmp/static.json \
  --observed tmp/runtime-targets.json \
  --output spec/fixtures/runtime_feedback
```

## Configuration

Create `.necropsy.yml` in the project root. The default configuration analyzes
an application world and uses known load roots:

```yaml
analysis:
  world: application # application | library
  load_roots: known # known | all

paths:
  analyze: ["app/**/*.rb", "lib/**/*.rb"]
  reference: ["**/*"]
  exclude: ["app/legacy/**/*.rb"]

report:
  include: ["app/**", "lib/**"]
  exclude: ["lib/generated/**"]

ci:
  baseline: .necropsy_baseline.yml
  fail_on: new_review_candidate
```

Important scope rules:

- `paths.analyze` selects Ruby definitions eligible for findings.
- `paths.reference` discovers callers and references outside the analysis
  scope; it defaults to the whole repository.
- `report.include` and `report.exclude` filter output only. They do not remove
  graph nodes, callers, or entry points.
- `analysis.world: library` protects non-test public and protected methods as
  external roots for open-world libraries.
- `ci.fail_on: new_review_candidate` is the default safety gate. Legacy
  confidence thresholds remain available for compatibility.

The scan cache is enabled by default and is invalidated when analyzed files,
reference files, or configuration values change.

## How It Works

1. **Discover** Ruby definitions and repository references with Prism and safe
   source discovery.
2. **Build** a physical-definition call graph from static analyzers, framework
   conventions, configured entry points, and positive runtime evidence.
3. **Resolve** calls conservatively. Partial or unknown dispatch produces a
   scoped blocker instead of speculative deadness.
4. **Classify** reachability, confidence, actionability, and analysis health.
5. **Report** findings in a human or machine-readable format, or compare them
   with a physical-definition baseline for CI.

Machine-readable reports use schema v2. The published contract is
[`schema/necropsy-report-v2.schema.json`](schema/necropsy-report-v2.schema.json).
The [0.3.0 migration guide](docs/migrations/0.3.0.md) describes the structured
physical-definition and resolution model.

## Development

Set up a checkout and run the complete local quality suite:

```bash
bin/setup
bundle exec rake
```

Run individual checks or build the gem:

```bash
bundle exec rspec
bundle exec rubocop
gem build necropsy.gemspec
```

Use `bin/console` for an interactive Ruby session with Necropsy loaded.

## Contributing

Bug reports and pull requests are welcome on
[GitHub](https://github.com/ydah/necropsy).

## License

Released under the [MIT License](https://opensource.org/licenses/MIT).
