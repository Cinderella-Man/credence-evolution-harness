defmodule Cev.OrchestratorTest do
  use ExUnit.Case, async: true

  alias Cev.Orchestrator

  # The full GenServer boots Preflight + the dataset, so only the pure breaker
  # decision is unit-tested here (docs/10 Fix 1). The don't-consume / move
  # wiring is covered in RouterTest.
  describe "breaker_step/3 — consecutive-:transient_abort circuit breaker" do
    test "transient_abort increments until the limit, then halts" do
      assert {:cont, 1} = Orchestrator.breaker_step(0, 5, :transient_abort)
      assert {:cont, 4} = Orchestrator.breaker_step(3, 5, :transient_abort)
      assert :halt = Orchestrator.breaker_step(4, 5, :transient_abort)
    end

    test "any real outcome resets the streak to 0" do
      assert {:cont, 0} = Orchestrator.breaker_step(4, 5, :committed)
      assert {:cont, 0} = Orchestrator.breaker_step(4, 5, :too_slow)
      assert {:cont, 0} = Orchestrator.breaker_step(4, 5, :duplicate)
    end

    test "a blacklisted row leaves the streak unchanged (no Mimo signal)" do
      assert {:cont, 3} = Orchestrator.breaker_step(3, 5, :blacklist)
    end
  end

  # H9. `rows.jsonl` is JSON and `Jason` cannot encode a tuple, so the Router's
  # `{:rejected, reason}` outcome raised `Protocol.UndefinedError` inside
  # `write_row_stat/2`, was swallowed by `run_row/2`'s rescue, and every Gate
  # rejection was booked as the contentless
  # `{"index":N,"outcome":"exception"}` — 21 such rows in the live ledger, and
  # ZERO `"rulegen":"rejected"` lines.
  describe "row_outcome/1 — the row stat has to survive Jason" do
    test "atoms pass through unchanged, so the breaker still sees :transient_abort" do
      assert Orchestrator.row_outcome(:committed) == :committed
      assert Orchestrator.row_outcome(:gate_environmental) == :gate_environmental

      assert {:cont, 1} =
               Orchestrator.breaker_step(0, 5, Orchestrator.row_outcome(:transient_abort))
    end

    test "a tuple outcome is inspected into a string instead of raising" do
      assert Orchestrator.row_outcome({:rejected, :full_suite_red}) ==
               "{:rejected, :full_suite_red}"
    end

    test "every Router outcome shape is JSON-encodable" do
      outcomes = [
        :committed,
        :no_action,
        :gate_environmental,
        {:rejected, :full_suite_red},
        {:rejected, {:corpus, :over_fire, %{new: 1, gone: 0}}}
      ]

      for o <- outcomes do
        assert {:ok, _} = Jason.encode(%{rulegen: Orchestrator.row_outcome(o)})
      end
    end

    test "positive control: the raw tuple the Router returns is NOT encodable" do
      assert_raise Protocol.UndefinedError, fn ->
        Jason.encode!(%{rulegen: {:rejected, :full_suite_red}})
      end
    end
  end
end
