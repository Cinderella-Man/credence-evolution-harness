defmodule Cev.LD1ResidualsTest do
  use ExUnit.Case, async: true

  alias Cev.AppliedRules
  alias Cev.Evolve.Router

  @prompt_opts [
    distilled_log: "the row log",
    closed_set: [Credence.Pattern.NoA],
    ledger: "",
    assumptions: [],
    solve_outcome: :solved,
    rule_index: ""
  ]

  @moduledoc """
  docs/22 T4.3 — the LD1 residuals: three places where evidence was being lost
  between credence's stdout and the harness's reading of it.

  All three share a root cause worth naming: **Elixir's Logger truncates a
  message at 8096 bytes by default**, and this harness does not merely read
  those logs, it parses them as data. A row firing ~150 rules puts the
  `APPLIED_RULES:` line within a few hundred bytes of that cap.
  """

  describe "APPLIED_RULES survives a truncated line" do
    test "a complete line parses, as before" do
      log = "APPLIED_RULES: [{Credence.Pattern.NoA, 1}, {Credence.Pattern.NoB, :reverted}]"

      assert AppliedRules.parse(log) == [
               {Credence.Pattern.NoA, 1},
               {Credence.Pattern.NoB, :reverted}
             ]
    end

    # The regression. The closing `]` used to be required, so a line cut
    # mid-list matched nothing at all and EVERY rule on that row was discarded —
    # losing the most evidence on exactly the busiest rows.
    test "a line cut mid-list still yields the pairs that survived" do
      log = "APPLIED_RULES: [{Credence.Pattern.NoA, 1}, {Credence.Pattern.NoB, :crashed}, {Cred"

      assert AppliedRules.parse(log) == [
               {Credence.Pattern.NoA, 1},
               {Credence.Pattern.NoB, :crashed}
             ]
    end

    test "a line cut before any complete pair yields nothing, not a crash" do
      assert AppliedRules.parse("APPLIED_RULES: [{Credence.Patte") == []
    end

    test "the first `]` ends the list — a later bracket on the line is not the terminator" do
      log = "APPLIED_RULES: [{Credence.Pattern.NoA, 1}] and then [{Credence.Pattern.NoB, 2}]"

      assert AppliedRules.parse(log) == [{Credence.Pattern.NoA, 1}]
    end
  end

  describe "every unmatched diagnostic is handed over, not just the last" do
    test "a single diagnostic is returned as before" do
      log = ~s|[credence_fix] no rule matched diagnostic: %{message: "undefined function a/0"}|

      assert Router.extract_diagnostic(log) == ~s|%{message: "undefined function a/0"}|
    end

    # The defect: a source that fails to compile commonly emits several
    # unmatched diagnostics, and `List.last/1` picked one by emission order —
    # an artifact, not a judgment about which deserves a rule. The others, which
    # nothing claimed, were invisible.
    test "several diagnostics all survive, in order" do
      log = """
      [credence_fix] no rule matched diagnostic: %{message: "first"}
      [credence_fix] something else entirely
      [credence_fix] no rule matched diagnostic: %{message: "second"}
      [credence_fix] no rule matched diagnostic: %{message: "third"}
      """

      assert Router.extract_diagnostic(log) ==
               ~s|%{message: "first"}\n%{message: "second"}\n%{message: "third"}|
    end

    test "the same diagnostic repeated across attempts is listed once" do
      log = """
      [credence_fix] no rule matched diagnostic: %{message: "same"}
      [credence_fix] no rule matched diagnostic: %{message: "same"}
      """

      assert Router.extract_diagnostic(log) == ~s|%{message: "same"}|
    end

    test "no diagnostic is nil, so the seed block is omitted rather than empty" do
      assert Router.extract_diagnostic("nothing here") == nil
    end
  end

  describe "the Logger cap that caused all of it" do
    # Pinning the config rather than the symptom: if `:truncate` is ever removed
    # or set to a finite value, the parsers above go back to reading clipped
    # evidence and nothing else would say so.
    test "Logger truncation is disabled, because these logs are parsed as data" do
      assert Application.get_env(:logger, :truncate) == :infinity
    end
  end

  # T4.3: the prompt solicited a report the validator is required to reject.
  #
  # BUGFIX_RULE is validated against the CLOSED SET — the rules that actually
  # fired, read out of `APPLIED_RULES`. A rule that UNDER-fired did not fire, so
  # it is absent from that set and `:rule_name_not_in_closed_set` rejects the
  # report however true the observation is. 19 rows named real rules that
  # genuinely did not fire. The gate was right; the prompt was wrong.
  describe "the prompt does not ask for what the gate must reject" do
    test "it no longer calls an under-fired rule a BUGFIX_RULE" do
      prompt = Cev.Classify.Prompt.build(@prompt_opts)

      refute prompt =~ "under-fired, that's a\n    BUGFIX_RULE"
      refute prompt =~ "MIS-fired or under-fired"
    end

    test "it says what to do instead, naming the reason" do
      prompt = Cev.Classify.Prompt.build(@prompt_opts)

      assert prompt =~ "A rule that did NOT fire cannot be a BUGFIX_RULE"
      assert prompt =~ "Report NO_ACTION"
    end

    test "a MIS-fire is still solicited — that rule IS in the closed set" do
      prompt = Cev.Classify.Prompt.build(@prompt_opts)

      assert prompt =~ "MIS-fired"
      assert prompt =~ "that IS a BUGFIX_RULE"
    end
  end

  # T4.3 / ledger row 95: the observation was right and the row was thrown away
  # over a spelling.
  describe "rule-name spellings the model actually emits" do
    test "the path-ish form becomes a module name" do
      assert Cev.Classify.Parser.normalize_rule_name("pattern/no_uniq_then_count") ==
               "Credence.Pattern.NoUniqThenCount"
    end

    test "a full path with lib/ and .ex is normalised too" do
      assert Cev.Classify.Parser.normalize_rule_name("lib/syntax/fix_div_rem.ex") ==
               "Credence.Syntax.FixDivRem"
    end

    test "the requested form is left exactly as it is" do
      assert Cev.Classify.Parser.normalize_rule_name("Credence.Pattern.NoUniqThenCount") ==
               "Credence.Pattern.NoUniqThenCount"
    end

    test "an Elixir. prefix is not doubled" do
      assert Cev.Classify.Parser.normalize_rule_name("Elixir.Credence.Pattern.Foo") ==
               "Credence.Pattern.Foo"
    end

    # Only the three real phases are treated as phases. `foo/bar` is not a rule
    # spelling and must not be silently turned into `Credence.Foo.Bar`, which
    # would resolve to nothing and hide the real problem.
    test "a two-segment name that is not a phase is left alone" do
      assert Cev.Classify.Parser.normalize_rule_name("foo/bar") == "foo/bar"
    end
  end

  describe "resolving a rule whose phase the model got wrong" do
    @tag :tmp_dir
    test "falls back to the file basename and reports the real module", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "lib/syntax"))

      File.write!(
        Path.join(dir, "lib/syntax/fix_div_rem.ex"),
        "defmodule Credence.Syntax.FixDivRem do\nend\n"
      )

      # The model named the Pattern phase; the rule lives in Syntax.
      assert {:ok, info} = Cev.RulePaths.resolve(Credence.Pattern.FixDivRem, dir)
      assert info.module == Credence.Syntax.FixDivRem
      assert info.phase == "syntax"
      assert info.rule_path == "lib/syntax/fix_div_rem.ex"
    end

    @tag :tmp_dir
    test "a basename matching two files is not guessed at", %{tmp_dir: dir} do
      for phase <- ["pattern", "syntax"] do
        File.mkdir_p!(Path.join(dir, "lib/#{phase}"))

        File.write!(
          Path.join(dir, "lib/#{phase}/twin.ex"),
          "defmodule Credence.#{String.capitalize(phase)}.Twin do\nend\n"
        )
      end

      assert {:error, {:not_found, _}} = Cev.RulePaths.resolve(Credence.Semantic.Twin, dir)
    end

    @tag :tmp_dir
    test "an unknown rule is still not found", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "lib/pattern"))

      assert {:error, {:not_found, _}} = Cev.RulePaths.resolve(Credence.Pattern.Ghost, dir)
    end
  end
end
