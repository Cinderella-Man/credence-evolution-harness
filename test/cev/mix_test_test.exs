defmodule Cev.MixTestTest do
  use ExUnit.Case, async: true

  doctest Cev.MixTest

  alias Cev.MixTest

  @moduledoc """
  T4.6 / H5 — every `mix test` the harness shells out to is now capped.

  `System.cmd/3` has no timeout, and `gate.ex` and `implement.ex` both used it
  bare: one hung suite hung the entire run, with no row completed and nothing
  written.
  """

  describe "argv/2" do
    test "wraps the command for coreutils timeout, cap first" do
      assert MixTest.argv(["--exclude", "corpus"], 90) ==
               ["--kill-after=5", "90", "mix", "test", "--exclude", "corpus"]
    end

    test "a bare run still names the subcommand" do
      assert MixTest.argv([], 30) == ["--kill-after=5", "30", "mix", "test"]
    end
  end

  describe "classify/1" do
    test "124 is the cap firing" do
      assert MixTest.classify(124) == :timeout
    end

    test "an ordinary red suite is not a timeout" do
      assert MixTest.classify(1) == :ran
    end

    # 137 is SIGKILL, which `--kill-after` can produce — but it is also what the
    # kernel OOM killer produces, and `suite_verdict/2` already routes an exit
    # carrying no ExUnit summary to `:did_not_run` -> environmental. Claiming it
    # as "the cap fired" would assert a cause we cannot distinguish.
    test "a SIGKILLed child is left to the existing environmental triage" do
      assert MixTest.classify(137) == :ran
    end
  end

  # The whole mechanism rests on one external contract: that coreutils `timeout`
  # exits 124 when it fires. That is an assumption about another program, so it
  # gets executed rather than believed — this is the same class of claim as the
  # anchors probe in `corpus_dispatch_anchors_test.exs`.
  describe "the coreutils contract this depends on" do
    @tag :tmp_dir
    test "timeout really does exit 124, and really does kill the child", %{tmp_dir: dir} do
      started = System.monotonic_time(:millisecond)

      {_out, code} =
        System.cmd("timeout", ["--kill-after=1", "1", "sleep", "30"],
          cd: dir,
          stderr_to_stdout: true
        )

      elapsed = System.monotonic_time(:millisecond) - started

      assert code == 124, "coreutils timeout no longer exits 124 — MixTest.classify/1 is wrong"

      # It killed the child rather than waiting it out: a 30s sleep under a 1s
      # cap must not have taken 30s.
      assert elapsed < 10_000
    end

    @tag :tmp_dir
    test "a command finishing inside the cap keeps its own exit code", %{tmp_dir: dir} do
      assert {_, 0} = System.cmd("timeout", ["5", "true"], cd: dir)
      assert {_, 3} = System.cmd("timeout", ["5", "sh", "-c", "exit 3"], cd: dir)
    end
  end
end
