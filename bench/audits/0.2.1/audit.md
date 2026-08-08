# 0.2.1 safety release audit

Status: **PASS**

Baseline: `d0168e881120320d28dc2f42e10f9947330fdcb7` — d0168e881120320d28dc2f42e10f9947330fdcb7 is the first commit with the bounded evidence identity path and artifact-independent production scopes for all five required corpora.

## Candidate changes

| corpus | baseline | current | added | removed | state changed | newly high |
|---|---:|---:|---:|---:|---:|---:|
| dynamic_evidence | 4 | 4 | 0 | 0 | 0 | 0 |
| plain_ruby | 3 | 3 | 0 | 0 | 0 | 0 |
| rails | 4 | 4 | 0 | 0 | 0 | 0 |
| rubocop_1_75_0 | 1122 | 1122 | 0 | 0 | 0 | 0 |
| self | 145 | 147 | 2 | 0 | 1 | 0 |

## Difference review

| corpus | strategy | changes | required | completed | zero difference |
|---|---|---:|---:|---:|:---:|
| rails | all | 0 | 0 | 0 | yes |
| rubocop_1_75_0 | stratified | 0 | 0 | 0 | yes |

## Performance

| corpus | wall baseline/current/limit (s) | RSS baseline/current/limit (KiB) | pass |
|---|---:|---:|:---:|
| dynamic_evidence | 0.3476 / 0.146051 / 1.0 | 57728 / 57696 / 123264 | yes |
| plain_ruby | 0.381025 / 0.122945 / 1.0 | 59360 / 62944 / 124896 | yes |
| rails | 0.369907 / 0.149768 / 1.119907 | 63168 / 65904 / 128704 | yes |
| rubocop_1_75_0 | 5.559264 / 5.50558 / 8.338896 | 349136 / 355920 / 436420 | yes |
| self | 22.508282 / 24.104173 / 30.0 | 1136080 / 1175248 / 1300000 | yes |

## Adversarial suites

| suite | result | summary |
|---|:---:|---|
| ambiguity | pass | 17 examples, 0 failures |
| dynamic | pass | 24 examples, 0 failures |
| parse | pass | 10 examples, 0 failures |
| remote_input | pass | 28 examples, 0 failures |

## Release gates

| gate | result | failures |
|---|:---:|---:|
| adversarial | pass | 0 |
| difference_review | pass | 0 |
| new_high_false_positives | pass | 0 |
| new_high_reviewed | pass | 0 |
| new_high_unresolved | pass | 0 |
| performance | pass | 0 |
| review_false_positives | pass | 0 |

Reviewed RuboCop/Rails changes: 0; missing: 0.
