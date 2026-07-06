# Continuous re-pass over a finite corpus (vs Tunex's single forward pass)

**Context.** Tunex walks 118k rows in a seeded-shuffle **single forward pass** that
never finishes (years); the operator stops it, PRs the rules, and `reset`s for a
fresh sample order. Our corpus is 230 tasks — a full pass finishes in hours.

**Decision.** After a pass over all 230 tasks completes, immediately start another
pass. The harness runs passes back-to-back until the operator kills it. Progress is
pass-scoped (pass number + done-index set) for crash-resume within a pass; the
seeded-shuffle-over-parquet machinery is dropped in favour of iterating the sorted
task list.

**Why.** Re-passing a small finite corpus is productive here in a way it is not for
Tunex: Solve is non-deterministic (local model, temp > 0), so the same task yields
different clumsy [[feedstock]] each pass, and every committed rule changes what
later solves surface (emergent dedup). A single pass would leave most rules
undiscovered and force the operator to babysit restarts. The `decisions.md`
dead-end ledger and emergent dedup already prevent re-attempting dead-ends across
passes.

**Consequence.** Classify runs on every task every pass, so re-passes cost Mimo
tokens even when a pass is mostly `NO_ACTION` — inherent to the rule-hunting goal.
The operator watches rule yield and kills the run when a full pass goes dry.
