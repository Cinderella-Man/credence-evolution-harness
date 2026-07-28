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

      prev_path = System.get_env("PATH")
      System.put_env("PATH", bin <> ":" <> prev_path)
      System.put_env("GATE_STUB_CALLS", calls)
      System.put_env("GATE_STUB_CRASH", @row_2_crash)

      on_exit(fn ->
        System.put_env("PATH", prev_path)
        Enum.each(~w(GATE_STUB_CALLS GATE_STUB_CRASH GATE_STUB_MODE), &System.delete_env/1)
        File.rm_rf!(root)
      end)

      %{clone: clone, calls: calls}
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
      assert calls(ctx) == ["test test/new_rule_test.exs", "test --exclude corpus"]
      assert clean?(ctx.clone)
    end

    test "a crash in the CORPUS phase is environmental too, and names that phase", ctx do
      System.put_env("GATE_STUB_MODE", "corpus_crash")

      capture_log(fn ->
        assert {:reject, {:environmental, %{phase: :corpus}}} = Gate.check(ctx.clone)
      end)

      assert calls(ctx) == [
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
          *)     summary "7333 tests, 0 failures"; exit 0 ;;
        esac ;;
      "test --only corpus")
        case "$GATE_STUB_MODE" in
          corpus_crash) printf '%s' "$GATE_STUB_CRASH"; exit 1 ;;
          *)            summary "40 tests, 0 failures"; exit 0 ;;
        esac ;;
      *)
        printf '\\n== Compilation error in file test/new_rule_test.exs ==\\n'
        printf '** (UndefinedFunctionError) function NewRule.go/0 is undefined\\n'
        exit 1 ;;
    esac
    """)

    File.chmod!(path, 0o755)
  end
end
