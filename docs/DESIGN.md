# Credence Evolution Harness — Design

**App:** `:cev` · **Status:** design (rev 3 — deep scrutiny + pre-code empirical gate census) · **Date:** 2026-07-06

A 24/7, human-free OTP loop that feeds native-Elixir coding tasks to a local
model, validates the output with **Credence**, and drives an agent to write or
fix Credence rules. It is a fork of [`opc-sft-stage2-elixir`](../../opc-sft-stage2-elixir)
("Tunex") with one structural change — the Python-translation data source is
replaced by a direct read of the [`elixir-sft-dataset`](../../elixir-sft-dataset)
tasks — plus a small set of deliberate divergences designed to stress the models
harder (§11).

> **Primary goal (read first).** Generate and validate/improve **as many Credence
> rules as possible.** Running the dataset is *not* the goal — it is a workload
> that surfaces where Credence is weak. Solve output is disposable feedstock: it
> is never emitted, never trained on, and the local model is never scored. Every
> design choice is judged by "does this yield more/better rules?" and "is this the
> simplest thing that works?" This is identical to Tunex's goal.

---

## 1. The ecosystem

Four sibling repos under `/home/kamil/projects/`:

| Repo | Role |
|---|---|
| **`elixir-sft-dataset`** | Supplies native-Elixir **Tasks** (`prompt.md` + `solution.ex` + `test_harness.exs`). Our new data source. |
| **`credence`** | The AST semantic linter we **evolve**. Rules committed to its `evolution` branch. App `:credence` v0.8.1. |
| **`opc-sft-stage2-elixir` (Tunex)** | The upstream we fork. Authoritative reference for every copied module (`docs/01`–`12`). |
| **`credence-evolution-harness`** | **This repo.** App `:cev` — the loop orchestrator. |

Nothing about Credence changes: it stays a separate project reached only by
shelling `mix` inside the clone at `../credence` (never a loaded dependency).

---

## 2. What changes vs Tunex — the whole delta

Tunex's per-row loop is: **translate** (Python→Elixir via Mimo) → **round-trip**
(discard mistranslations) → **solve** (local model, Python-blind) → **validate**
(Credence) → **rule-gen** (classifier-split spine) → **gate** → **push**.

Our dataset already ships Elixir, so the translation stages have nothing to do:

| Tunex stage | Fate | Reason |
|---|---|---|
| **Translate** | **Deleted** | Dataset is already Elixir; no Python exists anywhere. |
| **Round-trip** | **Reborn as a one-time Sanity gate** | Mistranslations can't exist, but broken dataset entries can — and under continuous re-pass a broken entry would burn tokens *every pass, forever* and pollute the failed-lens signal. The fix-free runner survives, run **once per task ever** (`solution.ex` vs `test_harness.exs`). See [ADR-0006](adr/0006-one-time-sanity-gate.md). |
| **Cache / blacklist** | **Slimmed to a task-verdict store** | Translation payloads are gone; a tiny `var/cache/task_verdicts.jsonl` keeps the once-ever sanity verdicts (survives resets, like Tunex's cache). |
| **Solve** | **Kept, prompt reshaped** | Still need clumsy model output as rule feedstock — attempt 1 is now *blind* (§5). |
| **Validate** | **Kept, identical** | The Credence-fix→compile→format→credo→credence→test pipeline. |
| **Rule-gen (Router spine)** | **Kept; Classify prompt gains gold contrast** | The whole point (§7). |
| **Gate → Git** | **Kept, identical** | 5-part contract → push `evolution`. |

Everything from Validate onward is structurally unchanged; §11 lists every
deliberate behavioural divergence.

**On feedstock character:** Tunex's clumsiness came partly from translationese.
Ours comes from the model's own habits — but our hand-written test harnesses are
*idiomatic*, so showing them to the model would anchor it toward clean code and
suppress exactly the clumsiness that is the product. The blind first attempt (§5)
exists to protect the feedstock.

---

## 3. The loop, per task

```
pick Task ── prompt.md + test_harness.exs + solution.ex
  │
  ├─► Sanity gate  (first encounter only; verdict cached forever, hash-keyed)
  │              solution.ex vs test_harness.exs, fix-free (lenient compile + test; retry once)
  │              fail twice → :blacklist in var/cache/task_verdicts.jsonl → task skipped every pass
  │
  ├─► Solve      local model; temperature = solve_params_schedule[pass]
  │              attempt 1 = prompt.md ONLY (blind — unanchored, max-clumsiness feedstock)
  │              attempt 2+ = prompt.md + test_harness.exs + previous attempt + validator errors
  │              validate each attempt; retry ≤ max_retries (3)
  │              → {:ok, clumsy_elixir} | {:failed, …}   (emits nothing either way)
  │
  ├─► Validate   in the workspace, against Credence (path dep):
  │              1. credence fix  (mix run --no-compile run_credence_fix.exs)
  │              2. compile       (mix compile --warnings-as-errors --force)
  │              3. format        (mix format — auto-fix, never fails)
  │              4. credo         (mix credo list --strict … lib/solution.ex)
  │              5. credence check(mix run run_credence.exs → Credence.analyze)
  │              6. test          (mix test … test/solution_test.exs)  ← +wall-clock timeout
  │              PASS = failure list empty. Emits APPLIED_RULES trace into the row log.
  │
  ├─► Rule-gen   Router reads the row log's APPLIED_RULES:
  │              :reverted culprit ─► implementer BUGFIX (rule broke compile), skip classify
  │              else CLASSIFY (Mimo; prompt includes the task's solution.ex as fenced
  │                             GOLD_REFERENCE contrast — §7) ─►
  │                 NO_ACTION           → no_action/
  │                 SWITCH_PROPOSAL     → switch_proposals/ (record, no build)
  │                 BUGFIX_RULE         → implementer bugfix ─► Gate
  │                 POTENTIAL_NEW_RULE  → Novelty (covers?) ─►
  │                        COVERED → duplicate/
  │                        NOVEL   → Equiv trichotomy ─►
  │                              DIVERGES              → behaviour_diverged/
  │                              REPAIR | EQUIVALENT   → scaffold (gen.rule) ─► Implement ─► Gate
  │
  ├─► Gate       token-free: git add -A; (b) touches lib/ (c) touches test/
  │              (e) scope lib/+test/ only + pure-deletion guard;
  │              (d) mutation check (revert lib to HEAD, changed test must go RED, restore);
  │              (a) full suite: mix test --exclude corpus (~15s) then full mix test (~8min, corpus)
  │              pass ─► Git commit → recompile credence → push evolution ; log → committed/
  │              reject ─► reset --hard + clean ; corpus reject preserved ; log → escalated/
  │
  └─► mark done (pass-scoped) ; next Task ; on exhaustion ─► new Pass
                                            (new shuffle order, next scheduled temperature)
```

There is **no SFT emission** (goal is rules only): Tunex's `elixir_sft_*.jsonl`
success/error appends are dropped. `rows.jsonl` (per-task stats: outcome, timing,
temperature, cost) is kept for observability.

---

## 4. The data source — `TaskSource` (replaces `Dataset`)

### Task format (verified)

Each `elixir-sft-dataset/tasks/<name>/` contains exactly three files:

- **`prompt.md`** — the NL Elixir request. Names the target module ("Write me an
  Elixir GenServer module called `RateLimiter` …") and the required public API.
  Verified across all 230 tasks: **230/230 name the module; 226/230 spell out the
  full API (functions + return shapes) in prose** — which is what makes the blind
  first attempt (§5) viable.
- **`solution.ex`** — a hand-written idiomatic reference (`defmodule RateLimiter …`).
  **Read-only in v1**: consumed by the Sanity gate and as fenced contrast in the
  Classify prompt. **Never shown to Solve.**
- **`test_harness.exs`** — an ExUnit module (`defmodule RateLimiterTest do use
  ExUnit.Case …`) that calls the target module by its real bare name. 29/230 assert
  on implementation internals (`:sys.get_state`); 48/230 use `Process.sleep`
  (worst-case total sleep per harness: 6s).

### Selection

The operator's slice is **dir name starts with `0` and ends with `01`** → **230
tasks** (the first variant of each numbered `0xx` problem family). Verified
distribution of the 3272 task dirs: prefixes `0`(848) `1`(149) `6`(4) `t`(1997)
`w`(274); suffixes span `_01`…`_10+`. So the `0*01` glob deliberately excludes the
`t…`/`w…` families and all `_02+` variants. The glob (`task_root` + pattern) is a
config knob — widening to more variants or families is a one-line change.

### `TaskSource` interface

A small new module replacing `dataset.ex`:

- `list/0` → sorted `[%{name, path}]` for all dirs matching the glob under `task_root`.
- `load/1` → `%{name, prompt, test, reference}` reading all three files
  (`reference` feeds only the Sanity gate + Classify contrast — never Solve).
- `count/0`.

No parquet, no HTTP, no `Explorer` dependency, no download step. This is the entire
"data source" simplification the project is named for.

### The Sanity gate (`SanityGate`)

On a task's **first encounter ever**: write `solution.ex` + `test_harness.exs` into
the workspace and run a fix-free check adapted from Tunex's round-trip runner —
**`mix compile --force` (lenient — NO `--warnings-as-errors`) + `mix test`**, no
Credence/credo/format, so the verdict is a pure function of the dataset entry,
immune to the evolving ruleset. Three hardenings over the naive version, all
empirically motivated (census below):

- **Lenient compile.** Strict compile falsely blacklists 9 good tasks (tests all
  pass) whose gold code merely *warns* under Elixir 1.20 — version drift, not
  breakage. The strict bar stays on **model** output in Validate (§6), where
  Credence-fix repairs warnings first.
- **Retry-once before blacklist.** 48/230 harnesses are timing-sensitive; the
  census caught `013_003` failing once and passing on rerun. Only a double
  failure blacklists.
- **Content-hash verdict keys.** Each verdict records
  `sha256(solution.ex + test_harness.exs)`; a hash mismatch on lookup = treat as
  never-checked. Upstream dataset fixes auto-un-blacklist; upstream breaks get
  caught.

Pass → `verdict: :ok`; double-fail → `verdict: :blacklist` and the task is skipped
in every pass. Verdicts live in `var/cache/task_verdicts.jsonl` and **survive
`mix cev.reset`** (a dataset entry doesn't get less broken on a fresh run). ~100
lines salvaged from Tunex's `round_trip.ex` + `cache.ex`. See
[ADR-0006](adr/0006-one-time-sanity-gate.md).

### Pre-code empirical census (2026-07-06)

Before any harness code was written, all 230 tasks were swept through a prototype
of exactly this gate (scratch Mix project, Elixir 1.20.2/OTP 29, workspace deps
below). Whole-corpus gate cost: **~6 minutes, one-time**. Result:

| Verdict | Count | Breakdown |
|---|---|---|
| **Usable** | **215 (93.5%)** | 199 pass outright · 9 rescued by lenient compile (Elixir-1.20 warning drift, tests pass) · 6 rescued by `stream_data`/`nimble_csv` deps · 1 flaky rescued by retry-once (`013_003`) |
| **Blacklisted** | **15 (6.5%)** | 10 multi-file `<file path=…>` bundles (not single-file Elixir at all) · 4 DB-requiring (harness spins up an `Ecto.Repo` + SQLite/PG adapter) · 1 deterministically broken harness (`072_004`) |

Every blacklist is a genuine structural defect — none is a false positive. The
census drove the workspace dep list: the generated workspace's `mix.exs` includes
**`jason`, `plug`, `ecto`, `stream_data`, `nimble_csv`** (all pure-Elixir, no
external services) alongside `credo` + the `credence` path dep — rescuing 25
tasks vs a bare workspace. Model solutions may use these libs when a task calls
for them.

---

## 5. Solve (reshaped, not rewritten)

`Pipeline.Solve` keeps its structure — single-shot generation, `Validator.run`
each attempt, failures fed into a retry prompt, `≤ max_retries` — with four edits:

1. **Blind first attempt** ([ADR-0005](adr/0005-blind-first-solve-attempt.md)).
   The hand-written harness is *idiomatic* Elixir; a model that sees it cribs its
   idioms, suppressing the clumsiness that is the product. So:

   | Attempt | Prompt contains |
   |---|---|
   | 1 (blind) | `prompt.md` only |
   | 2+ | `prompt.md` + **full `test_harness.exs`** + previous attempt + validator errors |

   The row log captures *both*: the unanchored attempt-1 code with its full
   Credence fix trace (feedstock), and — via harness-guided retries — a passing
   final solution ("passing + non-idiomatic" is the gold rule-gen signal). Viable
   because 230/230 prompts name the module and 226/230 fully spec the API; the
   29 internals-asserting harnesses converge once revealed on attempt 2.
2. **Per-pass temperature** — `solve_params_schedule` (§8) is merged into the LLM
   call params; the active temperature is logged per row for provenance.
3. **Retry budget `max_retries: 3`** (Tunex: 5). Tunex's 5 was sized for when a
   passing solve had product value (an SFT record); with emission gone, retries
   exist only for signal — 1 blind attempt (feedstock) + 2 harness-guided shots
   (convergence to the stronger `:solved` classify lens). Grinding a stubborn
   tail steals wall-clock from the next pass (fresh temperature, fresh
   feedstock). Pure config knob; raise it if `rows.jsonl` shows many tasks
   failing at exactly attempt 3.
4. **No Python.** Nothing to strip — the prompt is native Elixir. Tunex's
   "assert the prompt contains no `` ```python ``" guard is dropped as moot.

Canonical-naming machinery stays deleted: the model reads the module name from
`prompt.md` (attempt 1) or the harness (attempt 2+), and the compile/test loop
enforces it. Solve output is written to the workspace's fixed `lib/solution.ex`
regardless of the module's real name — Elixir compiles by module, not filename, so
a `defmodule RateLimiter` living in `lib/solution.ex` compiles and the harness
(copied to `test/solution_test.exs`) resolves it.

---

## 6. Validate (identical) — the six steps

Verbatim from Tunex's `Validator.run/3`. Runs in a single scratch Mix project
(`var/run/workspace`) that wires the Credence clone as a path dep
(`{:credence, path: "../credence", only: [:dev, :test], runtime: false}`) and `credo`
as a hex dep:

1. **Credence auto-fix — before compile.** `Credence.fix(code)` (Syntax→Semantic→
   Pattern) rewrites `lib/solution.ex`; prints `FIXED`/`NO_CHANGES` and the
   **`APPLIED_RULES: [{Module, count | :reverted}]`** trace. A fix is kept only if
   the result still compiles, else reverted.
2. **Compile** — `mix compile --warnings-as-errors --force`. Non-zero → `{:compile, …}`
   failure and the remaining steps are skipped. (Strict is right for *model*
   output — Credence-fix repairs warnings first, and a warning is retry signal.
   The one-time Sanity gate deliberately compiles lenient instead; §4.)
3. **Format** — `mix format` (silent auto-fix, never a failure).
4. **Credo** — `mix credo list --strict --format oneline lib/solution.ex`; issue
   lines mentioning the file → `{:credo, …}`.
5. **Credence check** — `mix run run_credence.exs` → `Credence.analyze`; exit 0 =
   `OK`, else `{:credence, …}`.
6. **Test** — `mix test test/solution_test.exs --no-deps-check`; exit 0 = pass, else
   `{:test, …}`. **Change:** wall-clock timeout, default 60s (verified safe: the
   worst harness sleeps 6s total). Timeout → failed attempt + route to `too_slow/`.

PASS = empty failure list. The `APPLIED_RULES` line and the before/after fix trace
land in the per-task row log — the literal input the Rule-gen stage consumes.

**Only other edit:** drop `propagate_is_renames` (a Python-translation artifact).

---

## 7. Rule-gen (near-identical) — how rules are created and fixed

This is the value of the fork and copies almost verbatim: the classifier-split
**Router** spine (Tunex `docs/07`/`08`), not the dormant single-agent
`CredenceRuleGenerator`.

**Credence rule anatomy** (in the clone, so the harness only orchestrates):
- Source `lib/<phase>/<snake>.ex`; tests `test/<phase>/<snake>*_test.exs`. Phases:
  `syntax` (raw-string pre-parse fixes), `semantic` (compiler-warning fixes),
  `pattern` (Sourceror-AST anti-pattern rewrites — the bulk). Current counts ≈
  pattern 150 / syntax 21 / semantic 18. Auto-discovered by `@behaviour`; no registry.
- Pattern rule callbacks: `check(ast, opts) → [Issue]`, `fix_patches(ast, opts) →
  [byte-range patch]`, `assumptions() → [atom]` (safety switches a fix needs),
  `unsafe_in_dsl()`, `priority()`.

**Fixing an existing rule** (`BUGFIX_RULE` / `:reverted`): `RulePaths.resolve`
greps `defmodule <Mod>` to find the rule's source + test glob; the implementer gets
the source + tests + the failing diagnostic. Two sub-shapes: `:broke_compile` (fix
produced non-compiling output → `:reverted`) and `:over_fire` (fired on good code).

**Creating a new rule** (`POTENTIAL_NEW_RULE`): after `Novelty` (`mix credence.covers`)
confirms it's not already covered and `Equiv` (`mix credence.equiv`) confirms the
before/after are behaviourally equivalent (or a REPAIR), `Implement.Naming` runs
`mix credence.gen.rule <Pascal> --type <phase>` to lay down intentionally-red stub +
test files, then `Implement.run` (driver `:cc` = Claude-Code→Mimo, or `:pi`/`:llm`)
fills them until `mix test test/<phase>/<rule>_test.exs` is green.

**Gold-contrast Classify (divergence).** The Classify prompt gains a fenced
`===GOLD_REFERENCE===` section containing the task's `solution.ex`, with an explicit
guardrail: *use it to judge whether the model output's shape is a generalizable
anti-pattern; do NOT propose rules that merely enforce this reference's stylistic
choices; the before/after you emit must generalize beyond this task.* The
Implement seed is **unchanged** — the classifier's before/after spec is already
task-independent, and adding gold context at the code-writing stage would raise the
taste-rule risk. Residual taste-rules are caught by Novelty/Equiv/Gate/corpus.

**The Gate decides — never the agent** (§3). On accept: commit to `evolution`,
`recompile_credence` so the enlarged ruleset validates the next task. The corpus
ratchet (`test/corpus/`, ~500 real projects) blocks any rule that over-fires on
real idiomatic code; corpus rejects are escalated with drop/accept instructions.

**Net feedback loop:** clumsy Elixir → Credence fix/analyze emits `APPLIED_RULES` +
issues into the row log → Router/Classify reads that trace (plus the gold contrast) →
Implement writes/repairs a rule in the clone → Gate (mutation + full suite + corpus) →
on accept, commit + recompile so the grown linter validates subsequent tasks.
Dead-ends go to `decisions.md` (inlined into every Classify prompt) so they aren't
re-attempted; committed rules auto-fix their pattern so it stops recurring
(emergent dedup).

---

## 8. Models & cost (Mimo kept)

| Stage | Model | Notes |
|---|---|---|
| **Solve** | local llama.cpp (setup value) | Free. A *weak* model is desirable — clumsy output = feedstock. Temperature cycled per pass via `solve_params_schedule` (default `[%{temperature: 0.6}, %{temperature: 0.9}, %{temperature: 1.2}]`), logged per row. Model rotation is operator-level (llama.cpp serves one model at a time) — swap the served model between runs for a different clumsiness fingerprint. Per-stage `CEV_SOLVE_PROVIDER` env override kept. |
| **Classify** | Mimo (`mimo-v2.5-pro`) via `LLM` chat | The only paid stages… |
| **Implement** | Mimo via Claude-Code `:cc` driver (`mimo-v2.5-pro[1m]`) | …"Claude Code" (harness) ≠ "Claude" (model). |

The whole Mimo cost/observability layer copies verbatim: `MimoConsole` (ground-truth
token-bucket meter behind the Xiaomi-Account cookie), token-bucket `Budget`,
`usage.jsonl`/`heartbeat.jsonl`/`diag.jsonl`, `mix cev.budget`/`cev.usage`/`cev.diag`.
Cost caveats carry over unchanged: the in-band ledger undercounts the bucket ~20–50×,
so `mix cev.budget` (the console) is the only ground truth; ignore Claude Code's
`total_cost_usd`. Translate is gone, so Mimo now bills **only** rule-gen. The Sanity
gate is token-free.

---

## 9. The copy / modify / delete / create map

The heart of "what can we just reuse?" — **~44 of 51 modules copy verbatim** (a
single `Tunex` → `Cev` namespace rename; `TUNEX_*` env → `CEV_*`).

### Copy verbatim (rename only)

| Group | Modules |
|---|---|
| **Rule-gen spine** | `evolve/{router,gate,corpus,git,ledger}`, `classify/{classify,parser,spec}`, `implement/{implement,seed,naming,output}`, `novelty`, `equiv`, `applied_rules`, `rule_index`, `rule_paths`, `switch_proposal`, `transient_attempts`, `markers`, `distill` |
| **Model / linter layer** | `llm`, `claude_code`, `pi`, `credence` (CLI wrapper), `mimo_console` |
| **Infra / observability** | `row_log`, `jsonl`, `budget`, `diag`, `report`, `application` |
| **Mix tasks** | `cev.{preflight,reset,usage,budget,diag,switch_proposals}` |

`evolve/credence_rule_generator` (dormant legacy agent) copies too — only `mix
cev.diag` uses it; keep for that.

### Modify

| Module | Change |
|---|---|
| `orchestrator` | Replace `RoundTrip.ensure` + `Dataset` + seeded-shuffle-over-parquet with `TaskSource` iteration + **continuous Pass loop**: per-pass shuffle (seed = pass number), per-pass solve params from the schedule, `SanityGate.ensure` skip. Drop translate/cache branches and SFT append. Keep solve → router → gate → mark-done. |
| `config` (+ `config.exs`) | Drop `translate` provider + `translate_ceiling` + `dataset_base`/`subset`. Add `task_root` + glob + `solve_params_schedule` + validator test timeout. Set `max_retries: 3` (§5). Solve provider defaults to a localhost OpenAI-compatible endpoint. Keep classify/implement=Mimo, Budget, credence_clone, git_identity. |
| `pipeline/solve` | Two-phase prompt: blind attempt 1 (`prompt.md` only), harness + failures on retries (§5). Merge scheduled params into the LLM call. Drop canonical-fn injection + Python guards. |
| `classify/prompt` | Add the fenced `===GOLD_REFERENCE===` contrast section + anti-taste-rule guardrail (§7). |
| `parser` | Keep `parse_module_test`, `strip_outer_fences`. Drop `parse_translate`, `parse_full`, `elixir_name`, `snake_name`, `fix_is_prefix`. |
| `validator` | Drop `propagate_is_renames`. **Add a wall-clock timeout on the test step** (60s default) → route to `too_slow/`. |
| `workspace` | Drop translate-specific bits. Keep `run_credence_fix.exs` / `run_credence.exs` script writers, `.credo.exs`, the credence path-dep block, `recompile_credence`. **Add five hex deps** to the generated workspace `mix.exs` — `jason`, `plug`, `ecto`, `stream_data`, `nimble_csv` (census-driven, §4: rescues 25 tasks). |
| `preflight` | Drop dataset download + translate smoke test. Add a `task_root` exists/non-empty check. Keep clone-on-`evolution` + clean-tree + Mimo + local-solve smoke checks. |
| `progress` | Pass-scoped: (pass number, done-index set) for crash-resume; reset per pass. |

### Delete

`pipeline/translate` (the only Python-aware module) · `dataset`. Drop the
`explorer` dep (parquet) from `mix.exs`; deps become `{:req, …}` + `{:jason, …}`.
`pipeline/round_trip` + `cache` are not copied wholesale — their slim cores (the
fix-free runner; the durable verdict store) are salvaged into `sanity_gate`.

### Create

- `task_source` (§4) — the filesystem task reader.
- `sanity_gate` (§4) — one-time cached reference-vs-harness check (~100 lines
  salvaged from `round_trip.ex` + `cache.ex`): lenient compile, retry-once
  before blacklist, content-hash-keyed verdicts.

---

## 10. Orchestrator & Progress — the continuous loop

```
boot: Preflight.run!() → load-or-init pass state → TaskSource.list()
loop over pass p:
  order  = shuffle(tasks, seed: p)                 # deterministic per pass, resumable
  params = solve_params_schedule[rem(p, length)]   # e.g. temperature 0.6 / 0.9 / 1.2
  for task in order, skipping done-in-this-pass:
    SanityGate.ensure(task) == :blacklist → skip + mark_done
    RowLog.open(task)
    Solve(params) → Router → (Gate → Git) → route log
    Progress.mark_done(pass, task) LAST
    per-task try/rescue: throw → log + git checkout/clean the clone + skip
  pass complete → p+1, clear done-set, continue
```

- **Single stream** (one local model, one clone, one workspace) — no concurrency,
  exactly as Tunex.
- **Crash-resume within a pass** via `Progress` (pass number + done-set); on
  restart, re-derive the same shuffle from the pass number and resume.
- **Circuit breaker & graceful shutdown** (`Budget` runaway ceiling, consecutive-
  transient-abort breaker → `Cev.shutdown` → `System.halt(1)`) copied verbatim.
- Started only under `CEV_RUN=1` so `mix test`/dev never trigger a paid run.

---

## 11. Deliberate divergences from Tunex (beyond the data source)

1. **Blind first solve attempt** ([ADR-0005](adr/0005-blind-first-solve-attempt.md)).
   Tunex's initial solve prompt included the tests; ours withholds the (idiomatic,
   hand-written) harness until attempt 2 to protect feedstock clumsiness.
2. **Per-pass solve temperature schedule.** Each pass runs the model at a different
   operating point (confident habits → default variance → unstable tail), so
   re-passes surface different clumsiness instead of resampling the same modes.
3. **Gold-contrast Classify prompt** (§7). The classifier judges against the task's
   idiomatic `solution.ex`, fenced and guardrailed against taste-rules.
4. **One-time Sanity gate** ([ADR-0006](adr/0006-one-time-sanity-gate.md)).
   Revises ADR-0002's "no gate" under continuous-loop economics.
5. **Per-pass task-order shuffle** (seed = pass number). The ruleset evolves
   mid-pass, so fixed order would always give late tasks the richer ruleset;
   shuffling rotates which tasks meet which ruleset.
6. **Validator test-step timeout** (60s, configurable). Tunex has *no* timeout on
   the eval shell commands, so an infinite-loop solution blocks a row forever —
   unacceptable for unattended re-passing. Timeout → `too_slow/`, failed attempt.
7. **Continuous re-pass** over the finite corpus ([ADR-0003](adr/0003-continuous-repass-over-finite-corpus.md)).
8. **No SFT emission** — the dataset is pure workload; success/error JSONL appends
   are dropped.
9. **Retry budget 3** (Tunex: 5) — retries exist only for signal once emission is
   gone; pass cadence beats tail-grinding (§5).
10. **Curated workspace deps + lenient gate compile** — empirically driven (§4
    census): 5 pure-Elixir hex deps rescue 25 tasks; lenient compile rescues 9
    version-drift golds. Model-output validation stays strict.
11. **Gate retry-once + content-hash verdict keys** — the census caught a real
    flaky harness (`013_003`) that a one-shot gate would have silently lost.

**Considered and declined (recorded so it isn't re-proposed blindly):**
- *Dry-task triage* (skip Classify for tasks NO_ACTION K passes running — Tunex's
  planned "62% no_opportunity" burn cut): declined for v1; maximum signal preferred
  over token savings. Natural v2 lever if re-pass Classify spend becomes the bottleneck.
- *Cut Implement `max_turns` 80→40*: upstream measured the burn but never validated
  the cut; keep 80 verbatim and revisit with our own `usage.jsonl` data.
- *Persona schedule for Solve* (cycling system prompts: Python-dev / JS-dev /
  "just make it pass" to regenerate translationese feedstock): declined — feedstock
  should be the model's *authentic* output; no manufactured patterns. Diversity
  comes from the temperature schedule only.
- *Console-polling token circuit breaker* (upstream's planned-but-unbuilt fix for
  the wrong-unit `runaway_ceiling_usd` fed by a 20–50×-undercounting ledger):
  declined — Tunex parity. **Known accepted gap:** the only runaway backstop is the
  fuzzy USD ceiling; watch `mix cev.budget` manually during long runs.

---

## 12. Future enhancements (documented, not built)

- **Over-fire oracle (highest-value).** The dataset's `solution.ex` is *gold*
  idiomatic Elixir — something Tunex never had. Run `Credence.fix(solution.ex)` per
  task: if Credence rewrites known-good code, that rewrite is an **over-fire = a rule
  bug**, routable straight to the `BUGFIX_RULE` lane. Today over-firing is caught
  reactively (corpus ratchet, broken solve tests); the oracle catches it proactively
  and cheaply. Deferred: a new deterministic stage, best added once the base loop is
  proven. (The gold reference already flows into Classify as contrast — §7 — so v1
  gets part of this value.)
- **Widen the task glob** beyond `0*01` (more `_02+` variants, the `t…`/`w…`
  families) for breadth once the base loop is proven — potentially auto-widening
  after a dry pass.
- **Dry-task triage** — see §11 "declined".

---

## 13. Open setup values (not design)

- **Mimo:** a `tp-` token (chat + Claude-Code auth) + the console cookie, in
  `config/secrets.exs` (gitignored). Required for Classify + Implement + `mix cev.budget`.
- **Local model:** the URL + model name for Solve (llama.cpp / the
  `elixir-predictive-tokens` stack); reconcile the port (Tunex config used 8080 vs a
  README saying 8000).
- **Credence clone:** `../credence` present, on branch **`evolution`** (reused,
  configurable), clean tree, commit identity a GitHub noreply email (a real email →
  silent `GH007` push failure), remote pre-authenticated.
- **`task_root`:** path to `elixir-sft-dataset/tasks` + the `0*01` glob.
- **CLIs:** `claude` on `PATH` (present, v2.1.201); `pi` only if `implement_driver: :pi`.

---

## 14. Build plan (milestones)

Mirrors Tunex's vertical-slice strategy, minus the deleted stages.

- **M0 — Skeleton.** New `mix.exs` (`:cev`, `mod: {Cev.Application, []}`, deps
  `req` + `jason`). Copy the verbatim modules under `lib/cev/` with the namespace
  rename. `.gitignore` (`/var/`, `secrets.exs`, `_build`, `deps`).
- **M1 — Config + TaskSource + SanityGate.** `config.exs` per §9; `Cev.TaskSource`;
  `Cev.SanityGate` (lenient compile, retry-once, hash keys) + `task_verdicts.jsonl`;
  `mix cev.reset` (must NOT wipe the verdict store).
- **M2 — Workspace + Validate.** Copy `workspace` + `validator` (edits per §9,
  incl. the test timeout and the five census-driven workspace deps); path-dep the
  clone; confirm the 6-step pipeline + `APPLIED_RULES` land in a row log.
- **M3 — Solve.** `Pipeline.Solve` two-phase prompt (§5); scheduled params merged
  into the LLM call; the validate/retry loop.
- **M4 — Rule-gen spine.** Copy `evolve/*` + `classify/*` + `implement/*` + support
  verbatim; add the gold-contrast section to `classify/prompt`; wire `Router.run`
  after Solve.
- **M5 — Orchestrator + Budget.** Continuous-Pass orchestrator (§10: shuffle,
  schedule, sanity skip); copy `Budget` + `Preflight` (edits per §9);
  `CEV_RUN=1 mix run --no-halt`.

---

## 15. Verification checklist

1. `Cev.TaskSource.list()` returns 230 tasks; `load/1` yields
   `%{name, prompt, test, reference}`.
2. **Sanity gate:** a task with a deliberately broken harness is blacklisted on
   first encounter (after one retry), skipped on every later pass *without*
   re-running the check; the verdict survives `mix cev.reset`; editing the task's
   files invalidates the verdict (hash mismatch → re-check). Expected census on
   the untouched dataset: **215 usable / 15 blacklisted** (10 bundles, 4 DB,
   1 broken — §4); the flaky `013_003` must land usable via retry-once.
3. **Blind solve:** the attempt-1 prompt contains `prompt.md` and NOT the harness
   source; the attempt-2 prompt contains the full harness; a solve for
   `001_001_rate_limiter_01` produces a `RateLimiter` module that compiles against
   the harness.
4. **Validate:** the 6-step pipeline runs; `APPLIED_RULES` + before/after trace appear
   in `var/run/logs/<name>.log`; a clean idiomatic solution passes with an empty
   failure list.
5. **Test timeout:** a solution with an infinite loop is killed at the timeout and
   routed to `too_slow/` (60s default is safe — max legitimate harness sleep is 6s).
6. **Temperature schedule:** `rows.jsonl` records each row's temperature; pass N+1
   uses the next schedule entry; the cycle wraps.
7. **Rule-gen every task + gold contrast:** a clean, passing, non-idiomatic solution
   (zero issues) still invokes Classify; the Classify prompt contains the fenced
   `===GOLD_REFERENCE===` section with the task's `solution.ex`.
8. **Create / bugfix:** a novel idiom → new rule + regression test through the Gate;
   an over-firing rule → bugfixed with a locking test.
9. **Gate:** rejects (no new test / non-RED mutation / out-of-scope diff / standalone
   pure deletion); allows a rename (delete+add). Pass → commit → recompile → push
   `evolution`; corpus reject → `escalated/` + `.patch` + `.corpus.md`.
10. **Continuous pass + shuffle:** exhausting all 230 tasks rolls into pass N+1 with
    a different (deterministic, pass-seeded) order without operator action; kill
    mid-pass → restart resumes the same pass, same order, skipping done tasks.
11. **Emergent dedup:** a committed rule's pattern stops recurring in later passes; a
    `decisions.md` dead-end isn't re-attempted.
12. **Cost:** `mix cev.budget` reads the Mimo console; Solve on the local model is free;
    Claude Code `total_cost_usd` ignored.
13. **Credence green:** `cd ../credence && mix test` green before and after a run.

---

*Every copied module's fine-grained behaviour is documented upstream in
`opc-sft-stage2-elixir/docs/01_plan.md` (the base design) and `07`/`08` (the
classifier-split rule-gen spine this fork inherits). This document records only the
delta.*
