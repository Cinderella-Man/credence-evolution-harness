# One-time cached sanity gate over dataset tasks

**Status:** supersedes the "no pre-solve gate" consequence of
[ADR-0002](0002-filesystem-task-source-replaces-translation.md).

**Context.** ADR-0002 dropped Tunex's round-trip gate, pricing a broken dataset
entry at "one wasted cycle." That was written before
[ADR-0003](0003-continuous-repass-over-finite-corpus.md) locked continuous
re-passing, which changes the economics: a broken entry (harness that doesn't
compile, flaky timing, wrong assertion) now burns 5 local solves + 1 paid Mimo
classify **every pass, forever** — and worse, its failures pollute the classify
`:failed` lens with signal caused by a broken harness rather than model weakness,
a bogus premise that can seed bogus rule proposals.

**Decision.** On a task's first encounter ever, run `solution.ex` against
`test_harness.exs` with a fix-free runner (**lenient** `mix compile --force` +
`mix test` only — no Credence/credo/format, so the verdict is a pure function of
the dataset entry, immune to the evolving ruleset). A failure is **retried once**
before blacklisting; verdicts are **keyed by content hash** of the two files (an
upstream edit auto-invalidates). The verdict (`:ok` | `:blacklist`) is cached in
`var/cache/task_verdicts.jsonl`, which **survives `mix cev.reset`**; a blacklisted
task is skipped in every pass.

**Why.** One compile+test per task, ever (~6 minutes for the whole corpus,
token-free), buys permanent protection of both token spend and signal purity. The
implementation is ~100 lines salvaged from the already-proven `round_trip.ex` +
`cache.ex`. The three hardenings are empirically grounded — a pre-code census of
all 230 tasks (DESIGN §4) showed: strict `--warnings-as-errors` would falsely
blacklist 9 good tasks (Elixir-1.20 warning drift; their tests pass); a one-shot
check would have falsely blacklisted the flaky `013_003`; and with 5 curated
workspace deps the final census is **215 usable / 15 blacklisted, every blacklist
a genuine structural defect** (10 multi-file bundles, 4 DB-requiring, 1 broken
harness).

**Consequence.** The reference `solution.ex` is read after all (gate + classify
contrast) — but still never shown to Solve. A blacklisted task is invisible to the
loop until the operator deletes its verdict line from `task_verdicts.jsonl`.
