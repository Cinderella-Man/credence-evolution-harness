defmodule Cev.SanityGateTest do
  use ExUnit.Case, async: false
  alias Cev.SanityGate

  test "hash/2 is deterministic and sensitive to both files" do
    h = SanityGate.hash("ref", "test")
    assert h == SanityGate.hash("ref", "test")
    refute h == SanityGate.hash("ref-changed", "test")
    refute h == SanityGate.hash("ref", "test-changed")
  end

  test "ensure/3 returns :ok for a task with no reference (nothing to check)" do
    assert SanityGate.ensure(%{name: "x", reference: nil, test: "t"}) == :ok
  end

  test "verdict store round-trips and reloads from disk (survives restart)" do
    path = Path.join(System.tmp_dir!(), "cev_verdicts_#{System.unique_integer([:positive])}.jsonl")
    on_exit(fn -> File.rm_rf!(path) end)

    {:ok, pid} = SanityGate.start_link(name: :sg_a, path: path)
    assert GenServer.call(:sg_a, {:get, "h1"}) == nil
    :ok = GenServer.call(:sg_a, {:put, "h1", "task_a", :blacklist})
    :ok = GenServer.call(:sg_a, {:put, "h2", "task_b", :ok})
    assert GenServer.call(:sg_a, {:get, "h1"}) == :blacklist
    GenServer.stop(pid)

    # A fresh process must reload the persisted verdicts.
    {:ok, _pid2} = SanityGate.start_link(name: :sg_b, path: path)
    assert GenServer.call(:sg_b, {:get, "h1"}) == :blacklist
    assert GenServer.call(:sg_b, {:get, "h2"}) == :ok
    assert GenServer.call(:sg_b, {:get, "missing"}) == nil
  end
end
