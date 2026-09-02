# Ranking-abuse response

**Owner:** marketplace operator
**Approver:** security responder for account action

Trigger on coordinated installs/favorites/saves, automation, creator rings,
replayed receipts, or unexplained ranking movement.

1. Snapshot the deterministic ranking inputs and algorithm revision. Preserve
   raw bounded events under restricted access; do not expose actor identifiers
   in public metrics.
2. Exclude known invalid events using reason-coded, reversible rules. Never edit
   aggregate counts directly without a reproducible rebuild.
3. Check one-use install receipts, rate limits, account age, device/session
   signals, network concentration, and cross-creator coordination. No single
   signal is an automatic guilt decision.
4. Recompute the ranking snapshot and compare before/after positions. Apply
   throttles, event exclusion, or account restrictions proportionately.
5. Give affected creators a private appeal route and retain the policy/rule
   revision used.

Exit after the manipulation no longer changes public ordering, the snapshot is
reproducible, false-positive review is complete, and monitoring covers the new
pattern.
