# 0.2.1 safety release audit

Status: **PASS**

Baseline: `51d490188ae9ad846b4c023f14e252ec624a2d5e` — 51d490188ae9ad846b4c023f14e252ec624a2d5e is the first commit with integrity-bound normalized reports for all five required P0-01 corpora, including the pinned RuboCop 1.75.0 checkout, so it is the reproducible pre-safety baseline.

## Candidate changes

| corpus | baseline | current | added | removed | state changed | newly high |
|---|---:|---:|---:|---:|---:|---:|
| dynamic_evidence | 4 | 4 | 0 | 0 | 0 | 0 |
| plain_ruby | 3 | 3 | 0 | 0 | 0 | 0 |
| rails | 4 | 4 | 0 | 0 | 0 | 0 |
| rubocop_1_75_0 | 5797 | 5797 | 0 | 0 | 119 | 0 |
| self | 78 | 50 | 27 | 55 | 2 | 0 |

## Difference review

| corpus | strategy | changes | required | completed | zero difference |
|---|---|---:|---:|---:|:---:|
| rails | all | 0 | 0 | 0 | yes |
| rubocop_1_75_0 | stratified | 119 | 9 | 9 | no |

## Performance

| corpus | wall baseline/current/limit (s) | RSS baseline/current/limit (KiB) | pass |
|---|---:|---:|:---:|
| dynamic_evidence | 0.001035 / 0.002818 / 0.751035 | 52720 / 51200 / 118256 | yes |
| plain_ruby | 0.001883 / 0.001999 / 0.751883 | 53088 / 51488 / 118624 | yes |
| rails | 0.00361 / 0.004443 / 0.75361 | 54272 / 52656 / 119808 | yes |
| rubocop_1_75_0 | 5.196168 / 5.280823 / 7.794252 | 576256 / 584432 / 700000 | yes |
| self | 0.217221 / 0.422554 / 0.967221 | 608448 / 580480 / 700000 | yes |

## Adversarial suites

| suite | result | summary |
|---|:---:|---|
| ambiguity | pass | 16 examples, 0 failures |
| dynamic | pass | 19 examples, 0 failures |
| parse | pass | 9 examples, 0 failures |
| remote_input | pass | 25 examples, 0 failures |

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

Reviewed RuboCop/Rails changes: 9; missing: 0.
