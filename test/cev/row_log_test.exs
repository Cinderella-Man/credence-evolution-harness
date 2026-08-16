defmodule Cev.RowLogTest do
  @moduledoc """
  A crash is the outcome whose evidence matters most, and it was the only one
  that threw its evidence away.

  Both of `Orchestrator`'s rescues called `RowLog.close/1`, which deletes the
  log; every other outcome moves it. Measured on the 3rd evolution: 68
  `rulegen: raised` plus 21 `outcome: exception` rows — 7.6% of 1,177 — and
  grepping all 489 archived row logs for either crash marker returns nothing,
  because the logs were removed as they were written. Those rows also carry
  `decision: null`, so `rows.jsonl` says nothing either.
  """
  use ExUnit.Case, async: false

  alias Cev.RowLog

  setup do
    prev = Application.get_env(:cev, :run_dir)
    tmp = Path.join(System.tmp_dir!(), "cev_rowlog_#{System.unique_integer([:positive])}")
    Application.put_env(:cev, :run_dir, tmp)
    RowLog.ensure_ready()

    on_exit(fn ->
      if prev,
        do: Application.put_env(:cev, :run_dir, prev),
        else: Application.delete_env(:cev, :run_dir)

      File.rm_rf!(tmp)
    end)

    %{tmp: tmp}
  end

  defp write_log(tmp, index, body) do
    path = Path.join([tmp, "logs", "#{index}.log"])
    File.write!(path, body)
    path
  end

  describe "crashed/1" do
    test "moves the log instead of deleting it", %{tmp: tmp} do
      source = write_log(tmp, 42, "EXCEPTION: ** (KeyError) key :rule_source not found\n")

      RowLog.crashed(42)

      refute File.exists?(source), "the log should have moved out of logs/"

      dest = Path.join([tmp, "logs", "crashed", "42.log"])
      assert File.exists?(dest), "expected the log under logs/crashed/"
      assert File.read!(dest) =~ "KeyError"
    end

    test "logs/crashed/ is created at boot like every other outcome dir", %{tmp: tmp} do
      assert File.dir?(Path.join([tmp, "logs", "crashed"]))
    end
  end

  describe "close/1 — the contrast, so the difference is pinned" do
    # `close/1` deleting is CORRECT for an ordinary completion: a row that did
    # nothing interesting should not leave 170KB behind. The defect was using it
    # for crashes. Both behaviours are asserted so a future change to either has
    # to be deliberate.
    test "ordinary completion still deletes", %{tmp: tmp} do
      source = write_log(tmp, 7, "nothing happened\n")

      RowLog.close(7)

      refute File.exists?(source)
      refute File.exists?(Path.join([tmp, "logs", "crashed", "7.log"]))
    end
  end
end
