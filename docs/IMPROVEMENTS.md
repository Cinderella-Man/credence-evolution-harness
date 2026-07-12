# Improvement Proposals — Credence Evolution Harness

> **Hand-off entry point:**
> [`credence/docs/15-handoff-index.md`](../../credence/docs/15-handoff-index.md)
> maps every document this investigation produced (research reports, both
> proposal sets, the performance study, the experimental validation with full
> reproduction appendices) plus verified defects, tree state, and gotchas.
> The raw harness research behind this document is preserved at
> [`docs/research/harness-internals.md`](research/harness-internals.md).

> **Scrutinized 2026-07-11 — see
> [`credence/docs/14-proposal-scrutiny.md`](../../credence/docs/14-proposal-scrutiny.md)**
> for the experiments. Corrections that affect this document: **H1's
> "gold = zero findings" premise is false** — 76/304 golds (25%) carry 124
> findings across 20 rules, so build the gold oracle as an
> accepted-findings **ratchet** (exactly like the corpus layer), never a
> zero-findings assert; the full-gold scan measured **1.1 s**, so run it per
> candidate. **H2 upheld and cheaper**: a fixed gold's own harness runs
> standalone in ~0.6 s (`elixir -e` + `Code.compile_file`) — no workspace
> needed for pure-OTP tasks. **H4 scoped down**: neutered mutants are
> dynamically redundant for any pattern rule with a real `assert_equivalent`
> (measured: 7/7 kills); their value concentrates on the 13
> `mark_equivalence_*` opt-out rules, syntax/semantic rules, and hollow-test
> insurance. **H7's rescue branch corrected**: `covers(fix(before))` trends
> NOVEL for any input (fix output is a fixed point) — rescue instead iff the
> `before→fix(before)` diff spans do **not** overlap the `before→after` spans.

**Status:** proposal · **Date:** 2026-07-11 · **Scope:** the `:cev` loop and the
quality of the rules it generates. The sister document
[`credence/docs/12-improvement-proposals.md`](../../credence/docs/12-improvement-proposals.md)
covers the linter side; items that span both are cross-referenced as `C#`.

How this was produced: a full read of `docs/DESIGN.md`, the ADRs, and every module
on the rule-gen spine (`router` → `classify` → `novelty` → `equiv` → `implement` →
`gate`), the credence-side oracles they shell into (`mix credence.covers`,
`credence.equiv`, the corpus suite), plus a survey of prior art on learned
transformation rules and auto-fix validation (Getafix, Revisar, SafeRefactor,
RuboCop/ESLint autofix policy, Semgrep Assistant, Tricorder). Items are ranked by
expected impact on **rule quality** (precision, behaviour-safety, generality,
non-redundancy), not by effort.

One framing observation up front: the pipeline's *negative* knowledge is
excellent — the Classify prompt's five NO_ACTION classes are distilled from
measured rejects, the adversarial checklist and type-change ban are verbatim
canon, and the Gate is genuinely adversarial. The weak edges are (a) the
**fix-correctness oracle for structural rewrites**, which currently collapses
onto a test the implementing agent writes for itself, (b) **deterministic
dedup**, which was demoted to advisory, and (c) **signal that evaporates**
(NO_ACTION re-litigation, stranded narrowings, environmental failures classified
as code failures). Everything below follows from those three.

---

## Tier 1 — close the fix-correctness gap

### H1. Build the gold over-fire oracle (DESIGN §12), and run it at two points

**Problem.** Over-firing is caught only reactively: the corpus snapshot at the
Gate (a static `accepted_findings.txt` in the clone) and broken solve tests.
DESIGN §12 already names the proactive oracle — the dataset ships a hand-written
idiomatic `solution.ex` per task, and any Credence rewrite of gold code is
by definition a rule bug — but it is not built.

**Proposal.** Two deterministic, token-free insertions:

1. **Per row (cheap):** after the Sanity gate passes, run `Credence.fix` over the
   task's `solution.ex` in the workspace. Any change → route the offending rule
   (from `APPLIED_RULES`) straight to the `BUGFIX_RULE` lane with the gold diff
   as evidence. This piggybacks on files already on disk and costs one fix call.
2. **At the Gate, for new/changed rules (thorough):** run the changed rule alone
   (`Credence.fix(gold, rules: [TheRule])`) over **all** cached gold solutions
   (215 usable tasks). Any rewrite of any gold → reject with the diff, same
   escalation shape as a corpus reject. ~215 single-rule fix calls is well under
   the corpus scan's 8-minute budget.

**Why it matters.** The dataset's golds are the only corpus the harness owns that
is (i) idiomatic by construction, (ii) small, and (iii) *executable with tests*
(→ H2). The ~500-project corpus can't represent every idiom; 215 curated golds in
the exact task domain the feedstock comes from are a precision oracle the corpus
can't replace.

### H2. Add an executable fix-safety oracle: re-run the task harness on fixed code

**Problem.** For any structurally non-trivial rewrite (multi-clause, multi-var,
pattern params — the common case), the classify-time equivalence check returns
`:skipped` (`lib/cev/equiv.ex:29-39`) and the **only** behaviour-preservation
check left is the rule's `_equivalence_test` — written by the same agent that
wrote the rule, choosing its own inputs. This is a self-graded exam. The external
evidence says the risk is real: measured across six models, 19–35% of LLM
"refactorings" change behaviour, and **~21% of the behaviour-changing ones still
pass the project's existing tests** (arXiv:2602.15761). The credence-side corpus
`fix_safety_test` is metamorphic/structural only — corpus files can't compile
standalone, so nothing currently *executes* a fixed program.

**Proposal.** The harness owns what the corpus lacks: programs that compile *and*
carry a test suite. Add a Gate step (after the corpus-free suite, before the
corpus scan) for new/changed Pattern rules:

1. Collect executable subjects: every cached gold `solution.ex` **plus** the
   current row's passing solve (and optionally an archive of previous passing
   solves — see H10). Subjects are `(code, test_harness.exs)` pairs.
2. For each subject where the rule's `check` fires: apply the single-rule fix,
   compile, and run the subject's own harness in the workspace.
3. Any test regression → reject with the failing diff. This is a *behavioural*
   verdict from real assertions, not from LLM-chosen inputs.

Passing solves are the highest-value subjects: they are exactly the clumsy shapes
the rule was learned from, with a harness proving behaviour. Cost is bounded —
the rule fires on a handful of subjects, and each run is one focused `mix test`
(the validator already caps a harness run at 60s).

**Effect.** Structural rewrites get a deterministic equivalence oracle for the
first time; the `_equivalence_test` becomes defence-in-depth instead of the last
line.

### H3. Extend the deterministic equivalence check's reach (with `C2`)

**Problem.** `Cev.Equiv` only reaches single-def / single-clause / single-var /
simple-param modules; everything else is `:skipped`. Additionally the credence
battery has no map/keyword/tuple/float dimensions, and `credence.equiv` with an
empty input set returns a **vacuous EQUIVALENT** (`Enum.all?` over `[]`) — the
harness guards this by only calling with one var, but the trap is latent.

**Proposal (harness side; battery/generative work is `C2`).**
- Extend `extract/1` to multi-var simple-param defs and pass `--dim` selections
  inferred from the AST (e.g. `Map.`/`Keyword.` calls → map/keyword dimensions
  once they exist credence-side).
- For multi-clause single-def modules, fall back to **module-level** equivalence:
  compile before/after modules under distinct names and drive the public function
  over the battery (credence already has `assert_equivalent_module` machinery to
  reuse; expose it through `mix credence.equiv --module-mode`).
- Treat "0 inputs admitted" as `:skipped`, never EQUIVALENT (also fix in the mix
  task itself, `C2`).

**Effect.** Shrinks the `:skipped` population that H2 must carry; DIVERGES gets to
block *before* a 20–50 minute build instead of after.

---

## Tier 2 — make the Gate test the tests

### H4. Replace the vacuous new-rule mutation check with neutered-rule mutants

**Problem.** The mutation check reverts `lib/` to HEAD and requires the changed
tests to go RED, "incl. compile-error = RED" (`lib/cev/evolve/gate.ex:133-153`).
For a **new** rule the revert deletes the module, so the test file *always* fails
to compile — the check passes regardless of assertion quality. For new rules it
currently proves only "the test mentions the module".

**Proposal.** For each new/changed rule module, generate two *neutered mutants*
and require the focused tests to go red under each:

1. **Blind mutant:** `check/2` (or `match?/1`, `analyze/1`) → returns `[]`/`false`.
   Kills tests that never assert a positive finding.
2. **No-op-fix mutant:** `fix_patches/2` → `[]` (or `fix/2` → input). Kills fix
   and equivalence tests that don't assert a real rewrite.

Mechanically: parse the rule file, swap the callback body, write, run the focused
test files, restore — same snapshot/restore scaffolding the Gate already has. Two
extra focused-test runs (~seconds each). Keep the existing revert-to-HEAD check
for *modified* rules (there it is meaningful).

**Effect.** The Gate stops accepting tautological or assertion-free tests, which
is precisely the failure mode an LLM under "make the tests green" pressure
produces. (A later refinement — mutating the *matcher*: dropping a context node,
loosening an arity guard — would also flag over-general rules whose narrowing
tests don't exist; see prior art on guard mutation. Phase 2.)

### H5. Give the Gate its own tests and timeouts

**Problem.** `evolve/gate.ex` — the entire trust boundary — has **no unit tests**
(nothing under `test/cev/` covers it), and its `mix test` invocations have **no
wall-clock timeout** (`gate.ex:217-229`), unlike the Solve validator which wraps
`timeout --kill-after`. `validator.ex` is also untested.

**Proposal.**
- Unit-test the contract against a fixture git repo (temp dir, `git init`,
  synthetic staged states): each of the five rejects, the rename pass-through,
  the scratch sweep, mutation snapshot/restore (including the new-file branch),
  and the two-phase suite ordering (stub `run_tests` via a module boundary).
- Wrap Gate and `focused_test` (`implement.ex:248-253`) `mix test` calls in the
  same `timeout` wrapper the validator uses; a hung test otherwise blocks the
  24/7 loop indefinitely, and only the agent phase is currently time-bounded.

### H6. Bounded auto-retry on corpus rejects, feeding the evidence back

**Problem.** A corpus reject escalates to a human with a patch + report, and the
40+ minutes already spent are lost even when the fix is a mechanical narrowing.
Meanwhile the refine literature is clear that agent loops improve only when
closed over an *external* oracle — which is exactly what a corpus reject is: a
concrete list of `file:line` over-fires on real code.

**Proposal.** On `{:corpus, :over_fire, detail}`, run **one** bounded repair
round: re-seed the implementer (bugfix mode, `:over_fire` sub-shape) with the new
findings — file, line, and the source excerpt the credence over-fire test already
formats — and the instruction to narrow the matcher so those sites no longer
fire, without weakening the rule's own tests. Then the full Gate again. Second
reject → escalate exactly as today.

Also split `:narrowing` handling: when the *only* snapshot delta is `gone` lines
belonging to the rule being bug-fixed, that is the expected effect of narrowing an
over-firing rule — auto-repin those lines (a scoped
`mix credence.corpus --update-snapshot` equivalent) instead of stranding the fix
in `escalated/`. `gone` lines from *other* rules keep escalating.

**Effect.** Converts the most common expensive dead-end into a one-shot
self-repair with a deterministic oracle, while keeping the human in the loop for
anything surprising.

---

## Tier 3 — restore deterministic dedup, stop re-litigating

### H7. Reinstate novelty as a *precise* blocking gate

**Problem.** Novelty was demoted to advisory (`router.ex:119-132`) because
`covers` was unsound as a skip gate: the synthetic `before` often trips an
*unrelated* rule, reading COVERED for genuinely-novel proposals. Consequence
today: deterministic duplicate-suppression is gone; dedup rests on the
classifier's judgment plus the Gate — and the Gate cannot catch a functional
duplicate (a same-idiom rule under a new name perturbs no corpus finding). The
NO_ACTION class-2 text itself records that duplicates have shipped
(`no_doc_false_on_private` twice).

**Proposal.** Make `covers` precise instead of advisory, via a residual check:

1. Run `fixed = Credence.fix(before)` and capture `applied_rules` (the task
   should report *which* rules engaged, not just COVERED/NOVEL — add a
   `--verbose` output mode, `C6`).
2. If nothing engaged → NOVEL (as today).
3. If something engaged, compare `fixed` against the proposal's `after`
   (normalized AST equality, or the equivalence battery when extractable):
   - `fixed` realizes the proposed rewrite → **COVERED, name the rule** — block
     as duplicate, and record the covering rule in `decisions.md` so Classify
     stops re-proposing it.
   - `fixed` still contains the proposed delta → the engagement was an unrelated
     smell: **re-run the check on `fixed`** (the unrelated fix is now applied);
     if the target idiom survives untouched → NOVEL, and hand the implementer
     `fixed` as the cleaner `before`.

This addresses the exact unsoundness that forced the demotion, deterministically,
and restores `duplicate/` as a live outcome.

**Phase 2 (optional):** empirical subsumption — run the *candidate* rule alone
over the corpus and compare its firing sites with existing rules' sites; a
candidate whose sites are a subset of one rule's is redundant. Needs a cached
parse of the corpus to be cheap; worth it only if duplicates persist after the
residual check.

### H8. Give Classify a memory of prior verdicts (per task) and positive exemplars

**Problem.** Two asymmetries in an otherwise excellent prompt:
- `decisions.md` records only dead-ends (`gave_up`, `gate_reject`). A task that
  was NO_ACTION'd is re-judged *from scratch every pass* — Mimo cost (ADR-0003
  accepts this) but also *decision churn*: nothing anchors pass N+1's judgment to
  pass N's, so borderline rows eventually produce a bad proposal by sampling
  noise. The prompt's own thesis is "uncertain is NO_ACTION"; memory makes that
  sticky.
- The prompt teaches almost entirely by prohibition (five NO_ACTION classes,
  bans, checklists) with **zero worked examples of a good spec**. The
  before/after granularity the pipeline wants (self-contained module, one issue,
  generalized shape) is exactly the kind of thing one exemplar communicates
  better than three paragraphs of rules.

**Proposal.**
- Append one compact line per classified row to a per-task history
  (`var/cache/classify_verdicts.jsonl`, hash-keyed like the sanity verdicts so
  dataset edits invalidate): decision + one-line rationale. Inline the current
  task's history into its Classify prompt ("Prior passes judged this task:
  NO_ACTION ×3 — 'reduce is idiomatic here'"). Cache-scoped, so `cev.reset`
  keeps it; a committed rule that changes the code invalidates naturally via the
  solve trace changing.
- Add 2–3 positive few-shot exemplars to the prompt: real accepted specs
  (name, before, after, rationale) drawn from committed rules — ideally one
  pattern, one semantic, one repair. Add **one** filled-rule exemplar
  (abridged) to the Implement seed. Static text, zero marginal cost, and
  Semgrep's published experience says curated examples + prior-decision memory
  is where most of their precision came from.
- Once history exists, the "dry-task triage" declined in DESIGN §11 becomes a
  one-line policy on top of it (skip Classify after K consecutive NO_ACTIONs of
  the same task) — adopt only if Mimo spend becomes the bottleneck, as designed.

### H9. Don't classify environmental failures as code failures

**Problem.** Rule-gen runs on every row, and the `:failed` lens is prompted as
the higher-value path ("judge the attempts for an ISSUE they repeatedly hit").
But a solve can fail for reasons that are not code-shape: the 60s timeout
(`too_slow`), a missing workspace dep, a harness quirk. Feeding those rows the
"broken code" premise invites a bogus Syntax/Semantic rule proposal built on
environment noise. The Sanity gate protects the *reference* only.

**Proposal.** Cheap failure triage before the lens fork in
`orchestrator.router_outcome` / `Router.run`: if the final attempt's failure set
contains only `{:test, "TIMEOUT …"}` entries or workspace/dependency-shaped
compile errors (module from the dep list not available, `Mix.Dep` errors), route
to `too_slow//no_action` with a distinct row outcome instead of the `:failed`
Classify lens. Keep genuine parse/compile/test-assertion failures on the
`:failed` lens untouched.

---

## Tier 4 — measurement and provenance (make rule quality a number)

### H10. Birth certificates: per-rule provenance records

**Problem.** A committed rule carries no machine-readable link back to how it was
born (task, pass, temperature, solve model, classify decision, equiv verdict,
gate stats). Post-hoc quality analysis — which feedstock/temperature/lens
produces rules that later need bugfixes? — requires archaeology across row logs
that `cev.reset` deletes.

**Proposal.** On commit, write `provenance/<rule_snake>.json` (in the harness
`var/cache/`, and mirror the essentials into the commit message as trailers:
`Cev-Task:`, `Cev-Pass:`, `Cev-Temperature:`, `Cev-Equiv:`): task name, row
index, pass, temperature, solve provider, decision, equiv verdict + minimal set,
gate timings, implementer driver + turns used. Also archive the row's passing
solve (`var/cache/solves/<task>-<pass>.ex`) — these become H2's executable
subjects and future regression feedstock.

The defect-rate join this enables (bugfix commits per rule vs birth parameters)
is the only way to *tune* the temperature schedule and lens biases with data
instead of intuition.

### H11. A per-pass quality report

**Problem.** `rows.jsonl` and `mix cev.usage` expose cost and outcomes, but
nothing aggregates the quality funnel per pass: rows → classify decisions →
novelty/equiv outcomes → gate accept/reject reasons → committed rules → (later)
bugfixes of those rules. The gate-census CSV shows the project's style is
empirical; the loop deserves the same instrumentation.

**Proposal.** `mix cev.report`: one table per pass from `rows.jsonl` +
`decisions.md` + outcome dirs — decision histogram, reject-reason histogram,
cost per committed rule, NO_ACTION rate, duplicate rate (once H7 lands),
time-to-rule. Cheap to build (all inputs exist), and it turns "is pass 7 still
worth running?" into a look at a table instead of a feeling.

---

## Tier 5 — smaller correctness and hygiene items

### H12. Make the `APPLIED_RULES` hand-off a real contract
The classifier's entire input rides on a `Logger.debug` line surviving into the
row log (`validator.ex:333` → RowLog handler at `:debug`, `row_log.ex:121`).
Raising the log level would silently sever rule-gen from validation. Write the
applied-rules trace (and the fix before/after diff) to a dedicated sidecar file
(`logs/<idx>.applied_rules`) from the validator itself; keep the log line for
humans. Distill reads the sidecar first, falls back to the log.

### H13. Fix the dead `:claude_code` preflight branch
`preflight.check_secrets!` tests `implement_driver == :claude_code`
(`preflight.ex:99`) but the config produces `:cc` — so the CC auth token is never
validated by the secrets check (masked today by `cc_smoke!` raising later).
One-line fix; add a regression test.

### H14. Surface push failures
`git.ex:61-71` warns and continues when the `evolution` push fails; commits can
strand locally with only boot-time reconciliation as catch-up. Count consecutive
push failures and trip the existing breaker (or at minimum a distinct row-log
outcome + a `cev.report` column), so a broken remote doesn't silently turn a
24/7 run into a local-only run.

### H15. Delete the dead Python-translation code
`parser.ex` still ships `parse_translate`, `parse_full`, `elixir_name`,
`snake_name`, `fix_is_prefix` (+ their tests), with zero callers — DESIGN §9
said to drop them. Also sweep the stale "Translate" mentions in `llm.ex`,
`budget.ex` (including the `:translate` stage atom), and `config.exs` comments.
Pure maintenance drag now; a trap for future readers.

### H16. Align the Solve system prompt with the workspace deps
The system prompt's "Use only the OTP standard library unless the problem says
otherwise" fights the five census-driven workspace deps that rescue 25 tasks —
on the blind attempt the model can't know jason/plug/ecto/stream_data/nimble_csv
are available. Name them as available-when-needed in the system prompt (this does
not anchor style, unlike revealing the harness). Keep everything else about
ADR-0005 as is.

### H17. Unit-test the untested spine modules
Beyond the Gate (H5): `validator.ex` (6-step ordering, revert-on-broken-fix,
timeout routing), `novelty.ex`/`distill.ex`/`applied_rules.ex`/`rule_paths.ex`
(pure parsers — cheap tests), `seed.ex` (section presence per mode), `git.ex`,
`preflight.ex` (the checks are individually stubable). The spine is what decides
what lands in credence; it deserves the same rigor credence's own meta-gates
apply to rules.

---

## Explicitly not proposed

- **Persona schedules / manufactured feedstock** — declined in DESIGN §11 for
  authenticity; nothing here changes that calculus.
- **Replacing Mimo or the single-stream architecture** — ADR-0004's cost
  rationale stands; H10/H11 give the data to revisit later.
- **Trusting LLM self-review as a gate** — the external-oracle principle the
  pipeline already embodies is correct and confirmed by the literature; every
  proposal above adds *deterministic* oracles or feeds *measured* evidence back
  into prompts, never model self-approval.

## Suggested sequencing

| Order | Items | Rationale |
|---|---|---|
| 1 | H1.1, H4, H13, H12 | Days of work, immediate precision gains, no new infra |
| 2 | H2, H1.2, H5 | The executable oracle — biggest single quality upgrade |
| 3 | H7, H8, H9 | Dedup + memory + lens hygiene; cuts waste and churn |
| 4 | H6, H3 (`C2`) | Self-repair on corpus rejects; wider equiv reach |
| 5 | H10, H11, H14–H17 | Instrumentation + hygiene, continuous thereafter |

---

## Addendum (2026-07-11): measurements adopted from `elixir-sft-dataset`

The sibling dataset repo's 2026-07 QA campaign (its `docs/10`–`12` +
`STATUS.md`) hardened a generation loop with the same architecture as this
one — LLM authors artifacts, deterministic gates accept them. Its
battle-tested additions map onto the rule-gen spine directly. Two new
proposals and three amendments.

### H18. Spec-entailment judge on the implementer's tests

**The problem.** H2 attacks the self-graded-exam hole from the execution
side; this attacks it from the specification side. The implementing agent
writes the rule *and* its tests under "make the tests green" pressure — so a
test can drift toward what the implementation happens to do rather than what
the classify spec demanded. Nothing today compares the landed tests against
the spec.

**The transferable mechanism** (dataset `docs/12` §5.2.2, their entailment
judge on repaired accepts): one LLM call per built rule, before the Gate —
*"for each assertion in these test files, quote the element of the classify
spec (before / after / rationale) that entails it — or say NONE."* Assertions
with no entailment are either enrichment (fine, flagged) or drift (the agent
bent a fixture/expectation toward its own bug — reject or re-seed). The
dataset uses the same judge shape to verify harness assertions trace to
prompt sentences (their S7). Cheap (one call), and it catches exactly the
failure the equivalence battery can miss when the agent also chose the
battery dimension.

### H19. Flake-aware Gate + stability confirmation

**The problem.** The Gate runs credence's full suite per candidate; the suite
grows with every accepted rule. One flaky test — async timing, port cleanup —
now (a) rejects an unrelated good rule as `:full_suite_red`, and (b) keeps
poisoning **every subsequent candidate** until a human notices. And a flaky
test in the *candidate's own* files has one chance to look green before it
lands and becomes everyone else's problem. The dataset hit both failure modes
and built: a **flake ledger** (`logs/flaky.jsonl` with failing test + message,
nightly stability sweep, "fix only on flake-ledger evidence") and a
**stability confirmation** re-grade of every accept (`docs/12` §5.1.6).

**Applied here:**
- On a non-corpus `:full_suite_red`, re-run just the failing files once. A
  failure that does not reproduce *and* lies outside the staged diff → append
  to a flake ledger (`var/run/flaky.jsonl`), proceed with the Gate; a
  reproducing failure stays a hard reject. The ledger becomes the maintainer's
  fix list for the clone's suite.
- Before commit, re-run the candidate's focused tests once more (optionally
  under a different ExUnit seed). Red on the confirmation run → treat as
  `tests_red`, not accept. One extra ~seconds-scale run per accepted rule buys
  factory stability for every rule after it.

### Amendments

- **H10 (birth certificates)** — also record **which gates were active and in
  what mode** (mutation variant, equiv verdict source, corpus snapshot SHA,
  standard version once `C17`'s versioned standard exists). The dataset's S12
  finding is the cautionary tale: their ledger hardcoded `mutant_failed: true`
  at two mint sites where no mutant ever ran — provenance that lies is worse
  than none. Record what actually executed.
- **H5 (Gate tests)** — include **positive controls**: fixture bad-rules that
  each contract part must reject (out-of-scope file, assertion-free test,
  pure deletion, over-firing matcher), run in this repo's CI. The dataset
  proved its per-function mutation sweep non-vacuous by planting a survivor
  and asserting it was flagged; every Gate check deserves the same "seen red
  at least once, on purpose" treatment.
- **H11 (per-pass report)** — add near-free **difficulty metadata** the
  ledgers already contain (their §5.3.5): solve attempts-to-green and blind
  first-attempt outcome per task, joined against rule yield. This tells you
  which difficulty band actually produces committed rules, which is the datum
  the temperature schedule is currently tuned without.

**Explicitly not adopted:** the dataset's benchmark-decontamination gate
(S11) has no analog here (rules are not training data), and its
prompt-register-diversity concern is out of scope for rule generation —
feedstock diversity is already handled by the temperature schedule and
declined-persona decision (DESIGN §11).

---

## Addendum (2026-07-11): Gate latency — the corpus scan

A measured investigation of why the Gate's corpus phase costs ~8 minutes per
candidate, with fixes, lives in
[`credence/docs/13-test-suite-performance.md`](../../credence/docs/13-test-suite-performance.md).
Summary of the harness-relevant results: the corpus suite runs three
full-corpus sweeps serially-within-module on a machine with ~13× measured
parallel headroom; a single-rule corpus scan costs ~8 ms/file vs ~53 ms/file
for all 146 rules; and corpus layers are Pattern-only. The harness-side
consequences (all sound, dispatch-by-staged-paths):

- **Phase 2 should be `mix test --only corpus`**, not the full `mix test` — the
  Gate currently re-pays the 13 s corpus-free suite it just ran (one-line
  change in `evolve/gate.ex`).
- **Syntax/Semantic-only candidates skip the corpus phase entirely** (they
  cannot change Pattern findings).
- **Single-rule candidates get a rule-scoped scan** (`docs/13` P3): seconds
  instead of minutes; full scan remains the authority whenever the diff
  touches shared code.

End state: Gate deterministic cost per candidate drops from ~8.5 min to
~20–40 s, which also makes the per-candidate oracles proposed above (H1.2
gold scan, H2 executable fix-safety) affordable.
