# TYPE-01 decision record

Status: no-go for a default external type provider.

The 0.4 implementation keeps a small `TypeFact` value object and an empty provider profile so that optional type evidence has a stable boundary. No Sorbet or RBS parser is enabled by default, and no type fact can remove a target unless it is explicitly authoritative and complete. Hints and conflicting facts remain explanatory evidence only.

The promotion experiment is deferred until the typed Sorbet and RBS corpora are pinned. It must compare candidate precision, known-positive recall, blocked reduction, runtime, and RSS with provider on/off, and must report parser/type errors as scoped blockers. The provider is eligible for promotion only when it improves a primary metric without reducing recall at the configured threshold. Until that evidence exists, adding either parser would increase dependency and failure surface without a measured benefit.
