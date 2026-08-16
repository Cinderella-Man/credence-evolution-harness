defmodule Cev.AppliedRules do
  @moduledoc """
  Parse the closed set of rules that actually fired from a row log (08 T2.3).

  Credence's fix script emits one `APPLIED_RULES: [{Module, outcome}]` line per
  solve attempt (workspace.ex). `parse/1` collects every entry across every
  attempt **un-deduped** (intermediate over-firing matters — a rule can
  over-fire on an early attempt and be masked by a later rewrite).

  Drives:
    * the `:reverted` deterministic bugfix lane (`reverted/1`, 07 §3.9),
    * BUGFIX closed-set validation + option-shaping (`modules/1`, 07 §3.3/§4.3).

  ## Why the outcome pattern is generic (T3.2)

  An outcome is `non_neg_integer()` or an atom from `t:Credence.rule_outcome/0`,
  which has grown past `:reverted` to `:rolled_back`, `:patch_rejected`,
  `:crashed` and `:no_op`. This regex used to accept `:reverted|\\d+` and
  nothing else — and `Regex.scan/3` does not fail on a pair it cannot match, it
  **skips** it. So every one of those newer outcomes was silently discarded here.

  That is not a cosmetic loss. A dropped pair removes the module from
  `modules/1`, so it is absent from the closed set the classifier is allowed to
  name, and `Cev.Classify`'s `:rule_name_not_in_closed_set` then *rejects* a
  correct `BUGFIX_RULE` report about it. A rule that crashed — the case most
  worth reporting — was the case least reportable.

  The atom branch is therefore deliberately **generic** rather than an
  enumeration of today's vocabulary: pinning the list would restore exactly this
  failure mode the next time credence adds an outcome, and the whole point is
  that this side must never again lose an outcome it has not heard of. Credence
  pins the closed set on its own side (`Credence.rule_outcomes/0` and its
  contract test) — that is where a new member is meant to become visible.
  """

  # APPLIED_RULES: [ ... ]  — capture the bracketed list body.
  # The closing `]` is OPTIONAL. It used to be required, so a line cut mid-list
  # matched nothing and EVERY rule on that row was discarded — losing most of the
  # evidence precisely on the busiest rows, which are the ones worth reading.
  # Logger's truncation is fixed at source (`config :logger, truncate: :infinity`),
  # but a log can be clipped by other hands too (the Gate's own `tail/1`), and the
  # cost asymmetry is stark: parsing the pairs that survived is strictly better
  # than dropping the row.
  @line ~r/APPLIED_RULES:\s*\[(?<body>.*?)(?:\]|$)/
  # {Credence.Pattern.Foo, 3} or {Credence.Pattern.Foo, :reverted | :crashed | …}
  @pair ~r/\{\s*(?<mod>[A-Z][A-Za-z0-9_.]*)\s*,\s*(?<count>:[a-z][a-z0-9_]*|\d+)\s*\}/

  @typedoc """
  A fired rule and what the round did with it. The atom half mirrors
  `t:Credence.rule_outcome/0`; it is typed as `atom()` rather than an
  enumeration on purpose — see the moduledoc.
  """
  @type entry :: {module(), non_neg_integer() | atom()}

  @doc """
  Entries for row `index`, preferring the sidecar over the log.

  The sidecar (`logs/<index>.applied_rules`, written by the validator) is the
  contract; parsing the row log is the fallback for rows produced before it
  existed. Both go through the same `parse/1`, so a sidecar cannot drift into a
  different format than the log.
  """
  @spec for_row(term()) :: [entry()]
  def for_row(index) do
    sidecar = Cev.RowLog.sidecar(index, "applied_rules")

    case File.read(sidecar) do
      {:ok, contents} -> parse(contents)
      {:error, _} -> index |> Cev.RowLog.path() |> File.read() |> then(&parse_result/1)
    end
  end

  defp parse_result({:ok, log}), do: parse(log)
  defp parse_result({:error, _}), do: []

  @spec parse(String.t()) :: [entry()]
  def parse(log) when is_binary(log) do
    log
    |> String.split("\n")
    |> Enum.flat_map(&parse_line/1)
  end

  @doc """
  The `:reverted` culprits (Pattern rules that broke compilation, 07 §3.9).

  Deliberately still only `:reverted`, even though `:crashed` and
  `:patch_rejected` now survive parsing. Widening this changes *routing* — which
  rows open the deterministic bugfix lane at `Cev.Evolve.Router` — and that is a
  behavioural decision to take on its own evidence, not a side effect of
  repairing the parser. The two are separable precisely because the parse fix
  only stops discarding data.
  """
  @spec reverted([entry()]) :: [module()]
  def reverted(entries) do
    for {mod, :reverted} <- entries, do: mod
  end

  @doc "Unique fired modules — the BUGFIX closed set (any count, incl. :reverted)."
  @spec modules([entry()]) :: [module()]
  def modules(entries) do
    entries |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
  end

  @doc """
  Unique fired modules, each with the outcomes it produced this row.

  `parse/1` deliberately accepts any outcome atom so this side "never again
  loses an outcome it has not heard of" — and then `modules/1` dropped every one
  of them three lines later, since the closed set is the only thing that reaches
  the classifier. The outcomes were visible to it only incidentally, as raw text
  inside a 40K-token log dump.

  That matters because the non-integer outcomes are the strongest bug evidence
  credence produces. `:crashed` is a rule that raised. `:patch_rejected` is a
  rule whose patches were built and then discarded by the safety invariants.
  `:no_op` is a rule that reported a finding and then changed nothing — the
  mechanical form of the classifier's most common and usually-wrong BUGFIX
  trigger. All three say "this specific rule misbehaved here" far more precisely
  than a hand-reduced repro does.

  Counts collapse to `:fired`: a rule that reported 3 issues and a rule that
  reported 1 are the same fact for this purpose, and printing the number invites
  the classifier to read significance into it.

  This changes what the classifier SEES, not what the router DOES. Routing on
  these atoms is a separate decision — see `reverted/1`.
  """
  @spec outcomes([entry()]) :: [{module(), [atom()]}]
  def outcomes(entries) do
    entries
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {mod, counts} ->
      {mod, counts |> Enum.map(&normalize_outcome/1) |> Enum.uniq() |> Enum.sort()}
    end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp normalize_outcome(count) when is_integer(count), do: :fired
  defp normalize_outcome(atom) when is_atom(atom), do: atom

  defp parse_line(line) do
    case Regex.named_captures(@line, line) do
      %{"body" => body} ->
        @pair
        |> Regex.scan(body, capture: ["mod", "count"])
        |> Enum.map(&to_entry/1)

      nil ->
        []
    end
  end

  defp to_entry([mod, ":" <> outcome]), do: {module_atom(mod), String.to_atom(outcome)}
  defp to_entry([mod, count]), do: {module_atom(mod), String.to_integer(count)}

  # Build the module atom from its source name without requiring it loaded
  # (the clone may carry a rule not yet recompiled into this build).
  defp module_atom(name), do: :"Elixir.#{name}"
end
