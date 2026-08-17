# Adversarial review record: 148 items (2026-08-12)

> Frozen record. This file captures the review state on 2026-08-12 and is not
> maintained as a live implementation checklist.

Reviewed against the working implementation on 2026-08-12. “Safe equivalent” means the proposed
mechanism was not copied literally, but its removal-safety or operability goal is enforced by a
smaller reviewed contract. “No-go” is an explicit adversarial decision with a reconsideration gate
in the linked ADR; it does not mean silently deferred work.

## 1–38: finite flow, Ruby semantics, and health

| # | Disposition | Evidence and decision |
|---:|---|---|
| 1 | Implemented | Dynamic send reads argument zero only; adversarial later literals, splats, forwarding, and finite names are covered in `flow_interpreter_spec.rb`. |
| 2 | Implemented | Unsupported/control-flow writes invalidate exact local facts in `flow_interpreter.rb`; monotonic safety specs compare candidate sets. |
| 3 | Implemented | No-else `if` joins the pre-branch environment. |
| 4 | Implemented | Case predicates/guards are evaluated and the unmatched path is joined. |
| 5 | Implemented | `and`/`or` use short-circuit path joins rather than unconditional right-side effects. |
| 6 | Implemented | Lambda capture uses an isolated environment; construction does not mutate outer locals. |
| 7 | Implemented | Return/break/next/raise-like termination is represented by transfer state and unreachable tails do not refine facts. |
| 8 | Implemented | Hash splats and unknown keys make the container partial/unknown. |
| 9 | Implemented | Symbol and string keys remain distinct and finite candidate keys are joined. |
| 10 | Implemented | `.new` is exact only for a proven core constructor path; overridden/unknown constructors remain hints. |
| 11 | Implemented | Modifier `private def`/`protected def` visits the nested definition without changing ambient visibility. |
| 12 | Implemented | Modifier `module_function def` creates the private instance definition and physical singleton copy without leaking mode. |
| 13 | Implemented | Positional and keyword default expressions are visited in method caller context. |
| 14 | Implemented | Every semantic call handler returns `CallTraversal(receiver, arguments, block)`; wrong contracts raise. |
| 15 | Implemented | Dynamic `define_method` gets an owner-scoped blocker and isolated synthetic body. |
| 16 | Implemented | `class << Constant` uses the constant singleton owner; a dynamic expression is blocked. |
| 17 | Implemented | Dynamic `def receiver.name` is isolated behind a dynamic singleton-definition blocker. |
| 18 | Implemented | Dynamic superclass expressions are visited and never substituted with `Object`. |
| 19 | Implemented | Scanner context carries lexical nesting separately from the definition owner. |
| 20 | Implemented | Pattern matching is ancestry control flow; unknown semantic shapes fail closed via the generated semantics matrix. |
| 21 | Implemented | `class_exec`, `module_exec`, and `instance_exec` use bounded owners or a synthetic blocked context. |
| 22 | Implemented | Dynamic attr/delegate/Forwardable/Struct/Data names emit generated-surface blockers and still traverse inputs. |
| 23 | Safe equivalent | `remove_method`/`undef_method` are activation blockers, so stale definitions are never treated as exact. Full activation simulation is intentionally not claimed. |
| 24 | Implemented | Alias/module-function relations retain physical source definitions when provable; ambiguity keeps duplicate/activation blockers. |
| 25 | Implemented | Visibility mutation considers physical definitions and retains uncertainty when activation order is not closed. |
| 26 | Implemented | Literal callback `if:`/`unless:` method names become callback roots; static disablement and dynamic conditions are distinguished. |
| 27 | Implemented | Callback blocks receive synthetic rooted definitions. |
| 28 | Implemented | Dynamic routes use owner, namespace, message, or global residual scope based on known context. |
| 29 | Implemented | Route read/encoding/parse failures create global `rails_route_health` blockers and degraded health. |
| 30 | Implemented | Oversized, unreadable, generated, and budget-skipped runtime references create a global blocker and degraded health. |
| 31 | Implemented | Discovery records unreadable paths and symlinks with domain provenance; unsafe runtime omissions block findings. |
| 32 | Implemented | `analysis_health` separates degraded/invalid analysis from findings; check, baseline, write quarantine, and release bench fail closed. |
| 33 | Implemented | Analyzer results are validated on a staged graph and committed atomically. |
| 34 | Implemented | Cache read/write rescue boundaries cannot execute the scan block twice. |
| 35 | Implemented | Pre/post source snapshots must match; a concurrent change makes analysis invalid. |
| 36 | Implemented | Normal check accepts exact v2 identity only; non-exact legacy migration produces an explicit review report. |
| 37 | Implemented | Baseline, ratchet, check, and benchmark gates use actionable classifications only. |
| 38 | Implemented | `bench --check` returns nonzero when release criteria fail. |

## 39–72: graph semantics and additional static analysis

| # | Disposition | Evidence and decision |
|---:|---|---|
| 39 | Implemented | `paths.test` configures test domains, including `features/` and nested engine layouts. |
| 40 | Implemented | File-root identity is path/load-unit based; content digest is separate provenance. |
| 41 | Implemented | Definition and call-site identity schemas are versioned and reported with Ruby/Prism/tool versions. |
| 42 | Implemented | `load_graph.rb` adds only literal require/require_relative/autoload evidence and blocks unresolved load targets. |
| 43 | Implemented | Unrooted load units with side-effectful bodies are emitted as bounded diagnostics. |
| 44 | No-go | Shadow classification without a closed activation witness is unsafe; duplicates remain physical and blocked. See [ADR-0001](../adr/0001-no-shadowed-definition-classification.md). |
| 45 | Implemented | Runtime/test definition indexes are separate for ambiguity fallback. |
| 46 | Implemented | Partial/unknown resolutions use the smallest proven owner/namespace/message residual scope. |
| 47 | Safe equivalent | A flow-budget miss falls back at the affected site; only an unscoped semantic loss can widen a blocker. |
| 48 | Implemented | Dynamic ancestry is owner/descendant or namespace scoped; only Object/Kernel/unknown surfaces go global. |
| 49 | Implemented | CHA delegates lookup order to the canonical CallGraph APIs. |
| 50 | Implemented | Singleton lookup does not fall back to the owner's instance surface. |
| 51 | Implemented | Include/prepend/extend have distinct instance and singleton lookup relations. |
| 52 | No-go | Default RTA is non-pruning, so a second root-seeded fixed point has no safety benefit absent measured precision gain. See [ADR-0002](../adr/0002-non-pruning-rta-by-default.md). |
| 53 | Implemented | Legacy RTA pruning adds invalid health; CI cannot allow it as a degraded exception. |
| 54 | Safe equivalent | Factory-name evidence is rank-only and cannot refute targets; exact construction still requires receiver/core-constructor proof. |
| 55 | Implemented | Core protocol summaries transform receivers/arguments/elements and encode block-state semantics; user methods with the same name do not trigger them. |
| 56 | Implemented | Derived protocol operations are first-class call sites with identities, resolutions, blockers, and diagnostics. |
| 57 | Implemented | Unresolved dispatch derives owner-scoped `method_missing` and implicit-private `respond_to_missing?` calls, respecting overrides. |
| 58 | Safe equivalent | Name-only discounts were narrowed to VM hooks/core protocols; concrete implicit operations produce edges and numeric scores remain ranking only. |
| 59 | Safe equivalent | Resolution status/scope, health, world policy, blockers, and evidence grade form the actionability claims; confidence numbers cannot override them. |
| 60 | Implemented | Only analyzers declaring `complete_resolution` capability may emit a complete resolution. |
| 61 | No-go | An RBS provider lacks a reviewed stale/conflicting-signature target corpus; syntax fixtures are insufficient. See [ADR-0011](../adr/0011-no-external-type-providers.md). |
| 62 | No-go | Sorbet/RBI ingestion has the same unproven open-world contract and a larger generated-RBI surface. See [ADR-0011](../adr/0011-no-external-type-providers.md). |
| 63 | No-go | Demand-driven interprocedural points-to is excluded from removal decisions until the type/alias/load-order gate is met. See [ADR-0011](../adr/0011-no-external-type-providers.md). |
| 64 | No-go | Interprocedural return summaries are not promoted without a purity/mutation corpus; local return facts stay bounded. See [ADR-0011](../adr/0011-no-external-type-providers.md). |
| 65 | No-go | Argument-to-parameter propagation is not promoted without dispatch and mutation labels; call arguments remain recorded evidence. See [ADR-0011](../adr/0011-no-external-type-providers.md). |
| 66 | No-go | Constructor ivar summaries are not promoted without aliasing/reopen coverage. See [ADR-0011](../adr/0011-no-external-type-providers.md). |
| 67 | Safe equivalent | Literal Proc/lambda/block values flow locally and fail closed at method boundaries; interprocedural promotion follows the type-facts gate. |
| 68 | No-go | Cross-file constant facts require proven activation/load order; literal local containers and class objects remain available without that claim. See [ADR-0011](../adr/0011-no-external-type-providers.md). |
| 69 | No-go | Physical definitions remain the removal/review unit; cycle collapsing can hide mixed-risk members. See [ADR-0003](../adr/0003-physical-definition-as-review-unit.md). |
| 70 | No-go | Per-definition why-not already exposes boundary sites/blockers; cluster frontier awaits the documented review-time gate. See [ADR-0003](../adr/0003-physical-definition-as-review-unit.md). |
| 71 | Implemented | Why-not emits bounded, structured `suggested_next_evidence` for receiver, route, parser, runtime, and caller gaps. |
| 72 | Safe equivalent | Typed load evidence and unrooted-load diagnostics keep activation distinct without a second mutable graph; split only at the ADR gate. See [ADR-0003](../adr/0003-physical-definition-as-review-unit.md). |

## 73–96: Rails, frameworks, and external references

| # | Disposition | Evidence and decision |
|---:|---|---|
| 73 | Implemented | Rails-generated definitions are excluded from removal findings and summarized by source macro. |
| 74 | Safe equivalent | Both enum declaration forms, prefix/suffix, scopes, and instance-method flags are modeled; dynamic/version-dependent forms block the owner instead of guessing. |
| 75 | Implemented | Belongs-to/has-one and collection associations generate distinct APIs; invalid collection build/create methods are not invented. |
| 76 | Implemented | Attribute, class/mattr/cattr, store, and store_accessor declarations share generated-method handling and are never removal candidates. |
| 77 | Implemented | Rails scope and enum scopes are singleton generated methods; literal scope bodies attach calls to the generated definition. |
| 78 | Safe equivalent | Prism first verifies route DSL calls and static argument shapes; regex is restricted to the verified call slice. Unrelated Ruby strings cannot root routes. |
| 79 | Implemented | Canonical inflection blocks are parsed structurally for literal irregular/acronym/uncountable declarations; unsupported plural rules globally block pruning. |
| 80 | Implemented | Only executable ERB regions are parsed with Prism; HTML and ERB comments cannot root/block methods. |
| 81 | No-go | Pretending generic token extraction is a sound Haml/Slim/Jbuilder/Builder parser is rejected; unparsed inputs remain conservative blockers. See [ADR-0004](../adr/0004-no-template-format-parsers.md). |
| 82 | Implemented | ActionCable hooks plus stream block/callback registrations are owner-scoped roots. |
| 83 | Implemented | ActiveJob/Sidekiq perform, serialization hooks, retry/discard, retry-in, and exhausted blocks are rooted declaratively. |
| 84 | Implemented | GraphQL resolver/subscription hooks and static `field` resolver methods are rooted; dynamic field methods block the GraphQL owner. |
| 85 | Safe equivalent | AMS, Blueprinter, and ViewComponent use the shared rule schema; generic presenter rooting is rejected because it has no runtime contract. See [ADR-0005](../adr/0005-no-generic-presenter-convention.md). |
| 86 | Implemented | Convention rule matching runs for every method family, not only `on_*`. |
| 87 | Implemented | Rule count is validated before any truncation and excess input is rejected. |
| 88 | Implemented | Gemfile/gemspec Prism calls and exact lock records enable non-Rails packs; comments/ordinary strings do not. |
| 89 | Implemented | Gemspec name and require_paths are parsed from the `Gem::Specification.new` block to find primary API files. |
| 90 | Safe equivalent | Format-aware strong contexts/comments/qualified owners reduce noise, while a generic barrier only adds uncertainty. Dedicated parsers require the ADR conformance gate. See [ADR-0004](../adr/0004-no-template-format-parsers.md). |
| 91 | Implemented | Text files up to the bounded streaming limit are scanned line by line. |
| 92 | Implemented | Global byte, match, and monotonic-time budgets degrade health instead of silently truncating. |
| 93 | Implemented | Qualified owner references block only the matching physical owner. |
| 94 | Implemented | Common short names require symbol/string, qualified, ERB, or structured DSL context. |
| 95 | No-go | A `trusted_generated` bypass would convert provenance into unsafe negative evidence; generated skips instead block globally. See [ADR-0004](../adr/0004-no-template-format-parsers.md). |
| 96 | Safe equivalent | Skip reason, file/domain samples, counts, blocker source, and stable config key are report/why-not provenance; YAML source-line retention is not required for safety. |

## 97–129: contracts, CLI, and performance

| # | Disposition | Evidence and decision |
|---:|---|---|
| 97 | Implemented | Top-level analysis health has complete/degraded/invalid status and structured reasons. |
| 98 | Implemented | Findings=1, configuration/execution=2, analysis health=3. |
| 99 | Implemented | Strict health and exact degraded-reason allowlists apply to every analysis command; invalid is never allowed. |
| 100 | Implemented | Reports include source snapshot and tool/runtime/config/identity provenance. |
| 101 | Safe equivalent | Packaged v2 JSON Schema, compatibility fields, migration notes, and schema specs define the compatibility policy without a second policy format. |
| 102 | Implemented | SARIF reachability witnesses are codeFlows. |
| 103 | Implemented | SARIF blocker/reference locations are relatedLocations. |
| 104 | Implemented | Summary separates actionable, diagnostic, blocked, and health counts. |
| 105 | Implemented | Check and health failures preserve JSON/YAML/NDJSON/SARIF/GitHub output; machine reports include structured health. |
| 106 | Implemented | `baseline migrate` is explicit; normal check will not silently migrate. |
| 107 | Implemented | Baseline writes use temporary write, fsync, and atomic rename. |
| 108 | Implemented | Duplicate identities and unknown classification/confidence values are rejected. |
| 109 | Implemented | Quarantine annotations carry and exactly match physical fingerprints at the definition. |
| 110 | Implemented | Generated methods from one macro are grouped into one macro diagnostic/annotation unit. |
| 111 | Implemented | Quarantine writes recheck source digests and atomically replace files. |
| 112 | Implemented | `--as-of` and SOURCE_DATE_EPOCH provide reproducible time. |
| 113 | Implemented | Fractions, days, limits, timeouts, and finite-number constraints are validated. |
| 114 | Implemented | Static analyzer uniqueness and dependency order are validated. |
| 115 | Safe equivalent | Model constructors bound enums/numbers/text/metadata; current producers are versioned and legacy is explicitly normalized to stable `unversioned`. See [ADR-0006](../adr/0006-normalize-legacy-analyzer-version.md). |
| 116 | Implemented | Custom analyzers require `trusted: true`, validate capabilities/results, and apply through the atomic staging contract. |
| 117 | No-go | A per-file fact cache failed the measured scan-share gate. See [ADR-0008](../adr/0008-no-per-file-fact-cache.md). |
| 118 | Implemented | Cache identity includes tool, Ruby engine/version, Prism, definition, call-site, config, inventory, and file content digests. |
| 119 | Implemented | Find-based discovery streams and prunes excluded directories before descent. |
| 120 | Safe equivalent | Fixed generated/cache directories are pruned at every depth; `paths.exclude` is not pruned because excluded Ruby still belongs to the default reference safety scope. |
| 121 | Implemented | Reverse subclass index and descendant cache avoid repeated whole-class scans. |
| 122 | Implemented | Instance and singleton lookup chains are cached and invalidated with graph indexes. |
| 123 | Implemented | Reachability and descendant traversal use head-index queues with stable ordering. |
| 124 | Implemented | Message, accepted/rejected target, and resolution indexes back why-not queries. |
| 125 | Implemented | Baseline comparison preindexes physical/logical fingerprints, body, symbol, and path. |
| 126 | Implemented | Benchmark gold labels are preindexed. |
| 127 | Implemented | NDJSON streams report, nodes, calls, edges, evidence, and metadata without nesting the graph payload. |
| 128 | No-go | Process-parallel parse is below the scan-share gate and adds worker/parity failure modes. See [ADR-0009](../adr/0009-no-process-parallel-parsing.md). |
| 129 | No-go | Candidate-specific template/reference caching is below its p95 share gate and risks stale blockers. See [ADR-0010](../adr/0010-no-template-reference-cache.md). |

## 130–148: adversarial tests and evaluation

| # | Disposition | Evidence and decision |
|---:|---|---|
| 130 | Implemented | Metamorphic identity specs cover comments, whitespace, unrelated definitions, ordering, and cache modes. |
| 131 | Implemented | Safety invariants assert unknown syntax, parse errors, dynamic routes, and unreadable references cannot increase actionable candidates. |
| 132 | Implemented | CLI integration covers analyzer execution, validation, capability, and atomic-apply failures. |
| 133 | Implemented | Source mutation during scan/snapshot makes health invalid. |
| 134 | Implemented | Dynamic-send fixtures cover later literals, splats, keywords, forwarding, and finite symbols. |
| 135 | Implemented | Flow fixtures cover no-else, short circuit, loops, lambda, transfer, rescue, op assignment, hash splat, and multi-key joins. |
| 136 | Implemented | Modifier, attr visibility, singleton constant, and dynamic singleton fixtures are present. |
| 137 | Implemented | CHA/RTA fixtures cover lookup surfaces, puts arguments, container elements, block states, sort/sort_by, and user-name collisions. |
| 138 | Implemented | Deterministic generated Ruby programs compare static targets with TracePoint runtime targets as a test oracle only. |
| 139 | Implemented | CI covers supported Ruby versions and a locked minimum Prism suite for identity, lookup, blockers, and report contracts. |
| 140 | Implemented | Deterministic AST-shape mutation/fuzz specs assert no crash, unbounded canonicalization, or unsafe finding growth. |
| 141 | Implemented | Candidate-union evaluation reports per-project metrics and macro averages, not only micro totals. |
| 142 | Implemented | Reviewed labels require reviewer, rationale, reviewed_at, and source_revision provenance. |
| 143 | Safe equivalent | Static analyzer ablation enumerates every built-in analyzer; the release precision gate requires every declared default feature's on/off evidence and improvement. |
| 144 | Implemented | Safety mutation harness breaks parse, scope, health, and positive-only constraints and requires the corpus to detect each mutant. |
| 145 | Implemented | Repeated samples gate p95/max wall time, RSS, allocations, and artifact size. |
| 146 | Implemented | `--self-check` validates resolution scope, derived-call resolution, evidence relations, node endpoints, and blocker/actionable exclusion. |
| 147 | Implemented | Runtime collectors and CLI artifact IDs accept injected clock/random sources and are deterministic under SOURCE_DATE_EPOCH. |
| 148 | Implemented | `semantics` enumerates every installed Prism node plus Ruby hooks and Rails DSL states; unknown/future nodes default unsupported. |
