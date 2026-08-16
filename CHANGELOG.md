# Changelog

All notable changes to Necropsy are documented in this file.

## Unreleased

- Separate priority confidence from reachability state, analysis completeness, and actionability. Blocked findings are never actionable.
- Change the default CI gate to `new_review_candidate`; legacy confidence thresholds remain accepted for compatibility and `doctor` reports their weaker safety contract.
- Add `doctor`, `feedback compare/export-fixtures/verify`, physical-definition causal report diffing, and isolated `plan`/`patch`/`verify` removal workflow commands.
- Extend finite literal and constant registries with conservative `Hash#fetch`/`dig`, array-index, and reflective callable lookup without using runtime non-observation as deadness evidence.

## 0.3.0 - 2026-08-13

- Preserve repeated and reopened Ruby definitions as distinct physical graph nodes while retaining logical method names for compatibility; ambiguous runtime references no longer silently select one definition.
- Record structured call-site resolution, scoped blockers, evidence grades, and analyzer provenance, with conservative adaptation for existing custom static analyzers.
- Store graph evidence once and expose exact, conservative, and scope-filtered observed views while preserving conservative reachability and the existing nested edge JSON.
- Separate runtime, test, and external roots; library mode now protects public and protected APIs from dead-code findings, with optional conservative roots for every production file.
- Separate analysis, repository reference, and report scopes so output filters cannot remove callers from the graph; reference-only Ruby definitions are not reported, and narrowed scans expose entry-point and symlink diagnostics.
- Block candidates that still appear in unparsed templates or configuration, with bounded file/line/snippet diagnostics and safe limits for common names, generated content, binary files, and oversized inputs.
- Add `why-not` human and versioned JSON diagnostics covering physical definitions, examined calls and resolutions, blockers, world policy, external text matches, analysis failures, enabled rules, and suggested evidence.
- Write physical-definition baseline schema v2 while continuing to read logical v1 baselines; CI now stops for an explicit review when a legacy entry maps to multiple definitions.
- Expose legacy and physical fingerprints additively in JSON and SARIF, and show both logical-symbol and physical-definition candidate views in benchmark output.
- Fail closed on analyzer, parser, source-revision, reference-scan, and unsafe RTA failures; expose explicit health status, strict-health policy, machine-readable failure reports, and graph self-checks.
- Harden Ruby semantic traversal and finite value flow for modifier definitions, default arguments, dynamic sends, short-circuit paths, unsupported control flow, reflective hooks, and receiver-aware core protocol calls.
- Add conservative Rails and framework conventions for generated methods, associations, enums, scopes, callbacks, ActionCable, ActiveJob, Sidekiq, GraphQL, serializers, ViewComponent, routes, ERB, inflections, and structural dependency detection.
- Add bounded and deterministic external-reference scanning with qualified-owner matching, streaming limits, byte/match/time budgets, unsafe-skip blockers, and safe repository discovery.
- Add deterministic NDJSON graph export, content-addressed cache metadata, reproducible runtime artifacts, performance distributions, macro-averaged evaluation, AST fuzzing, runtime target oracles, mutation safety harnesses, and a generated semantics matrix.

## 0.2.1 - 2026-08-04

- Prevent unsafe dead-code recommendations when runtime dispatch, source parsing, or an analyzer is incomplete; affected methods are now reported as low-confidence `blocked` findings with the reason and source location.
- Make the default analysis conservative: RTA no longer deletes broader static edges, runtime observations only prove liveness, and quarantine expiry requests review without increasing deadness confidence.
- Harden remote Coverband/Redis evidence loading with verified TLS, bounded DNS/connect/read/write/total deadlines, strict payload and RESP limits, safe deserialization, and credential-redacted errors.
- Add reproducible five-corpus release auditing with reviewed candidate transitions, safety-invariant and adversarial suites, provenance-bound artifacts, and fail-closed wall-time/RSS budgets.

## 0.2.0 - 2026-08-03

- **Breaking:** Reports now omit `low` confidence findings by default, substantially reducing noisy output. Pass `--min-confidence low` to retain the previous output.
- Improve analysis accuracy for qualified and inherited constants, implicit constructors, ambiguous calls, Ruby protocols, and framework callbacks, including Rails and RuboCop entry points.
- Speed up analysis of large projects by indexing and caching call-graph resolution and resolving each call site only once.
- Add `why` and `explain` commands to show shortest reachability paths, uncertainty, nearby live symbols, and confidence-score components in human or JSON output.
- Add `report.include` and `report.exclude` to limit reported paths without removing code from the call graph, and warn when scan-path filters hide potential entry points.
- Make CI and dynamic analysis more reliable with corrected ratchet behavior, hardened TracePoint/Coverage/Coverband imports, deterministic report ordering, and line-ending-safe quarantine writes.

## 0.1.0 - 2026-07-09

- Initial implementation.
