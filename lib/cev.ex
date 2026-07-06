defmodule Cev do
  @moduledoc """
  Cev — the Credence Evolution Harness.

  A 24/7, human-free OTP loop that reads native-Elixir tasks from
  `elixir-sft-dataset`, has a local model solve each one, validates the output
  with Credence, and drives an agent to write or fix Credence rules. The primary
  goal is rule discovery; running the dataset is the workload that surfaces where
  Credence is weak.

  See `docs/DESIGN.md` for the full design.
  """

  require Logger

  @doc """
  Graceful shutdown. Flushes the current row log, then halts the VM cleanly so
  the supervisor cannot restart into a fatal storm. Never raises.
  """
  @spec shutdown(term()) :: no_return()
  def shutdown(reason) do
    Logger.error("[Cev.shutdown] halting: #{inspect(reason)}")
    safe(fn -> Cev.RowLog.filesync() end)
    System.halt(1)
  end

  @spec safe((-> any())) :: :ok
  defp safe(fun) do
    fun.()
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
