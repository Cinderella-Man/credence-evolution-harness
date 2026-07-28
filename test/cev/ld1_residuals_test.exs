defmodule Cev.LD1ResidualsTest do
  use ExUnit.Case, async: true

  alias Cev.AppliedRules
  alias Cev.Evolve.Router

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
end
