# Measurements

Measurements are local wall-clock results. Compare runs made on the same machine and Ruby version; absolute timings are not portable.

| date | commit | target | nodes | findings | ratio | seconds |
|---|---|---|---:|---:|---:|---:|
| 2026-08-01 | baseline | necropsy | 678 | 246 | 36.3% | 4.33 |
| 2026-08-01 | +T-01 | necropsy | 678 | 56 | 8.3% | 4.33 |
| 2026-08-01 | +T-02 | necropsy | 681 | 19 | 2.8% | 4.33 |
| 2026-08-01 | +T-04,T-05 | necropsy | 681 | 19 | 2.8% | 0.52 |
| 2026-08-01 | +T-04,T-05 | rubocop 1.75.0 | 8999 | 6039 | 67.1% | 20.50 |
| 2026-08-02 | +T-06 | necropsy (Ruby 4.0.0) | 683 | 19 | 2.8% | 0.18 |
| 2026-08-02 | +T-07 | necropsy (Ruby 4.0.0) | 686 | 19 | 2.8% | 0.20 |
| 2026-08-02 | +T-07 | rubocop 1.75.0 (Ruby 4.0.0) | 8999 | 6029 | 67.0% | 6.53 |

## Ambiguous fallback experiment

RuboCop 1.75.0, Ruby 4.0.0. The limit of four is the smallest value with the lowest bounded finding count. Eight adds edges without reducing findings; unlimited has a small precision gain at a substantial runtime and recall risk.

| ambiguity limit | nodes | edges | findings | medium | low | seconds |
|---:|---:|---:|---:|---:|---:|---:|
| 1 (previous behavior) | 8999 | 44313 | 6039 | 1039 | 5000 | 5.96 |
| 2 | 8999 | 46398 | 6032 | 1292 | 4740 | 6.32 |
| 4 (selected) | 8999 | 46607 | 6029 | 1789 | 4240 | 6.76 |
| 8 | 8999 | 46951 | 6029 | 2184 | 3845 | 6.77 |
| unlimited | 8999 | 70616 | 5931 | 2351 | 3580 | 10.27 |

The 19 self-analysis findings remain unchanged at every tested limit, including the verified dead methods `Necropsy::CallGraph#modules_for` and `Necropsy::EntryPoints::Rails#helper_referenced?`.

## Default reporting threshold

RuboCop 1.75.0 at ambiguity limit four:

| threshold | reported findings |
|---|---:|
| `medium` (selected default) | 1789 |
| `low` (explicit compatibility mode) | 6029 |

## Implicit caller experiment

RuboCop 1.75.0 at ambiguity limit four and the default `medium` reporting threshold:

| rules | reported findings | change |
|---|---:|---:|
| none | 1789 | baseline |
| Ruby hooks and protocols | 1785 | -4 |
| Ruby rules plus scoped RuboCop `on_*` rule | 1161 | -624 |

The RuboCop rule is enabled as a built-in framework pack because its ancestor constraint limits it to commissioner-dispatched cop callbacks. The same rule remains configurable for other frameworks through `implicit_callers`.

## Report path experiment

RuboCop 1.75.0 at the default `medium` reporting threshold:

| configuration | graph nodes | raw findings | reported findings | outside `lib/` |
|---|---:|---:|---:|---:|
| full scan and report | 8999 | 6029 | 1161 | 4 |
| `report.include: ["lib/**"]` | 8999 | 6029 | 1157 | 0 |
| `paths.include: ["lib/**"]` | 8131 | — | 1552 | 0 |

`report.include` preserves the full graph and removes only four out-of-scope reports. `paths.include` removes 868 graph nodes, emits an entry-point warning, and increases reported findings by 34%.
