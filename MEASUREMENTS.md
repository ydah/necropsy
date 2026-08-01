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
