defmodule Cev.LogPlumbingTest do
  use ExUnit.Case, async: true

  alias Cev.{AppliedRules, Distill, RulePaths}

  describe "Distill.distill/1" do
    test "drops everything above the SOLVE_BOUNDARY sentinel" do
      log = """
      python source here
      translate output
      reference solution
      ===SOLVE_BOUNDARY===
      [Solve attempt 1] generating
      APPLIED_RULES: [{Credence.Pattern.Foo, 1}]
      """

      out = Distill.distill(log)
      refute out =~ "reference solution"
      refute out =~ "python source"
      assert out =~ "[Solve attempt 1]"
      assert out =~ "APPLIED_RULES"
    end

    test "returns the whole log when the sentinel is absent (graceful)" do
      log = "no boundary here\njust text"
      assert Distill.distill(log) == log
    end
  end

  describe "AppliedRules.parse/1" do
    test "parses counts and :reverted across multiple attempts, un-deduped" do
      log = """
      [Solve attempt 1]
      APPLIED_RULES: [{Credence.Semantic.UnusedVariable, 1}, {Credence.Pattern.NoSortThenAt, 2}]
      [Solve attempt 2]
      APPLIED_RULES: [{Credence.Pattern.NoSortThenAt, :reverted}]
      """

      entries = AppliedRules.parse(log)

      assert {:"Elixir.Credence.Semantic.UnusedVariable", 1} in entries
      assert {:"Elixir.Credence.Pattern.NoSortThenAt", 2} in entries
      assert {:"Elixir.Credence.Pattern.NoSortThenAt", :reverted} in entries
      assert length(entries) == 3
    end

    test "empty APPLIED_RULES yields no entries" do
      assert AppliedRules.parse("APPLIED_RULES: []") == []
    end

    test "reverted/1 extracts only :reverted culprits" do
      entries =
        AppliedRules.parse(
          "APPLIED_RULES: [{Credence.Pattern.A, 1}, {Credence.Pattern.B, :reverted}]"
        )

      assert AppliedRules.reverted(entries) == [:"Elixir.Credence.Pattern.B"]
    end

    test "modules/1 is the unique closed set" do
      entries =
        AppliedRules.parse("""
        APPLIED_RULES: [{Credence.Pattern.A, 1}]
        APPLIED_RULES: [{Credence.Pattern.A, 2}, {Credence.Pattern.C, 1}]
        """)

      assert Enum.sort(AppliedRules.modules(entries)) ==
               Enum.sort([:"Elixir.Credence.Pattern.A", :"Elixir.Credence.Pattern.C"])
    end
  end

  # T3.2. The other half of this contract lives in credence
  # (`Credence.rule_outcomes/0`, pinned by its own test/no_op_trace_test.exs).
  # Both sides must move together: an outcome this regex does not match is not
  # an error here, it is a silent SKIP by `Regex.scan/3` — the module vanishes
  # from `modules/1`, so it is missing from the classifier's closed set and a
  # correct BUGFIX_RULE report about it is rejected as
  # `:rule_name_not_in_closed_set`. The rule most worth reporting (`:crashed`)
  # was the one least reportable.
  describe "AppliedRules — the credence trace vocabulary contract" do
    @credence_outcomes ~w(reverted rolled_back patch_rejected crashed no_op)a

    test "every outcome in credence's closed set survives parsing" do
      body =
        @credence_outcomes
        |> Enum.with_index(1)
        |> Enum.map_join(", ", fn {outcome, i} ->
          "{Credence.Pattern.R#{i}, #{inspect(outcome)}}"
        end)

      entries = AppliedRules.parse("APPLIED_RULES: [#{body}]")

      assert length(entries) == length(@credence_outcomes),
             """
             #{length(@credence_outcomes) - length(entries)} outcome(s) were DROPPED, not rejected.
             Parsed: #{inspect(entries)}

             Widen @pair in lib/cev/applied_rules.ex. Do NOT repair this by shrinking
             the list — it mirrors Credence.rule_outcomes/0, and a dropped outcome
             makes a correct bug report about that rule unfileable.
             """

      for {outcome, i} <- Enum.with_index(@credence_outcomes, 1) do
        assert {:"Elixir.Credence.Pattern.R#{i}", outcome} in entries
      end
    end

    test "an outcome atom this harness has never heard of is still kept" do
      # The property that matters is not "we know the vocabulary" but "we cannot
      # lose a member of it". A future credence outcome must reach modules/1
      # even before anyone here has heard the name — which is why @pair matches
      # any outcome atom rather than an enumeration.
      entries = AppliedRules.parse("APPLIED_RULES: [{Credence.Pattern.Z, :some_future_outcome}]")

      assert entries == [{:"Elixir.Credence.Pattern.Z", :some_future_outcome}]
      assert AppliedRules.modules(entries) == [:"Elixir.Credence.Pattern.Z"]
    end

    test "reverted/1 stays narrow — the new outcomes are not culprits" do
      entries =
        AppliedRules.parse("""
        APPLIED_RULES: [{Credence.Pattern.A, :reverted}, {Credence.Pattern.B, :crashed}]
        APPLIED_RULES: [{Credence.Pattern.C, :no_op}, {Credence.Pattern.D, :patch_rejected}]
        """)

      # All four reach the closed set...
      assert length(AppliedRules.modules(entries)) == 4

      # ...but routing is unchanged. Widening the deterministic bugfix lane is a
      # separate decision on its own evidence, not a side effect of repairing
      # the parser; this pins that they did not move together by accident.
      assert AppliedRules.reverted(entries) == [:"Elixir.Credence.Pattern.A"]
    end
  end

  describe "RulePaths.resolve/2" do
    setup do
      # A tiny fake clone tree with one rule + its split tests.
      clone = Path.join(System.tmp_dir!(), "cev_rulepaths_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(clone, "lib/pattern"))
      File.mkdir_p!(Path.join(clone, "test/pattern"))

      File.write!(
        Path.join(clone, "lib/pattern/no_foo.ex"),
        "defmodule Credence.Pattern.NoFoo do\nend\n"
      )

      File.write!(Path.join(clone, "test/pattern/no_foo_check_test.exs"), "x")
      File.write!(Path.join(clone, "test/pattern/no_foo_fix_test.exs"), "x")
      on_exit(fn -> File.rm_rf!(clone) end)
      %{clone: clone}
    end

    test "resolves a module to its source + test glob", %{clone: clone} do
      assert {:ok, r} = RulePaths.resolve(:"Elixir.Credence.Pattern.NoFoo", clone)
      assert r.phase == "pattern"
      assert r.rule_path == "lib/pattern/no_foo.ex"
      assert "test/pattern/no_foo_check_test.exs" in r.test_paths
      assert "test/pattern/no_foo_fix_test.exs" in r.test_paths
    end

    test "errors on a module with no source file", %{clone: clone} do
      assert {:error, {:not_found, _}} =
               RulePaths.resolve(:"Elixir.Credence.Pattern.Ghost", clone)
    end
  end
end
