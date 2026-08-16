defmodule Cev.BugfixEvidenceTest do
  use ExUnit.Case, async: true

  alias Cev.Classify.Parser

  @moduledoc """
  docs/22 T4.2 — evidence gates on the BUGFIX lane.

  Both of these cost a full implementer run to discover, which is the point:
  they are cheap to check at classify time and expensive to find later.
  """

  # The marker-fenced contract the classifier must emit.
  defp spec_text(fields) do
    Enum.map_join(fields, "\n", fn {k, v} -> "===#{k}===\n#{v}" end) <> "\n===END==="
  end

  describe "a section filled with a markdown rule is empty, not content" do
    test "=== is not a BEFORE" do
      {:ok, spec} =
        Parser.parse(
          spec_text([
            {"DECISION", "NO_ACTION"},
            {"RATIONALE", "nothing to do"},
            {"BEFORE", "==="}
          ])
        )

      assert spec.before == nil
    end

    test "--- and blank-ish bodies are empty too" do
      for filler <- ["---", "___", "***", "  ", "-- --"] do
        {:ok, spec} =
          Parser.parse(
            spec_text([{"DECISION", "NO_ACTION"}, {"RATIONALE", "x"}, {"BEFORE", filler}])
          )

        assert spec.before == nil, "#{inspect(filler)} should read as an empty section"
      end
    end

    # The control. If the rule were "drop anything short" or "drop anything with
    # punctuation", real code would start vanishing — and a silently dropped
    # BEFORE is worse than a `===` one, because nothing downstream complains.
    test "CONTROL: real code containing = is kept" do
      {:ok, spec} =
        Parser.parse(
          spec_text([
            {"DECISION", "NO_ACTION"},
            {"RATIONALE", "x"},
            {"BEFORE", "x = 1"}
          ])
        )

      assert spec.before == "x = 1"
    end

    test "CONTROL: an equality comparison survives" do
      {:ok, spec} =
        Parser.parse(
          spec_text([{"DECISION", "NO_ACTION"}, {"RATIONALE", "x"}, {"BEFORE", "a == b"}])
        )

      assert spec.before == "a == b"
    end
  end

  describe "a BUGFIX whose BEFORE and AFTER are identical describes no change" do
    setup do
      Cev.Credence.put_assumptions([
        %{name: :single_codepoint_graphemes, default: true, summary: "x"}
      ])

      :ok
    end

    defp llm_returning(text), do: fn _u, _s -> {:ok, text, %{}} end

    defp bugfix_out(before_src, after_src) do
      """
      ===DECISION===
      BUGFIX_RULE
      ===RULE_NAME===
      Credence.Pattern.NoThing
      ===RATIONALE===
      it over-fires
      ===BEFORE===
      #{before_src}
      ===AFTER===
      #{after_src}
      ===END===
      """
    end

    test "identical BEFORE and AFTER is rejected" do
      out = bugfix_out("x = 1", "x = 1")

      assert {:error, {:classifier_errors, reason, _}} =
               Cev.Classify.run("log", :solved,
                 llm: llm_returning(out),
                 closed_set: [Credence.Pattern.NoThing],
                 ledger: ""
               )

      assert reason == :bugfix_before_equals_after
    end

    # The control: the gate must not reject every BUGFIX, only the empty ones.
    # It is rejected here for the closed-set reason instead, which proves the
    # before/after check let it through.
    test "CONTROL: a BUGFIX with a real change is not rejected for this reason" do
      out = bugfix_out("x = 1", "x = 2")

      assert {:error, {:classifier_errors, reason, _}} =
               Cev.Classify.run("log", :solved,
                 llm: llm_returning(out),
                 closed_set: [],
                 ledger: ""
               )

      refute reason == :bugfix_before_equals_after
    end
  end

  # ────────────────────────────────────────────────────────────────────────
  # T4.2d — the repro must actually make the accused rule fire.
  #
  # A BUGFIX report names one rule and one snippet. If the rule does not engage
  # with the snippet, the report is not about that rule, and without this gate
  # the row costs a full implementer run to find out. Ledger rows 40, 50 and 59
  # were live over-fires the harness talked itself out of exactly here.
  #
  # The probe is injected rather than shelled, so every branch is drivable
  # without a built clone — a gate nobody can drive is a gate nobody has seen
  # red.
  # ────────────────────────────────────────────────────────────────────────

  describe "T4.2d — repro validation against the accused rule" do
    alias Cev.Classify.Spec

    # A one-file clone, so the resolvability gate ahead of ours is satisfied by
    # something real rather than stubbed past.
    setup do
      clone = Path.join(System.tmp_dir!(), "fires_clone_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(clone, "lib/pattern"))

      File.write!(
        Path.join(clone, "lib/pattern/no_manual_max.ex"),
        "defmodule Credence.Pattern.NoManualMax do\nend\n"
      )

      on_exit(fn -> File.rm_rf(clone) end)
      %{clone: clone}
    end

    defp ctx(fires_verdict, clone) do
      %{
        offered: ["BUGFIX_RULE"],
        closed: [Credence.Pattern.NoManualMax],
        assumption_names: [],
        clone: clone,
        fires: fn _rule, _src, _clone -> fires_verdict end
      }
    end

    defp bugfix(before) do
      %Spec{
        decision: :bugfix_rule,
        rule_name: Credence.Pattern.NoManualMax,
        before: before,
        after: "defmodule M do\n  def f(l), do: Enum.max(l)\nend\n",
        rationale: "over-fires"
      }
    end

    test "an INERT repro fails the row", %{clone: clone} do
      assert {:error, {:bugfix_repro_does_not_fire, Credence.Pattern.NoManualMax}} =
               Cev.Classify.validate(
                 bugfix("defmodule M do\n  def f, do: :ok\nend\n"),
                 ctx(:inert, clone)
               )
    end

    test "a FIRES repro passes", %{clone: clone} do
      assert :ok =
               Cev.Classify.validate(
                 bugfix("defmodule M do\n  def f, do: :ok\nend\n"),
                 ctx(:fires, clone)
               )
    end

    # The inversion this gate must not commit. `:unknown` means the question
    # could not be asked — no such rule, the pipeline raised, the shell-out
    # died. Failing on it would reject correct rows for the checker's own
    # limitations, which is the bug `Cev.Premise` is written around.
    test "CONTROL: :unknown passes — we could not tell is never refuted", %{clone: clone} do
      assert :ok =
               Cev.Classify.validate(
                 bugfix("defmodule M do\n  def f, do: :ok\nend\n"),
                 ctx(:unknown, clone)
               )
    end

    # Without this, every row whose BEFORE the model left out would shell out
    # and then fail on a snippet that was never offered as evidence.
    test "CONTROL: no BEFORE is not this gate's business", %{clone: clone} do
      spec = %{bugfix(nil) | before: nil}
      assert :ok = Cev.Classify.validate(spec, ctx(:inert, clone))
    end

    test "CONTROL: a blank BEFORE likewise", %{clone: clone} do
      assert :ok = Cev.Classify.validate(bugfix("   \n  "), ctx(:inert, clone))
    end

    # Ordering control: the earlier gates must still own their errors, so a row
    # that is wrong for two reasons reports the cheaper one.
    test "CONTROL: before == after still reports T4.2a, not this gate", %{clone: clone} do
      same = "defmodule M do\n  def f, do: :ok\nend\n"
      spec = %{bugfix(same) | after: same}

      assert {:error, :bugfix_before_equals_after} =
               Cev.Classify.validate(spec, ctx(:inert, clone))
    end
  end
end
