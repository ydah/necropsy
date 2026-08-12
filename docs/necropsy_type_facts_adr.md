# TYPE-01 decision record

Status: no-go for external and interprocedural type providers in the removal decision.

The 0.4 implementation keeps a small `TypeFact` value object and an empty provider profile so that optional type evidence has a stable boundary. No Sorbet or RBS parser is enabled by default, and no type fact can remove a target unless it is explicitly authoritative and complete. Hints and conflicting facts remain explanatory evidence only.

The repository contains syntax fixtures with `.rbs` files, but those fixtures are not a reviewed type corpus: they do not label receiver facts, expected call targets, stale signatures, conflicting reopenings, or generated RBI/RBS behavior. Treating their existence as evidence for a provider would therefore be circular.

The same decision covers demand-driven points-to, interprocedural return and argument propagation,
constructor instance-variable summaries, and cross-load-unit constant facts. Those analyses can add
ranking evidence in an experiment, but cannot remove a conservative target until their open-world,
mutation, aliasing, and load-order assumptions are represented as claims. The existing local finite
flow remains bounded and fails closed; Proc/lambda values are local only.

## Reconsideration gate

Pin at least two reviewed RBS projects and two reviewed Sorbet projects. Each must label static call
targets and stale/conflicting type declarations at physical-definition granularity. Compare the
provider on/off for candidate precision, known-positive recall, blocked reduction, wall time, p95
RSS, and failure health. A provider may ship as hint-only when it improves a primary metric without
reducing recall. It may participate in complete resolution only after adversarial stale-signature,
dynamic-reopen, and load-order mutations preserve every known-positive target.
