# Changelog

All notable changes to Necropsy are documented in this file.

## Unreleased

## 0.2.0 - 2026-08-03

- **Breaking:** Reports now omit `low` confidence findings by default, substantially reducing noisy output. Pass `--min-confidence low` to retain the previous output.
- Improve analysis accuracy for qualified and inherited constants, implicit constructors, ambiguous calls, Ruby protocols, and framework callbacks, including Rails and RuboCop entry points.
- Speed up analysis of large projects by indexing and caching call-graph resolution and resolving each call site only once.
- Add `why` and `explain` commands to show shortest reachability paths, uncertainty, nearby live symbols, and confidence-score components in human or JSON output.
- Add `report.include` and `report.exclude` to limit reported paths without removing code from the call graph, and warn when scan-path filters hide potential entry points.
- Make CI and dynamic analysis more reliable with corrected ratchet behavior, hardened TracePoint/Coverage/Coverband imports, deterministic report ordering, and line-ending-safe quarantine writes.

## 0.1.0 - 2026-07-09

- Initial implementation.
