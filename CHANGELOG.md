# Changelog

All notable changes to Necropsy are documented in this file.

## Unreleased

- **Breaking:** Reports now omit `low` confidence findings by default. Pass `--min-confidence low` to retain the previous output.
- Lower confidence for Ruby hooks, protocol methods, configured implicit callers, and RuboCop commissioner callbacks.
- Propagate implicit-caller uncertainty to methods reachable from those callbacks.
- Retain shortest runtime and test reachability witnesses for diagnostics.
- Add `why` and `explain` commands with human/JSON paths, uncertainty, suggestions, and score components.
- Resolve unqualified constants through superclass namespaces after lexical lookup.
- Add report-only include/exclude paths and warn when scan includes hide potential entry points.

## 0.2.0 - 2026-08-02

- Correct dynamic-evidence classification and CI ratchet behavior.
- Expand Ruby AST coverage, Rails entry-point detection, and call resolution.
- Harden TracePoint, Coverage, Coverband, Redis, configuration, and cache handling.
- Add path controls, compact reports, packaging checks, and development tooling.
- Resolve qualified constants through lexical scopes.
- Detect constructors invoked through implicit or explicit `self` receivers.
- Index method names and cache dispatch lookup chains for faster analysis.

## 0.1.0 - 2026-07-09

- Initial implementation.
