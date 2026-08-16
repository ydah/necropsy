# Benchmark v1 protocol

The v1 command is `bundle exec ruby bench/run.rb`. It emits raw JSON reports,
`candidate_union.json`, and a summary containing category-level precision, known-positive recall,
candidate LOC/yield, unknown and blocked rates, and performance measurements.

The five pinned corpus roles are intentionally different: plain Ruby, Rails/DSL callbacks,
positive dynamic evidence, visitor-heavy RuboCop, and the Necropsy repository itself. The
plain Ruby corpus also carries an RBS signature fixture (`sig/plain_seed.rbs`) so typed input is
represented without requiring a heavyweight typechecker subprocess. The versioned `type_aware.yml`
is a reviewed type-aware comparison snapshot; it is not silently treated as a fresh run. Tool output
is only comparable within the same normalized physical
definition universe, so skipped or missing competitors are reported explicitly.

The repository and RuboCop entries use explicit production scopes. Necropsy self-analysis covers
`lib`, `exe`, `bin`, `bench`, and `script`; the pinned RuboCop role covers its layout cops and
shared cop base. Tests and fixtures remain separate adversarial/fixture inputs. Reference-scope
exclusions are retained as blockers in reports, so these scopes cannot turn missing callers into
actionable candidates silently.

Labels and known positives are reviewed metadata, not tuning input. A future holdout must be
declared as a separate manifest corpus and may not be used to select default features or
thresholds. Empty candidate output reports `precision_status: no_candidates` and yield zero.
The raw candidate diff remains available in `candidate_union.json` for every tool.

The 1.0 review target is tracked separately from this safety release. `bundle exec ruby
bench/review_queue.rb` deterministically selects 300 actionable rows as `pending`, ordering by
actionability before priority confidence; the queue never adds labels and cannot make the public
claim gate pass. Legacy high-confidence counts remain as compatibility telemetry, while new
reports expose `review_candidate` and `verified_candidate` explicitly. Human reviewers must
supply rationale, outcome, and reviewer identity before a claim can be enabled.
