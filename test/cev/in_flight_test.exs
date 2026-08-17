defmodule Cev.InFlightTest do
  @moduledoc """
  A row that kills the VM used to be retried forever.

  `pending` is recomputed from `progress` at boot and the per-pass permutation is
  derived from the pass number, so the order is identical on every restart. A row
  that takes the BEAM down is therefore the FIRST one retried, kills it again,
  and the loop never advances. `TransientAttempts` does not catch it — that
  counts `:transient_abort` from the rule-gen router, and a dead VM books no
  outcome at all.

  For an unattended run that is the difference between a bad row and a dead run.
  """
  use ExUnit.Case, async: false

  alias Cev.InFlight

  setup do
    path = Path.join(System.tmp_dir!(), "cev_in_flight_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm(path) end)
    %{path: path}
  end

  test "a first start records zero previous crashes", %{path: path} do
    assert InFlight.start(7, path) == 0
  end

  test "a marker left behind by a dead VM counts as one crash", %{path: path} do
    assert InFlight.start(7, path) == 0
    # No `finish/1` — this is what a VM death looks like from the next boot.
    assert InFlight.start(7, path) == 1
    assert InFlight.start(7, path) == 2
  end

  test "finishing clears the marker, so a healthy row never accumulates", %{path: path} do
    for _ <- 1..5 do
      assert InFlight.start(7, path) == 0
      InFlight.finish(path)
    end
  end

  # The marker names ONE row. A crash on row 7 must not make row 8 look poisoned
  # — that would skip healthy work on the strength of someone else's failure.
  test "a marker for a different row does not count against this one", %{path: path} do
    InFlight.start(7, path)

    assert InFlight.start(8, path) == 0
  end

  test "an unreadable or malformed marker counts as zero", %{path: path} do
    File.write!(path, "not a marker at all\n")
    assert InFlight.crashes_for(7, path) == 0

    File.write!(path, "7 not-a-number\n")
    assert InFlight.crashes_for(7, path) == 0

    File.rm(path)
    assert InFlight.crashes_for(7, path) == 0
  end

  describe "poisoned?/1" do
    test "is false below the limit and true at it" do
      refute InFlight.poisoned?(0)
      refute InFlight.poisoned?(2)
      assert InFlight.poisoned?(3)
      assert InFlight.poisoned?(9)
    end

    test "the limit is configurable" do
      prev = Application.get_env(:cev, :budget, %{})
      Application.put_env(:cev, :budget, Map.put(prev, :row_crash_limit, 1))
      on_exit(fn -> Application.put_env(:cev, :budget, prev) end)

      assert InFlight.poisoned?(1)
      refute InFlight.poisoned?(0)
    end
  end
end
