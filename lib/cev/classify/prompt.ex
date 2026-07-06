defmodule Cev.Classify.Prompt do
  @moduledoc """
  Build the classifier prompt (07 §3, §4; 08 T3.1).

  A ~200-token system prompt + a user prompt carrying the distilled log, the
  `APPLIED_RULES` closed set, the whole ledger, the `no_/prefer_/avoid_`
  convention prefixes, the assumption registry (§3.12), and BOTH verbatim §3.10
  canonical blocks (the type-change ban + the adversarial-input checklist). The
  offered decision set is option-shaped (§3.3) and the lens forks on solve
  outcome (solved → idiomatic residual; failed → unfixed issue).
  """

  alias Cev.Classify.Spec

  # ── Canonical §3.10 block (i): the type-change ban (verbatim) ───────────
  @type_change_block ~S"""
  NEVER generate a rule whose fix changes the TYPE of the value the code produces.
  A rewrite must return the same kind of value (integer, string, list, etc.) for
  every input. If the "before" and "after" can ever be different types, the rule is
  wrong even if it looks tidier — discard it, do not emit it.

  The most common trap is codepoint↔grapheme on strings. These are NOT
  interchangeable:

    - String.to_charlist/1, String.codepoints/1, ?c literals  -> work on CODEPOINTS
      (small pieces; produce INTEGERS / lists of integers)
    - String.at/1, String.length/1, String.reverse/1, String.graphemes/1,
      String.count/2                                            -> work on GRAPHEMES
      (whole characters; produce STRINGS)

  Specifically BANNED — never generate these or any variant of them:

    - Enum.at(String.to_charlist(s), i)  ->  String.at(s, i)
        WRONG: left returns a codepoint INTEGER, right returns a one-character
        STRING. This is a type change, true for every input including plain ASCII.
        There is no safe fix for indexed character access off a charlist — leave
        it alone. (Do not work around the exact wording with hd(tl(...)),
        |> Enum.fetch(i), |> Enum.at(i), list comprehensions, etc. — same trap.)

  Rule of thumb: if a rewrite swaps a codepoint operation for a grapheme operation
  (or the reverse), and the result types differ, NEVER emit it. (A same-type
  codepoint↔grapheme rewrite — e.g. a count or a reverse where both sides are
  strings — is a separate, switch-gated case and is handled elsewhere; that is not
  your call to make here.)
  """

  # ── Canonical §3.10 block (ii): the adversarial-input checklist (verbatim) ─
  @adversarial_block ~S"""
  A green test suite proves a rule DOES something, not that it is SAFE. Before you
  propose an `after`, run `before` and `after` against every input below. If the
  rewrite gives a different answer on ANY of them, the rule is NOT fixable as-is:
  narrow the match so it no-ops on that input, or emit NO_ACTION.

    - Unicode:
        * plain ASCII
        * a PRECOMPOSED accent  "é" (1 codepoint)
        * a COMBINING accent    "é" = "e" + U+0301 (2 codepoints, 1 grapheme)
        * a multi-codepoint emoji "👨‍👩‍👧" (5 codepoints, 1 grapheme)
        * a flag "🇵🇱" (2 codepoints, 1 grapheme)
    - Edge cases: empty, single element, nil, a negative index.
    - Value-KIND traps: number 7 vs char "7"; codepoints vs graphemes vs bytes.
      The result must be the SAME KIND of value — integer stays integer, string
      stays string, list stays list. A kind change is wrong even on plain ASCII.
    - A variable the moved/removed code also uses elsewhere; side effects in moved
      code (IO, send, raise) that re-ordering would observably change.

  EXCEPTION — REPAIR: if `before` CRASHES on EVERY one of these inputs (it is
  broken on all input — e.g. an arg-order bug, a hallucinated guard), it is a
  REPAIR candidate, not a divergence to suppress. Propose the corrected `after`
  anyway; the deterministic gate confirms it.

  Same-answer on every one of these (or all-crash for a repair), or it is not a
  fixable rule.
  """

  # ── Phase taxonomy (docs/10 Fix 3): the model is told the PHASE token but not
  # what the rounds MEAN — define them so it can't propose Pattern for
  # non-compiling code (whose fix is then gated forever). ──────────────────────
  @phase_taxonomy ~S"""
  ## Choosing PHASE — Credence runs 3 ordered rounds; pick by the INPUT's parse/compile status
  - syntax   — `before` WON'T PARSE (Sourceror fails); fixes raw text. e.g. `n*(n+1) div 2` → `div(n*(n+1), 2)`.
  - semantic — `before` PARSES but the COMPILER rejects/warns (error- or warning-level diagnostics).
               e.g. `@attr` ABOVE `defmodule` ("cannot invoke @/1 outside module"), unused var,
               undefined function. A semantic rule matches a COMPILER DIAGNOSTIC, not an AST shape.
  - pattern  — `before` COMPILES and runs but is non-idiomatic; deeper AST rewrites.
  HARD: a Pattern rule's fix ONLY runs on code that COMPILES. If `before` does not compile you MUST
  choose syntax or semantic — NEVER pattern (a Pattern rule there detects but its fix is skipped forever).
  """

  # ── The NO_ACTION classes (the value/dedup bar) — derived from the escalated
  # rejects: ~70% of them were rules that should never have been proposed (style
  # tweaks, duplicates, type-inference-dependent, whole-pipeline reimplementations).
  # Each here maps to a concrete over-fire/reject the corpus caught after 20-50 min
  # of wasted build. ──────────────────────────────────────────────────────────────
  @no_action_classes ~S"""
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

  3. NEEDS RUNTIME-TYPE INFERENCE. Credence is type-BLIND — it cannot know whether an
     expression evaluates to a boolean, string, list, integer, nil, etc. If the
     rewrite is only correct when some sub-expression has a particular runtime type
     you cannot prove from the AST alone, it WILL diverge on real inputs. e.g.
     rewriting `cond and value` assuming `value` is non-boolean — a boolean RHS (a
     predicate/`==`/`Regex.match?` call) makes it wrong.

  4. REIMPLEMENTATION, not a local patch. A fix must be a LOCALIZED AST substitution.
     Do NOT propose re-expressing a hand-rolled reduce / recursion state machine as a
     different Enum pipeline (reduce -> chunk_by, manual loop -> comprehension): that
     re-derives behaviour rather than patching a shape — unsafe, and it does not build.

  5. DUPLICATED EVALUATION. If `after` evaluates any function or expression MORE times
     than `before`, it diverges for a side-effecting or expensive argument even when it
     is value-identical for a pure one (`Enum.max_by(l, f) |> f.()` re-runs `f` on the
     winner). Narrow it away, or NO_ACTION.
  """

  @system "You classify one solved/failed dataset row for the Credence Elixir AST linter. " <>
            "Decide the SINGLE most valuable deterministic action — a new fixable rule, a fix to an " <>
            "over-firing existing rule, a switch proposal, or nothing. You are the QUALITY BAR: a wrong " <>
            "landing rule pollutes all future code, a missed one is lost forever. Tiny-but-real is welcome; " <>
            "uncertain is NO_ACTION. Never speculate. Output ONLY the marker-fenced spec — no prose around it."

  @doc "The ~200-token system prompt."
  def system, do: @system

  @doc """
  Build the user prompt. `opts`:
    * `:distilled_log` (req) — the post-SOLVE_BOUNDARY log.
    * `:closed_set` — `[module()]` from APPLIED_RULES (drives option-shaping).
    * `:ledger` — the whole `decisions.md` (string).
    * `:assumptions` — `[%{name, default, summary}]` (the switch registry).
    * `:solve_outcome` — `:solved | :failed` (lens fork).
    * `:rule_index` — `<phase>/<name> — <intent>` per line (dedup; `Cev.RuleIndex`).
  """
  def build(opts) do
    closed = Keyword.get(opts, :closed_set, [])
    offered = offered_decisions(closed)

    """
    #{lens(Keyword.fetch!(opts, :solve_outcome))}

    ## Decisions you may emit (pick exactly one)
    #{Enum.map_join(offered, "\n", &"  - #{&1}")}

    ## Rule naming convention (for a new rule's proposed_name)
    Names are snake_case and almost always prefixed: no_ (forbid), prefer_ (steer),
    avoid_ (discourage). Propose a SEMANTIC name; the orchestrator owns the final
    name + any numeric suffix.

    #{@phase_taxonomy}

    #{@no_action_classes}

    ## Hard rule — FIXABLE ONLY, no check-only
    Every proposed rule MUST carry a real `after` (a `fix`). There is NO check-only
    path. If a pattern has no safe auto-fix even on a narrowed core, or the only fix
    changes a value's TYPE, emit NO_ACTION — never a do-nothing stub.

    ## Hard rule — BEFORE must be SELF-CONTAINED
    `before` must stand alone: inline or define EVERY helper/function it calls. Do
    NOT leave a dangling call to something you didn't include. An incomplete snippet
    fails to compile for a reason UNRELATED to your idiom (an `undefined function`
    error), an unrelated rule fires on that breakage, and the novelty check then
    drops your whole proposal as a FALSE DUPLICATE. Keep only the ONE issue you are
    isolating; everything else must be valid: a Pattern `before` must fully COMPILE;
    a Semantic `before` may carry only its ONE targeted compiler diagnostic; a Syntax
    `before` is the lone parse failure.

    ## Behaviour preservation (HARD — §3.10)
    `after` must be output-identical to `before` for EVERY admitted input (Cev
    runs Credence's default helpful mode). A behaviour-changing rewrite is NO_ACTION
    — UNLESS a declared assumption admits it (see the switch registry below), or it
    is a REPAIR (before crashes on every input).

    ### Type-change ban (read it)
    #{@type_change_block}

    ### Adversarial-input checklist (screen `after` against ALL of these)
    #{@adversarial_block}

    ## Assumption switches you MAY lean on (existing only — §3.12 Tier 1)
    #{assumptions_block(Keyword.get(opts, :assumptions, []))}
    Tag a rule with `assumptions: [<existing switch name>]` ONLY to rescue a
    rare-text-divergent (same-type) rewrite. You MUST NOT invent a switch in the
    assumptions field — if a clean rare-text class needs a switch that does not
    exist, emit a SWITCH_PROPOSAL instead.

    ## Self-check (state this in your reasoning BEFORE proposing)
    Enumerate the adversarial inputs and write {input, before, after, before==after}
    for each. Any divergence ⇒ NO_ACTION (except all-crash ⇒ REPAIR candidate).

    ## Existing rule index (dedup — do NOT propose a rule already covered here)
    Each line is `<phase>/<name> — <intent>`. Before any POTENTIAL_NEW_RULE, scan
    this: if one of these ALREADY targets your idiom (even under a different name /
    as a broader or narrower variant), emit NO_ACTION (NO_ACTION class 2). Match by
    INTENT, not by name spelling.
    #{rule_index_block(Keyword.get(opts, :rule_index, ""))}

    ## Rules that already fired on this row (the BUGFIX closed set)
    #{closed_set_block(closed)}
    These rules ALREADY engaged on this row — Credence handled what they target.
    Do NOT propose a POTENTIAL_NEW_RULE for an idiom one of them already fixes;
    that is already covered. (If such a rule MIS-fired or under-fired, that's a
    BUGFIX_RULE, not a new rule.)

    ## Dead-ends already tried (do NOT re-propose)
    #{ledger_block(Keyword.get(opts, :ledger, ""))}

    ## Output contract — marker-fenced, EXACTLY these blocks, nothing else
    #{output_contract()}
    #{gold_reference_block(Keyword.get(opts, :reference))}
    ## Row log (distilled)
    #{Keyword.fetch!(opts, :distilled_log)}
    """
  end

  # The task ships a hand-written IDIOMATIC reference solution — gold Elixir the
  # translated-Python source never had (DESIGN §7). Show it as CONTRAST so the
  # classifier can judge whether the model output's shape is a *generalizable*
  # anti-pattern, with a hard guardrail against encoding the reference author's
  # taste as a rule.
  defp gold_reference_block(nil), do: ""

  defp gold_reference_block(reference) do
    """

    ## Gold reference (idiomatic — CONTRAST ONLY, do NOT encode its taste)
    Below is a hand-written idiomatic solution to THIS task. Use it to judge
    whether a difference in the model's output is a genuine, generalizable
    anti-pattern (a real rule) versus mere style. HARD: do NOT propose a rule that
    merely enforces this reference's stylistic choices — the `before`/`after` you
    emit must generalize far beyond this one task, and must pass the NO_ACTION /
    behaviour / adversarial gates above regardless of what the reference happens
    to do. The reference is context, never a target.
    ```elixir
    #{reference}
    ```
    """
  end

  @doc "Option-shaping (§3.3): empty closed set → BUGFIX not offered."
  def offered_decisions([]), do: ["POTENTIAL_NEW_RULE", "SWITCH_PROPOSAL", "NO_ACTION"]
  def offered_decisions(_closed), do: ["BUGFIX_RULE", "POTENTIAL_NEW_RULE", "SWITCH_PROPOSAL", "NO_ACTION"]

  # ── Sections ───────────────────────────────────────────────────────────

  defp lens(:solved) do
    "This row's solve SUCCEEDED — the final code is clean, compiles, passes, trips no " <>
      "Credence issue. Judge it for a GENUINE NON-IDIOMATIC DEFECT a human expert would " <>
      "deterministically rewrite (a new Pattern rule), plus any existing rule that over-fired " <>
      "in the trace (BUGFIX). BIAS STRONGLY TO NO_ACTION: most clean solves have no rule-worthy " <>
      "residual, and a Pattern rewrite of already-idiomatic code is the #1 cause of rejected " <>
      "rules (it over-fires on the real-world corpus). A style/taste/efficiency tweak is NOT a " <>
      "defect — see the NO_ACTION classes. Propose a Pattern rule only if you can name the concrete " <>
      "correctness/idiom flaw and are confident it will not fire on ordinary real code."
  end

  defp lens(:failed) do
    "This row's solve FAILED — there is NO clean final. This is the HIGHER-VALUE lens: judge the " <>
      "attempts for an ISSUE they repeatedly hit that NO existing rule fixed — a Syntax/Semantic " <>
      "repair of code that does not PARSE or does not COMPILE (e.g. a Python-ism like `a div b`, a " <>
      "missing `require`, an unfixed warning). Those repairs of genuinely-broken code are the rules " <>
      "most likely to land (they do not over-fire), so favour them; also flag any existing rule that " <>
      "over-fired (BUGFIX). Still NO_ACTION if there is no clear deterministic repair."
  end

  defp assumptions_block([]), do: "(none registered)"

  defp assumptions_block(list) do
    Enum.map_join(list, "\n", fn s -> "  - #{s.name} (default #{s.default}): #{s.summary}" end)
  end

  defp rule_index_block(""), do: "(index unavailable)"
  defp rule_index_block(index), do: index

  defp closed_set_block([]), do: "(none fired — BUGFIX is not possible this row)"

  defp closed_set_block(modules) do
    Enum.map_join(modules, "\n", fn m ->
      "  - " <> (m |> Atom.to_string() |> String.replace_prefix("Elixir.", ""))
    end)
  end

  defp ledger_block(ledger) do
    case String.trim(ledger) do
      "" -> "(none)"
      l -> l
    end
  end

  defp output_contract do
    """
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
    """
  end

  @doc false
  # Exposed for tests: the canonical blocks must be injected verbatim.
  def type_change_block, do: @type_change_block
  def adversarial_block, do: @adversarial_block
  def phase_taxonomy, do: @phase_taxonomy

  @doc false
  def __spec_fields__, do: Map.keys(Map.from_struct(%Spec{decision: :no_action}))
end
