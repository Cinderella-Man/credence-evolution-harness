defmodule Cev.AppliedRulesSidecarTest do
  use ExUnit.Case, async: false

  alias Cev.{AppliedRules, RowLog}

  # H12. The APPLIED_RULES closed set — the classifier's entire input — used to
  # reach it only by riding a `Logger.debug/1` into the row log and being regex'd
  # back out. That is a contract held together by a log level: raise it and
  # rule-gen is severed from validation silently, with the classifier handed an
  # empty closed set and no error raised anywhere.
  #
  # The sidecar is now the contract. These tests pin the three properties that
  # make it one: it is written, it is preferred, and it survives the row's move
  # into its outcome directory.

  @output """
  FIXED
  APPLIED_RULES: [{Credence.Pattern.NoSortThenAt, 2}, {Credence.Pattern.NoBadRule, :reverted}]
  """

  setup do
    index = "sidecar_test_#{System.unique_integer([:positive])}"
    RowLog.ensure_ready()
    on_exit(fn -> cleanup(index) end)
    {:ok, index: index}
  end

  defp cleanup(index) do
    (Path.rootname(RowLog.path(index)) <> ".*")
    |> Path.wildcard()
    |> Enum.each(&File.rm/1)

    RowLog.outcome_dirs()
    |> Enum.each(fn dir ->
      Path.join(RowLog.outcome_path(dir), "#{index}.*")
      |> Path.wildcard()
      |> Enum.each(&File.rm/1)
    end)
  end

  test "write_sidecar lands beside the open row log", %{index: index} do
    RowLog.open(index)
    RowLog.write_sidecar("applied_rules", @output)

    assert File.exists?(RowLog.sidecar(index, "applied_rules"))
    assert File.read!(RowLog.sidecar(index, "applied_rules")) == @output
  end

  test "for_row/1 reads the sidecar", %{index: index} do
    RowLog.open(index)
    RowLog.write_sidecar("applied_rules", @output)

    entries = AppliedRules.for_row(index)

    assert {Credence.Pattern.NoSortThenAt, 2} in entries
    assert AppliedRules.reverted(entries) == [Credence.Pattern.NoBadRule]
  end

  # The point of the change: the closed set must survive a log that no longer
  # carries the line. Before H12 this returned [].
  test "for_row/1 works even when the row log never captured the line", %{index: index} do
    RowLog.open(index)
    RowLog.write_sidecar("applied_rules", @output)
    File.write!(RowLog.path(index), "some log text with no APPLIED_RULES in it at all\n")

    assert AppliedRules.for_row(index) != []

    assert AppliedRules.modules(AppliedRules.for_row(index)) == [
             Credence.Pattern.NoSortThenAt,
             Credence.Pattern.NoBadRule
           ]
  end

  # Backward compatibility: rows produced before the sidecar existed must still
  # classify, so the log fallback has to keep working.
  test "for_row/1 falls back to the row log when no sidecar exists", %{index: index} do
    RowLog.open(index)
    RowLog.filesync()
    File.write!(RowLog.path(index), @output)

    refute File.exists?(RowLog.sidecar(index, "applied_rules"))

    assert AppliedRules.modules(AppliedRules.for_row(index)) == [
             Credence.Pattern.NoSortThenAt,
             Credence.Pattern.NoBadRule
           ]
  end

  test "sidecars follow the log into its outcome directory", %{index: index} do
    RowLog.open(index)
    RowLog.write_sidecar("applied_rules", @output)
    RowLog.commit(index)

    moved = Path.join(RowLog.outcome_path("committed"), "#{index}.applied_rules")

    assert File.exists?(moved), "sidecar was left behind in logs/ when the row completed"
    assert File.read!(moved) == @output
    refute File.exists?(RowLog.sidecar(index, "applied_rules"))
  end

  # A unit test driving the validator directly has no row open. That must not
  # raise — the sidecar is an enrichment of the run, not a precondition of it.
  test "write_sidecar is a no-op when no row is open", %{index: index} do
    RowLog.open(index)
    RowLog.close(index)

    assert RowLog.current_log_path() == nil
    assert RowLog.write_sidecar("applied_rules", @output) == :ok
    refute File.exists?(RowLog.sidecar(index, "applied_rules"))
  end
end
