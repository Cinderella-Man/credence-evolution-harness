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
                                   phases. FIRST `mix test --exclude corpus` (~15s):
                                   all meta + cross-rule invariants (DSL-safety,
                                   equivalence/fix/check-meta, scope-parity) — a red
                                   here is a plain `:full_suite_red`, rejected
                                   WITHOUT paying the corpus. ONLY if that is green
                                   do we run the full `mix test` (~8 min), which adds
                                   Credence's real-world over-firing corpus (a
                                   snapshot ratchet, `../credence/docs/09`), so a
                                   rule that over-fires on idiomatic real code is
                                   rejected here for free. Non-corpus already passed,
                                   so a full-suite red IS the corpus:
                                   `Cev.Evolve.Corpus.classify_failure/1` tags it
                                   `{:corpus, :over_fire|:narrowing, …}` and the
                                   caller preserves the patch + a drop-or-accept report.

  Renames / supersession-with-replacement (delete+add) pass: the *add* side
  touches `lib/` + `test/` and the mutation check runs on the new test.
  **Standalone pure deletion is rejected + escalated** — removing a rule is a
  human-only decision.

  Returns `{:ok, summary}` (caller commits) or `{:reject, reason}` (Gate has
  already discarded the working tree via `reset --hard HEAD` + `clean -fd`).
  """

  require Logger

  alias Cev.Config
  alias Cev.Evolve.Corpus

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
         :ok <- check_full_suite(clone) do
      {:ok, summarize(entries)}
    else
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

  defp check_touches(entries, prefix, reason) do
    if Enum.any?(entries, fn e -> Enum.any?(e.paths, &under?(&1, prefix)) end),
      do: :ok,
      else: {:reject, reason}
  end

  # ── (e) scope: only lib/ and test/ ──────────────────────────────────

  defp check_scope(entries) do
    offending =
      entries
      |> Enum.flat_map(& &1.paths)
      |> Enum.reject(&(under?(&1, "lib/") or under?(&1, "test/")))

    if offending == [], do: :ok, else: {:reject, {:scope, offending}}
  end

  # ── pure-deletion guard ─────────────────────────────────────────────

  defp check_not_pure_deletion(entries) do
    lib_entries = Enum.filter(entries, fn e -> Enum.any?(e.paths, &under?(&1, "lib/")) end)

    if lib_entries != [] and Enum.all?(lib_entries, &(&1.status == "D")) do
      {:reject, {:pure_deletion, Enum.flat_map(lib_entries, & &1.paths)}}
    else
      :ok
    end
  end

  # ── (d) mutation check ──────────────────────────────────────────────

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
        Logger.info("[Gate] mutation OK — changed test(s) RED without the rule (exit #{exit_code})")
        :ok
      else
        {:reject, {:mutation_no_effect, test_files}}
      end
    end
  end

  defp snapshot_lib(clone, lib_files) do
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

  defp restore_lib(snapshot) do
    Enum.each(snapshot, fn f ->
      if f.content, do: File.write!(f.abs, f.content)
    end)
  end

  # ── (a) full suite ──────────────────────────────────────────────────

  defp check_full_suite(clone) do
    cond do
      # Fail-fast: the corpus-free suite (all meta + cross-rule invariants —
      # DSL-safety, equivalence/fix/check-meta, scope-parity) runs in ~15s and
      # catches every non-corpus reject BEFORE the ~8-min over-firing corpus scan.
      # A red here is definitionally non-corpus → a plain `:full_suite_red`.
      run_tests(clone, [], ["--exclude", "corpus"]) != 0 ->
        Logger.info("[Gate] corpus-free suite RED — rejecting before the corpus scan")
        {:reject, :full_suite_red}

      # Non-corpus already passed, so a full-suite red is the corpus layer. Capture
      # the agent's diff BEFORE classification touches the snapshot, so a corpus-only
      # reject (over-fire to drop / narrowing to accept) is preserved + re-appliable
      # by the maintainer instead of silently discarded.
      run_tests(clone, []) != 0 ->
        patch = staged_patch(clone)

        case Corpus.classify_failure(clone) do
          nil -> {:reject, :full_suite_red}
          detail -> {:reject, {:corpus, detail.kind, Map.put(detail, :patch, patch)}}
        end

      true ->
        Logger.info("[Gate] full suite GREEN")
        :ok
    end
  end

  defp staged_patch(clone) do
    {out, _code} = git(clone, ["diff", "--cached"])
    out
  end

  # ── Git / test helpers ──────────────────────────────────────────────

  defp run_tests(clone, files, extra \\ []) do
    args = extra ++ files

    {out, code} =
      System.cmd("mix", ["test" | args],
        cd: clone,
        stderr_to_stdout: true,
        env: [{"MIX_ENV", "test"}]
      )

    Logger.debug("[Gate] mix test #{inspect(args)} exit=#{code}\n#{out}")
    code
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
