defmodule Cev.Evolve.GateTest do
  # `async: false` — the integration describe below puts a stub `mix` on the
  # VM-global PATH.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Cev.Evolve.Gate

  # ── Verbatim fixtures ─────────────────────────────────────────────────
  #
  # Every string below was lifted out of a real run log, not written by hand.
  # That matters: the discriminator has to hold on what `mix test` ACTUALLY
  # prints — under this project's own (non-default) ExUnit formatter, and on the
  # Elixir the clone actually runs.

  # var/run/logs/escalated/2.log, the `[Gate] mix test ["--exclude", "corpus"]
  # exit=1` block (excerpt — the 2nd..6th warning blocks elided). 4.7s, ZERO
  # tests run, and the Gate booked it `REJECT: :full_suite_red`, discarding a
  # candidate that had already passed the mutation gate.
  @row_2_crash ~S"""
  Compiling 1 file (.ex)
  Generated credence app
      warning: default values for the optional arguments in the private function fix/3 are never used
      │
   11 │   defp fix(source, message, line \\ 1) do
      │        ~
      │
      └─ test/semantic/fix_undefined_struct_in_pattern_fix_test.exs:11:8: Credence.Semantic.FixUndefinedStructInPatternFixTest (module)


  ** (ErlangError) Erlang error: :terminated
      (stdlib 7.3) io.erl:202: :io.put_chars(:standard_error, ["    warning: default values for the optional arguments in the private function fix/3 are never used\n    │\n 10 │   defp fix(source, message, line \\\\ 1) do\n    │        ~\n    │\n    └─ test/semantic/fix_raise_in_keyword_value_fix_test.exs:10:8: Credence.Semantic.FixRaiseInKeywordValueFixTest (module)", [], 10, 10])
      (elixir 1.19.5) src/elixir_errors.erl:86: :elixir_errors.print_diagnostic/2
      (elixir 1.19.5) lib/kernel/parallel_compiler.ex:829: Kernel.ParallelCompiler.wait_for_messages/8
      (elixir 1.19.5) lib/kernel/parallel_compiler.ex:342: Kernel.ParallelCompiler.spawn_workers/5
      (elixir 1.19.5) lib/kernel/parallel_compiler.ex:316: Kernel.ParallelCompiler.spawn_workers/3
      (mix 1.19.5) lib/mix/compilers/test.ex:88: Mix.Compilers.Test.require_and_run/3
      (mix 1.19.5) lib/mix/compilers/test.ex:35: Mix.Compilers.Test.require_and_run/4
      (mix 1.19.5) lib/mix/tasks/test.ex:680: Mix.Tasks.Test.do_run/3
      (mix 1.19.5) lib/mix/task.ex:499: anonymous fn/3 in Mix.Task.run_task/5
      (mix 1.19.5) lib/mix/cli.ex:129: Mix.CLI.run_task/2
      /home/kly/.asdf/installs/elixir/1.19.5-otp-28/bin/mix:7: (file)
      (elixir 1.19.5) lib/code.ex:1613: Code.require_file/2
  """

  # var/run/logs/committed/186.log — a real GREEN full suite in the clone
  # (Elixir 1.19.5, `Credence.QuietFormatter`).
  @green_1_19 """
  Finished in 534.2 seconds (487.4s async, 46.7s sync)
  6 properties, 7333 tests, 0 failures
  Randomized with seed 859057
  """

  # var/run/logs/committed/165.log — a real RED run in the clone.
  @red_1_19 """
  Finished in 0.05 seconds (0.00s async, 0.05s sync)
  9 tests, 9 failures
  """

  # Elixir 1.20's `ExUnit.CLIFormatter` (captured on 1.20.2). The counts line
  # changed shape completely between 1.19 and 1.20; `Finished in …` did not.
  # This is the case that would rot a `~r/\d+ tests, \d+ failures/` gate.
  @red_1_20 """
  Finished in 0.03 seconds (0.00s async, 0.03s sync)

  Result: 3/4 passed (1/1 doctest, 2/3 tests), 1 skipped
  Failed: 1 test
  """

  # var/run/logs/no_action/190.log — the tree did not compile. A real reject.
  @compile_error """

  == Compilation error in file test/solution_test.exs ==
  ** (UndefinedFunctionError) function AssertHelpers.__using__/1 is undefined or private
      (workspace 0.1.0) AssertHelpers.__using__([])
      test/solution_test.exs:3: (module)
      (elixir 1.19.5) lib/kernel/parallel_compiler.ex:648: Kernel.ParallelCompiler.require_file/2
  """

  describe "suite_verdict/2 — did the suite RUN?" do
    test "exit 0 is green" do
      assert Gate.suite_verdict(0, @green_1_19) == :green
    end

    test "non-zero WITH the ExUnit summary is a real red (Elixir 1.19 counts line)" do
      assert Gate.suite_verdict(2, @red_1_19) == :red
    end

    test "non-zero WITH the ExUnit summary is a real red (Elixir 1.20 `Result:` line)" do
      assert Gate.suite_verdict(2, @red_1_20) == :red
    end

    test "a green summary with a non-zero exit is still red — the exit code decides the verdict, the summary only proves there WAS one" do
      assert Gate.suite_verdict(1, @green_1_19) == :red
    end

    test "non-zero with a compile-error banner is a real red — a candidate whose code does not compile IS rejected" do
      assert Gate.suite_verdict(1, @compile_error) == :red
    end

    test "--warnings-as-errors is a compile failure, not an environmental one" do
      output = "Compilation failed due to warnings while using the --warnings-as-errors option\n"
      assert Gate.suite_verdict(1, output) == :red
    end

    test "`--only <tag>` matching nothing DID run — mix's own exit 1, but ExUnit finished" do
      output = """
      Including tags: [:corpus]

      All tests have been excluded.

      Finished in 0.01 seconds (0.00s async, 0.01s sync)
      Result: 0 tests, 4 excluded
      The --only option was given to "mix test" but no test was executed
      """

      assert Gate.suite_verdict(1, output) == :red
    end

    test "row 2 verbatim: non-zero, no summary, no compile error → the suite never ran" do
      refute @row_2_crash =~ "Finished in"
      refute @row_2_crash =~ "== Compilation error in file"
      assert Gate.suite_verdict(1, @row_2_crash) == :did_not_run
    end

    test "a killed runner (no output at all) never ran" do
      assert Gate.suite_verdict(137, "") == :did_not_run
    end
  end

  describe "phase_args/1" do
    test "the two suite phases, quoted back verbatim in the maintainer report" do
      assert Gate.phase_args(:non_corpus) == ["--exclude", "corpus"]
      assert Gate.phase_args(:corpus) == ["--only", "corpus"]
    end
  end

  # ── Integration: check/1 against a stub `mix` ──────────────────────────
  #
  # The pure verdict is only half the contract. These drive the real
  # `Gate.check/1` over a real (tiny) git tree with a stub `mix` on PATH, so the
  # retry, the reject shape and the preserved patch are exercised too.

  describe "check/1 suite-phase triage" do
    setup do
      root = Path.join(System.tmp_dir!(), "cev_gate_#{System.unique_integer([:positive])}")
      clone = Path.join(root, "clone")
      bin = Path.join(root, "bin")
      File.mkdir_p!(Path.join(clone, "lib"))
      File.mkdir_p!(Path.join(clone, "test"))
      File.mkdir_p!(bin)

      git = fn args -> System.cmd("git", args, cd: clone, stderr_to_stdout: true) end
      git.(["init", "-q", "."])
      git.(["config", "user.email", "gate@test"])
      git.(["config", "user.name", "gate"])
      File.write!(Path.join(clone, "lib/base.ex"), "defmodule Base0 do\nend\n")
      File.write!(Path.join(clone, "test/base_test.exs"), "# base\n")
      git.(["add", "-A"])
      git.(["commit", "-qm", "base"])

      # The agent's (uncommitted) candidate: one lib file + one test file.
      File.write!(Path.join(clone, "lib/new_rule.ex"), "defmodule NewRule do\nend\n")
      File.write!(Path.join(clone, "test/new_rule_test.exs"), "# new\n")

      calls = Path.join(root, "calls.txt")
      File.write!(calls, "")
      write_stub_mix(Path.join(bin, "mix"))

      # Keep the flake ledger out of the real repo: H19 appends to
      # `Config.run_path("flaky.jsonl")`, and a test that writes into var/run of
      # the checkout it is running in is not hermetic.
      prev_run_dir = Application.get_env(:cev, :run_dir)
      Application.put_env(:cev, :run_dir, Path.join(root, "var/run"))

      prev_path = System.get_env("PATH")
      System.put_env("PATH", bin <> ":" <> prev_path)
      System.put_env("GATE_STUB_CALLS", calls)
      System.put_env("GATE_STUB_CRASH", @row_2_crash)

      on_exit(fn ->
        if prev_run_dir,
          do: Application.put_env(:cev, :run_dir, prev_run_dir),
          else: Application.delete_env(:cev, :run_dir)

        System.put_env("PATH", prev_path)
        Enum.each(~w(GATE_STUB_CALLS GATE_STUB_CRASH GATE_STUB_MODE), &System.delete_env/1)
        File.rm_rf!(root)
      end)

      %{clone: clone, calls: calls}
    end

    # ── The two mutation-check rejects, which had no controls at all ──────
    #
    # Census of the 489 archived row logs of the 3rd evolution: `mutation OK`
    # appears in 179 of them and `mutation_no_effect` in exactly ONE, so this
    # check rejected 1 of 180 candidates. Neither of its reject atoms had a unit
    # test, so a 0.6% rejection rate was indistinguishable from a check that had
    # quietly stopped working. These are the controls it shipped without.

    test "a changed test that stays GREEN without its rule is rejected", ctx do
      # The stub answers 0 for the focused run regardless of the tree, so the
      # test passes with lib/ reverted — an assertion-free test, which is exactly
      # what this check exists to catch.
      System.put_env("GATE_STUB_MODE", "mutation_no_effect")

      capture_log(fn ->
        assert {:reject, {:mutation_no_effect, files}} = Gate.check(ctx.clone)
        assert "test/new_rule_test.exs" in files
      end)
    end

    # `:no_changed_test_to_mutate` is reachable only through a narrow gap, and
    # finding it is the reason this control was worth writing. `check_touches`
    # (which runs first) asks whether ANY staged path is under `test/`, counting
    # every git status; `check_mutation` asks for test files that were ADDED or
    # MODIFIED. A candidate that adds a rule and DELETES an existing test passes
    # the first and has nothing to mutate at the second.
    #
    # Removing the candidate's test file instead gives `:no_test_change` — which
    # is what my first attempt at this test asserted, and it was wrong.
    test "a candidate that only DELETES a test has nothing to mutate", ctx do
      File.rm!(Path.join(ctx.clone, "test/base_test.exs"))
      File.rm!(Path.join(ctx.clone, "test/new_rule_test.exs"))

      capture_log(fn ->
        assert {:reject, :no_changed_test_to_mutate} = Gate.check(ctx.clone)
      end)

      # The point of rejecting here is that it costs nothing: no suite is run.
      assert calls(ctx) == []
    end

    # And the near miss, so the two rejects cannot be confused: no test/ path at
    # all is a different atom, raised by a different check, one step earlier.
    test "a candidate with no test/ path at all is :no_test_change, not the mutation reject",
         ctx do
      File.rm!(Path.join(ctx.clone, "test/new_rule_test.exs"))

      capture_log(fn ->
        assert {:reject, :no_test_change} = Gate.check(ctx.clone)
      end)
    end

    test "a crashed runner on BOTH attempts is environmental, not :full_suite_red", ctx do
      System.put_env("GATE_STUB_MODE", "crash")

      log =
        capture_log(fn ->
          assert {:reject, {:environmental, detail}} = Gate.check(ctx.clone)
          assert detail.phase == :non_corpus
          # The candidate is NOT lost with the tree — its diff rides out.
          assert detail.patch =~ "+++ b/lib/new_rule.ex"
          assert detail.patch =~ "+++ b/test/new_rule_test.exs"
          assert detail.tail =~ "Erlang error: :terminated"
        end)

      assert log =~ "suite NEVER RAN"
      assert log =~ "ENVIRONMENTAL"
      refute log =~ "REJECT: :full_suite_red"

      # Mutation run + TWO corpus-free attempts, and the corpus phase is never
      # paid for.
      assert calls(ctx) == [
               "test test/new_rule_test.exs",
               "test test/new_rule_test.exs",
               "test test/new_rule_test.exs",
               "test --exclude corpus",
               "test --exclude corpus"
             ]

      assert clean?(ctx.clone)
    end

    test "a crash that clears on the retry SAVES the candidate — this is row 2", ctx do
      System.put_env("GATE_STUB_MODE", "flaky")

      capture_log(fn -> assert {:ok, _summary} = Gate.check(ctx.clone) end)

      assert calls(ctx) == [
               "test test/new_rule_test.exs",
               "test test/new_rule_test.exs",
               "test test/new_rule_test.exs",
               "test --exclude corpus",
               "test --exclude corpus",
               "test --only corpus"
             ]
    end

    test "a genuine red still rejects as :full_suite_red, with NO wasted retry", ctx do
      System.put_env("GATE_STUB_MODE", "red")

      log = capture_log(fn -> assert {:reject, :full_suite_red} = Gate.check(ctx.clone) end)

      assert log =~ "REJECT: :full_suite_red"
      refute log =~ "suite NEVER RAN"

      assert calls(ctx) == [
               # the mutation run, then H19's two stability runs
               "test test/new_rule_test.exs",
               "test test/new_rule_test.exs",
               "test test/new_rule_test.exs",
               "test --exclude corpus"
             ]

      assert clean?(ctx.clone)
    end

    # ── H19 / T4.7: a red suite is not automatically a verdict ──────────
    #
    # Live evidence for why: this harness's own suite went 325/326 then 326/326
    # in one session, with nothing changed between the runs.

    # ── H19's third half: the pre-commit stability re-run ──────────────
    #
    # The mutation check proves the candidate's tests go RED without the rule.
    # This proves they go GREEN twice WITH it. A test that passes once and fails
    # once must not be committed — and the flake triage above deliberately will
    # not forgive it later, because a failing file inside the staged diff is
    # never called a flake.

    test "a candidate whose own tests are unstable is rejected", ctx do
      System.put_env("GATE_STUB_MODE", "unstable_focused")

      log =
        capture_log(fn ->
          assert {:reject, {:unstable_tests, ["test/new_rule_test.exs"]}} = Gate.check(ctx.clone)
        end)

      assert log =~ "focused stability"
      assert log =~ "unstable, rejecting"
    end

    # ── sweep_scratch/1 ────────────────────────────────────────────────
    #
    # It deletes untracked files, which makes it the one destructive step that
    # runs before any check — and it had no test at all (T4.6's H5 residue).
    # What matters is not that it sweeps, but exactly what it must NOT sweep:
    # the candidate's own new rule and test are untracked too, and are the
    # entire point of the run.

    test "sweeps untracked scratch outside lib/ and test/, and keeps the candidate", ctx do
      scratch = Path.join(ctx.clone, "probe.exs")
      nested = Path.join(ctx.clone, "tmp/notes.md")
      File.mkdir_p!(Path.dirname(nested))
      File.write!(scratch, "IO.puts(:hi)\n")
      File.write!(nested, "scratch\n")

      capture_log(fn -> assert {:ok, _} = Gate.check(ctx.clone) end)

      refute File.exists?(scratch), "an untracked root scratch file should be swept"
      refute File.exists?(nested), "an untracked scratch file in any other dir should be swept"

      # The candidate is untracked too — sweeping it would delete the thing
      # being judged.
      assert File.exists?(Path.join(ctx.clone, "lib/new_rule.ex"))
      assert File.exists?(Path.join(ctx.clone, "test/new_rule_test.exs"))
    end

    test "CONTROL: sweeping leaves TRACKED files outside lib/ and test/ alone", ctx do
      readme = Path.join(ctx.clone, "README.md")
      File.write!(readme, "tracked\n")
      System.cmd("git", ["add", "README.md"], cd: ctx.clone, stderr_to_stdout: true)
      System.cmd("git", ["commit", "-qm", "readme"], cd: ctx.clone, stderr_to_stdout: true)

      capture_log(fn -> assert {:ok, _} = Gate.check(ctx.clone) end)

      assert File.exists?(readme), "a tracked file is not scratch — only --others is swept"
    end

    test "a red whose failing file is OUTSIDE the staged diff and passes on re-run PROCEEDS",
         ctx do
      System.put_env("GATE_STUB_MODE", "red_unstaged")

      log = capture_log(fn -> assert {:ok, _summary} = Gate.check(ctx.clone) end)

      assert log =~ "recording as flaky and PROCEEDING"
      assert log =~ "test/base_test.exs"
      refute log =~ "REJECT: :full_suite_red"

      # It re-ran only the failing file, then went on to the corpus phase.
      assert calls(ctx) == [
               "test test/new_rule_test.exs",
               "test test/new_rule_test.exs",
               "test test/new_rule_test.exs",
               "test --exclude corpus",
               "test --exclude corpus test/base_test.exs",
               "test --only corpus"
             ]
    end

    # The control that keeps the triage honest. The candidate TOUCHED this file,
    # so however cleanly it passes alone, a failure in the full suite is exactly
    # the interference a new rule causes — never a flake.
    test "CONTROL: a red whose failing file IS staged rejects, even though the re-run passes",
         ctx do
      System.put_env("GATE_STUB_MODE", "red_staged")

      log = capture_log(fn -> assert {:reject, :full_suite_red} = Gate.check(ctx.clone) end)

      assert log =~ "in the staged diff"
      refute log =~ "PROCEEDING"

      # And it does NOT pay for a re-run it already knows the answer to.
      assert calls(ctx) == [
               "test test/new_rule_test.exs",
               "test test/new_rule_test.exs",
               "test test/new_rule_test.exs",
               "test --exclude corpus"
             ]
    end

    test "CONTROL: a red that reproduces on re-run rejects", ctx do
      System.put_env("GATE_STUB_MODE", "red_persistent")

      log = capture_log(fn -> assert {:reject, :full_suite_red} = Gate.check(ctx.clone) end)

      assert log =~ "failed again on re-run"
      refute log =~ "PROCEEDING"
    end

    test "CONTROL: a red with no parseable failure location rejects without re-running", ctx do
      System.put_env("GATE_STUB_MODE", "red")

      log = capture_log(fn -> assert {:reject, :full_suite_red} = Gate.check(ctx.clone) end)

      assert log =~ "no failing file could be parsed"

      assert calls(ctx) == [
               "test test/new_rule_test.exs",
               "test test/new_rule_test.exs",
               "test test/new_rule_test.exs",
               "test --exclude corpus"
             ]
    end

    test "a crash in the CORPUS phase is environmental too, and names that phase", ctx do
      System.put_env("GATE_STUB_MODE", "corpus_crash")

      capture_log(fn ->
        assert {:reject, {:environmental, %{phase: :corpus}}} = Gate.check(ctx.clone)
      end)

      assert calls(ctx) == [
               "test test/new_rule_test.exs",
               "test test/new_rule_test.exs",
               "test test/new_rule_test.exs",
               "test --exclude corpus",
               "test --only corpus",
               "test --only corpus"
             ]
    end
  end

  describe "persist_environmental/2" do
    setup do
      run_dir = Path.join(System.tmp_dir!(), "cev_gate_run_#{System.unique_integer([:positive])}")
      prev = Application.get_env(:cev, :run_dir)
      Application.put_env(:cev, :run_dir, run_dir)
      Cev.RowLog.ensure_ready()

      on_exit(fn ->
        if prev,
          do: Application.put_env(:cev, :run_dir, prev),
          else: Application.delete_env(:cev, :run_dir)

        File.rm_rf!(run_dir)
      end)

      :ok
    end

    test "keeps the patch + a maintainer report and returns a compact reason" do
      detail = %{
        phase: :non_corpus,
        tail: "** (ErlangError) Erlang error: :terminated\n",
        patch: "diff --git a/lib/x.ex b/lib/x.ex\n"
      }

      assert Gate.persist_environmental(9, detail) == {:environmental, :non_corpus}

      dir = Cev.RowLog.outcome_path("gate_environmental")
      assert File.read!(Path.join(dir, "9.patch")) == detail.patch

      report = File.read!(Path.join(dir, "9.environmental.md"))
      assert report =~ "mix test --exclude corpus"
      assert report =~ "git apply"
      assert report =~ "Erlang error: :terminated"
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────

  defp calls(ctx), do: ctx.calls |> File.read!() |> String.split("\n", trim: true)

  defp clean?(clone) do
    {out, 0} = System.cmd("git", ["status", "--porcelain"], cd: clone)
    out == ""
  end

  # A stub `mix` whose behaviour is chosen by GATE_STUB_MODE. The mutation leg
  # (`mix test <file>`) is always a compile-error RED — which is what reverting
  # lib/ genuinely produces, and is why `check_mutation/2` is deliberately left
  # on the raw exit code.
  defp write_stub_mix(path) do
    File.write!(path, """
    #!/usr/bin/env bash
    echo "$@" >> "$GATE_STUB_CALLS"
    n=$(grep -c -- "--exclude corpus" "$GATE_STUB_CALLS")
    summary() { printf '\\nFinished in 1.0 seconds (0.5s async, 0.5s sync)\\n%s\\n' "$1"; }
    case "$*" in
      "test --exclude corpus")
        case "$GATE_STUB_MODE" in
          crash) printf '%s' "$GATE_STUB_CRASH"; exit 1 ;;
          flaky) if [ "$n" -ge 2 ]; then summary "7333 tests, 0 failures"; exit 0; fi
                 printf '%s' "$GATE_STUB_CRASH"; exit 1 ;;
          red)   summary "7333 tests, 1 failure"; exit 2 ;;
          red_unstaged) printf '\n  1) test something (BaseTest)\n     test/base_test.exs:12\n'
                 summary "7333 tests, 1 failure"; exit 2 ;;
          red_staged) printf '\n  1) test something (NewRuleTest)\n     test/new_rule_test.exs:3\n'
                 summary "7333 tests, 1 failure"; exit 2 ;;
          red_persistent) printf '\n  1) test something (BaseTest)\n     test/base_test.exs:12\n'
                 summary "7333 tests, 1 failure"; exit 2 ;;
          *)     summary "7333 tests, 0 failures"; exit 0 ;;
        esac ;;
      "test --exclude corpus test/base_test.exs")
        case "$GATE_STUB_MODE" in
          red_persistent) printf '\n  1) test something (BaseTest)\n     test/base_test.exs:12\n'
                 summary "1 test, 1 failure"; exit 2 ;;
          *)     summary "1 test, 0 failures"; exit 0 ;;
        esac ;;
      "test --exclude corpus test/new_rule_test.exs")
        summary "1 test, 0 failures"; exit 0 ;;
      "test --only corpus")
        case "$GATE_STUB_MODE" in
          corpus_crash) printf '%s' "$GATE_STUB_CRASH"; exit 1 ;;
          *)            summary "40 tests, 0 failures"; exit 0 ;;
        esac ;;
      *)
        # The mutation check reverts lib/ and re-runs the changed tests; a test
        # that stays GREEN without its rule proves nothing. This mode makes the
        # focused run answer 0 REGARDLESS of the tree, which is exactly the
        # assertion-free test `{:mutation_no_effect, _}` exists to reject.
        if [ "$GATE_STUB_MODE" = "mutation_no_effect" ]; then
          summary "2 tests, 0 failures"; exit 0
        fi
        # See the note in gate_corpus_dispatch_test.exs: the focused run answers
        # from the tree, because the mutation check reverts lib/ around it and
        # H19's stability re-run needs the restored (green) half.
        if [ "$GATE_STUB_MODE" = "unstable_focused" ] && grep -rqs defmodule lib/new_rule.ex; then
          # green then red on identical trees — the flake this gate exists for
          f=$(grep -c "^test test/new_rule_test.exs$" "$GATE_STUB_CALLS")
          if [ "$f" -ge 3 ]; then summary "2 tests, 1 failure"; exit 2; fi
          summary "2 tests, 0 failures"; exit 0
        fi
        if grep -rqs defmodule lib/new_rule.ex lib/pattern/no_uniq_then_count.ex; then
          summary "2 tests, 0 failures"; exit 0
        fi
        printf '\\n== Compilation error in file test/new_rule_test.exs ==\\n'
        printf '** (UndefinedFunctionError) function NewRule.go/0 is undefined\\n'
        exit 1 ;;
    esac
    """)

    File.chmod!(path, 0o755)
  end

  # The parser decides whether the triage runs at all: no parseable location
  # means a straight reject, so a false NEGATIVE here silently disables H19 and
  # a false POSITIVE re-runs the wrong files and calls a real failure flaky.
  describe "failing_files/1" do
    test "takes the distinct test files out of an ExUnit failure block" do
      out = """
        1) test a thing (FooTest)
           test/foo_test.exs:12
           Assertion with == failed

        2) test another (FooTest)
           test/foo_test.exs:40

        3) test elsewhere (BarTest)
           test/nested/bar_test.exs:7

      Finished in 1.0 seconds
      7333 tests, 3 failures
      """

      assert Gate.failing_files(out) == ["test/foo_test.exs", "test/nested/bar_test.exs"]
    end

    test "a green run yields nothing" do
      assert Gate.failing_files("Finished in 1.0 seconds\n7333 tests, 0 failures\n") == []
    end

    # Controls against the two ways this can be wrong. A `.ex` path is not a
    # test file, and a lib path mentioned in a stacktrace is not a failure
    # location — matching either would re-run files ExUnit cannot take.
    test "CONTROL: does not take lib paths or stacktrace lines" do
      out = """
        1) test a thing (FooTest)
           test/foo_test.exs:12
           stacktrace:
             (credence 0.8.1) lib/pattern/some_rule.ex:88: SomeRule.check/2
             test/support/rule_case.ex:31: Credence.RuleCase.fix/2
      """

      assert Gate.failing_files(out) == ["test/foo_test.exs"]
    end

    test "CONTROL: an unindented mention is not a failure location" do
      assert Gate.failing_files("test/foo_test.exs:12\n") == []
    end
  end

  # ── The corpus reject, driven end to end (T4.6/H5's original wording) ──
  #
  # `corpus_test.exs` unit-tests `Corpus.findings/diff`; nothing drove a corpus
  # DRIFT through `Gate.check/1` to see the reject shape the Router actually
  # receives. This does, using the real captured `--only-rule` stdout that
  # `corpus_dispatch_anchors_test.exs` already committed as a fixture — so the
  # parser under test is fed bytes credence really printed, not bytes a person
  # wrote to match the parser.

  describe "check/1 corpus phase" do
    @drift File.read!("test/fixtures/corpus_only_rule_drift.txt")
    @clean File.read!("test/fixtures/corpus_only_rule_clean.txt")

    setup do
      root = Path.join(System.tmp_dir!(), "cev_gate_corpus_#{System.unique_integer([:positive])}")
      clone = Path.join(root, "clone")
      bin = Path.join(root, "bin")
      File.mkdir_p!(Path.join(clone, "lib/pattern"))
      File.mkdir_p!(Path.join(clone, "test/pattern"))
      File.mkdir_p!(bin)

      git = fn args -> System.cmd("git", args, cd: clone, stderr_to_stdout: true) end
      git.(["init", "-q", "."])
      git.(["config", "user.email", "gate@test"])
      git.(["config", "user.name", "gate"])
      File.write!(Path.join(clone, "lib/base.ex"), "defmodule Base0 do\nend\n")
      git.(["add", "-A"])
      git.(["commit", "-qm", "base"])

      # A candidate shaped so CorpusDispatch.plan/2 answers :scoped — one
      # lib/pattern/ file declaring the behaviour, plus its own tests.
      File.write!(
        Path.join(clone, "lib/pattern/no_uniq_then_count.ex"),
        "defmodule Credence.Pattern.NoUniqThenCount do\n  use Credence.Pattern.Rule\nend\n"
      )

      File.write!(Path.join(clone, "test/pattern/no_uniq_then_count_test.exs"), "# new\n")

      calls = Path.join(root, "calls.txt")
      File.write!(calls, "")
      write_corpus_stub_mix(Path.join(bin, "mix"))

      prev_run_dir = Application.get_env(:cev, :run_dir)
      Application.put_env(:cev, :run_dir, Path.join(root, "var/run"))
      prev_path = System.get_env("PATH")
      System.put_env("PATH", bin <> ":" <> prev_path)
      System.put_env("GATE_STUB_CALLS", calls)
      System.put_env("GATE_STUB_CORPUS_DRIFT", @drift)
      System.put_env("GATE_STUB_CORPUS_CLEAN", @clean)

      on_exit(fn ->
        if prev_run_dir,
          do: Application.put_env(:cev, :run_dir, prev_run_dir),
          else: Application.delete_env(:cev, :run_dir)

        System.put_env("PATH", prev_path)

        Enum.each(
          ~w(GATE_STUB_CALLS GATE_STUB_MODE GATE_STUB_CORPUS_DRIFT GATE_STUB_CORPUS_CLEAN),
          &System.delete_env/1
        )

        File.rm_rf!(root)
      end)

      %{clone: clone, calls: calls}
    end

    test "a scoped over-fire DRIFT rejects with the finding attached, before the full scan",
         ctx do
      System.put_env("GATE_STUB_MODE", "corpus_drift")

      log =
        capture_log(fn ->
          assert {:reject, {:corpus, :over_fire, detail}} = Gate.check(ctx.clone)

          # The reject carries the evidence the Router books, not just an atom.
          assert detail.new != []
          assert Enum.any?(detail.new, &String.contains?(&1, "archethic"))
          assert detail.gone == []
          # And the candidate's patch rides out with it.
          assert detail.patch =~ "+++ b/lib/pattern/no_uniq_then_count.ex"
        end)

      assert log =~ "DRIFT (over_fire)"

      # The whole point of the scoped pre-gate: the 234 s full scan never runs.
      refute Enum.any?(calls(ctx), &(&1 == "test --only corpus"))
    end

    # The task's contract is exit 0 + RESULT=clean, or non-zero + RESULT=drift.
    # A stub that printed drift and exited 0 was how this test first failed, and
    # believing that combination is exactly the mutant T2.1's controls kill — so
    # pin it: a drift claim on a zero exit is INCONCLUSIVE, never a reject, and
    # inconclusive falls through to the full scan rather than forgiving anything.
    test "CONTROL: RESULT=drift on a ZERO exit is not believed", ctx do
      System.put_env("GATE_STUB_MODE", "corpus_drift_exit0")

      capture_log(fn -> assert {:ok, _summary} = Gate.check(ctx.clone) end)

      assert "test --only corpus" in calls(ctx)
    end

    test "CONTROL: a clean scoped scan does NOT stop there — it falls through to the full phase",
         ctx do
      System.put_env("GATE_STUB_MODE", "corpus_clean")

      capture_log(fn -> assert {:ok, _summary} = Gate.check(ctx.clone) end)

      # Clean scoped is an optimization, never the authority: fix-safety,
      # scope-parity and fix-breakage are untouched by --only-rule, and
      # scope-parity fires hardest on a rule with zero findings.
      assert "test --only corpus" in calls(ctx)
    end
  end

  defp write_corpus_stub_mix(path) do
    File.write!(path, """
    #!/usr/bin/env bash
    echo "$@" >> "$GATE_STUB_CALLS"
    summary() { printf '\\nFinished in 1.0 seconds (0.5s async, 0.5s sync)\\n%s\\n' "$1"; }
    case "$*" in
      "credence.corpus --only-rule"*)
        case "$GATE_STUB_MODE" in
          corpus_drift) printf '%s' "$GATE_STUB_CORPUS_DRIFT"; exit 1 ;;
          corpus_drift_exit0) printf '%s' "$GATE_STUB_CORPUS_DRIFT"; exit 0 ;;
          *)            printf '%s' "$GATE_STUB_CORPUS_CLEAN"; exit 0 ;;
        esac ;;
      "test --exclude corpus") summary "7333 tests, 0 failures"; exit 0 ;;
      "test --only corpus")    summary "40 tests, 0 failures"; exit 0 ;;
      *)
        # The focused run answers from the TREE: red while the mutation check has
        # lib/ reverted, green once it is restored. H19's stability re-run needs
        # the green half, and a constant cannot give both.
        if grep -rqs defmodule lib/pattern/no_uniq_then_count.ex; then
          summary "2 tests, 0 failures"; exit 0
        fi
        summary "1 test, 1 failure"; exit 2 ;;
    esac
    """)

    File.chmod!(path, 0o755)
  end
end
