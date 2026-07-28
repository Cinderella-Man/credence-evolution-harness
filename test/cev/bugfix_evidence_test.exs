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
end
