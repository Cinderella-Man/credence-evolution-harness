defmodule Cev.Evolve.Gate do
  @moduledoc """
  The trust boundary. Runs only on a **dirty** clone tree (the agent edited
  files). Stages everything (`git add -A`) and enforces a hard 5-part contract
  on the staged diff, **cheap-first / fail-fast** (plan #6):

    (b) diff touches `lib/`      — a rule/infra file changed
    (c) diff touches `test/`     — a regression test added/modified
    (e) scope                    — diff touches ONLY `lib/` and `test/`
        pure-deletion guard      — reject if every `lib/` change is a deletion
    (d) mutation                 — revert `lib/` to HEAD, run the changed test
                                   file(s), assert RED (incl. compile-error =
                                   RED), then restore
    (a) full suite green         — last; the slow one, itself fail-fast in two
                                   phases. FIRST `mix test --exclude corpus` (~2min):
                                   all meta + cross-rule invariants (DSL-safety,
                                   equivalence/fix/check-meta, scope-parity) — a red
                                   here is a plain `:full_suite_red`, rejected
                                   WITHOUT paying the corpus. ONLY if that is green
                                   do we run `mix test --only corpus` (~4 min), which
                                   is Credence's real-world over-firing corpus (a
                                   snapshot ratchet, `../credence/docs/09`), so a
                                   rule that over-fires on idiomatic real code is
                                   rejected here for free. Only corpus tests ran,
                                   so a red in phase 2 IS the corpus:
                                   `Cev.Evolve.Corpus.classify_failure/1` tags it
                                   `{:corpus, :over_fire|:narrowing, …}` and the
                                   caller preserves the patch + a drop-or-accept report.

  Phase 2 is **dispatched on the staged paths** (`Cev.Evolve.CorpusDispatch`,
  docs/13 P3). Syntax/Semantic-only candidates skip it outright — every corpus
  layer analyzes through `Credence.Pattern`, and 150 of this harness's 155
  committed candidates are that case. A candidate that stages exactly one
  Pattern rule plus its own tests first gets a ~12 s rule-scoped over-fire scan
  (`mix credence.corpus --only-rule`); a drift there is booked as a corpus
  reject immediately, without the 234 s phase or the classifier's re-runs. A
  clean scoped scan is *not* a clean corpus — it covers over-firing only, not
  fix-safety / scope-parity / fix-breakage — so it falls through to the full
  phase rather than replacing it.

  Renames / supersession-with-replacement (delete+add) pass: the *add* side
  touches `lib/` + `test/` and the mutation check runs on the new test.
  **Standalone pure deletion is rejected + escalated** — removing a rule is a
  human-only decision.

  ## Environmental triage in the suite phases (H9)

  A non-zero `mix test` exit used to mean exactly one thing here: "suite red".
  It does not. Row 2 of the escalated ledger is the counter-example — `mix test
  --exclude corpus` died inside `Kernel.ParallelCompiler` with
  `:io.put_chars(:standard_error, …) → :terminated` after 4.7s having run **zero
  tests**, and the Gate logged `REJECT: :full_suite_red` and discarded a
  candidate that had already passed the mutation gate and whose implementer had
  run the same command 4 minutes earlier with 7309 tests passing.

  So each suite phase is now triaged on **evidence that the suite ran**, never
  on wall-clock (a duration threshold is a guess that rots as the suite grows):

    * `:green`       — exit 0.
    * `:red`         — non-zero AND the run produced a *verdict*: either ExUnit
                       reached `:suite_finished` (`Finished in …`) or the tree
                       failed to compile (`== Compilation error in file …`).
                       A candidate whose code does not compile is a real reject.
    * `:did_not_run` — non-zero with neither. The runner crashed; nothing was
                       learned about the candidate.

  `:did_not_run` retries the phase **once** (row 2's tree was green minutes
  earlier, so a retry is the cheapest path back to a real verdict). If the suite
  still never runs, the Gate returns `{:reject, {:environmental, detail}}`
  instead of `:full_suite_red`, and the candidate's staged diff travels inside
  `detail` so the caller can preserve it — see `persist_environmental/2`. This
  is deliberately NOT a merit verdict: the caller must not book it as a
  dead-end.

  Returns `{:ok, summary}` or `{:reject, reason}` (Gate has already discarded
  the working tree via `reset --hard HEAD` + `clean -fd`).
  """

  require Logger

  alias Cev.Config
  alias Cev.Evolve.Corpus
  alias Cev.Evolve.CorpusDispatch
  alias Cev.RowLog

  # Positive evidence that ExUnit reached `:suite_finished` — i.e. the suite RAN.
  #
  # Emitted by `ExUnit.Formatter.format_times/1`, which is called by the stock
  # `ExUnit.CLIFormatter` *and* by Credence's own `Credence.QuietFormatter`
  # (test/support/quiet_formatter.ex:92 — `test_helper.exs` swaps the formatter
  # out, so anything keyed on CLIFormatter specifically would be wrong here).
  # It is printed even when zero tests matched the filters, and it is the one
  # line the formatter never colorizes, so it survives `IO.ANSI.enabled?`.
  #
  # Deliberately NOT the counts line: Elixir 1.20 replaced CLIFormatter's
  # `2 doctests, 3 tests, 1 failure` with `Result: 3/4 passed (…)`, whereas
  # `Finished in <digits>` is byte-identical on 1.19 and 1.20 — and
  # QuietFormatter colorizes the counts line, so `^\d+ tests` would not even
  # anchor on a tty.
  @suite_finished ~r/^\s*Finished in \d/m

  # The other way a non-zero exit is a real verdict: the tree does not compile.
  # Mix prints this banner for `lib/` *and* `test/` compile failures
  # (TokenMissingError, CompileError, and an UndefinedFunctionError raised at
  # module-compile time), and a candidate whose code does not compile is a
  # genuine REJECT, not an environmental blip. The `--warnings-as-errors`
  # alternative is included so that turning that flag on in `mix.exs` later
  # cannot silently reroute every warning failure into the environmental lane.
  #
  # Row 2's crash printed only *warnings* plus an `ErlangError`, so neither
  # pattern matches it — which is the whole point.
  @compile_failed ~r/^\s*(== Compilation error in file |Compilation failed due to warnings)/m

  # One retry per suite phase. More than one is guesswork; zero loses exactly
  # the candidate this triage exists to save.
  @suite_retries 1

  # How much of the failing output to keep in the maintainer report.
  @tail_chars 4_000

  @doc "Run the contract against the (already-dirty) clone. `clone` defaults to config."
  def check(clone \\ Config.credence_clone()) do
    sweep_scratch(clone)
    git(clone, ["add", "-A"])
    entries = staged_entries(clone)
    Logger.info("[Gate] staged entries: #{inspect(Enum.map(entries, &{&1.status, &1.paths}))}")

    with :ok <- check_touches(entries, "lib/", :no_lib_change),
         :ok <- check_touches(entries, "test/", :no_test_change),
         :ok <- check_scope(entries),
         :ok <- check_not_pure_deletion(entries),
         :ok <- check_mutation(clone, entries),
         :ok <- check_full_suite(clone, entries) do
      {:ok, summarize(entries)}
    else
      # An environmental failure is NOT a rejection of the candidate — the
      # candidate was never judged. Logged distinctly so `REJECT:` in the row
      # log keeps meaning "the Gate ruled against this rule".
      {:reject, {:environmental, _} = reason} ->
        Logger.error(
          "[Gate] ENVIRONMENTAL: #{reject_label(reason)} — discarding the tree, " <>
            "but the candidate's patch is preserved (it was never judged)"
        )

        discard(clone)
        {:reject, reason}

      {:reject, reason} ->
        Logger.warning("[Gate] REJECT: #{reject_label(reason)} — discarding")
        discard(clone)
        {:reject, reason}
    end
  end

  # A corpus reject carries a (possibly large) patch + finding lists — keep the
  # log line compact; the full detail is written to `escalated/` by the caller.
  defp reject_label({:corpus, kind, %{new: new, gone: gone}}),
    do: "corpus #{kind} (#{length(new)} new, #{length(gone)} gone)"

  defp reject_label({:environmental, %{phase: phase}}),
    do:
      "#{phase} suite never ran (no ExUnit summary, no compile error) after #{@suite_retries + 1} attempts"

  defp reject_label(reason), do: inspect(reason)

  # Remove UNTRACKED files outside lib/ and test/ before staging. An agent's stray
  # scratch file (e.g. a `tmp_debug.exs` it wrote to inspect Sourceror output and
  # couldn't reliably delete) would otherwise trip the scope check and discard an
  # otherwise fully-green rule (row 68946: a 22/22-passing rule lost to a 0-byte
  # file). Only *untracked* scratch is swept — `--exclude-standard` skips gitignored
  # paths (`_build`, `deps`), and a *tracked* file modified outside lib/test still
  # reaches `check_scope` and is rejected as a real violation. New rule/test files
  # (under lib/ or test/) are never swept.
  defp sweep_scratch(clone) do
    {out, _} = git(clone, ["ls-files", "--others", "--exclude-standard", "-z"])

    out
    |> String.split("\0", trim: true)
    |> Enum.reject(&(under?(&1, "lib/") or under?(&1, "test/")))
    |> Enum.each(fn rel ->
      File.rm(Path.join(clone, rel))
      Logger.info("[Gate] swept untracked scratch file (outside lib/, test/): #{rel}")
    end)
  end

  @doc "Discard all working-tree + staged changes in the clone."
  def discard(clone \\ Config.credence_clone()) do
    git(clone, ["reset", "--hard", "HEAD"])
    git(clone, ["clean", "-fd"])
    :ok
  end

  # ── (b)/(c) touches ─────────────────────────────────────────────────

  @doc false
  # Public for contract tests (T4.6): these three decide a reject purely from the
  # staged diff, with no clone and no suite, so they can be pinned directly.
  def check_touches(entries, prefix, reason) do
    if Enum.any?(entries, fn e -> Enum.any?(e.paths, &under?(&1, prefix)) end),
      do: :ok,
      else: {:reject, reason}
  end

  # ── (e) scope: only lib/ and test/ ──────────────────────────────────

  @doc false
  def check_scope(entries) do
    offending =
      entries
      |> Enum.flat_map(& &1.paths)
      |> Enum.reject(&(under?(&1, "lib/") or under?(&1, "test/")))

    if offending == [], do: :ok, else: {:reject, {:scope, offending}}
  end

  # ── pure-deletion guard ─────────────────────────────────────────────

  @doc false
  def check_not_pure_deletion(entries) do
    lib_entries = Enum.filter(entries, fn e -> Enum.any?(e.paths, &under?(&1, "lib/")) end)

    if lib_entries != [] and Enum.all?(lib_entries, &(&1.status == "D")) do
      {:reject, {:pure_deletion, Enum.flat_map(lib_entries, & &1.paths)}}
    else
      :ok
    end
  end

  # ── (d) mutation check ──────────────────────────────────────────────

  # NOTE (H9 scope boundary): this check is deliberately left on the raw exit
  # code. Its RED expectation is legitimately satisfied by a *compile* failure
  # (reverting `lib/` deletes the new rule module the new test references), so
  # "no ExUnit summary" is the normal case here, not a signal. Its reject
  # direction is already sound — `mix test` cannot exit 0 without having run —
  # so the only hole is a crashed runner reading as a spurious mutation PASS.
  # Closing that needs a different discriminator than the one this item is
  # evidence-backed for; see the residual-risk note in the H9 hand-off.
  defp check_mutation(clone, entries) do
    lib_files = added_or_modified(entries, "lib/")
    test_files = added_or_modified(entries, "test/")

    if test_files == [] do
      {:reject, :no_changed_test_to_mutate}
    else
      snapshot = snapshot_lib(clone, lib_files)
      revert_lib_to_head(clone, snapshot)
      exit_code = run_tests(clone, test_files)
      restore_lib(snapshot)
      git(clone, ["add", "-A"])

      if exit_code != 0 do
        Logger.info(
          "[Gate] mutation OK — changed test(s) RED without the rule (exit #{exit_code})"
        )

        :ok
      else
        {:reject, {:mutation_no_effect, test_files}}
      end
    end
  end

  @doc false
  def snapshot_lib(clone, lib_files) do
    Enum.map(lib_files, fn rel ->
      abs = Path.join(clone, rel)
      content = if File.exists?(abs), do: File.read!(abs), else: nil
      in_head? = tracked_in_head?(clone, rel)
      %{rel: rel, abs: abs, content: content, in_head?: in_head?}
    end)
  end

  defp revert_lib_to_head(clone, snapshot) do
    Enum.each(snapshot, fn f ->
      if f.in_head? do
        git(clone, ["checkout", "HEAD", "--", f.rel])
      else
        File.rm(f.abs)
      end
    end)
  end

  @doc false
  def restore_lib(snapshot) do
    Enum.each(snapshot, fn f ->
      if f.content, do: File.write!(f.abs, f.content)
    end)
  end

  # ── (a) full suite ──────────────────────────────────────────────────

  defp check_full_suite(clone, entries) do
    # Fail-fast: the corpus-free suite (all meta + cross-rule invariants —
    # DSL-safety, equivalence/fix/check-meta, scope-parity) catches every
    # non-corpus reject BEFORE the ~4-min over-firing corpus scan. A red here is
    # definitionally non-corpus → a plain `:full_suite_red`.
    case suite_phase(clone, :non_corpus) do
      {:did_not_run, out} ->
        {:reject, environmental(clone, :non_corpus, out)}

      {:red, _out} ->
        Logger.info("[Gate] corpus-free suite RED — rejecting before the corpus scan")
        {:reject, :full_suite_red}

      {:green, _out} ->
        check_corpus(clone, entries)
    end
  end

  # ── (a2) corpus, dispatched on the staged paths (docs/13 P3) ────────
  #
  # `Cev.Evolve.CorpusDispatch.plan/2` reads the staged diff and answers one of
  # three things. Its moduledoc carries the evidence for each; the short version:
  #
  #   :skip   — Syntax/Semantic only. Every corpus layer analyzes through
  #             `Credence.Pattern`, so nothing it looks at can have changed.
  #             150 of this harness's 155 committed candidates are this case.
  #   :scoped — exactly one Pattern rule + its own tests. `--only-rule` answers
  #             the over-firing question for it in ~12 s instead of 234 s, and
  #             a drift there is a reject we can book immediately.
  #   :full   — anything shared, anything multi-rule, anything unclear.
  defp check_corpus(clone, entries) do
    case CorpusDispatch.plan(entries, clone) do
      {:skip, why} ->
        Logger.info("[Gate] corpus phase SKIPPED — #{why}")
        :ok

      {:scoped, module, path} ->
        Logger.info("[Gate] corpus: rule-scoped pre-gate on #{inspect(module)} (#{path})")
        scoped_pre_gate(clone, module)

      {:full, why} ->
        Logger.info("[Gate] corpus: full scan — #{why}")
        full_corpus(clone)
    end
  end

  # The scoped scan answers ONE of the four corpus layers — over-firing. A DRIFT
  # there is that layer's assertion already red (same sweep, same identities,
  # same snapshot, restricted to one rule), so reject now: 12 s instead of 234 s
  # plus the ~3 min of re-runs `Corpus.classify_failure/1` would pay. Skipping
  # that classifier is sound here because the only thing it establishes beyond
  # what we already have is "the corpus-free suite is green", which phase 1 just
  # proved, and the drift is already attributed to this candidate's rule.
  #
  # A CLEAN scoped scan is not a clean corpus: fix-safety, scope-parity and
  # fix-breakage are untouched by it — and scope-parity fires hardest exactly on
  # a rule with zero findings (it flags a fix that rewrites code the check leaves
  # clean). So clean falls through to the full phase, as does inconclusive. The
  # fast path is an optimization, never the authority (docs/13 §5.1).
  defp scoped_pre_gate(clone, module) do
    case CorpusDispatch.scan(clone, module) do
      {:drift, %{new: new, gone: gone}} ->
        kind = if new != [], do: :over_fire, else: :narrowing

        Logger.warning(
          "[Gate] corpus scoped pre-gate DRIFT (#{kind}) for #{inspect(module)}: " <>
            "#{length(new)} new, #{length(gone)} gone — rejecting without the full phase"
        )

        detail = %{kind: kind, new: new, gone: gone, patch: staged_patch(clone)}
        {:reject, {:corpus, kind, detail}}

      {:clean, %{live: live, accepted: accepted}} ->
        Logger.info(
          "[Gate] corpus scoped pre-gate CLEAN (live=#{live} accepted=#{accepted}) — " <>
            "running the full phase for fix-safety / scope-parity / fix-breakage"
        )

        full_corpus(clone)

      {:inconclusive, detail} ->
        Logger.warning(
          "[Gate] corpus scoped pre-gate INCONCLUSIVE (#{inspect(detail.reason)}, " <>
            "exit #{detail.exit}) — falling back to the full corpus phase"
        )

        full_corpus(clone)
    end
  end

  # Phase 2 runs `--only corpus`, not the whole suite: the corpus-free half
  # already passed above, so re-running it is pure duplication. That
  # duplication used to cost ~13s (docs/13 P5); the suite has since grown to
  # ~120s non-corpus, so this now saves ~2 minutes per candidate — and it
  # makes the corpus phase separately timeable in the Gate log.
  #
  # It also turns the inference below into a fact. Before, "a full-suite red
  # IS the corpus" was reasoning from the previous phase having passed; now
  # only corpus tests ran, so a red here is a corpus red by construction.
  #
  # Capture the agent's diff BEFORE classification touches the snapshot, so a
  # corpus-only reject (over-fire to drop / narrowing to accept) is preserved
  # + re-appliable by the maintainer instead of silently discarded.
  defp full_corpus(clone) do
    case suite_phase(clone, :corpus) do
      {:did_not_run, out} ->
        {:reject, environmental(clone, :corpus, out)}

      {:red, _out} ->
        patch = staged_patch(clone)

        case Corpus.classify_failure(clone) do
          nil -> {:reject, :full_suite_red}
          detail -> {:reject, {:corpus, detail.kind, Map.put(detail, :patch, patch)}}
        end

      {:green, _out} ->
        Logger.info("[Gate] full suite GREEN")
        :ok
    end
  end

  # Run one suite phase, retrying while the run produces NO verdict. The retry is
  # what actually rescues the candidate: row 2's tree was green when its own
  # implementer ran the identical command 4 minutes earlier, so a second run
  # would very likely have committed the rule instead of discarding it.
  defp suite_phase(clone, phase, attempts_left \\ @suite_retries) do
    {verdict, out} = attempt(clone, phase)

    cond do
      verdict != :did_not_run ->
        {verdict, out}

      attempts_left > 0 ->
        Logger.warning(
          "[Gate] #{phase}: mix test exited non-zero but the suite NEVER RAN " <>
            "(no ExUnit `Finished in` line, no compile error) — environmental; retrying"
        )

        suite_phase(clone, phase, attempts_left - 1)

      true ->
        Logger.error(
          "[Gate] #{phase}: suite never ran on any attempt — environmental failure, " <>
            "NOT a verdict on the candidate"
        )

        {:did_not_run, out}
    end
  end

  defp attempt(clone, phase) do
    {code, out} = run_tests_traced(clone, [], phase_args(phase))
    {suite_verdict(code, out), out}
  end

  @doc false
  # Pure triage of ONE `mix test` invocation (exposed for tests — the whole
  # point of H9 is that this decision is testable without a live suite).
  #
  #   :green        — exit 0.
  #   :red          — non-zero AND the run produced a verdict: ExUnit finished,
  #                   or the tree failed to compile.
  #   :did_not_run  — non-zero with NO evidence the suite ever ran. The
  #                   environmental case (row 2: `:io.put_chars(:standard_error,
  #                   …) → :terminated` inside `Kernel.ParallelCompiler`, 0 tests
  #                   run, 4.7s against a ~2min baseline).
  @spec suite_verdict(integer(), binary()) :: :green | :red | :did_not_run
  def suite_verdict(0, _output), do: :green

  def suite_verdict(_code, output) do
    cond do
      Regex.match?(@suite_finished, output) -> :red
      Regex.match?(@compile_failed, output) -> :red
      true -> :did_not_run
    end
  end

  @doc false
  # The `mix test` arguments for each suite phase (also quoted back to the
  # maintainer in the environmental report, so the two cannot drift).
  def phase_args(:non_corpus), do: ["--exclude", "corpus"]
  def phase_args(:corpus), do: ["--only", "corpus"]

  # The candidate was never judged, so its diff is preserved rather than lost
  # with the tree — same principle as a corpus reject, different reason.
  defp environmental(clone, phase, out) do
    {:environmental, %{phase: phase, tail: tail(out), patch: staged_patch(clone)}}
  end

  defp tail(out) do
    if String.length(out) > @tail_chars,
      do: "…(truncated)…\n" <> String.slice(out, -@tail_chars, @tail_chars),
      else: out
  end

  @doc """
  Preserve a `{:environmental, detail}` Gate outcome for the maintainer and
  return a COMPACT reason (`{:environmental, phase}` — the patch and output tail
  stripped from the term so the ledger/row stat stay small).

  Writes `<index>.patch` (the candidate's staged diff, re-appliable) and
  `<index>.environmental.md` (what failed and how to re-judge it) into
  `logs/gate_environmental/`, where the row log is about to move. This is the
  whole point of the triage: the candidate had already passed the mutation gate
  and was never actually judged, so its work is kept rather than discarded.
  """
  @spec persist_environmental(term(), map()) :: {:environmental, atom()}
  def persist_environmental(index, %{phase: phase, tail: tail, patch: patch}) do
    dir = RowLog.outcome_path("gate_environmental")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "#{index}.patch"), patch)
    File.write!(Path.join(dir, "#{index}.environmental.md"), env_report(index, phase, tail))
    {:environmental, phase}
  end

  defp env_report(index, phase, tail) do
    """
    # Gate environmental failure — row #{index}

    Phase: **#{phase}** (`mix test #{Enum.join(phase_args(phase), " ")}`)

    `mix test` exited non-zero WITHOUT ever running the suite: no ExUnit
    `Finished in …` line and no `== Compilation error in file …` banner. That is
    a crashed test runner, not a verdict on the candidate — so the Gate did NOT
    book it as `:full_suite_red`. It re-ran the phase #{@suite_retries} more
    time(s) and the suite still never ran.

    The candidate had already passed the mutation gate, so its diff is preserved
    here as `#{index}.patch` instead of being discarded with the tree.

    ## To re-judge
        cd #{Config.credence_clone()}
        git apply #{Path.expand(Path.join(RowLog.outcome_path("gate_environmental"), "#{index}.patch"))}
        mix test --exclude corpus && mix test --only corpus

    ## Tail of the failing `mix test` output
    ```
    #{tail}
    ```
    """
  end

  defp staged_patch(clone) do
    {out, _code} = git(clone, ["diff", "--cached"])
    out
  end

  # ── Git / test helpers ──────────────────────────────────────────────

  # Exit code only — the mutation check reads nothing but RED/GREEN.
  defp run_tests(clone, files) do
    {code, _out} = run_tests_traced(clone, files, [])
    code
  end

  # Same invocation as `run_tests/3` but hands the captured output back, so a
  # phase can be triaged on what `mix test` actually printed rather than on the
  # exit code alone.
  defp run_tests_traced(clone, files, extra) do
    args = extra ++ files

    case Cev.MixTest.run(clone, args) do
      {:ok, code, out} ->
        Logger.debug("[Gate] mix test #{inspect(args)} exit=#{code}\n#{out}")
        {code, out}

      # A hung suite is environmental, not red. Returning a non-zero exit with no
      # ExUnit summary routes it through `suite_verdict/2` -> `:did_not_run` ->
      # `environmental/3`, which preserves the candidate's patch instead of
      # judging it on a suite that never finished.
      {:timeout, secs, out} ->
        Logger.warning("[Gate] mix test #{inspect(args)} exceeded #{secs}s — environmental")
        {124, out <> "\n[Gate] mix test exceeded the #{secs}s wall-clock cap and was killed.\n"}
    end
  end

  defp tracked_in_head?(clone, rel) do
    {_out, code} = git(clone, ["cat-file", "-e", "HEAD:" <> rel])
    code == 0
  end

  defp staged_entries(clone) do
    {out, _} = git(clone, ["diff", "--cached", "--name-status", "-z"])
    parse_name_status_z(out)
  end

  # `-z` output: records are NUL-separated; a rename/copy record is
  # status\0old\0new, others are status\0path.
  defp parse_name_status_z(out) do
    out
    |> String.split("\0", trim: true)
    |> consume([])
    |> Enum.reverse()
  end

  defp consume([], acc), do: acc

  defp consume([status | rest], acc) do
    letter = String.first(status)

    if letter in ["R", "C"] do
      [old, new | rest2] = rest
      consume(rest2, [%{status: letter, paths: [old, new]} | acc])
    else
      [path | rest2] = rest
      consume(rest2, [%{status: letter, paths: [path]} | acc])
    end
  end

  # Added/modified/renamed-new files under prefix that exist on disk (the
  # agent's version), as repo-relative paths.
  defp added_or_modified(entries, prefix) do
    Enum.flat_map(entries, fn e ->
      case e.status do
        s when s in ["A", "M"] -> Enum.filter(e.paths, &under?(&1, prefix))
        s when s in ["R", "C"] -> e.paths |> Enum.take(-1) |> Enum.filter(&under?(&1, prefix))
        _ -> []
      end
    end)
    |> Enum.uniq()
  end

  defp summarize(entries) do
    removes =
      Enum.flat_map(entries, fn
        %{status: "D", paths: [p]} -> if under?(p, "lib/"), do: [p], else: []
        %{status: "R", paths: [old, _new]} -> if under?(old, "lib/"), do: [old], else: []
        _ -> []
      end)

    %{entries: entries, removes: removes}
  end

  defp under?(path, prefix), do: String.starts_with?(path, prefix)

  defp git(clone, args) do
    System.cmd("git", args, cd: clone, stderr_to_stdout: true)
  end
end
