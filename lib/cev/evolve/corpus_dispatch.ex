defmodule Cev.Evolve.CorpusDispatch do
  @moduledoc """
  Decides — from the staged diff alone — how much corpus the Gate has to pay for
  a candidate, and runs the rule-scoped scan when one is available (docs/13 P3,
  harness half).

  ## Why this exists

  The Gate's phase-2 `mix test --only corpus` is the most expensive thing it
  does: **234 s** over the 20,076-file corpus (docs/16 §4.5). For 150 of the 155
  candidates this harness has ever committed it is also **pure waste** — every
  corpus layer analyzes through `Credence.Pattern`, and those 150 touched only
  `lib/syntax/` or `lib/semantic/`:

      $ for f in var/run/logs/committed/*.log; do
          grep -o '\\[Gate\\] staged entries: .*' "$f" | head -1
        done | grep -o 'lib/[a-z_]*/' | sort | uniq -c | sort -rn
          117 lib/semantic/
           33 lib/syntax/
            5 lib/pattern/

  ## The three plans

  `plan/2` reads the staged entries and returns exactly one of:

    * `{:skip, why}` — every staged path is a Syntax/Semantic rule or one of its
      tests, and no staged `lib/` file declares `Credence.Pattern.Rule`. Nothing
      the corpus layer looks at can have changed, so the phase is skipped
      outright (234 s → 0). This is the case `mix credence.corpus --only-rule`
      itself refuses with *"skip the corpus phase entirely"*.

    * `{:scoped, module, path}` — exactly ONE staged `lib/` file; it is
      `lib/pattern/<name>.ex`; it declares `Credence.Pattern.Rule`; it defines
      exactly one module, a `Credence.Pattern.*`; and every other staged path is
      that rule's own `test/pattern/<name>…_test.exs`. `scan/2` can then answer
      the over-firing question for that one rule in ~12 s instead of 234 s.

    * `{:full, why}` — everything else. Shared code, several `lib/` files, a
      `test/corpus/` edit, a `lib/pattern/` file that is not a rule, an
      unreadable file: when in doubt, full scan. docs/13 §5.1: *"the fast path
      is an optimization, never the authority."*

  ## What the scoped scan is NOT allowed to replace

  `mix credence.corpus --only-rule` implements **one** of the four corpus layers
  — over-firing. `mix test --only corpus` also runs fix-safety, scope-parity and
  fix-breakage, and none of those is implied by a clean over-fire result.

  docs/13 P3's table claims "fix-safety/scope-parity trivially empty" for a new
  single-rule candidate. That is false for scope-parity, *by scope-parity's own
  construction*: it fires exactly where a rule's check is CLEAN and its fix
  rewrites code anyway, so a rule with zero findings is the case it scans
  hardest, not one it skips (`test/corpus/scope_parity_test.exs` moduledoc:
  "the fix-safety test applies fixes only at already-flagged findings, so it
  never exercises a check-clean file. This layer closes that gap.").

  Measured on this corpus with a rule whose `check/2` returns `[]` and whose
  `fix_patches/2` rewrites `length(x)` → `Enum.count(x)`: **0** over-firing
  findings (so `--only-rule` would print `RESULT=clean`) against **12**
  scope-parity violations in a 170-file sample.

  So the scoped scan is wired as a **fail-fast pre-gate**, never as a substitute:

    * `{:drift, …}` ⇒ the over-firing layer is definitely red (the scoped diff is
      the over-firing assertion restricted to one rule, over the same sweep, the
      same identities and the same snapshot), so reject NOW — ~12 s instead of
      234 s plus the ~180 s of re-runs `Cev.Evolve.Corpus.classify_failure/1`
      would pay, and with the drift already attributed to the candidate's rule.
    * `{:clean, …}` ⇒ over-firing is answered; the other three layers are not.
      Fall through to the full phase.
    * `{:inconclusive, …}` ⇒ the task's contract did not hold (no `RESULT=` line,
      more than one, an exit code that disagrees with the verdict, or drift
      bullets that do not add up to the reported `new=`/`gone=` counts). Fall
      through to the full phase, loudly. There is deliberately no "probably
      clean" branch: an unreadable scan reporting clean is precisely the failure
      the corpus gate exists to prevent.
  """

  require Logger

  alias Cev.Config

  @type entry :: %{status: String.t(), paths: [String.t()]}

  @type plan ::
          {:skip, String.t()}
          | {:scoped, module(), String.t()}
          | {:full, String.t()}

  @type outcome ::
          {:clean, %{rule: String.t(), live: non_neg_integer(), accepted: non_neg_integer()}}
          | {:drift, %{rule: String.t(), new: [String.t()], gone: [String.t()]}}
          | {:inconclusive, %{reason: term(), exit: integer(), tail: String.t()}}

  # Directories whose contents cannot reach the Pattern phase.
  @nonpattern_dirs ~w(lib/syntax/ lib/semantic/ test/syntax/ test/semantic/)

  # The one line `mix credence.corpus --only-rule` contracts on
  # (credence lib/mix/tasks/credence.corpus.ex:209-222). `new=`/`gone=` are
  # printed on drift only, so they are optional here — and cross-checked below.
  @result ~r/^\[only-rule\] RESULT=(?<verdict>clean|drift) rule=(?<rule>\S+) live=(?<live>\d+) accepted=(?<accepted>\d+)(?:\s+new=(?<new>\d+)\s+gone=(?<gone>\d+))?\s*$/m

  # `explain/1` renders each NEW identity line as `  • <line>`, optionally
  # followed by source-excerpt lines — which are always `      <marker> <n> | …`
  # and so cannot collide with this anchor.
  @new_bullet ~r/^\s*•\s(?<line>.+?)\s*$/

  @gone_header "GONE — pinned but no longer firing"

  # How much of a non-conforming run to keep for the log / the maintainer.
  @tail_chars 2_000

  # ── plan/2 ───────────────────────────────────────────────────────────

  @doc """
  Classify the staged diff into a corpus plan.

  Reads the clone only to confirm what a staged `lib/` file actually declares —
  the path is a hint, never the proof. `Credence.Pattern.default_rules/0`
  discovers rules by **behaviour** (`Application.spec(:credence, :modules)` |>
  `implements?(Credence.Pattern.Rule)`), so a Pattern rule saved under
  `lib/syntax/` would be a live Pattern rule and a path-only skip would be
  unsound.
  """
  @spec plan([entry()], String.t()) :: plan()
  def plan(entries, clone \\ Config.credence_clone()) do
    paths = entries |> Enum.flat_map(& &1.paths) |> Enum.uniq()

    cond do
      paths == [] ->
        {:full, "no staged paths"}

      Enum.any?(paths, &under?(&1, "test/corpus/")) ->
        {:full, "the candidate edits the corpus layer itself (test/corpus/)"}

      skippable?(paths, clone) ->
        {:skip, "only Syntax/Semantic rules + their tests — the corpus is Pattern-only"}

      true ->
        scoped_plan(entries, paths, clone)
    end
  end

  # SKIP is allowed only when BOTH hold:
  #   * every staged path lives in a syntax/semantic rule or test directory, AND
  #   * no staged lib/ file declares the Pattern rule behaviour.
  # The second condition is what makes this sound rather than merely plausible.
  defp skippable?(paths, clone) do
    Enum.all?(paths, fn p -> Enum.any?(@nonpattern_dirs, &under?(p, &1)) end) and
      not Enum.any?(paths, &pattern_rule_file?(&1, clone))
  end

  defp scoped_plan(entries, paths, clone) do
    case Enum.filter(paths, &under?(&1, "lib/")) do
      [rel] -> scoped_for(entries, paths, rel, clone)
      [] -> {:full, "no staged lib/ file"}
      many -> {:full, "#{length(many)} lib/ files staged — more than one rule may be involved"}
    end
  end

  defp scoped_for(entries, paths, rel, clone) do
    cond do
      not under?(rel, "lib/pattern/") ->
        {:full, "#{rel} is not under lib/pattern/"}

      not String.ends_with?(rel, ".ex") ->
        {:full, "#{rel} is not an .ex source file"}

      not added_or_modified?(entries, rel) ->
        {:full, "#{rel} is deleted or renamed, not added/modified"}

      not pattern_rule_file?(rel, clone) ->
        {:full, "#{rel} does not declare Credence.Pattern.Rule"}

      not own_tests_only?(paths -- [rel], rel) ->
        {:full, "staged tests are not #{Path.basename(rel, ".ex")}'s own test/pattern/ tests"}

      true ->
        with_sole_module(rel, clone)
    end
  end

  defp with_sole_module(rel, clone) do
    case sole_module(rel, clone) do
      {:ok, module} -> {:scoped, module, rel}
      {:error, why} -> {:full, why}
    end
  end

  # `lib/pattern/no_uniq_then_count.ex` ⇒ `test/pattern/no_uniq_then_count*_test.exs`,
  # the same convention `Cev.RulePaths.resolve/2` uses.
  defp own_tests_only?(others, rel) do
    name = Path.basename(rel, ".ex")

    Enum.all?(others, fn p ->
      under?(p, "test/pattern/") and
        String.starts_with?(Path.basename(p), name) and
        String.ends_with?(p, "_test.exs")
    end)
  end

  defp added_or_modified?(entries, rel) do
    Enum.any?(entries, fn e -> e.status in ["A", "M"] and rel in e.paths end)
  end

  # Does this staged file declare the Pattern rule behaviour? A file that is not
  # readable (a deletion) answers `false`, which is correct in both callers: for
  # `skippable?/2` a deleted syntax/semantic file cannot introduce a Pattern
  # rule, and for `scoped_for/4` a deleted file is already excluded by the
  # added-or-modified test above.
  defp pattern_rule_file?(rel, clone) do
    under?(rel, "lib/") and
      case File.read(Path.join(clone, rel)) do
        {:ok, src} -> src =~ ~r/^\s*(use|@behaviour)\s+Credence\.Pattern\.Rule\b/m
        {:error, _} -> false
      end
  end

  # Exactly one `defmodule … do` in the file, and it is a `Credence.Pattern.*`.
  # Two modules in one file means the candidate ships something besides the rule,
  # which the scoped scan would not cover.
  defp sole_module(rel, clone) do
    with {:ok, src} <- File.read(Path.join(clone, rel)),
         [[_, name]] <- Regex.scan(~r/^defmodule\s+([A-Za-z0-9_.]+)\s+do\s*$/m, src),
         true <- String.starts_with?(name, "Credence.Pattern.") do
      {:ok, Module.concat([name])}
    else
      {:error, reason} -> {:error, "cannot read #{rel}: #{inspect(reason)}"}
      false -> {:error, "#{rel} does not define a Credence.Pattern.* module"}
      found when is_list(found) -> {:error, "#{rel} defines #{length(found)} modules, not 1"}
    end
  end

  # ── scan/2 ───────────────────────────────────────────────────────────

  @doc """
  Run `mix credence.corpus --only-rule <Module>` in the clone and interpret it.

  `MIX_ENV=test` matches every other command the Gate runs in the clone, so the
  scan reuses the `_build/test` artifacts the corpus-free suite phase has just
  built rather than compiling a second tree into `dev`.
  """
  @spec scan(String.t(), module()) :: outcome()
  def scan(clone, module) do
    arg = module |> Atom.to_string() |> String.replace_prefix("Elixir.", "")

    {out, code} =
      System.cmd("mix", ["credence.corpus", "--only-rule", arg],
        cd: clone,
        stderr_to_stdout: true,
        env: [{"MIX_ENV", "test"}]
      )

    Logger.debug("[CorpusDispatch] mix credence.corpus --only-rule #{arg} exit=#{code}\n#{out}")
    interpret(code, out)
  end

  @doc """
  Pure interpretation of ONE `--only-rule` invocation (exposed for tests — the
  whole point is that this decision is testable without a 20k-file corpus).

  The task's contract is: exit **0** with `RESULT=clean`, or exit **non-zero**
  with `RESULT=drift` (it prints the line and *then* `Mix.raise`s). Anything
  else is `:inconclusive` and sends the Gate to the full scan.
  """
  @spec interpret(integer(), binary()) :: outcome()
  def interpret(code, output) do
    case Regex.scan(@result, output, capture: :all_names) do
      [captures] -> verdict(code, output, named(captures))
      [] -> inconclusive(:no_result_line, code, output)
      many -> inconclusive({:multiple_result_lines, length(many)}, code, output)
    end
  end

  # `capture: :all_names` yields the groups sorted by NAME, not by position.
  defp named(captures) do
    ~w(accepted gone live new rule verdict) |> Enum.zip(captures) |> Map.new()
  end

  defp verdict(0, _output, %{"verdict" => "clean"} = r) do
    {:clean, %{rule: r["rule"], live: int(r["live"]), accepted: int(r["accepted"])}}
  end

  defp verdict(code, output, %{"verdict" => "drift"} = r) when code != 0 do
    new = new_lines(output)
    gone = gone_lines(output)
    reported = {int(r["new"]), int(r["gone"])}
    parsed = {length(new), length(gone)}

    if parsed == reported do
      {:drift, %{rule: r["rule"], new: new, gone: gone}}
    else
      reason = {:drift_lines_do_not_match_counts, parsed: parsed, reported: reported}
      inconclusive(reason, code, output)
    end
  end

  defp verdict(code, output, r) do
    inconclusive({:exit_code_disagrees_with_verdict, r["verdict"]}, code, output)
  end

  defp inconclusive(reason, code, output) do
    {:inconclusive, %{reason: reason, exit: code, tail: tail(output)}}
  end

  @doc false
  # NEW identity lines, from `explain/1`'s `  • <line>` bullets.
  @spec new_lines(binary()) :: [String.t()]
  def new_lines(output) do
    output
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case Regex.named_captures(@new_bullet, line) do
        %{"line" => l} -> [l]
        nil -> []
      end
    end)
  end

  @doc false
  # GONE identity lines, from `bullets/1`: the indented lines between the GONE
  # header and the blank line before the RESULT summary. `  (none)` is the empty
  # rendering, not a finding.
  @spec gone_lines(binary()) :: [String.t()]
  def gone_lines(output) do
    output
    |> String.split("\n")
    |> Enum.drop_while(&(not String.contains?(&1, @gone_header)))
    |> Enum.drop(1)
    |> Enum.take_while(&gone_body?/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "(none)"))
  end

  defp gone_body?(line) do
    String.trim(line) != "" and not String.starts_with?(line, "[only-rule]")
  end

  defp int(nil), do: 0
  defp int(""), do: 0
  defp int(s), do: String.to_integer(s)

  defp tail(out) do
    if String.length(out) > @tail_chars,
      do: "…(truncated)…\n" <> String.slice(out, -@tail_chars, @tail_chars),
      else: out
  end

  defp under?(path, prefix), do: String.starts_with?(path, prefix)
end
