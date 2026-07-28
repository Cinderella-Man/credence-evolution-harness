defmodule Cev.MixTest do
  @moduledoc """
  Every `mix test` this harness shells out to, under a wall-clock cap.

  `System.cmd/3` has no timeout. `gate.ex` and `implement.ex` both used it bare,
  so a single hung suite hung the whole run — no row completed, nothing was
  written, and the only signal was a process sitting at 0% CPU forever (H5 /
  docs/22 T4.6). `validator.ex` already solved this for the one step that runs
  arbitrary model code; this module is that solution extracted so the three call
  sites cannot drift apart.

  ## Why coreutils `timeout` and not a `Task`

  Killing the Elixir process that owns a port does not kill the OS process on
  the other end of it — `mix test` would keep running, holding the clone's
  `_build` lock, and the next phase would block on a suite nobody is waiting
  for. `timeout` signals the child itself, and `--kill-after` follows with
  SIGKILL for a suite that ignores SIGTERM (an ExUnit run trapping exits, say).

  ## Exit codes

  `timeout` exits **124** when it fires. That is deliberately distinguished from
  every other non-zero exit: a hung suite is an *environmental* outcome, not a
  red one, and booking it as merit would fail a candidate for the machine's
  behaviour rather than its own (the mistake T4.5 catalogues elsewhere).

  A SIGKILLed child surfaces as **137** and is left as an ordinary non-zero exit
  on purpose: it is also what the kernel OOM killer produces, and `suite_verdict/2`
  already routes an exit with no ExUnit summary to `:did_not_run` → environmental.
  """

  require Logger

  alias Cev.Config

  # `timeout`'s documented exit status when the cap fires.
  @timeout_exit 124

  # Grace between SIGTERM and SIGKILL.
  @kill_after_s 5

  @doc """
  Run `mix test #{}` in `cd`, capped.

  Returns `{:timeout, seconds, output}` if the cap fired, else `{:ok, exit_code,
  output}`.

  Options: `:timeout_s` (default `Config.gate_test_timeout_s/0`).
  """
  @spec run(Path.t(), [String.t()], keyword()) ::
          {:ok, integer(), String.t()} | {:timeout, pos_integer(), String.t()}
  def run(cd, args, opts \\ []) do
    timeout_s = Keyword.get(opts, :timeout_s, Config.gate_test_timeout_s())

    {out, code} =
      System.cmd("timeout", argv(args, timeout_s),
        cd: cd,
        stderr_to_stdout: true,
        env: [{"MIX_ENV", "test"}]
      )

    case classify(code) do
      :timeout ->
        Logger.warning("[MixTest] `mix test #{Enum.join(args, " ")}` hit the #{timeout_s}s cap")

        {:timeout, timeout_s, out}

      :ran ->
        {:ok, code, out}
    end
  end

  @doc """
  The argv handed to `timeout`, without the executable itself.

  Pure, so the shape can be pinned without shelling out.

      iex> Cev.MixTest.argv(["--exclude", "corpus"], 60)
      ["--kill-after=5", "60", "mix", "test", "--exclude", "corpus"]
  """
  @spec argv([String.t()], pos_integer()) :: [String.t()]
  def argv(args, timeout_s) do
    ["--kill-after=#{@kill_after_s}", "#{timeout_s}", "mix", "test"] ++ args
  end

  @doc """
  Whether an exit code means the cap fired.

      iex> Cev.MixTest.classify(124)
      :timeout

      iex> Cev.MixTest.classify(0)
      :ran

      iex> Cev.MixTest.classify(137)
      :ran
  """
  @spec classify(integer()) :: :timeout | :ran
  def classify(@timeout_exit), do: :timeout
  def classify(_code), do: :ran
end
