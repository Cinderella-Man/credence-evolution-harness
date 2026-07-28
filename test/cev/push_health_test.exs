defmodule Cev.PushHealthTest do
  use ExUnit.Case, async: false

  alias Cev.Evolve.Git

  # H14. `push/1` warned and returned `:ok` on failure, forever. A broken remote
  # therefore turned a 24/7 run into a local-only run silently — days of commits
  # nobody else can see, with nothing but a `:warning` per row to say so, and
  # boot reconciliation as the only catch-up.
  #
  # One failure is genuinely non-fatal and stays that way. A STREAK is not: it
  # means the remote is gone, not flaky. Consecutive failures now trip the same
  # circuit breaker the transient-storm path uses.

  setup do
    Git.reset_push_failures()
    on_exit(&Git.reset_push_failures/0)
    :ok
  end

  describe "push_breaker_step/2" do
    test "continues below the limit" do
      assert Git.push_breaker_step(1, 5) == :cont
      assert Git.push_breaker_step(4, 5) == :cont
    end

    test "halts at the limit" do
      assert Git.push_breaker_step(5, 5) == :halt
    end

    test "halts past the limit — a streak cannot walk through the gate" do
      assert Git.push_breaker_step(6, 5) == :halt
      assert Git.push_breaker_step(100, 5) == :halt
    end

    test "a limit of 1 halts on the first failure" do
      assert Git.push_breaker_step(1, 1) == :halt
    end
  end

  describe "the failure counter" do
    test "starts at zero" do
      assert Git.consecutive_push_failures() == 0
    end

    test "reset clears a streak" do
      Git.reset_push_failures()
      assert Git.consecutive_push_failures() == 0
    end
  end

  describe "the limit is configurable" do
    test "defaults to 5" do
      assert Git.push_failure_limit() == 5
    end

    test "reads application config" do
      Application.put_env(:cev, :push_failure_limit, 2)
      assert Git.push_failure_limit() == 2
    after
      Application.delete_env(:cev, :push_failure_limit)
    end
  end

  # The property that matters, stated as a test rather than left implicit: a
  # successful push must clear the streak, or a run that fails 4 times, succeeds,
  # then fails once would halt on a single failure.
  test "the breaker is about CONSECUTIVE failures, not cumulative ones" do
    limit = Git.push_failure_limit()

    assert Git.push_breaker_step(limit - 1, limit) == :cont,
           "a run one short of the limit must still continue"

    Git.reset_push_failures()

    assert Git.consecutive_push_failures() == 0,
           "a successful push must clear the streak, not decrement it"
  end
end
