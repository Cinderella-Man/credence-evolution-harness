> **Provenance & verification status (added 2026-07-11 by the coordinating
> session before hand-off).** Produced by an autonomous research agent (Claude
> Opus); preserved verbatim below. The coordinator directly re-verified the
> three most load-bearing claims, all confirmed: the dead `:claude_code`
> preflight branch (`preflight.ex:99` vs `config.exs:131`'s `:cc`), the
> APPLIED_RULES hand-off riding a `Logger.debug` line into a `:debug`-level
> row-log handler (`validator.ex:333`, `row_log.ex:121`), and the non-fatal
> push (`git.ex:61-71`). The §2.1 finding that **Novelty no longer blocks**
> (router builds on `:covered`) is the single most important divergence from
> DESIGN.md and drove proposal H7 — whose original rescue formulation was
> later corrected by experiment (see `credence/docs/14-proposal-scrutiny.md`
> E8: span-overlap, not covers-rerun).

---

# Credence Evolution Harness (`:cev`) — Internals Report

Read-only audit of `/home/kamil/projects/credence-evolution-harness` against
`docs/DESIGN.md` (rev 3, 2026-07-06) and the actual code. All file:line cites are
into that repo unless prefixed `credence/` (the linter clone at
`/home/kamil/projects/credence`).

**Environment caveats affecting verification:**
- The sibling **`opc-sft-stage2-elixir` ("Tunex") repo is ABSENT** on disk — the
  authoritative upstream docs (`07`/`08`/`10`) that the code's moduledocs cite
  cannot be cross-checked; I verified against the DESIGN delta and the code only.
- The sibling **`elixir-sft-dataset` repo is ABSENT** — I could not read any real
  `prompt.md` / `solution.ex` / `test_harness.exs`. Section 7 is reconstructed
  from `docs/gate-census-2026-07-06.csv` (a 236-task probe committed to this repo)
  as a proxy.
- The **credence clone is currently on branch `main`, not `evolution`** — a live
  `mix cev.preflight` would `System.halt(1)` at `preflight.ex:47` today. The clone
  does contain all 8 mix tasks the harness shells to (verified below).

---

## 1. IMPLEMENTATION STATE — modules vs DESIGN §9

Every module DESIGN §9 promises exists under `lib/cev/` (41 `.ex` files, 7,112
LOC). Verified present: the whole rule-gen spine, model/linter layer, infra, and
6 mix tasks. Nothing designed is missing.

**Built-but-undocumented / diverges from DESIGN §9:**

1. **`pi.ex` (270 LOC) + the `:pi` / `:cc` implement drivers exist and `:cc` is the
   configured default** (`config.exs:131` `implement_driver: :cc`). DESIGN §8 lists
   only Claude-Code `:cc`; the `:pi` coding-agent driver (`@earendil-works/pi-coding-agent`
   via `pi/mimo_provider.ts`) is an entire alternative path not in DESIGN, tagged
   "docs/10" throughout (`implement.ex:33-38`, `config.ex:85-95`).

2. **Dead Python-translation code remains in `parser.ex`.** DESIGN §9 says drop
   `parse_translate`, `parse_full`, `elixir_name`, `snake_name`, `fix_is_prefix`.
   All five are still present (`parser.ex:13,50,131,158,177`) plus `parse_instruction`
   (`:118`). Grep confirms **zero callers in `lib/`** — pure dead code, still
   exercised by `parser_test.exs`. The moduledoc still documents "Translate" output
   formats (`parser.ex:2-10`).

3. **Leftover "Translate" references in moduledocs/config** for a stage that no
   longer exists: `llm.ex:2` ("Translate + Solve"), `budget.ex:6-8` ("every
   Translate response"), `config.exs:37` ("Chat providers (Translate + Solve)"),
   `budget.ex:273` (stage atom list includes `:translate`).

4. **`RowLog.duplicate/1` (`row_log.ex:87`) and the `duplicate/` outcome dir are
   dead in the active spine** — see §2 (Novelty is now non-blocking).

5. **`Ledger.phantom/2` (`ledger.ex:44`) is dead in the active spine** — only the
   dormant `credence_rule_generator.ex:229` calls it. The Router never writes
   phantom entries (the implementer re-verifies its own tests, so a phantom is
   impossible).

6. **`evolve/credence_rule_generator.ex` (251 LOC) is dormant** as DESIGN §9 says
   (kept only for `mix cev.diag`); its moduledoc `:2-21` still describes the old
   single-agent routing table.

The DESIGN's framing that the spine "copies almost verbatim" and the only rule-gen
change is "Classify gains gold contrast" (§7) **understates reality**: `classify/prompt.ex`,
`implement/seed.ex`, `router.ex`, `equiv.ex`, `implement.ex` all carry substantial
"docs/10" behavioural fixes inherited from Tunex post-DESIGN (see §2). Per ADR-0001
these are upstream-verbatim, but a reader of DESIGN §9 alone would be surprised.

---

## 2. THE RULE-GEN SPINE (the quality-deciding core)

### 2.1 `evolve/router.ex` — routing logic and inputs

Entry `Router.run(index, solve_outcome, clone, opts)` (`:45`). Inputs: it reads the
**row log file** `RowLog.path(index)` after `RowLog.filesync()` (`:46-48`), parses
`APPLIED_RULES` via `AppliedRules.parse/1`, then forks:

- **`:reverted` lane (deterministic, no classifier)** (`:50-72`): if any
  `{Module, :reverted}` entry exists (a Pattern fix that broke compile),
  `RulePaths.resolve` greps the culprit's source+tests and builds a
  `:broke_compile` bugfix ctx straight to `build_and_gate` — Classify is skipped.
  Unresolvable culprit → `Ledger.gave_up` + escalate.

- **else CLASSIFY** (`classify_and_dispatch/6`, `:76-100`): calls the injected
  `Classify.run/3` with `closed_set:` (fired modules), `clone:`, and **`reference:`**
  (the task's gold `solution.ex`, threaded from the orchestrator — `:81`,
  `orchestrator.ex:244`). Classifier errors are routed through `rulegen_abort`
  (transient→don't-consume; fatal→shutdown; else→`classifier_errors/`).

Dispatch on `spec.decision` (`:102-132`):
- `:no_action` → `no_action/`.
- `:switch_proposal` → `SwitchProposal.record` + `switch_proposals/` (no build).
- `:bugfix_rule` → resolve rule, `:over_fire` bugfix ctx → `build_and_gate`.
- `:potential_new_rule` → **Novelty is now NON-BLOCKING** then equiv → build.

**CRITICAL DIVERGENCE FROM DESIGN §3/§7 — Novelty no longer gates.** DESIGN's loop
diagram shows `COVERED → duplicate/` as a terminal skip. The code (`:119-132`)
instead runs `Novelty.check` and, on `:covered`, only logs *"an existing rule may
overlap this idiom (non-blocking) — building anyway"* and proceeds to equiv. The
inline comment (`:120-124`) explains: the synthetic-`before` covers check is
"UNSOUND as a SKIP gate" because it re-runs `Credence.fix` on a tidied-up snippet
and flagged rules that never fired on the real code, suppressing genuinely-novel
rules. `router_test.exs:65-79` locks this new behaviour ("COVERED no longer skips").
**Consequence:** `duplicate/` dedup is now enforced only by (a) the classifier's own
NO_ACTION-class-2 judgment and (b) the corpus/full-suite Gate — not deterministically.

Equiv trichotomy (`new_rule_after_equiv/6`, `:134-146`): `{:diverges, _}` →
`behaviour_diverged/`; `{:repair, ev}` or `{:equivalent, set}` → `build_new_rule`.
`build_new_rule` (`:150-175`) calls `Naming.resolve_and_scaffold` (runs
`mix credence.gen.rule`), builds the seed ctx (with `ast_before/after` via
`mix credence.ast` for non-syntax phases, `real_diagnostic` for semantic), then
`build_and_gate`.

`build_and_gate` (`:179-204`) runs the injected implementer; on `{:gave_up, reason}`
it routes through `rulegen_abort(discard?: true)` which `Gate.discard`es the dirty
clone. `gate/3` (`:254-271`): `Gate.check` → on `:ok` commit+push+recompile+`committed/`;
on `:reject` `Corpus.persist_reject` + `Ledger.gate_reject` + `escalated/`.

`rulegen_abort` (`:214-252`) classifies errors: `{:llm_error, inner}` → `Budget.classify_error`;
a `{:pi|:cc, "timeout"|"idle_timeout"}` is **transient** (don't poison decisions.md).
Transient aborts increment a persistent per-row counter and give up to `too_slow/`
at `Config.transient_row_limit` (default 3).

### 2.2 `classify/` — the CLASSIFY prompt (quoted verbatim)

`Classify.run/3` (`classify.ex:39-69`) distills the log (`Distill.distill`, drops
everything above `===SOLVE_BOUNDARY===`), reads the closed set, the assumptions
registry (`Credence.assumptions`), the ledger (`Ledger.read`), and the rule index
(`RuleIndex.build`), builds the user prompt, and makes **one raw LLM call with ONE
re-ask** on validation failure (`attempt/5`, `:73-96`).

**SYSTEM PROMPT (verbatim, `prompt.ex:135-139`):**

```
You classify one solved/failed dataset row for the Credence Elixir AST linter.
Decide the SINGLE most valuable deterministic action — a new fixable rule, a fix
to an over-firing existing rule, a switch proposal, or nothing. You are the
QUALITY BAR: a wrong landing rule pollutes all future code, a missed one is lost
forever. Tiny-but-real is welcome; uncertain is NO_ACTION. Never speculate.
Output ONLY the marker-fenced spec — no prose around it.
```

**USER PROMPT** is assembled by `build/1` (`prompt.ex:153-233`). Its literal
skeleton with every injected block:

**(a) Lens fork** (`lens/1`, `:265-283`), one of:
- `:solved` (`:265-273`): *"This row's solve SUCCEEDED — the final code is clean,
  compiles, passes, trips no Credence issue. Judge it for a GENUINE NON-IDIOMATIC
  DEFECT a human expert would deterministically rewrite (a new Pattern rule), plus
  any existing rule that over-fired in the trace (BUGFIX). BIAS STRONGLY TO
  NO_ACTION: most clean solves have no rule-worthy residual, and a Pattern rewrite
  of already-idiomatic code is the #1 cause of rejected rules (it over-fires on the
  real-world corpus). A style/taste/efficiency tweak is NOT a defect — see the
  NO_ACTION classes. Propose a Pattern rule only if you can name the concrete
  correctness/idiom flaw and are confident it will not fire on ordinary real code."*
- `:failed` (`:276-283`): *"This row's solve FAILED — there is NO clean final. This
  is the HIGHER-VALUE lens: judge the attempts for an ISSUE they repeatedly hit that
  NO existing rule fixed — a Syntax/Semantic repair of code that does not PARSE or
  does not COMPILE (e.g. a Python-ism like `a div b`, a missing `require`, an
  unfixed warning). Those repairs of genuinely-broken code are the rules most likely
  to land (they do not over-fire), so favour them; also flag any existing rule that
  over-fired (BUGFIX). Still NO_ACTION if there is no clear deterministic repair."*

**(b) Decision menu** — option-shaped by the closed set (`offered_decisions/1`,
`:260-261`): empty closed set omits BUGFIX_RULE →
`["POTENTIAL_NEW_RULE", "SWITCH_PROPOSAL", "NO_ACTION"]`; else prepends
`"BUGFIX_RULE"`.

**(c) Naming convention** (`:163-166`): "Names are snake_case … prefixed: no_
(forbid), prefer_ (steer), avoid_ (discourage). Propose a SEMANTIC name; the
orchestrator owns the final name + any numeric suffix."

**(d) PHASE taxonomy** (`@phase_taxonomy`, `:79-88`, verbatim):
```
## Choosing PHASE — Credence runs 3 ordered rounds; pick by the INPUT's parse/compile status
- syntax   — `before` WON'T PARSE (Sourceror fails); fixes raw text. e.g. `n*(n+1) div 2` → `div(n*(n+1), 2)`.
- semantic — `before` PARSES but the COMPILER rejects/warns (error- or warning-level diagnostics).
             e.g. `@attr` ABOVE `defmodule` ("cannot invoke @/1 outside module"), unused var,
             undefined function. A semantic rule matches a COMPILER DIAGNOSTIC, not an AST shape.
- pattern  — `before` COMPILES and runs but is non-idiomatic; deeper AST rewrites.
HARD: a Pattern rule's fix ONLY runs on code that COMPILES. If `before` does not compile you MUST
choose syntax or semantic — NEVER pattern (a Pattern rule there detects but its fix is skipped forever).
```

**(e) NO_ACTION classes** (`@no_action_classes`, `:95-133`, verbatim) — the value
bar, 5 numbered classes each with concrete rejected over-fires and real site counts:
```
## When to emit NO_ACTION — these are NOT rules (the corpus/full-suite gate WILL reject them)
A rule must fix a GENUINE non-idiomatic or INCORRECT pattern that a human expert
would deterministically rewrite. The classes below are NOT rule-worthy → NO_ACTION.
They are the measured causes of rejected rules — each wasted 20-50 min of build.

1. STYLE / TASTE / EFFICIENCY. If the only justification is readability, clarity,
   conciseness, "cleaner", "more idiomatic", elegance, or micro-efficiency ("avoids
   an intermediate list", "one pass instead of two"), it is NOT a rule — both forms
   are fine Elixir and the rewrite over-fires on ubiquitous real code. Concrete
   over-fires that were rejected: `fn x -> x == v end` -> `&(&1 == v)` (79 real
   sites); `Enum.map(l, f) |> Enum.max()` -> `Enum.max_by(l, f) |> f.()` (26 sites);
   inlining a single-use `defp` into an anonymous fn (30+ sites); dropping a
   redundant `@doc false`. If your RATIONALE reaches for those words, choose NO_ACTION.

2. ALREADY COVERED (duplicate). If an existing rule (see ## Existing rule index)
   already targets this idiom — EVEN under a differently-worded name, or as a
   broader/narrower variant — it is a duplicate. NEVER re-propose it under a new
   name or a numeric suffix (`no_doc_false_on_private` was shipped twice; a
   `prefer_reduce_when_never_halting` duplicated `no_reduce_while_without_halt`). If
   that existing rule MIS-fired on THIS row, that is a BUGFIX_RULE, not a new rule.

3. NEEDS RUNTIME-TYPE INFERENCE. Credence is type-BLIND … [rewriting `cond and value`
   assuming `value` is non-boolean …]

4. REIMPLEMENTATION, not a local patch. A fix must be a LOCALIZED AST substitution.
   [Do NOT re-express a hand-rolled reduce/recursion as a different Enum pipeline …]

5. DUPLICATED EVALUATION. If `after` evaluates any function or expression MORE times
   than `before`, it diverges for a side-effecting or expensive argument …
```

**(f) Hard rules** (`:172-191`): FIXABLE-ONLY (every rule needs a real `after`, no
check-only); BEFORE must be SELF-CONTAINED (inline every helper or an unrelated
`undefined function` error makes an unrelated rule fire and "the novelty check then
drops your whole proposal as a FALSE DUPLICATE"); Behaviour preservation (§3.10).

**(g) Type-change ban** (`@type_change_block`, `:16-45`, injected verbatim at `:194`)
— the full codepoint↔grapheme treatise banning e.g.
`Enum.at(String.to_charlist(s), i) -> String.at(s, i)`.

**(h) Adversarial-input checklist** (`@adversarial_block`, `:48-74`, injected at
`:196`) — screen `after` against ASCII / precomposed accent / combining accent /
multi-codepoint emoji / flag / empty / nil / negative index / value-KIND traps /
aliased vars / side-effects; with the REPAIR exception (before crashes on EVERY
input → propose the corrected after).

**(i) Assumption switches** (`assumptions_block`, `:285-289`) — the live registry
read from the clone; "You MUST NOT invent a switch … emit a SWITCH_PROPOSAL instead."

**(j) Self-check** (`:206-208`): "Enumerate the adversarial inputs and write {input,
before, after, before==after} for each. Any divergence ⇒ NO_ACTION (except all-crash
⇒ REPAIR candidate)."

**(k) Existing rule index** (`:210-215`) — `RuleIndex.build` output: `<phase>/<name>
— <intent>` per line (intent = first moduledoc sentence), for dedup by INTENT.

**(l) Closed set** (`:217-222`) — the rules that already fired this row (BUGFIX
targets; "Do NOT propose a POTENTIAL_NEW_RULE for an idiom one of them already fixes").

**(m) Dead-ends** (`:224-225`) — the whole `decisions.md` ledger inlined.

**(n) Output contract** (`output_contract/0`, `:309-323`, verbatim):
```
===DECISION===
one of the offered decisions
===RULE_NAME===          (BUGFIX_RULE only — a module name from the closed set)
===PROPOSED_NAME===      (POTENTIAL_NEW_RULE only — snake_case)
===PHASE===              (when a rule is proposed: pattern | syntax | semantic)
===BEFORE===             (a full, self-contained defmodule isolating ONE issue)
===AFTER===              (REQUIRED for any proposed rule — the idiomatic rewrite; NO check-only)
===ASSUMPTIONS===        (optional — existing switch names; omit for no-promise)
===PROPOSED_SWITCH===    (SWITCH_PROPOSAL only — name:/summary:/default:/divergence_class: lines, with ===BEFORE===, no ===AFTER===)
===RATIONALE===
one line
===END===
```

**(o) GOLD_REFERENCE contrast** (`gold_reference_block/1`, `:240-257`) — injected only
when a reference is present (verbatim):
```
## Gold reference (idiomatic — CONTRAST ONLY, do NOT encode its taste)
Below is a hand-written idiomatic solution to THIS task. Use it to judge whether a
difference in the model's output is a genuine, generalizable anti-pattern (a real
rule) versus mere style. HARD: do NOT propose a rule that merely enforces this
reference's stylistic choices — the `before`/`after` you emit must generalize far
beyond this one task, and must pass the NO_ACTION / behaviour / adversarial gates
above regardless of what the reference happens to do. The reference is context,
never a target.
```elixir
#{reference}
```
```
Note the header is titled "Gold reference", NOT the `===GOLD_REFERENCE===` fence
DESIGN §7 promised — `prompt_test.exs:20-32` asserts the "Gold reference" wording.

**Expected output format** — `Spec` struct (`classify/spec.ex:17-28`): `decision`
(enforced key), `rule_name`, `proposed_name`, `phase`, `before`, `after`,
`proposed_switch`, `rationale`, `assumptions: []`. `Parser.parse/1`
(`classify/parser.ex:21-34`) splits markers via `Cev.Markers`, **rejects ambiguous
double-DECISION replies** (`single_decision/1`, `:36-48` — guards the "model
reconsiders mid-reply" trap), strips outer fences off every block, and maps to the
struct. Validation gates in `Classify` (`:100-171`): decision ∈ offered set; BUGFIX
rule_name ∈ closed set AND resolves to a clone file; POTENTIAL_NEW_RULE needs valid
phase + snake proposed_name + before/after present and (phase-conditional, syntax
skipped) **parseable**; assumptions ⊆ registry; SWITCH_PROPOSAL needs a
proposed_switch. Any failure → one re-ask appending "YOUR PREVIOUS REPLY WAS
INVALID" (`:92-96`), then `{:error, {:classifier_errors, …}}`.

### 2.3 Novelty — deterministic, now advisory only

`Novelty.check(before, clone)` (`novelty.ex:13-15`) → `Credence.covers?`
(`credence.ex:51-60`): writes the `before` full-module snippet to a temp `.exs`,
runs **`mix credence.covers <path>` in the clone** (`:56`, `cd: clone`), and returns
`:covered` iff a line matching `^(COVERED|NOVEL)$` equals `COVERED`. Fully
deterministic (an existing rule engaged: code changed / applied_rules / non-parse
issue), no LLM. **But as of the docs/10 change it is non-blocking** (§2.1): the
Router builds even on `:covered`. `mix credence.covers` **exists in the clone**
(`credence/lib/mix/tasks/credence.covers.ex`, verified).

### 2.4 Equiv — deterministic, expression-level, frequently `:skipped`

`Equiv.check(spec, clone:)` (`equiv.ex:27-40`) bridges the classifier's
full-`defmodule` before/after to the **expression-level** `mix credence.equiv`. It
`extract/1`s the single public `def`'s param-vars + body from each module; if either
side is multi-clause / has pattern params / >1 var / multiple defs, extraction
returns `:error` and `check` returns **`:skipped`** (`:29-39`). Only single-clause,
single-var modules reach `Credence.equiv` (`credence.ex:71-90`), which writes both
expressions to temp files and runs **`MIX_ENV=test mix credence.equiv --before … --after
… --vars … --minimal-set`** in the clone (verified `credence.equiv.ex` present),
returning the raw verdict line. `interpret/1` (`:92-113`) maps it:
- `"EQUIVALENT" <> rest` → `{:equivalent, parse_minimal_set(rest)}` (the switch set
  OVERRIDES the spec's assumptions tag).
- `"REPAIR" <> rest` → `{:repair, rest}` (before crashes on every input).
- `"DIVERGES" <> rest` → `{:diverges, rest}` **UNLESS** the rest contains "does not
  compile", in which case it returns `:skipped` (the bare extracted expression
  couldn't compile standalone; defer to the Gate's `_equivalence_test` — docs/10).
- anything else → `:skipped`.

Hybrid character: deterministic tool, but its **reach is narrow** — any structurally
non-trivial rewrite (the common case for real defmodules) is `:skipped` and the
DIVERGES safety net collapses onto the Gate's per-rule equivalence test. Only
`{:diverges, _}` blocks a build; `:skipped`, `:equivalent`, `:repair` all proceed
(`router.ex:137-144`).

### 2.5 `implement/` — the IMPLEMENT SEED prompt + driver

**Driver selection** (`implement.ex:32-38`): `Config.implement_driver()` (default
`:cc`) → `run_agent` with the Claude-Code adapter `cc_run/2`. `:pi` → the pi agent;
`:llm` → the single-shot `run_llm` emit→write→test→retry loop.

**IMPLEMENT SEED SYSTEM PROMPT (verbatim, `seed.ex:21-24`):**
```
You implement ONE Credence rule by FILLING generated stub files. Write `check`/`fix`
(or analyze/fix, or match?/to_issue/fix), replace placeholder fixtures with the real
before/after, and make the red assertions green WITHOUT weakening any test. Emit the
WHOLE content of each file via the role/path markers — nothing else. Preserve the
stub's structure.
```

**SEED USER PROMPT** — `build/2` (`seed.ex:42-64`) concatenates these sections
(nils dropped). DESIGN §7 claims "The Implement seed is unchanged"; it is in fact
heavily elaborated with docs/10 blocks. The full section set, verbatim where load-bearing:

- **header** (`:68-78`): "## Task: implement a NEW <phase> rule by filling the
  generated stubs." (or "FIX an existing rule (<sub_shape>)…"). The `:pi`/`:cc`
  agentic variant says "Fill the generated stub files IN PLACE, run the focused
  tests, and loop until green."
- **spec_block** (`:130-148`): rationale + fenced BEFORE + fenced AFTER, plus the
  crucial NOTE that before/after "are a ONE-SHOT proposal and may be incomplete or
  fail to compile on their own … They convey the INTENDED idiom — they are NOT
  gospel … fix that kind of MECHANICAL breakage yourself … Do NOT change WHAT the
  rule detects or the behaviour it must preserve."
- **scaffold_block** (`:150-159`): every generated stub file verbatim under `### <path>`
  ("FILL these — preserve module names, file shape, the test scaffolding").
- **ast_block** (`:161-167`): fenced BEFORE/AFTER `mix credence.ast` dumps (skipped
  for syntax phase) — "the Sourceror tuple shape check/2 matches".
- **diagnostic_block** (semantic only, `:169-187`): the REAL captured compiler
  diagnostic "use VERBATIM in the test diag + key match? on it", with the HARD
  warning to match the distinctive message substring not the generic "cannot compile
  module" envelope (cites over-fire row 58344).
- **bugfix_block** (`:189-204`): the offending rule source + its tests, "edit IN
  PLACE — add the must-not-fire / regression case; no new/renamed files".
- **invariants_block** (`:206-220`): behaviour preservation (§3.10) + the
  `Prompt.type_change_block()` and `Prompt.adversarial_block()` re-injected verbatim.
- **dsl_safety_block** (`:228-254`, verbatim core): the top escalation cause. Tells
  the agent that `DslSafetyClassificationTest` fails any fix that changes the count
  of an Ash.Expr/Ecto.Query/Nx.Defn-reinterpreted construct
  (`! && || and or not == != === !== < > <= >= is_nil / div rem in + - * ** <> ++ --
  if unless cond case with`) unless it either declares
  `def unsafe_in_dsl, do: [:ash_expr, :ecto_query, :nx_defn]` or adds a one-line
  `@verified_dsl_safe` entry in `test/dsl_safety_classification_test.exs`.
- **syntax_fix_block** (syntax only, `:261-270`): drive fixes from
  `Code.string_to_quoted/2`'s `{:error, {meta, message, token}}`, "Do NOT scan with
  String.split(\"\\n\") + line/substring heuristics".
- **conventions_block** (`:274-291`): §5.6 test conventions — fix tests use
  `confirm_fix(fix(R, input), expected)`, ban `=~`/`String.contains?`/`match?`/…,
  `expected` is the rule's REAL output (run it, copy the string), fixture form rules,
  and the pattern `_equivalence_test` must call `assert_equivalent(before, rule:,
  vars:, inputs:)` with ≥3 discriminating inputs passing strict `===`.
- **assumptions_block** (switch-gated only, `:293-301`): emit `def assumptions, do:
  [...]` + a `<Rule>PropertyTest` from the shared generator.
- **repair_block** (repair sub-mode only, `:305-312`): use `mark_equivalence_repair("...")`
  in the equivalence test instead of `assert_equivalent`.
- **closing**: either the marker output-contract (`output_contract/1`, `:316-332` —
  `===RULE=== / ===CHECK_TEST=== / ===FIX_TEST=== / ===EQUIVALENCE_TEST=== (pattern) /
  (PROPERTY_TEST iff switch-gated) / ===END===`, prefixed with the no-fence
  instruction `:31`) or the **agentic task** (`agent_task_text/1`, `:91-128`) for
  pi/cc: "The files shown above ALREADY EXIST on disk … EDIT them in place … Then run
  `mix test <target>` and LOOP until every one passes … Finishing bar: `mix test
  --exclude corpus` MUST be green … Do NOT weaken/skip/delete assertions … NEVER run
  the plain full `mix test` (triggers the ~8-min corpus) … Do NOT run git."

**`naming.ex`** (`resolve_and_scaffold/3`, `:24-45`): canonicalizes the proposed
snake name (`Macro.underscore(Macro.camelize(...))`, `:71`) to match what
`gen.rule` writes, finds the first free `_N` suffix by checking on-disk
`lib/<phase>/<snake>.ex` (`:57-68`), runs `mix credence.gen.rule <Pascal> --type
<phase>` (`credence.ex:123-139`), and returns the module + generated paths +
file contents (read back for the seed). The model never picks paths.

**`output.ex`** (`:28-91`): parses the `:llm` driver's whole-file emit; new-mode
requires RULE+CHECK_TEST+FIX_TEST, **Pattern additionally requires EQUIVALENCE_TEST**
and Syntax/Semantic **reject** one, PROPERTY_TEST required iff switch-gated. Bugfix
mode requires RULE + ≥1 test, each test path ⊆ the known glob (no new files).

**`claude_code.ex` — the `:cc` driver** (`381 LOC`). Runs the `claude` CLI headless
(`-p`) over a **Port** with `--output-format stream-json` for live logging
(`:60-64`). Model = `mimo-v2.5-pro[1m]` via `ANTHROPIC_BASE_URL` =
`https://token-plan-sgp.xiaomimimo.com/anthropic` (`cc_env/0`, `:353-359`;
config.exs:150-162) — "Claude Code (harness) ≠ Claude (model)". **max_turns = 80**
(`config.exs:158`, `cc_max_turns` default 30 at `config.ex:76`). **timeout_ms =
3,600,000** (1h, `config.exs:161`). `--permission-mode bypassPermissions` (`:45`)
auto-approves tools; `@allowed_tools = Read Grep Glob Edit Write + Bash(mix test:*)`
(`:41`); `@disallowed_tools = ["Bash(git:*)"]` (`:42`) is a hard git block regardless
of permission mode (plus no git creds in env). Prompt fed via stdin temp file +
`exec claude … < file` (`:54-66`) to dodge the 128KB arg limit.

**Failure detection** (`cc_run/2`, `implement.ex:82-89`): keys off the result
`subtype` — `"error_timeout"`→gave_up "timeout"; `"error_max_turns"`→gave_up "max
turns reached"; else hands the result to `focused_test` (the real judge — "a green
claim from the agent is not trusted", `:50-54`). A wall-clock TIMEOUT kills the port
(`kill/1`, `:367-377`) and returns `subtype: "error_timeout"` (`timeout_result/1`,
`:285-311`). `parse_decision/3` (`:321-349`) parses a `DECISION:` verb but the
implement agent never emits one, so this path is generator-flow-specific.

**Post-agent cleanup before the Gate** (`implement.ex:97-126`): `canonicalize_fix_tests`
runs `mix credence.fix_tests` to rewrite `expected =` heredocs to the rule's REAL
output (the agent can't byte-predict it), and `normalize_test_heredocs` runs
`mix credence.normalize_tests` — both best-effort, both mix tasks **verified present**
in the clone.

**Retry/repair loop.** `:llm` driver: flat (non-accumulating) retry — seed + LAST
attempt + LAST failures (`retry/7`, `:167-176`), ≤ `rule_gen_max_retries` (default 5,
`config.exs:121`), bounded by input/output char ceilings (240k/480k, `:130-134`).
`focused_test` (`:242-246`) is two-phase: the rule's own tests, THEN `mix test
--exclude corpus` (~15s cross-rule invariants) — so a DSL-safety failure is fixed
in-loop, not at the Gate. The agentic drivers (`:pi`/`:cc`) loop internally; the
harness re-runs `focused_test` after (`run_agent`, `:55-71`) and returns
`{tests_red_tag, …}` if still red.

### 2.6 `evolve/gate.ex` — the 5-part contract (token-free)

`Gate.check(clone)` (`:45-64`) runs only on a dirty tree, cheap-first / fail-fast:

0. **sweep_scratch** (`:81-91`): `git ls-files --others --exclude-standard` and
   **delete every untracked file outside `lib/`+`test/`** before staging (a stray
   `tmp_debug.exs` would otherwise trip scope and lose a green rule — cites row
   68946). Only untracked scratch; a tracked out-of-scope edit still fails scope.
1. `git add -A`, then `staged_entries` from `git diff --cached --name-status -z`.
2. **(b) touches `lib/`** (`check_touches`, `:102-106`) else `:no_lib_change`.
3. **(c) touches `test/`** else `:no_test_change`.
4. **(e) scope** (`check_scope`, `:110-117`): every staged path under `lib/` or
   `test/` else `{:scope, offending}`.
5. **pure-deletion guard** (`check_not_pure_deletion`, `:121-129`): if every `lib/`
   change is status `D` → `{:pure_deletion, …}` (removing a rule is human-only).
6. **(d) mutation check** (`check_mutation`, `:133-153`): if no changed test →
   `:no_changed_test_to_mutate`; else snapshot the changed `lib/` files, **revert
   them to HEAD** (`git checkout HEAD --` for tracked, `File.rm` for new files),
   run the changed test file(s), assert **exit ≠ 0 (RED, incl. compile-error =
   RED)**, restore lib, `git add -A`. Green-without-the-rule → `{:mutation_no_effect,
   …}`.
7. **(a) full suite** (`check_full_suite`, `:182-208`), two-phase fail-fast:
   - FIRST `mix test --exclude corpus` (~15s): red → plain `:full_suite_red`
     (rejected *without* paying the corpus).
   - ONLY if green, `mix test` (~8min, adds the ~500-project corpus). Red here is
     definitionally the corpus layer → capture the staged patch, then
     `Corpus.classify_failure` tags it `{:corpus, :over_fire|:narrowing, …}`.

On any `{:reject, _}` the Gate `discard`es (`reset --hard HEAD` + `clean -fd`,
`:94-98`) and returns the reason. `{:ok, summary}` → the Router commits.

**Mutation-check mechanics** are literal: `snapshot_lib` records content + whether
each file `tracked_in_head?` (`git cat-file -e HEAD:<rel>`), `revert_lib_to_head`
either checks out HEAD or `File.rm`s a brand-new file, `run_tests` execs `mix test
<test_files>` under `MIX_ENV=test`, `restore_lib` writes the agent's content back.
Renames pass because the add-side touches lib/+test/ (`:270-274` takes the new path).

**Corpus-reject handling** (`corpus.ex`): `classify_failure/1` (`:32-47`) re-checks
`mix test --exclude corpus` is green (corpus-only), then `delta/1` (`:56-71`)
regenerates the snapshot via `mix credence.corpus --update-snapshot`, diffs it
against the committed `test/corpus/accepted_findings.txt`, and **restores the file**
— `new` findings ⇒ `:over_fire`, `gone` ⇒ `:narrowing`. `persist_reject/2`
(`:93-99`) writes `escalated/<idx>.patch` (the staged diff) + `escalated/<idx>.corpus.md`
(drop-or-accept instructions incl. the exact `git apply` + `mix credence.corpus
--update-snapshot` recipe, `:103-127`) and returns a compact reason. Verified the
clone has `credence.corpus.ex` and a 456KB `accepted_findings.txt`.

**Bypasses / escape hatches:** none in the Gate itself — every path either commits a
green-full-suite rule or resets. But note: the **push is non-fatal** (`git.ex:61-71`
warns and continues on failure), and `Gate` trusts the corpus snapshot in the clone
as the over-fire oracle (a stale/edited snapshot would silently change the bar).

### 2.7 Supporting modules

- **`applied_rules.ex`**: regex-parses `APPLIED_RULES: [{Mod, count|:reverted}]`
  across **every** attempt un-deduped (`:23-27`) — intermediate over-fires matter.
  `reverted/1` (culprits), `modules/1` (closed set).
- **`rule_index.ex`**: 0-token `<phase>/<name> — <first-moduledoc-sentence>` index
  from the clone's `lib/<phase>/*.ex` (`:21-29`); dedup-by-intent for Classify.
- **`rule_paths.ex`**: `resolve/2` greps `grep -rl "defmodule <Mod> do" lib/` in the
  clone (`:46-54`); requires exactly one match (0/>1 → error).
- **`markers.ex`**: order-preserving `===KEY===` splitter (`:21-33`), drops `===END===`,
  supports path-keyed `TEST:<path>` keys; `to_map` keeps FIRST occurrence.
- **`distill.ex`**: keeps everything below the last `===SOLVE_BOUNDARY===`
  (`:24-29`), degrades to whole-log if absent.
- **`switch_proposal.ex`**: writes `switch_proposals/<idx>.json` (`:14-28`); never
  touches `lib/assumptions.ex` — human-authored switches only.
- **`transient_attempts.ex`**: persistent `index→count` JSON under `var/run/`
  (`:17-23`, wiped by reset); best-effort, under-counts on IO failure.
- **`evolve/ledger.ex`** — the `decisions.md` mechanism: append-only markdown,
  written by the **orchestrator/Router only** (never the agent), for **dead-ends
  only** (`gave_up`, `gate_reject`, `phantom` — `:33-46`). NOT written for
  `no_action` (majority), so it stays small; the whole file is inlined into every
  Classify prompt (§2.2 block m) so the agent won't re-propose. Run-scoped (wiped by
  reset). Active callers: `router.ex:68,171,196,267` (gave_up ×3 + gate_reject).
  **`phantom` is never called by the active spine.** Emergent dedup is the *other*
  half: a committed rule auto-fixes its pattern so it stops recurring
  (`git.ex:36-38` recompiles credence after commit).

---

## 3. SOLVE + VALIDATE

### 3.1 `pipeline/solve.ex` — prompt construction

**System prompt** (`@system`, `:32-47`, verbatim): "You write Elixir. Given a problem
statement, implement the module(s) it asks for … Produce a single self-contained
solution … Name the module exactly as the problem statement asks. **Use only the OTP
standard library unless the problem says otherwise.** OUTPUT: the complete Elixir
source in ONE fenced ```elixir block … No prose."

**Attempt 1 (BLIND)** — `build_initial/1` (`:53-61`, verbatim):
```
Implement this Elixir task.

#{prompt}

Output the complete module(s) in one ```elixir code block.
```
Contains ONLY `prompt.md`. `solve_test.exs:14-20` asserts it does NOT contain
`RateLimiterTest` / `use ExUnit.Case`.

**Attempt 2+ (harness-guided)** — `build_retry/4` (`:64-87`, verbatim): "Your
previous Elixir solution did not pass. Fix it … ## Task {prompt} ## Test suite (your
module MUST pass these — do not modify them) ```elixir {test} ``` ## Your previous
attempt ```elixir {previous_code} ``` ## What failed {Report.format_errors(failures)}
…". So the full `test_harness.exs` + previous attempt + `{stage, msg}` failures.

Loop (`attempt/7`, `:101-154`): each attempt calls `LLM.for_stage(:solve, …, opts)`
(opts carry the per-pass temperature), `extract_module` (fenced blocks preferred,
`---MODULE---` fallback, bare-defmodule fallback; requires a `defmodule`), then
`Validator.run`. Empty failure list → `{:ok, %{elixir_code, attempts}}`; else retry.
`>max_retries` (3) → `{:failed, …}`. Truncated/empty/no-code → re-roll at
`build_initial` (n+1). API `{:error,_}` bubbles up.

### 3.2 `validator.ex` — the six steps

`run/3` (`:33-271`) writes `lib/solution.ex` + `test/solution_test.exs` (injecting
`use ExUnit.Case, async: false` if missing, `:387-404`), then:
1. **credence fix** (`:52-75`): `mix run --no-compile run_credence_fix.exs`; keeps
   the fix only if it still compiles else reverts (`run_credence_fix/1`, `:320-382`).
2. **compile** (`:78-119`): `mix compile --warnings-as-errors --force`; if the
   credence-fix broke compile, revert to original and re-compile; still broken →
   `{:compile, …}` and steps 3-6 skipped.
3. **format** (`:122-148`): `mix format --check-formatted` then auto-format; never
   a failure.
4. **credo** (`:151-184`): `mix credo list --strict --format oneline lib/solution.ex`;
   lines mentioning the file → `{:credo, …}`.
5. **credence check** (`:187-211`): `mix run run_credence.exs` → `{:credence, …}` on
   non-zero.
6. **test** (`:214-252`): wrapped in coreutils **`timeout --kill-after=5
   <timeout_s> mix test …`** (`:224-231`); exit 124 → `{:test, "TIMEOUT after …"}`
   (routes to `too_slow/`); other non-zero → `{:test, …}`.

Returns `{failures, final_mod, final_test}`. **How APPLIED_RULES reaches the row
log:** the fix script's stdout (which prints `APPLIED_RULES: …`, workspace.ex:49) is
captured by `System.cmd` and logged via **`Logger.debug`** at `validator.ex:333`;
the RowLog handler is registered at **`level: :debug`** (`row_log.ex:121`), so it
lands in `var/run/logs/<idx>.log`. This is the literal Classify input — but it is
**level-fragile** (raising the global log level would silently drop the signal).

### 3.3 `workspace.ex` — generated project + scripts

`setup/1` (`:83-108`) does `mix new`, injects deps, writes scripts + `.credo.exs`,
bootstraps. **Generated `mix.exs` deps** (`deps_block/0`, `:141-158`): `credo`,
**`jason`, `plug`, `ecto`, `stream_data`, `nimble_csv`** (the 5 census-driven
rescues), and `{:credence, path: <clone>, only: [:dev, :test], runtime: false}`.
`rewrite_deps/1` (`:172-175`) replaces the whole `defp deps` function idempotently.

**Scripts** (`:18-58`): `run_credence.exs` reads `lib/solution.ex`, calls
`Credence.analyze`, prints `OK` or `ISSUES:` + `System.halt(1)`. `run_credence_fix.exs`
calls `Credence.fix`, writes the result, prints `FIXED`/`NO_CHANGES`, then
**`APPLIED_RULES: #{inspect(result.applied_rules)}`** and any `REMAINING_ISSUES`.
`recompile_credence/1` (`:121-134`) force-recompiles the credence path dep in dev+test
after each accepted rule.

### 3.4 `sanity_gate.ex` — one-time cached reference check

GenServer owning the verdict store; `ensure/3` (`:50-68`) hashes
`sha256(solution.ex + "\0" + test)` (`:72-74`), looks it up, and on miss runs
`run_check` (`:78-97`): the **fix-free** `check/3` (`:101-134`) writes the reference
+ harness, runs **lenient `mix compile --force`** (no `--warnings-as-errors`) then
`mix test`, **retry-once** before `:blacklist`. Verdicts appended to
`var/cache/task_verdicts.jsonl` (`:166-170`), loaded at init. A task with `nil`
reference is `:ok` (never blacklist for a missing gold file). Survives `cev.reset`
(reset keeps `var/cache/`, §4).

---

## 4. ORCHESTRATOR & OPS

### 4.1 `orchestrator.ex` — the continuous loop

GenServer `restart: :transient` (`:20`). Boot (`handle_continue(:boot)`, `:35-81`):
`Preflight.run!()` → `TaskSource.list()` (halt if 0) → `load_pass` (`var/run/pass`,
default 0) → `Progress.load` → `permutation(pass, total)` (deterministic shuffle,
seed = pass+1, `:322-326`) → drop completed. Opens `rows.jsonl` (fsync'd,
`:330-339`), sets solve params from `Config.solve_params_for_pass`.

Pass loop (`handle_info(:next, …)`): `[]` pending → next pass (increment,
`Progress.clear`, new permutation+params, `:86-103`); `[idx|rest]` → `run_row`,
apply breaker, `Progress.mark_done`, log progress, recurse (`:105-112`).

`do_row` (`:169-199`): `Budget.set_row` → `RowLog.open` → `TaskSource.load` →
`SanityGate.ensure`. `:blacklist` → close+mark_done (no solve). `:ok` →
`solve_and_finish` (`:207-241`): emits `===SOLVE_BOUNDARY===`, runs `Solve.run`
(via `stage/3` API-error wrapper), then **runs rule-gen on EVERY task** (success or
fail) — `router_outcome` forks the lens `:solved`/`:failed` (`:255-256`), the gold
`task.reference` threads into `Router.run(reference:)` (`:244`). On
`:transient_abort` it **skips `mark_done`** (re-runs next pass); else marks done.
`run_row` wraps everything in `rescue` → discard clone + close log + row-stat +
mark_done (`:157-167`). Per-row stat written to `rows.jsonl`: `index, ts, elapsed_s,
cost_est, task, solve, solve_attempts, temperature, rulegen, decision` (or `sanity:
:blacklist`, or `outcome: :exception`).

### 4.2 progress / budget / ledger / breakers

- **`progress.ex`**: one-index-per-line text file → MapSet (`:11-23`); `mark_done`
  appends, `clear` deletes. Crash-resume re-derives the same pass shuffle.
- **`budget.ex`** (the ledger): GenServer tracking Mimo spend + error class.
  `record/4` normalizes `usage` per kind (`:chat` prompt/completion; `:cc`
  input/output+cache, `:197-214`), prices per provider (`config.exs:199-209`; pro
  in $0.435/M out $0.87/M), writes one line/call to `var/run/usage.jsonl` (`:267-292`),
  5-min heartbeat to `heartbeat.jsonl`. **Circuit breaker (runaway):** spend >
  `runaway_ceiling_usd` (default **500.0**) → `on_runaway` = `Cev.shutdown`
  (`:117-120`). **Error class** (`:296-312`): 401/402/403 → `:fatal`; 429 → `:fatal`
  after 5 consecutive else `:transient`; ≥500/network → `:transient`; other http →
  `:fatal`.
- **Consecutive-transient breaker** (`apply_breaker`/`breaker_step`, `:117-138`):
  `:transient_abort` streak ≥ `transient_storm_limit` (5) → `Cev.shutdown({:transient_storm,
  idx})`; any real outcome resets; blacklist holds the streak. Unit-tested
  (`orchestrator_test.exs`).
- **API-error retry** (`stage/3`, `:275-297`): `:fatal`→shutdown; `:transient`→
  exponential backoff (`transient_backoff_ms * 2^(n-1)`) up to `transient_retries`
  (5) then `shutdown({:transient_exhausted, …})`.
- **`Cev.shutdown/1`** (`cev.ex:21-25`): filesync the row log then `System.halt(1)`
  (never raises, so the `:transient` supervisor can't restart into a storm).

### 4.3 row_log — what Classify reads

`row_log.ex`: a dedicated `:logger_std_h` handler per row at `var/run/logs/<idx>.log`,
**level `:debug`** (`:116-125`). It captures the whole VM's Logger stream during the
row — solve attempts (`Logger.info`/`debug` in solve.ex), the full validator trace
including the credence fix before/after and the `APPLIED_RULES` line (§3.2). On
completion the file **moves** to one of 9 outcome dirs (`escalated/ committed/
no_action/ duplicate/ behaviour_diverged/ switch_proposals/ classifier_errors/
transient/ too_slow/`, `:34`) — `close/1` alone deletes (ordinary success). Rule-gen
reads `path/1` after `filesync/0` (`router.ex:46-48`).

### 4.4 preflight & mix tasks

`preflight.ex` `run!/0` (`:22-31`): static (clone exists + on `evolution` +
task_root non-empty + secrets) → `reconcile!` (reset HEAD, set git identity,
best-effort push, `deps.get`, workspace setup+recompile) → runtime (clean tree,
implement-driver smoke, solve+classify endpoint smokes, **full credence HEAD suite
must be GREEN**, `:278-309`). Mix tasks present: `cev.{preflight,reset,usage,budget,
diag,switch_proposals}`. `cev.reset` wipes `var/run/` and **keeps `var/cache/`**
(`cev.reset.ex:23-30`).

---

## 5. TESTS — coverage map

16 test files, 1,464 LOC, hermetic by default (`ExUnit.start(exclude: [:integration])`,
`test_helper.exs:6`). Only two `:integration` blocks (shell into the live clone):
`equiv_test.exs:45` and `implement_test.exs:242` (real `gen.rule` scaffold /
collision-progression).

**Covered (unit):** `budget` (breakdown/pricing/error-class), `classify` (226 LOC,
17 cases — validation gates, re-ask, ambiguous decision), `classify/prompt` (gold
ref, lens fork), `claude_code` (decision parsing), `config`, `corpus` (diff/findings),
`equiv` (extract + interpret), `implement` (299 LOC — output parse, retry, drivers),
`log_plumbing`, `orchestrator` (breaker_step ONLY — `:9`), `parser`, `pipeline/solve`
(blind vs retry prompt, extract_module), `router` (141 LOC, 9 cases — full dispatch
incl. transient/fatal/covered-non-blocking), `sanity_gate`, `task_source`, `workspace`.

**NOT unit-tested (notable gaps):**
- **`evolve/gate.ex` — NO test file at all.** The 5-part contract (mutation check,
  scope, pure-deletion guard, two-phase full suite, scratch sweep) — the entire
  trust boundary that decides rule quality — is exercised only via integration/real
  runs. Highest-risk gap.
- **`validator.ex`** — the 6-step pipeline is untested (no `validator_test.exs`).
- **`novelty.ex`, `distill.ex`, `applied_rules.ex`, `markers.ex`, `rule_paths.ex`,
  `implement/seed.ex`, `implement/naming.ex` (unit), `evolve/git.ex`, `preflight.ex`,
  `pi.ex`, `mimo_console.ex`** — no dedicated tests.
- The orchestrator's per-row wiring (sanity skip, boundary emit, mark_done gating on
  transient) is untested beyond the pure `breaker_step`.

No end-to-end integration test drives solve→validate→router→gate on a real task.

---

## 6. ADRs + CONTEXT.md

- **ADR-0001 (fork Tunex wholesale):** copy Tunex `lib/` verbatim (one
  `Tunex`→`Cev` rename), surgically swap the data source. ~45/51 modules unchanged;
  the whole spine + cost layer taken as-is. Rationale: the spine is the hard,
  proven, expensive part; rebuilding risks Gate-safety regressions. Consequence:
  Tunex `docs/01-12` remain the authoritative per-module reference (and are absent
  here — see caveats).
- **ADR-0002 (filesystem task source):** delete the entire Python translate +
  round-trip + cache + parquet pipeline; replace `Dataset` with `TaskSource` over
  `0*01`. **Status: partially superseded by 0006** — its "a broken entry just fails
  Solve's retries" pricing was written before continuous re-passing; the
  translate-pipeline deletion stands.
- **ADR-0003 (continuous re-pass):** after a 230-task pass completes, immediately
  start another (pass-scoped progress for crash-resume). Justified because Solve is
  non-deterministic and each committed rule changes what later solves surface
  (emergent dedup). Consequence: Classify runs on every task every pass, so
  re-passes cost Mimo even on mostly-NO_ACTION passes.
- **ADR-0004 (keep Mimo for rule-gen):** keep Mimo (token-bucket, cheap for 24/7)
  for Classify + Implement despite a working local `claude` CLI, for zero divergence
  from Tunex's cost/observability layer. Consequence: inherits the ~20-50× ledger
  undercount; `mix cev.budget` (console) is the only ground truth.
- **ADR-0005 (blind first solve attempt):** attempt 1 sees `prompt.md` only; the
  idiomatic harness is revealed only on retries so the model can't crib idioms and
  starve the feedstock. Backed by "230/230 name the module, 226/230 spell the API;
  29/230 assert internals." Consequence: lower attempt-1 pass rate is intentional —
  judge by rule yield, not solve pass rate.
- **ADR-0006 (one-time cached sanity gate):** supersedes 0002's "no gate." On first
  encounter, run `solution.ex` vs `test_harness.exs` fix-free (**lenient** compile +
  test, retry-once, content-hash keys); `:blacklist` skips the task every pass.
  ~100 lines salvaged from `round_trip.ex`+`cache.ex`. Backed by the pre-code census
  (215 usable / 15 blacklisted). Consequence: the reference is read after all (gate
  + classify contrast) but never shown to Solve.

**CONTEXT.md** is a controlled-vocabulary glossary (Task / Prompt / Test harness /
Reference solution / Sanity gate / Pass / Solve / Blind attempt / Feedstock /
Validate / Rule-gen / Classify / Gold contrast / Gate / Credence / Rule / Phase /
Assumption / Over-fire / Corpus / Evolution branch / APPLIED_RULES), each with an
`_Avoid_:` list of banned synonyms. It is consistent with the code; it still
describes `duplicate/` as a live novelty outcome (CONTEXT.md "APPLIED_RULES" and the
loop) which the non-blocking-novelty change (§2.1) has made dead.

---

## 7. DATASET GLANCE (via the census CSV — the actual dataset repo is ABSENT)

`/home/kamil/projects/elixir-sft-dataset` does not exist, so I cannot read any real
`prompt.md`/`solution.ex`/`test_harness.exs`. `docs/gate-census-2026-07-06.csv`
(236 data rows: `task, compile_strict, compile_lenient, test, secs`) characterizes
the slice:

- **Naming/shape:** `NNN_MMM_<descriptive_snake_name>_01`, e.g.
  `001_001_rate_limiter_01`, `001_002_fixed_window_counter_01`,
  `013_003_budget_constrained_retry_worker_with_decorrelated_jitter_01`,
  `032_003_jsonl_streaming_ingestion_with_parallel_batch_processing_01`. Families are
  numbered `001…098`, mostly 4 variants each; the `0*01` glob takes one slice.
- **Task style / difficulty:** backend-Elixir building blocks — rate limiters,
  window counters, retry workers with jitter, CRUD/webhook/long-poll HTTP endpoints
  (016-025), CSV/JSON→Ecto ingestion pipelines (031-032), property-based generators
  (075), promo-code + token systems (089/098), clocks (072). Difficulty spread:
  **208/236 PASS outright**; the hard tail needs external libs (Plug/Ecto/StreamData/
  NimbleCSV) or a DB.
- **Census verdict corroboration:** 13 tasks compile-strict FAIL but compile-lenient
  OK (the warning-drift rescues, e.g. `089_00x_*promo*`, `098_001`, `075_00x`) —
  evidence for the lenient-compile hardening. The endpoint family (016-025) and
  `031/032` CSV/Ecto tasks are the SKIP/FAIL cluster (DB/multi-file bundles). The
  CSV's own footer states **FINAL: 215 usable / 15 blacklisted (10 `<file>` bundles,
  4 DB-requiring, 1 broken harness)** — matching DESIGN §4. `013_003` is annotated
  flaky→PASS-on-rerun (the retry-once evidence).

This confirms scale/shape/difficulty at the census level but I could not directly
inspect prose prompts or gold solutions.

---

## 8. WEAKNESSES / SIGNAL-LOSS MAP

**Where bad rules can slip through the gates:**
1. **Deterministic dedup is gone.** Novelty is now non-blocking (`router.ex:127-131`);
   the covers check is admitted-unsound. Duplicate-rule suppression rests entirely on
   the classifier's NO_ACTION-class-2 judgment (an LLM call, fallible) and the corpus
   Gate (which does NOT catch a *functional duplicate* that fires on the same idiom
   without changing corpus findings). The `duplicate/` dir is dead.
2. **The classify-time equiv gate is weak for the common case.** Any multi-clause /
   multi-var / structural rewrite → `:skipped` (`equiv.ex:29-39`); DIVERGES only
   fires for single-clause single-var modules. For everything else the *only*
   behavioural-equivalence check is the rule's own `_equivalence_test`, authored by
   the same agent that wrote the rule — a self-graded exam. A behaviour-changing
   Pattern rewrite that the agent's equivalence test happens to pass (weak inputs)
   and that doesn't perturb the corpus snapshot will commit.
3. **Corpus over-fire oracle = a static snapshot in the clone.** The Gate trusts
   `test/corpus/accepted_findings.txt` as ground truth (`corpus.ex:25,57`). A rule
   whose over-fire target isn't represented in the ~500-project corpus passes. The
   proactive gold-`solution.ex` over-fire oracle (DESIGN §12) is **not built**.
4. **Gate has no unit tests** (§5) — a regression in the mutation check or scope
   logic would be silent until a bad rule lands.

**Where signal is thrown away:**
5. **Failed solves still classify (good)** but the `:failed` lens is the "higher
   value" path (`prompt.ex:276-283`) — yet a solve that fails for an *environmental*
   reason (missing workspace dep the census didn't add, a `too_slow` timeout) feeds
   the classifier a "broken code" premise that can seed a bogus Syntax/Semantic rule.
   The sanity gate only protects the *reference*, not the *model's* environmental
   failures.
6. **NO_ACTION rows write nothing to the ledger** (`ledger.ex:6-8`) — by design, but
   it means a *repeatedly-proposed-then-NO_ACTION'd* idiom leaves no trace and is
   re-litigated every pass, burning Mimo (ADR-0003 accepts this).
7. **Corpus rejects are preserved but require a human** (`escalated/*.patch` +
   `*.corpus.md`) — a *narrowing* (`:narrowing`, a legit fix that removed a finding)
   is rejected identically to an over-fire and stranded until a human re-pins; the
   loop never auto-accepts narrowings, so genuinely-good narrowing rules are lost to
   the run.
8. **APPLIED_RULES reaches Classify only via a `Logger.debug` line** (`validator.ex:333`
   → RowLog at `:debug`, `row_log.ex:121`). This is the entire input contract, riding
   on the debug log level — brittle and implicit.

**Single points of failure:**
9. **Clone-state coupling:** the harness shells `mix credence.{covers,equiv,ast,
   gen.rule,corpus,fix_tests,normalize_tests}` into the clone. All 8 exist today, but
   determinism of Novelty/Equiv/Gate is only as sound as those tasks; a clone on the
   wrong branch (currently `main`) or with a red HEAD poisons everything (preflight
   `credence_suite_green!` guards boot, but not mid-run drift after a bad commit —
   though the Gate re-runs the suite each time).
10. **Push is non-fatal + best-effort** (`git.ex:61-71`, `preflight.reconcile!`) —
    commits can strand locally; boot reconciliation is the only catch-up.
11. **Budget is a fuzzy backstop only.** The sole runaway guard is
    `runaway_ceiling_usd` (500.0) fed by the ~20-50× undercounting ledger
    (ADR-0004; DESIGN §11 "known accepted gap"); no console-polling breaker. A 24/7
    loop must be watched manually via `mix cev.budget`.

**Prompt weaknesses:**
12. **No positive few-shot in Classify or Implement.** The Classify prompt is rich in
    *negative* examples (the 5 NO_ACTION classes with real over-fire counts) but has
    **zero worked examples of a good POTENTIAL_NEW_RULE spec** — the model must infer
    the exact before/after granularity from prose. Same for the Implement seed (no
    exemplar filled rule).
13. **Solve system prompt tension:** "Use only the OTP standard library unless the
    problem says otherwise" (`solve.ex:38`) discourages exactly the jason/plug/ecto/
    stream_data/nimble_csv deps the census added for 25 tasks; on the blind attempt
    the model can't see the harness that would justify them, so lib-requiring tasks
    are pushed toward attempt-2+.
14. **Gold-contrast fence mismatch:** DESIGN §7 promises a `===GOLD_REFERENCE===`
    fence; the code emits a `## Gold reference` markdown header + a plain ```elixir
    block (`prompt.ex:245-256`). Cosmetic, but the design's verification checklist
    item 7 (grep for `===GOLD_REFERENCE===`) would fail.

**Determinism gaps / brittleness:**
15. **`credence.covers`/`equiv`/`corpus` verdicts are parsed by regex line-matching**
    (`credence.ex:143-150`, "last match wins") — a change to the clone task's output
    wording silently flips a verdict.
16. **`:cc` implement default vs the dead `:claude_code` secrets check.**
    `implement_driver` returns `:cc` (config.exs:131) but `preflight.check_secrets!`
    tests `== :claude_code` (`preflight.ex:99`) — an atom the code never produces — so
    `needs_cc` is always false and the CC auth token is never validated by the secrets
    check. Masked only because `cc_smoke!` (`:199-219`) actually runs the agent (and
    `cc_auth_token` is `fetch_env!`, which would raise). Latent dead branch.
17. **Dead Python-translation code** (`parser.ex`, §1) still ships and is tested —
    maintenance drag, and a reader could mistake it for live behaviour.
18. **`focused_test` / Gate run `mix test` in the clone with no wall-clock timeout**
    (`implement.ex:248-253`, `gate.ex:217-229`) — unlike the Solve validator (which
    wraps `timeout`), a hung rule test or corpus run can block a rule-gen row
    indefinitely; only the outer `:cc`/`:pi` driver timeout bounds the agent phase,
    not the Gate's own `mix test`.
```
