defmodule Cev.Evolve.GateCorpusDispatchTest do
  @moduledoc """
  Integration cover for the Gate's phase-2 dispatch (docs/13 P3, harness half).

  These drive the real `Gate.check/1` over a real (tiny) git tree with a stub
  `mix` on PATH, in the same style as `Cev.Evolve.GateTest`'s
  `"check/1 suite-phase triage"` describe — the assertion that matters in every
  case is the exact `calls` transcript, because the whole change is about which
  commands the Gate does and does not pay for.

  **Apply together with the `check_corpus/2` / `scoped_pre_gate/2` /
  `full_corpus/1` change to `lib/cev/evolve/gate.ex`.** Without it, every test
  here fails on the `calls` transcript (the Gate would run `test --only corpus`
  unconditionally) — which is the positive control for the whole item.
  """
  # `async: false` — puts a stub `mix` on the VM-global PATH.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Cev.Evolve.Gate

  setup do
    root = Path.join(System.tmp_dir!(), "cev_gate_disp_#{System.unique_integer([:positive])}")
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

    calls = Path.join(root, "calls.txt")
    File.write!(calls, "")
    write_stub_mix(Path.join(bin, "mix"))

    prev_path = System.get_env("PATH")
    System.put_env("PATH", bin <> ":" <> prev_path)
    System.put_env("GATE_STUB_CALLS", calls)

    on_exit(fn ->
      System.put_env("PATH", prev_path)
      Enum.each(~w(GATE_STUB_CALLS GATE_STUB_ONLY_RULE), &System.delete_env/1)
      File.rm_rf!(root)
    end)

    %{clone: clone, calls: calls}
  end

  describe "phase 2 dispatch — Syntax/Semantic candidates" do
    test "a Semantic rule + its tests never pays for the corpus phase", ctx do
      stage_semantic_rule(ctx.clone)

      log = capture_log(fn -> assert {:ok, _} = Gate.check(ctx.clone) end)

      assert log =~ "corpus phase SKIPPED"
      assert log =~ "Pattern-only"

      # The `test --only corpus` line is simply absent — 234 s not paid.
      assert calls(ctx) == [
               "test test/semantic/fix_thing_check_test.exs test/semantic/fix_thing_fix_test.exs",
               "test --exclude corpus"
             ]
    end

    test "a Semantic rule that also edits a shared lib/ file DOES pay", ctx do
      stage_semantic_rule(ctx.clone)
      File.write!(Path.join(ctx.clone, "lib/rule_helpers.ex"), "defmodule RH do\nend\n")

      log = capture_log(fn -> assert {:ok, _} = Gate.check(ctx.clone) end)

      assert log =~ "corpus: full scan"
      assert "test --only corpus" in calls(ctx)
    end
  end

  describe "phase 2 dispatch — one Pattern rule (scoped pre-gate)" do
    test "a clean scoped scan STILL runs the full phase — it covers over-firing only",
         ctx do
      stage_pattern_rule(ctx.clone)
      System.put_env("GATE_STUB_ONLY_RULE", "clean")

      log = capture_log(fn -> assert {:ok, _} = Gate.check(ctx.clone) end)

      assert log =~ "rule-scoped pre-gate on Credence.Pattern.NoThing"
      assert log =~ "CLEAN (live=0 accepted=0)"
      assert log =~ "fix-safety / scope-parity / fix-breakage"

      assert calls(ctx) == [
               "test test/pattern/no_thing_check_test.exs test/pattern/no_thing_fix_test.exs",
               "test --exclude corpus",
               "credence.corpus --only-rule Credence.Pattern.NoThing",
               "test --only corpus"
             ]
    end

    test "a scoped DRIFT rejects immediately — no full phase, no classifier re-runs", ctx do
      stage_pattern_rule(ctx.clone)
      System.put_env("GATE_STUB_ONLY_RULE", "drift")

      log =
        capture_log(fn ->
          assert {:reject, {:corpus, :over_fire, detail}} = Gate.check(ctx.clone)
          assert detail.new == ["jason/lib/codegen.ex:42  no_thing"]
          assert detail.gone == []
          # The candidate's diff rides out for the maintainer, as on the slow path.
          assert detail.patch =~ "+++ b/lib/pattern/no_thing.ex"
        end)

      assert log =~ "scoped pre-gate DRIFT (over_fire)"
      assert log =~ "REJECT: corpus over_fire (1 new, 0 gone)"

      # No `test --only corpus`, and — critically — no second
      # `test --exclude corpus` from `Corpus.classify_failure/1`, and no
      # `credence.corpus --update-snapshot`.
      assert calls(ctx) == [
               "test test/pattern/no_thing_check_test.exs test/pattern/no_thing_fix_test.exs",
               "test --exclude corpus",
               "credence.corpus --only-rule Credence.Pattern.NoThing"
             ]
    end

    test "a scoped GONE-only drift is booked as a narrowing", ctx do
      stage_pattern_rule(ctx.clone)
      System.put_env("GATE_STUB_ONLY_RULE", "narrowing")

      capture_log(fn ->
        assert {:reject, {:corpus, :narrowing, detail}} = Gate.check(ctx.clone)
        assert detail.new == []
        assert detail.gone == ["postgrex/lib/postgrex/types.ex:88  no_thing"]
      end)
    end

    test "an unusable scoped scan falls back to the full phase, loudly", ctx do
      stage_pattern_rule(ctx.clone)
      System.put_env("GATE_STUB_ONLY_RULE", "broken")

      log = capture_log(fn -> assert {:ok, _} = Gate.check(ctx.clone) end)

      assert log =~ "scoped pre-gate INCONCLUSIVE"
      assert log =~ ":no_result_line"

      assert calls(ctx) == [
               "test test/pattern/no_thing_check_test.exs test/pattern/no_thing_fix_test.exs",
               "test --exclude corpus",
               "credence.corpus --only-rule Credence.Pattern.NoThing",
               "test --only corpus"
             ]
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────

  defp stage_semantic_rule(clone) do
    File.mkdir_p!(Path.join(clone, "lib/semantic"))
    File.mkdir_p!(Path.join(clone, "test/semantic"))

    File.write!(Path.join(clone, "lib/semantic/fix_thing.ex"), """
    defmodule Credence.Semantic.FixThing do
      use Credence.Semantic.Rule
    end
    """)

    File.write!(Path.join(clone, "test/semantic/fix_thing_check_test.exs"), "# check\n")
    File.write!(Path.join(clone, "test/semantic/fix_thing_fix_test.exs"), "# fix\n")
  end

  defp stage_pattern_rule(clone) do
    File.mkdir_p!(Path.join(clone, "lib/pattern"))
    File.mkdir_p!(Path.join(clone, "test/pattern"))

    File.write!(Path.join(clone, "lib/pattern/no_thing.ex"), """
    defmodule Credence.Pattern.NoThing do
      use Credence.Pattern.Rule
    end
    """)

    File.write!(Path.join(clone, "test/pattern/no_thing_check_test.exs"), "# check\n")
    File.write!(Path.join(clone, "test/pattern/no_thing_fix_test.exs"), "# fix\n")
  end

  defp calls(ctx), do: ctx.calls |> File.read!() |> String.split("\n", trim: true)

  # A stub `mix` covering the three commands the Gate can now issue. The suite
  # phases are always green; the `credence.corpus --only-rule` reply is chosen by
  # GATE_STUB_ONLY_RULE and reproduces the task's real output format verbatim
  # (credence lib/mix/tasks/credence.corpus.ex, `report_only_rule/1`).
  defp write_stub_mix(path) do
    File.write!(path, """
    #!/usr/bin/env bash
    echo "$@" >> "$GATE_STUB_CALLS"
    summary() { printf '\\nFinished in 1.0 seconds (0.5s async, 0.5s sync)\\n%s\\n' "$1"; }
    case "$1 $2" in
      "test --exclude") summary "7333 tests, 0 failures"; exit 0 ;;
      "test --only")    summary "40 tests, 0 failures"; exit 0 ;;
      "credence.corpus --only-rule")
        printf '\\n[only-rule] no_thing — scanned 20076 file(s) across 2008 corpus entries in 11.6s\\n'
        case "$GATE_STUB_ONLY_RULE" in
          clean)
            printf '[only-rule] RESULT=clean rule=no_thing live=0 accepted=0\\n'
            exit 0 ;;
          drift)
            printf '\\nNEW — not previously accepted (a candidate OVER-FIRE — investigate!):\\n'
            printf '  • jason/lib/codegen.ex:42  no_thing\\n'
            printf '        41 |   defp escape(data) do\\n'
            printf '      > 42 |     data |> Enum.uniq() |> length()\\n'
            printf '        43 |   end\\n'
            printf '\\nGONE — pinned but no longer firing (a rule narrowed / was removed):\\n'
            printf '  (none)\\n'
            printf '\\n[only-rule] RESULT=drift rule=no_thing live=1 accepted=0 new=1 gone=0\\n'
            printf '** (Mix.Error) corpus drift for no_thing: 1 new, 0 gone.\\n'
            exit 1 ;;
          narrowing)
            printf '\\nNEW — not previously accepted (a candidate OVER-FIRE — investigate!):\\n'
            printf '  (none)\\n'
            printf '\\nGONE — pinned but no longer firing (a rule narrowed / was removed):\\n'
            printf '  postgrex/lib/postgrex/types.ex:88  no_thing\\n'
            printf '\\n[only-rule] RESULT=drift rule=no_thing live=0 accepted=1 new=0 gone=1\\n'
            exit 1 ;;
          *)
            printf '** (Mix.Error) unknown Pattern rule "no_thing".\\n'
            exit 1 ;;
        esac ;;
      *)
        printf '\\n== Compilation error in file test/x_test.exs ==\\n'
        exit 1 ;;
    esac
    """)

    File.chmod!(path, 0o755)
  end
end
