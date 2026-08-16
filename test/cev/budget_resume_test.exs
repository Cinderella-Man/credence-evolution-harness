defmodule Cev.BudgetResumeTest do
  @moduledoc """
  `runaway_ceiling_usd` is the only thing between a stuck loop and an unbounded
  bill, and `Budget.init/1` seeded `spent_usd: 0.0` unconditionally while never
  reading `usage.jsonl`. That made the ceiling per-VM-lifetime rather than
  per-run: a crash-restart loop — the exact failure shape it exists to stop —
  could never trip it, because every restart forgot what the last one spent.

  Its own module rather than a `describe` in `budget_test.exs`, because these
  tests move `run_dir` and must not run concurrently with anything that reads it.
  """
  use ExUnit.Case, async: false

  alias Cev.Budget

  setup do
    prev = Application.get_env(:cev, :run_dir)
    tmp = Path.join(System.tmp_dir!(), "cev_budget_resume_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:cev, :run_dir, tmp)

    # The test env disables resume globally (see config/config.exs — the shared
    # `tmp/test_run/usage.jsonl` would otherwise seed every booted Budget with
    # accumulated synthetic spend). These tests are ABOUT resume, so they turn it
    # back on for their own isolated run dir.
    prev_resume = Application.get_env(:cev, :budget_resume)
    Application.put_env(:cev, :budget_resume, true)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:cev, :run_dir, prev),
        else: Application.delete_env(:cev, :run_dir)

      if is_nil(prev_resume),
        do: Application.delete_env(:cev, :budget_resume),
        else: Application.put_env(:cev, :budget_resume, prev_resume)

      File.rm_rf!(tmp)
    end)

    %{tmp: tmp}
  end

  defp write_usage(tmp, costs) do
    File.write!(
      Path.join(tmp, "usage.jsonl"),
      Enum.map_join(costs, "\n", &Jason.encode!(%{cost_usd: &1})) <> "\n"
    )
  end

  defp start_budget(opts \\ []) do
    {:ok, pid} = start_supervised({Budget, Keyword.merge([name: nil, heartbeat: false], opts)})
    pid
  end

  test "a restart resumes from what was already spent", %{tmp: tmp} do
    write_usage(tmp, [10.0, 20.0, 5.5])

    assert_in_delta Budget.spent(start_budget()), 35.5, 0.0001
  end

  test "and the ceiling therefore trips on the very next call", %{tmp: tmp} do
    write_usage(tmp, [499.0])
    test_pid = self()

    budget = start_budget(on_runaway: fn reason -> send(test_pid, {:runaway, reason}) end)

    # $2 more takes it past the $500 ceiling. Before this change the restart
    # started from $0.00 and this could never fire.
    Budget.record(
      %{"prompt_tokens" => 1_000_000, "completion_tokens" => 333_334},
      :chat,
      %{provider: :xiaomi_mimo_2_5},
      budget
    )

    assert_receive {:runaway, {:runaway_budget, _}}, 1_000
  end

  test "no usage log means zero, not a crash" do
    assert Budget.spent(start_budget()) == 0.0
  end

  # Skipping a malformed line can only UNDER-count, which fails toward "keep
  # running" rather than toward a false runaway shutdown. A corrupt byte in the
  # ledger must not stop the run.
  test "a malformed line is skipped, not raised on", %{tmp: tmp} do
    File.write!(
      Path.join(tmp, "usage.jsonl"),
      ~s({"cost_usd": 3.0}\nnot json at all\n{"no_cost_field": 1}\n{"cost_usd": 4.0}\n)
    )

    assert_in_delta Budget.spent(start_budget()), 7.0, 0.0001
  end

  # The seam every other Budget test relies on: an explicit value wins, so they
  # are not silently reading whatever the run dir happens to hold.
  test "an explicit spent_usd overrides the log", %{tmp: tmp} do
    write_usage(tmp, [999.0])

    assert Budget.spent(start_budget(spent_usd: 0.0)) == 0.0
  end
end
