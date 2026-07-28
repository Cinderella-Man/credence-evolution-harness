defmodule Cev.Classify.Prompt do
  @moduledoc """
  Build the classifier prompt (07 §3, §4; 08 T3.1).

  A ~200-token system prompt + a user prompt carrying the distilled log, the
  `APPLIED_RULES` closed set, the whole ledger, the `no_/prefer_/avoid_`
  convention prefixes, the assumption registry (§3.12), and BOTH verbatim §3.10
  canonical blocks (the type-change ban + the adversarial-input checklist). The
  offered decision set is option-shaped (§3.3) and the lens forks on solve
  outcome (solved → idiomatic residual; failed → unfixed issue).

  H8 (docs/16 Phase 8.4) adds the three sections the prompt was missing, all of
  them *teaching by example* rather than by prohibition:

    * `@rejected_mechanisms` — shapes the real-world corpus already rejected,
      seeded from the Phase 5 triage (`maintainer_tools/escalation_ledger.md`).
      Each entry leads with the MECHANISM, not the rule name: the ledger's own
      instruction, because "the next proposal has a different name" and a list
      of names teaches the generator nothing.
    * `@exemplars` — three worked ACCEPTED specs (syntax / semantic / pattern),
      each one a live shipped Credence rule's verbatim before→after. The prompt
      otherwise teaches almost entirely by prohibition, with zero examples of
      the granularity the pipeline wants.
    * `verdict_memory_block/1` — what earlier passes concluded about THIS task
      (`Cev.Classify.Verdicts`), so a borderline row does not get re-judged from
      scratch every pass until sampling noise produces a bad proposal. Advisory
      text; it changes no control flow.
  """

  alias Cev.Classify.Spec

  # Newest N remembered verdicts rendered in full; the tally line still counts
  # every one of them, so a long history reads as "×9" without pasting nine
  # lines into the prompt.
  @history_shown 6

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

  # ── H8: the rejected-over-fire list, seeded from the Phase 5 triage ──────────
  #
  # `maintainer_tools/escalation_ledger.md`, cluster "escalated 144–225",
  # finding 1, states the design constraint verbatim:
  #
  #   "When H8's rejected-over-fire list is seeded, it must carry the MECHANISM
  #    per entry, not the rule name — 'no :ets.new/2 scope on a leaf-atom
  #    match', 'vacuous nil == nil guard' — or the same shapes will be
  #    re-proposed under new names."
  #
  # So every entry below leads with the mechanism and carries the rule name only
  # as a trailing provenance tag. The numbers are measured corpus hits from the
  # ledger's per-row sections (rows 48, 73, 124, 150, 162, 199, 221); every one
  # of these rules had a fully green check/fix/equivalence suite and passed the
  # mutation gate — the corpus scan (or a human) was the only thing that caught
  # it. That is why "green tests" appears in the header rather than as a footnote.
  @rejected_mechanisms ~S"""
  ## Shapes ALREADY REJECTED on the real-world corpus — never re-propose, under ANY name
  Each entry below is a MECHANISM, not a rule name. A proposal that carries the
  same mechanism under a new name IS the same rejected rule → NO_ACTION. Match on
  the mechanism, not on the spelling.

  Every rule below had a GREEN check/fix/equivalence suite written by its own
  author and passed the mutation gate. A green suite proves a rule DOES
  something; only the real-world corpus scan (or a human reading the diff)
  caught these. Do not let "my tests would pass" reassure you.

  R1. LEAF-TOKEN MATCH WITH NO ENCLOSING-CALL SCOPE — matching a bare atom,
      literal or token ANYWHERE in the AST without proving which call, argument
      position, or construct encloses it.
      Measured: rewriting the bare atom `:write_concurrency` to
      `{:write_concurrency, true}` wherever it appeared. It fired on
      `:counters.new(2, [:write_concurrency])` — where the bare atom is the
      CORRECT option — producing a runtime `ArgumentError: 2nd argument: invalid
      option in list`, and it rewrote entries of a plain `@info_keys` data list.
      4 corpus hits, 4 false positives, 2 of them program-breaking.
      REQUIRED INSTEAD: the match must name the enclosing call AND the argument
      position ("an element of the list literal in argument 2 of `:ets.new/2`").
      Same mechanism, another rule: matching a range's `-1` ENDPOINT while
      ignoring its start, so the idiomatic suffix slice `s |> String.slice(-6..-1)`
      (inferred step +1, no warning at all) was flagged next to the genuinely
      deprecated `2..-1`. That one survived ONLY because a reviewer added the
      missing "start is not a negative literal" predicate by hand.
      (seen as: fix_ets_bare_concurrency_option; no_negative_step_in_string_slice)

  R2. A GUARD OF THE FORM `f(a) == f(b)` WHERE `f` CAN RETURN A SENTINEL —
      vacuously true on every input for which `f` returns the sentinel twice.
      Measured: `var_name(kind_var) == var_name(k)`, where `var_name/1` falls
      through to `nil` for anything that is not a variable. On real code the
      guard evaluated `nil == nil` and matched ANY two non-variables.
      REQUIRED INSTEAD: compare only after proving both sides are the kind of
      node `f` can actually name, or compare the nodes structurally.
      (seen as: no_reraise_after_atom_catches)

  R3. DELETING A CLAUSE, BRANCH OR `catch`/`rescue` AS THE FIX — removing error
      handling is not behaviour-preserving whenever the surviving clauses do not
      cover the same inputs.
      Measured: the fix deleted a live
      `:error, {:data_error, _} = reason -> reraise Tesla.Error, ...` clause, after
      which structured zlib errors escape as a raw ErlangError instead. The real
      defect in the shape it was aimed at was a WRONG CALL (`Kernel.reraise/3` is
      `reraise(exception, attrs, stacktrace)`, so it cannot re-raise a caught
      `kind`), and the repair for that is the correct call —
      `:erlang.raise(kind, reason, __STACKTRACE__)` — never a deletion.
      REQUIRED INSTEAD: if the `after` has strictly fewer branches than the
      `before`, name the input class that reaches the removed branch and prove it
      is empty. If you cannot, NO_ACTION.
      (seen as: no_reraise_after_atom_catches)

  R4. TREATING A NON-LOCAL EXIT AS A DISCARDED VALUE — a predicate whose only
      criterion is "this statement is not the last one, so its value is thrown
      away" must exclude `raise` / `throw` / `exit` bodies. They never return;
      nothing is discarded.
      Measured: 1064 corpus hits. In a 50-hit sample: 49 `raise`, 1 `throw`,
      0 error-tuples — i.e. EVERY hit was the canonical precondition guard
      (`if bad?, do: raise ArgumentError, "..."`), and the rewrite would have
      inverted all 1064 of them and nested each function's remaining body inside
      an `else`.
      (seen as: no_discarded_early_return_guard)

  R5. WRAPPING A TOKEN IN A FORMATTER AT EVERY OCCURRENCE — the surrounding call
      usually wants the RAW value, and the wrapper changes the type.
      Measured: flagging every bare `__STACKTRACE__` not already inside
      `Exception.format_stacktrace/1` and wrapping it. 810 corpus hits, ~all
      false: a 40-hit sample was 16 `reraise`, 10 `Exception.format(kind, e, st)`,
      3 `:erlang.raise/3`, 11 other list-typed contracts — every one needs the
      list, and `Exception.format_stacktrace/1` returns a String. That is the
      BANNED list→String type change (see the type-change ban), and it is banned
      just as hard when the wrapper looks like a tidy-up.
      Second lesson from the same rule: it was born from a MISREAD crash. The
      stack trace in the payload was incidental; the actual bug was
      `GenServer.reply/2` handed a bare pid instead of a `{pid, tag}` from-tuple.
      (seen as: no_stacktrace_in_term)

  R6. A REWRITE THAT CHANGES HOW MANY ELEMENTS A COMPREHENSION OR PIPELINE
      PRODUCES — `for x <- l, do: if(c, do: v)` yields one `nil` per non-matching
      element; `for x <- l, c, do: v` drops them. Different list LENGTH for every
      input where some element fails `c`. If your own rationale has to EXPLAIN
      that the output changes, the rule is disqualified — no matter how much
      tidier it reads.
      Measured: 35 corpus hits; the sampled ones were all `for` used as a
      side-effecting loop whose result is discarded, including two compile-time
      macro loops at module-body level (one whose `if` body was a `defp`
      definition) — which also falsified the DSL-safety claim its author asserted.
      (seen as: prefer_guard_over_nil_filter_in_for)

  R7. A PREMISE — A COMPILER DIAGNOSTIC OR A CRASH — THAT WAS NEVER OBSERVED.
      Measured: a rule motivated by "`--warnings-as-errors` rejects
      `incompatible types given to Kernel.*/2: float(), dynamic()`". That warning
      does not exist; `dynamic()` is compatible with `float()`. The "fix"
      rewrote the idiomatic `Map.get(opts, :k, 0) * 1.0` into
      `:erlang.float(Map.get(opts, :k, 0)) * 1.0` — a semantic no-op swapping
      readable Elixir for an `:erlang` BIF. 4 corpus hits, 4 false positives.
      REQUIRED INSTEAD: quote the diagnostic or the crash VERBATIM from THIS
      row's log in your rationale. If you cannot point at it in the log in front
      of you, you are inventing it → NO_ACTION. (A false premise is the most
      expensive mistake available to you: it buys a full implementer run.)
      (seen as: prefer_float_cast_for_dynamic_multiplicand)

  Before you emit a POTENTIAL_NEW_RULE, state which of R1–R7 your proposal comes
  closest to and why it does not apply. If it does apply → NO_ACTION.
  """

  # ── H8: positive exemplars (the prompt otherwise teaches only by ban) ────────
  #
  # Three real, committed Credence rules — one per phase, the semantic one also
  # in the REPAIR class. Each before→after pair is the live rule's VERBATIM
  # output, probed against the shipped pipeline rather than written by hand:
  #
  #   Credence.Syntax.FixPythonModulo       "def even?(n), do: n % 2 == 0"
  #                                       → "def even?(n), do: rem(n, 2) == 0"
  #   Credence.Semantic.NoMapHas            "Map.has?(store, key)"
  #                                       → "Map.has_key?(store, key)"
  #   Credence.Pattern.NoDeadMapUpdate      "map |> Map.update(key, 0, & &1) |> Map.drop([key])"
  #                                       → "Map.drop(map, [key])"
  #
  # Keep them verbatim: if a rule changes, re-probe before editing the text. A
  # fabricated exemplar teaches a shape that will not survive the Gate.
  @exemplars ~S"""
  ## Worked examples of ACCEPTED specs — copy this GRANULARITY
  Three specs that were accepted, built, and SHIPPED as live Credence rules.
  What to copy: ONE issue per `before`; a self-contained `defmodule` that stands
  alone; an `after` that is the exact rewrite, not a sketch; a phase that follows
  from whether `before` parses/compiles; and a one-line rationale naming a
  concrete defect rather than a preference.

  All three ALREADY EXIST in Credence — you will find them in the rule index
  above. They are here as FORM, never as targets: re-proposing one is a
  duplicate (NO_ACTION class 2).

  ### Example A — SYNTAX (a Python-ism that does not PARSE)
  ===DECISION===
  POTENTIAL_NEW_RULE
  ===PROPOSED_NAME===
  fix_python_modulo
  ===PHASE===
  syntax
  ===BEFORE===
  defmodule Even do
    def even?(n), do: n % 2 == 0
  end
  ===AFTER===
  defmodule Even do
    def even?(n), do: rem(n, 2) == 0
  end
  ===RATIONALE===
  `%` is map/struct syntax in Elixir, so `n % 2` does not parse; the modulo operator is rem/2
  ===END===
  Why it landed: `before` is the LONE parse failure and carries nothing else, so
  the phase follows mechanically (syntax — a pattern rule's fix would never run);
  and the rewrite is TOTAL — `rem/2` is defined for every integer pair `%` was
  standing in for. Small is fine. "Tiny-but-real is welcome."

  ### Example B — SEMANTIC (a hallucinated stdlib function; the REPAIR class)
  ===DECISION===
  POTENTIAL_NEW_RULE
  ===PROPOSED_NAME===
  no_map_has
  ===PHASE===
  semantic
  ===BEFORE===
  defmodule Cache do
    def cached?(store, key), do: Map.has?(store, key)
  end
  ===AFTER===
  defmodule Cache do
    def cached?(store, key), do: Map.has_key?(store, key)
  end
  ===RATIONALE===
  Map.has?/2 does not exist (compiler: "Map.has?/2 is undefined or private"); the function is Map.has_key?/2
  ===END===
  Why it landed: `before` PARSES but the compiler rejects it, so the phase is
  semantic and the rule keys on the compiler's own diagnostic text, not on an AST
  shape. It is also the REPAIR class — `before` raises on EVERY input, so there is
  no divergence to suppress, and the equivalence gate is told so. Repairs of
  genuinely-broken code are the highest-landing-rate class in this pipeline;
  favour them on the `:failed` lens. Note the `before`: one function, one defect,
  no dangling helper.

  ### Example C — PATTERN (a provable no-op, NARROWED to its safe core)
  ===DECISION===
  POTENTIAL_NEW_RULE
  ===PROPOSED_NAME===
  no_dead_map_update
  ===PHASE===
  pattern
  ===BEFORE===
  defmodule Counter do
    def forget(map, key), do: map |> Map.update(key, 0, & &1) |> Map.drop([key])
  end
  ===AFTER===
  defmodule Counter do
    def forget(map, key), do: Map.drop(map, [key])
  end
  ===RATIONALE===
  Map.update/4 with the identity capture and a literal default is a no-op whose result the very next Map.drop discards
  ===END===
  Why it landed, and the part that matters most: the NARROWING. In general
  `Map.update(m, k, default, fun)` runs `fun` on the existing value and eagerly
  evaluates `default`, so deleting it can drop an exception or a side effect —
  `%{prev: "x"} |> Map.update(:prev, 0, &(&1 - 1))` raises `ArithmeticError` while
  `Map.drop(map, [:prev])` returns `%{}`. The accepted rule therefore fires ONLY
  when `fun` is the identity capture `& &1` (it cannot raise or side-effect for
  any value) AND `default` is a literal (pure, eager evaluation unobservable).
  Under exactly those two conditions the removal is output-identical for every
  input. A `before` you cannot narrow to a core like this is a NO_ACTION, not a
  bolder rule.
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
    * `:verdict_history` — `[%{decision, subject, rationale, ts}]`, oldest first,
      from `Cev.Classify.Verdicts.history/2` (H8). Omitted entirely when empty.
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

    #{@rejected_mechanisms}

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
    that is already covered. If such a rule MIS-fired — it engaged and did the
    wrong thing — that IS a BUGFIX_RULE, and the trace above is your evidence.

    A rule that did NOT fire cannot be a BUGFIX_RULE on this row. BUGFIX_RULE is
    validated against this closed set, so naming a rule that is absent from it is
    rejected however true the observation is. There is no evidence to hand an
    implementer either: the whole case rests on a trace that does not exist.
    Report NO_ACTION.

    ## Dead-ends already tried (do NOT re-propose)
    #{ledger_block(Keyword.get(opts, :ledger, ""))}
    #{verdict_memory_block(Keyword.get(opts, :verdict_history, []))}
    ## Output contract — marker-fenced, EXACTLY these blocks, nothing else
    #{output_contract()}

    #{@exemplars}
    #{gold_reference_block(Keyword.get(opts, :reference))}
    ## Row log (distilled)
    #{Keyword.fetch!(opts, :distilled_log)}
    """
  end

  # ── H8: verdict memory ───────────────────────────────────────────────────
  #
  # Omitted entirely on the first pass over a task — an empty "(none)" section
  # would be pure noise, and the policy text below only makes sense with rows
  # under it.
  #
  # DELIBERATELY advisory. `decisions.md` above is a hard "do NOT re-propose";
  # this is not, because a task's landscape genuinely changes between passes
  # (the solve is non-deterministic, committed rules alter the fix trace). Making
  # it a veto would convert a NO_ACTION recorded by sampling noise into a
  # permanent blind spot — the same "loud failure → silent wrong answer" trade
  # this project has already rejected twice.
  defp verdict_memory_block([]), do: ""

  defp verdict_memory_block(entries) do
    shown = entries |> Enum.reverse() |> Enum.take(@history_shown)

    """

    ## Prior passes judged THIS TASK (your own memory)
    #{tally(entries, length(shown))}
    #{Enum.map_join(shown, "\n", &verdict_line/1)}

    Treat this as EVIDENCE, not as an order:
      - A repeated NO_ACTION is the standing answer; re-affirm it UNLESS you can
        name something concretely NEW in THIS row's log that the earlier passes
        did not have (a different failure, a different idiom, a rule that has
        landed since). "I would word it differently" is not new. The thesis is
        unchanged: uncertain is NO_ACTION, and the memory makes that stick.
      - A shape already proposed here must NOT be re-proposed under another name
        (NO_ACTION class 2). Check the `subject` in parentheses above.
      - It is NOT a veto. A genuine, newly-visible defect in this row still wins.
        Say in your reasoning which of the two cases you are in.
    """
  end

  defp tally(entries, shown_count) do
    counts =
      entries
      |> Enum.frequencies_by(& &1.decision)
      |> Enum.sort_by(fn {decision, n} -> {-n, decision} end)
      |> Enum.map_join(", ", fn {decision, n} -> "#{decision} ×#{n}" end)

    total = length(entries)
    scope = if shown_count < total, do: "; newest #{shown_count} shown", else: ""

    "#{counts}  (#{total} prior verdict#{if total == 1, do: "", else: "s"}#{scope}, most recent first)"
  end

  defp verdict_line(%{decision: d, subject: nil, rationale: r}),
    do: "  - #{d} — #{blank_to_dash(r)}"

  defp verdict_line(%{decision: d, subject: s, rationale: r}),
    do: "  - #{d} (#{s}) — #{blank_to_dash(r)}"

  defp blank_to_dash(""), do: "(no rationale recorded)"
  defp blank_to_dash(r), do: r

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

  def offered_decisions(_closed),
    do: ["BUGFIX_RULE", "POTENTIAL_NEW_RULE", "SWITCH_PROPOSAL", "NO_ACTION"]

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
  def rejected_mechanisms, do: @rejected_mechanisms
  def exemplars, do: @exemplars

  @doc false
  def __spec_fields__, do: Map.keys(Map.from_struct(%Spec{decision: :no_action}))
end
