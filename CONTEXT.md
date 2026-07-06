# Credence Evolution Harness

A 24/7, human-free OTP loop (`:cev`) that feeds native-Elixir coding tasks to a
local model, validates the output with **Credence**, and drives an agent to
write or fix Credence rules. It is a fork of `opc-sft-stage2-elixir` ("Tunex")
with the Python-translation data source replaced by a direct read of the
`elixir-sft-dataset` tasks. The product is **Credence rules**, not a dataset.

## Language

### Data source

**Task**:
One unit of work read from `elixir-sft-dataset/tasks/<name>/`: a `prompt.md`, a
`solution.ex`, and a `test_harness.exs`. The harness processes the 230 tasks
whose dir name starts with `0` and ends with `01`.
_Avoid_: row, problem, example, exercise.

**Prompt**:
The natural-language Elixir coding request in `prompt.md` — already Elixir, so
no translation. Fed verbatim to the local model.
_Avoid_: instruction, spec, question.

**Test harness**:
The `test_harness.exs` ExUnit module that decides whether a solution is correct.
It references the target module by its real bare name (e.g. `RateLimiter`), so it
also pins the name the model must produce.
_Avoid_: tests, spec.

**Reference solution**:
The hand-written idiomatic `solution.ex` — _gold_ Elixir, a capability Tunex never
had. Read-only: consumed by the [[sanity-gate]] and as [[gold-contrast]] in
Classify; never shown to Solve.
_Avoid_: answer, gold, model solution.

**Sanity gate**:
A one-time, cached check that a Task's Reference solution passes its own Test
harness (fix-free lenient compile + test, retried once before blacklisting).
Fail twice = the Task is blacklisted and skipped every Pass; verdicts are keyed
by content hash and survive resets.
_Avoid_: round-trip, pre-check.

**Pass**:
One full sweep over all 230 Tasks, in a Pass-seeded shuffled order and at that
Pass's scheduled solve temperature. The harness runs Passes back-to-back until
killed; each re-Pass yields fresh [[feedstock]] because Solve is non-deterministic
and the operating point changes.
_Avoid_: run, iteration, epoch.

### The loop

**Solve**:
The stage where the local model writes an Elixir module to satisfy a Task. The
first try is a [[blind-attempt]]; retries see the [[test-harness]] plus the
failures.
_Avoid_: generate, answer.

**Blind attempt**:
Solve's first attempt, which sees only the Task's [[prompt]] — never the
idiomatic Test harness — so the model writes unanchored, maximally clumsy code.
_Avoid_: cold attempt, zero-shot.

**Feedstock**:
Correct-but-clumsy model-generated Elixir. Its non-idiomatic shape is the signal
for where Credence is missing a rule. It is disposable — never emitted or trained.
_Avoid_: output, solution, dataset.

**Validate**:
The six-step workspace pipeline run on a solution: Credence-fix → compile →
format → credo → Credence-check → test. A solution passes when the failure list
is empty.
_Avoid_: check, grade, score.

**Rule-gen**:
The whole post-Validate track (the `Router` spine) that decides whether a Task
surfaced a rule opportunity and, if so, builds it. Decoupled from Solve's result.
_Avoid_: learn, evolve step.

**Classify**:
The LLM triage inside Rule-gen. Emits one of `NO_ACTION`, `BUGFIX_RULE`,
`POTENTIAL_NEW_RULE`, `SWITCH_PROPOSAL`. Its prompt includes the [[gold-contrast]].

**Gold contrast**:
The fenced copy of the Task's Reference solution injected into the Classify
prompt so the classifier judges generalizable anti-patterns against real
idiomatic code — guardrailed against proposing rules that merely encode the
reference author's taste.
_Avoid_: reference injection, exemplar.

**Gate**:
The token-free trust boundary that decides commit vs reject for a proposed rule:
a 5-part git-diff contract + a mutation check + the full Credence suite (incl.
the [[corpus]]). The agent's self-report never decides — the Gate does.
_Avoid_: validation, review.

### Credence

**Credence**:
The standalone AST semantic linter being evolved (`../credence`, app `:credence`).
Three phases — Syntax, Semantic, Pattern — auto-discovered by `@behaviour`. Not a
loaded dependency; reached only by shelling `mix` in its clone.
_Avoid_: linter, credo, the tool.

**Rule**:
One Credence check/fix module at `lib/<phase>/<snake_name>.ex` in the clone, with
paired tests at `test/<phase>/<snake_name>*_test.exs`. Pattern rules take Sourceror
AST and emit byte-range patches; Syntax rules take and return raw source string.
_Avoid_: check, lint.

**Phase**:
One of `syntax` (pre-parse string fixes), `semantic` (compiler-warning fixes),
`pattern` (AST anti-pattern rewrites, the bulk).

**Assumption** (safety switch):
A checkable promise about running data that a Rule's fix needs to be safe (e.g.
`proper_lists`). A Rule fires only when all its declared Assumptions are on.
_Avoid_: flag, option.

**Over-fire**:
A Rule rewriting code that was already correct/idiomatic — a bug. Caught reactively
by the [[corpus]] ratchet and (v2) proactively by the deferred over-fire oracle.

**Corpus**:
~500 real, reviewed Elixir projects Credence lints as a regression ratchet
(`test/corpus/accepted_findings.txt`). A new finding = a new rule Over-fires on
real idiomatic code → drop it.

**Evolution branch**:
The `evolution` branch of the `../credence` clone that accepted Rules are committed
and pushed to; a human PRs `evolution` → `main`.

**APPLIED_RULES**:
The trace line the workspace's `run_credence_fix.exs` prints —
`[{RuleModule, count | :reverted}]`. The literal input signal [[rule-gen]] reads
to find `:reverted` culprits and Over-fires.
