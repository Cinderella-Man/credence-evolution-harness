defmodule Cev.Equiv do
  @moduledoc """
  Classify-time behavioural-equivalence check (07 §3.11, 08 T4.3a).

  The classifier emits `before`/`after` as full `defmodule`s, but `credence.equiv`
  is **expression-level** (07 §3.11 honest limits). `extract/1` bridges them: it
  pulls the single public `def`'s **parameter names (→ vars)** and **body
  expression** out of a simple single-clause module. When the rewrite is
  module-structural (T2 — multi-clause, pattern params, >1 var, multiple defs)
  extraction returns `:error` and `check/2` returns **`:skipped`** — the safety
  net there is the built rule's mandatory `_equivalence_test` at the Gate.

  `check/2` returns:
    * `{:equivalent, minimal_switch_set}` — proceed (no-promise if `[]`, else
      switch-gated; the set OVERRIDES/corrects the spec's `assumptions` tag),
    * `{:repair, evidence}` — proceed in repair sub-mode (`mark_equivalence_repair`),
    * `{:diverges, detail}` — behaviour-changing ⇒ `NO_ACTION` → `behaviour_diverged/`,
    * `:skipped` — the expression-level probe is **inapplicable**: T2 /
      un-extractable, the extracted `after` doesn't compile standalone, or the
      battery exercised neither side (the vacuous-repair class, LD2 — see
      `interpret/1`). Defer to the Gate's per-rule equiv test.
  """

  require Logger

  alias Cev.Credence

  @type verdict ::
          {:equivalent, [atom()]} | {:repair, String.t()} | {:diverges, String.t()} | :skipped

  @spec check(Cev.Classify.Spec.t(), keyword()) :: verdict()
  def check(%{before: before, after: after_src, assumptions: assumptions}, opts \\ []) do
    with {:ok, vars, before_expr} <- extract(before),
         {:ok, _avars, after_expr} <- extract(after_src),
         true <- length(vars) == 1 do
      Credence.equiv(before_expr, after_expr, vars,
        minimal_set: true,
        assumptions: assumptions,
        clone: Keyword.get(opts, :clone, Cev.Config.credence_clone())
      )
      |> interpret()
    else
      _ -> :skipped
    end
  end

  @doc "Extract `{:ok, vars, body_expr}` from a single-public-def module, or `:error`."
  @spec extract(String.t() | nil) :: {:ok, [String.t()], String.t()} | :error
  def extract(nil), do: :error

  def extract(module_src) do
    case Code.string_to_quoted(module_src) do
      {:ok, ast} -> find_def(ast)
      _ -> :error
    end
  end

  defp find_def(ast) do
    {_ast, found} =
      Macro.prewalk(ast, nil, fn
        {:def, _, [head, kw]} = node, nil -> {node, head_body(head, kw)}
        node, acc -> {node, acc}
      end)

    found || :error
  end

  # `def f(a, b) when guard do/, do: body` → strip the guard wrapper.
  defp head_body({:when, _, [head, _guard]}, kw), do: head_body(head, kw)

  defp head_body({_name, _, args}, kw) when is_list(kw) do
    body = Keyword.get(kw, :do)
    params = if is_list(args), do: args, else: []

    case vars(params) do
      {:ok, names} when body != nil -> {:ok, names, Macro.to_string(body)}
      _ -> nil
    end
  end

  defp head_body(_other, _kw), do: nil

  # All params must be simple variables (no pattern destructuring) to map to
  # `credence.equiv` vars.
  defp vars(params) do
    Enum.reduce_while(params, {:ok, []}, fn
      {name, _, ctx}, {:ok, acc} when is_atom(name) and is_atom(ctx) ->
        {:cont, {:ok, acc ++ [Atom.to_string(name)]}}

      _other, _acc ->
        {:halt, :error}
    end)
  end

  # ── Verdict interpretation ──────────────────────────────────────────────

  @doc """
  Map one raw `credence.equiv` verdict line to a `t:verdict/0`.

  Public as the unit seam for the LD2 boundary: `check/2` needs a real clone and
  a ~30 s shell-out, while every distinction that matters here is a distinction
  between two verdict *strings*.
  """
  @spec interpret(String.t()) :: verdict()
  def interpret("EQUIVALENT" <> rest) do
    {:equivalent, parse_minimal_set(rest)}
  end

  def interpret("REPAIR" <> rest), do: {:repair, String.trim(rest)}

  def interpret("DIVERGES" <> rest) do
    rest = String.trim(rest)

    if String.contains?(rest, "does not compile") do
      # Not a behaviour divergence — the expression-level extract couldn't be
      # COMPILED standalone (e.g. the def body calls a private helper that isn't
      # in the bare extracted expression). The equiv check is simply inapplicable
      # here, so defer to the Gate's full-module `_equivalence_test` instead of
      # rejecting a (likely valid) rule into behaviour_diverged/ (docs/10).
      :skipped
    else
      diverges_or_vacuous(rest)
    end
  end

  def interpret(_), do: :skipped

  defp diverges_or_vacuous(detail) do
    case vacuous_probe(detail) do
      nil ->
        {:diverges, detail}

      after_exc ->
        Logger.info(
          "[Equiv] vacuous probe — before raised UndefinedFunctionError and after " <>
            "raised #{after_exc} on the reported input; the battery produced no value " <>
            "on either side, so there is nothing to compare. Skipped (LD2), deferring " <>
            "to the Gate. Raw: #{detail}"
        )

        :skipped
    end
  end

  # ── LD2: the vacuous-repair class ───────────────────────────────────────
  #
  # `credence.equiv` reports the FIRST battery input on which before and after
  # disagree, as `input=… before=<outcome> after=<outcome>`. One shape of that
  # report carries no information at all:
  #
  #     before={:raise, UndefinedFunctionError} after={:raise, <anything else>}
  #
  # The before calls a function that does not exist — the hallucinated-API class,
  # the harness's most productive rule family (98/155 commits) — so it has no
  # behaviour to preserve. The after never reached a value either, because the
  # default battery is type-blind: it is lists, binaries and numbers, so a fix
  # whose code needs a struct, a MapSet or a %Task{} raises on every input
  # (`BadMapError`, `FunctionClauseError`, `ArgumentError`). The probe compared
  # two crashes and called the difference a behaviour change. It is the same
  # situation as the `does not compile` branch — an INAPPLICABLE probe — so it
  # gets the same disposition: `:skipped`, defer to the Gate.
  #
  # `:skipped` and NOT `{:repair, …}` on purpose. `{:repair, …}` licenses the
  # implementer to write `mark_equivalence_repair` INSTEAD of a real equivalence
  # assertion (`Cev.Implement.Seed.repair_block/1`); that is an equivalence
  # CREDIT, and this evidence — before-raised, after never observed — cannot
  # support one. `:skipped` claims nothing: the row is built with no minimal set
  # and no repair licence.
  #
  # THE ROW-105 CLASS MUST NOT GET THROUGH. Row 105 proposed rewriting
  # `File.stream!/1` (exists) to `File.stream/1` (does not) — a fix that invents
  # an API — and the probe correctly killed it with
  # `before={:raise, WithClauseError} after={:raise, UndefinedFunctionError}`.
  # Two conditions here, in that order of importance:
  #
  #   1. the BEFORE must be `UndefinedFunctionError`. This is the condition that
  #      keeps row 105 out: a before that raises `WithClauseError` (or returns a
  #      value) has real behaviour, and changing it is a real change.
  #   2. the AFTER must NOT be `UndefinedFunctionError` — a fixed expression that
  #      calls a missing function is a hallucinated repair, and no input shape
  #      excuses it (`UndefinedFunctionError` means the function is absent, not
  #      that the argument was wrong). Unreachable through today's
  #      `credence.equiv`: two identical `{:raise, Mod}` outcomes compare `===`,
  #      so a both-`UndefinedFunctionError` pair is reported EQUIVALENT and never
  #      reaches this branch at all. It is written down anyway so the predicate is
  #      correct on its own terms rather than by luck of what the caller can emit.
  #
  # Every other outcome shape — a value on either side (`after={:ok, false}`,
  # row 185), a `{:throw, …}`/`{:exit, …}`, an outcome carrying an exception
  # message (`--compare-messages`), any future change to the verdict-line format
  # — fails the anchored match and stays DIVERGES. This function only ever turns
  # "both sides crashed and the before's crash was a missing function" into "no
  # verdict".
  #
  # It is a BACKSTOP, not a substitute for the battery (C2.1): with maps and
  # scalars in the battery, rows 1/7/18/205 already classify REPAIR on their own
  # and never reach here. What no battery can cover is the open set of types a
  # repair might need — %Task{}, MapSet, %Date{}, any user struct — and that
  # residue is exactly what this branch catches (measured: rows 12, 31, 106, 107,
  # 162, 164 today).
  @hallucinated_call "UndefinedFunctionError"

  @outcome_pair ~r/^input=.* before=\{:raise, (?<before>[A-Za-z0-9_.]+)\} after=\{:raise, (?<after>[A-Za-z0-9_.]+)\}(?: minimal_set=\S+)?$/

  # Returns the after-exception name when `detail` is the vacuous shape, else nil.
  defp vacuous_probe(detail) do
    case Regex.named_captures(@outcome_pair, detail) do
      %{"before" => @hallucinated_call, "after" => @hallucinated_call} -> nil
      %{"before" => @hallucinated_call, "after" => after_exc} -> after_exc
      _ -> nil
    end
  end

  # " minimal_set=[single_codepoint_graphemes]" → [:single_codepoint_graphemes];
  # "minimal_set=[]" / "" → [].
  defp parse_minimal_set(rest) do
    case Regex.run(~r/minimal_set=\[(.*?)\]/, rest) do
      [_, inner] ->
        inner
        |> String.split(",", trim: true)
        |> Enum.map(&(&1 |> String.trim() |> String.to_atom()))

      _ ->
        []
    end
  end
end
