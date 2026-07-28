defmodule Cev.Evolve.CorpusDispatchTest do
  use ExUnit.Case, async: true

  alias Cev.Evolve.CorpusDispatch

  # ── Verbatim fixtures ─────────────────────────────────────────────────
  #
  # Every string below is assembled from the literal format strings in credence
  # `lib/mix/tasks/credence.corpus.ex` (`report_only_rule/1`, `explain/1`,
  # `excerpt/2`, `bullets/1`), including `Mix.shell().info/1`'s trailing newline
  # per call and the leading "\n" each of those calls carries. That matters: the
  # Gate's fast path is only as trustworthy as this parse.

  @clean """

  [only-rule] no_uniq_then_count — scanned 20076 file(s) across 2008 corpus entries in 11.6s
  [only-rule] RESULT=clean rule=no_uniq_then_count live=19 accepted=19
  """

  # A brand-new rule: nothing pinned, nothing fired.
  @clean_new_rule """

  [only-rule] no_new_thing — scanned 20076 file(s) across 2008 corpus entries in 11.6s
  [only-rule] RESULT=clean rule=no_new_thing live=0 accepted=0
  """

  @drift """

  [only-rule] no_uniq_then_count — scanned 20076 file(s) across 2008 corpus entries in 12.0s

  NEW — not previously accepted (a candidate OVER-FIRE — investigate!):
    • jason/lib/codegen.ex:42  no_uniq_then_count
          41 |   defp escape(data) do
        > 42 |     data |> Enum.uniq() |> length()
          43 |   end
    • plug/lib/plug/conn.ex:117  no_uniq_then_count
         116 |
       > 117 |   headers |> Enum.uniq() |> Enum.count()
         118 |

  GONE — pinned but no longer firing (a rule narrowed / was removed):
    postgrex/lib/postgrex/types.ex:88  no_uniq_then_count

  [only-rule] RESULT=drift rule=no_uniq_then_count live=21 accepted=19 new=2 gone=1
  ** (Mix.Error) corpus drift for no_uniq_then_count: 2 new, 1 gone. If this is expected, review it and re-pin with `mix credence.corpus --update-snapshot`.
  """

  # A pure over-fire — the shape a bad new rule produces. GONE renders as
  # `  (none)`, which must not be counted as a pinned finding that vanished.
  @drift_over_fire_only """

  [only-rule] no_uniq_then_count — scanned 20076 file(s) across 2008 corpus entries in 11.7s

  NEW — not previously accepted (a candidate OVER-FIRE — investigate!):
    • jason/lib/codegen.ex:42  no_uniq_then_count
          41 |   defp escape(data) do
        > 42 |     data |> Enum.uniq() |> length()
          43 |   end

  GONE — pinned but no longer firing (a rule narrowed / was removed):
    (none)

  [only-rule] RESULT=drift rule=no_uniq_then_count live=20 accepted=19 new=1 gone=0
  """

  # A pure narrowing — the shape a legitimate bugfix produces.
  @drift_narrowing """

  [only-rule] no_uniq_then_count — scanned 20076 file(s) across 2008 corpus entries in 11.9s

  NEW — not previously accepted (a candidate OVER-FIRE — investigate!):
    (none)

  GONE — pinned but no longer firing (a rule narrowed / was removed):
    postgrex/lib/postgrex/types.ex:88  no_uniq_then_count
    jason/lib/codegen.ex:42  no_uniq_then_count

  [only-rule] RESULT=drift rule=no_uniq_then_count live=17 accepted=19 new=0 gone=2
  """

  # `resolve_rule!/1` raises before anything is scanned — a typo'd rule name, a
  # Syntax/Semantic rule, or a missing corpus all land here.
  @unknown_rule """
  ** (Mix.Error) unknown Pattern rule "no_such_rule".
  Expected one of the 155 rules in Credence.Pattern.default_rules/0, named as a snake name, a short Pascal name or a full module — e.g. avoid_length_for_empty_check.
  """

  describe "interpret/2 — the --only-rule contract" do
    test "exit 0 with RESULT=clean is clean, with both counts" do
      assert {:clean, r} = CorpusDispatch.interpret(0, @clean)
      assert r == %{rule: "no_uniq_then_count", live: 19, accepted: 19}
    end

    test "a brand-new rule with nothing pinned and nothing firing is clean" do
      assert {:clean, %{live: 0, accepted: 0}} = CorpusDispatch.interpret(0, @clean_new_rule)
    end

    test "non-zero with RESULT=drift yields the NEW and GONE identity lines" do
      assert {:drift, d} = CorpusDispatch.interpret(1, @drift)

      assert d.new == [
               "jason/lib/codegen.ex:42  no_uniq_then_count",
               "plug/lib/plug/conn.ex:117  no_uniq_then_count"
             ]

      assert d.gone == ["postgrex/lib/postgrex/types.ex:88  no_uniq_then_count"]
    end

    test "the source excerpts printed under each NEW bullet are not mistaken for findings" do
      assert {:drift, d} = CorpusDispatch.interpret(1, @drift)
      refute Enum.any?(d.new, &String.contains?(&1, "|"))
      assert length(d.new) == 2
    end

    # `bullets([])` renders `  (none)`. Counting that as a GONE identity would
    # send a pure over-fire to the maintainer labelled a narrowing.
    test "a pure over-fire parses with an empty GONE list — `(none)` is not a finding" do
      assert {:drift, d} = CorpusDispatch.interpret(1, @drift_over_fire_only)
      assert d.new == ["jason/lib/codegen.ex:42  no_uniq_then_count"]
      assert d.gone == []
    end

    test "a pure narrowing parses with an empty NEW list — `(none)` is not a finding" do
      assert {:drift, d} = CorpusDispatch.interpret(1, @drift_narrowing)
      assert d.new == []
      assert length(d.gone) == 2
      refute "(none)" in d.gone
    end

    # The whole point of the cross-check: if the printed bullets and the printed
    # counts ever disagree, the parse is wrong and the Gate must not act on it.
    test "drift bullets that do not add up to new=/gone= are INCONCLUSIVE, not a reject" do
      tampered = String.replace(@drift, "new=2 gone=1", "new=3 gone=1")

      assert {:inconclusive, %{reason: reason}} = CorpusDispatch.interpret(1, tampered)
      assert {:drift_lines_do_not_match_counts, parsed: {2, 1}, reported: {3, 1}} = reason
    end

    test "no RESULT line at all is inconclusive — a raise before the scan ever ran" do
      assert {:inconclusive, %{reason: :no_result_line, exit: 1}} =
               CorpusDispatch.interpret(1, @unknown_rule)
    end

    test "a killed task (no output) is inconclusive, never clean" do
      assert {:inconclusive, %{reason: :no_result_line}} = CorpusDispatch.interpret(137, "")
    end

    test "RESULT=clean with a NON-ZERO exit is inconclusive — the two must agree" do
      assert {:inconclusive, %{reason: {:exit_code_disagrees_with_verdict, "clean"}}} =
               CorpusDispatch.interpret(1, @clean)
    end

    test "RESULT=drift with a ZERO exit is inconclusive — the two must agree" do
      assert {:inconclusive, %{reason: {:exit_code_disagrees_with_verdict, "drift"}}} =
               CorpusDispatch.interpret(0, @drift)
    end

    test "two RESULT lines (a task that looped) is inconclusive" do
      assert {:inconclusive, %{reason: {:multiple_result_lines, 2}}} =
               CorpusDispatch.interpret(0, @clean <> @clean)
    end

    test "the failing output is kept for the log" do
      assert {:inconclusive, %{tail: tail}} = CorpusDispatch.interpret(1, @unknown_rule)
      assert tail =~ "unknown Pattern rule"
    end
  end

  # ── plan/2 ────────────────────────────────────────────────────────────

  describe "plan/2" do
    setup do
      clone = Path.join(System.tmp_dir!(), "cev_dispatch_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(clone, "lib/pattern"))
      File.mkdir_p!(Path.join(clone, "lib/syntax"))
      File.mkdir_p!(Path.join(clone, "lib/semantic"))
      on_exit(fn -> File.rm_rf!(clone) end)
      %{clone: clone}
    end

    defp write_rule(clone, rel, module, behaviour \\ "  use Credence.Pattern.Rule") do
      File.mkdir_p!(Path.join(clone, Path.dirname(rel)))

      File.write!(Path.join(clone, rel), """
      defmodule #{module} do
        @moduledoc "x"
      #{behaviour}
      end
      """)

      rel
    end

    defp add(paths), do: Enum.map(paths, &%{status: "A", paths: [&1]})

    # ── skip ──

    test "a Semantic rule + its tests skips the corpus phase entirely", ctx do
      write_rule(
        ctx.clone,
        "lib/semantic/fix_x.ex",
        "Credence.Semantic.FixX",
        "  use Credence.Semantic.Rule"
      )

      entries =
        add([
          "lib/semantic/fix_x.ex",
          "test/semantic/fix_x_check_test.exs",
          "test/semantic/fix_x_fix_test.exs"
        ])

      assert {:skip, why} = CorpusDispatch.plan(entries, ctx.clone)
      assert why =~ "Pattern-only"
    end

    test "a Syntax rule + its tests skips too", ctx do
      write_rule(
        ctx.clone,
        "lib/syntax/fix_y.ex",
        "Credence.Syntax.FixY",
        "  use Credence.Syntax.Rule"
      )

      entries =
        add(["lib/syntax/fix_y.ex", "test/syntax/fix_y_analyze_test.exs"])

      assert {:skip, _} = CorpusDispatch.plan(entries, ctx.clone)
    end

    # `Credence.Pattern.default_rules/0` discovers by BEHAVIOUR, not by
    # directory, so a Pattern rule parked under lib/syntax/ is a live Pattern
    # rule. The path alone must not be allowed to authorize the skip.
    test "a PATTERN rule hiding under lib/syntax/ does NOT skip", ctx do
      write_rule(ctx.clone, "lib/syntax/sneaky.ex", "Credence.Pattern.Sneaky")

      entries = add(["lib/syntax/sneaky.ex", "test/syntax/sneaky_test.exs"])

      assert {:full, why} = CorpusDispatch.plan(entries, ctx.clone)
      assert why =~ "is not under lib/pattern/"
    end

    test "a Semantic rule that also touches a shared lib/ file does NOT skip", ctx do
      write_rule(
        ctx.clone,
        "lib/semantic/fix_x.ex",
        "Credence.Semantic.FixX",
        "  use Credence.Semantic.Rule"
      )

      entries =
        add(["lib/semantic/fix_x.ex", "lib/rule_helpers.ex", "test/semantic/fix_x_fix_test.exs"])

      assert {:full, why} = CorpusDispatch.plan(entries, ctx.clone)
      assert why =~ "2 lib/ files staged"
    end

    # ── scoped ──

    test "one Pattern rule + its own tests is scoped to that module", ctx do
      write_rule(
        ctx.clone,
        "lib/pattern/no_uniq_then_count.ex",
        "Credence.Pattern.NoUniqThenCount"
      )

      entries =
        add([
          "lib/pattern/no_uniq_then_count.ex",
          "test/pattern/no_uniq_then_count_check_test.exs",
          "test/pattern/no_uniq_then_count_fix_test.exs"
        ])

      assert CorpusDispatch.plan(entries, ctx.clone) ==
               {:scoped, Credence.Pattern.NoUniqThenCount, "lib/pattern/no_uniq_then_count.ex"}
    end

    test "a MODIFIED Pattern rule (the bugfix lane) is scoped too", ctx do
      rel = write_rule(ctx.clone, "lib/pattern/no_uniq.ex", "Credence.Pattern.NoUniq")

      entries = [
        %{status: "M", paths: [rel]},
        %{status: "M", paths: ["test/pattern/no_uniq_check_test.exs"]}
      ]

      assert {:scoped, Credence.Pattern.NoUniq, ^rel} = CorpusDispatch.plan(entries, ctx.clone)
    end

    # ── full ──

    test "a second rule's test alongside is NOT 'plus its tests' — full scan", ctx do
      write_rule(ctx.clone, "lib/pattern/no_uniq.ex", "Credence.Pattern.NoUniq")

      entries =
        add([
          "lib/pattern/no_uniq.ex",
          "test/pattern/no_uniq_check_test.exs",
          "test/pattern/some_other_rule_fix_test.exs"
        ])

      assert {:full, why} = CorpusDispatch.plan(entries, ctx.clone)
      assert why =~ "own test/pattern/ tests"
    end

    test "two Pattern rules staged together is a full scan", ctx do
      write_rule(ctx.clone, "lib/pattern/a.ex", "Credence.Pattern.A")
      write_rule(ctx.clone, "lib/pattern/b.ex", "Credence.Pattern.B")

      entries = add(["lib/pattern/a.ex", "lib/pattern/b.ex", "test/pattern/a_test.exs"])

      assert {:full, why} = CorpusDispatch.plan(entries, ctx.clone)
      assert why =~ "2 lib/ files staged"
    end

    test "a file under lib/pattern/ that is not a rule is a full scan", ctx do
      write_rule(ctx.clone, "lib/pattern/helper.ex", "Credence.Pattern.Helper", "  def x, do: 1")

      entries = add(["lib/pattern/helper.ex", "test/pattern/helper_test.exs"])

      assert {:full, why} = CorpusDispatch.plan(entries, ctx.clone)
      assert why =~ "does not declare Credence.Pattern.Rule"
    end

    test "a lib/pattern/ file defining two modules is a full scan", ctx do
      File.write!(Path.join(ctx.clone, "lib/pattern/two.ex"), """
      defmodule Credence.Pattern.Two do
        use Credence.Pattern.Rule
      end

      defmodule Credence.Pattern.Two.Helper do
        def x, do: 1
      end
      """)

      entries = add(["lib/pattern/two.ex", "test/pattern/two_test.exs"])

      assert {:full, why} = CorpusDispatch.plan(entries, ctx.clone)
      assert why =~ "defines 2 modules"
    end

    test "touching the corpus layer itself is always a full scan", ctx do
      write_rule(ctx.clone, "lib/pattern/no_uniq.ex", "Credence.Pattern.NoUniq")

      entries =
        add([
          "lib/pattern/no_uniq.ex",
          "test/pattern/no_uniq_test.exs",
          "test/corpus/accepted_findings.txt"
        ])

      assert {:full, why} = CorpusDispatch.plan(entries, ctx.clone)
      assert why =~ "test/corpus/"
    end

    test "a shared engine file is a full scan", ctx do
      File.write!(Path.join(ctx.clone, "lib/pattern.ex"), "defmodule Credence.Pattern do\nend\n")

      entries = add(["lib/pattern.ex", "test/pattern_test.exs"])

      assert {:full, why} = CorpusDispatch.plan(entries, ctx.clone)
      assert why =~ "is not under lib/pattern/"
    end

    test "a deleted Pattern rule is never scoped — its removal changes the whole set", ctx do
      entries = [
        %{status: "D", paths: ["lib/pattern/gone.ex"]},
        %{status: "M", paths: ["test/pattern/gone_test.exs"]}
      ]

      assert {:full, why} = CorpusDispatch.plan(entries, ctx.clone)
      assert why =~ "deleted or renamed"
    end

    test "a renamed Pattern rule is a full scan", ctx do
      write_rule(ctx.clone, "lib/pattern/new_name.ex", "Credence.Pattern.NewName")

      entries = [
        %{status: "R", paths: ["lib/pattern/old_name.ex", "lib/pattern/new_name.ex"]},
        %{status: "M", paths: ["test/pattern/new_name_test.exs"]}
      ]

      assert {:full, why} = CorpusDispatch.plan(entries, ctx.clone)
      assert why =~ "2 lib/ files staged"
    end

    test "an empty staged set is a full scan, never a skip" do
      assert {:full, "no staged paths"} = CorpusDispatch.plan([], "/nonexistent")
    end

    test "an unreadable lib/pattern/ file is a full scan, never a skip", ctx do
      entries = add(["lib/pattern/vanished.ex", "test/pattern/vanished_test.exs"])

      assert {:full, why} = CorpusDispatch.plan(entries, ctx.clone)
      assert why =~ "does not declare Credence.Pattern.Rule"
    end
  end
end
