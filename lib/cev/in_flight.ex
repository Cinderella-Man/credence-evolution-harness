defmodule Cev.InFlight do
  @moduledoc """
  Which row was being worked when the VM died, and how often that has happened.

  ## The gap this closes

  `Progress.mark_done/2` is written LAST, deliberately: a row that throws is
  logged, the clone discarded, and the row still marked done, so the loop moves
  on. That covers everything the VM survives.

  It does not cover the VM not surviving. `pending` is recomputed from `progress`
  at boot and the per-pass permutation is derived from the pass number, so the
  order is identical on every restart — which means a row that takes the BEAM
  down (OOM, a `System.halt/0` reaching through, the kernel OOM killer) is the
  first one retried, kills the VM again, and the loop never advances.
  `TransientAttempts` does not catch it: that counts `:transient_abort` from the
  rule-gen router, and a dead VM books no outcome at all.

  So: a marker is written when a row STARTS and cleared when it finishes. If it
  is still there at boot, the previous VM died on that row. Past a threshold the
  row is skipped so the run can make progress, which is the same trade
  `TransientAttempts` makes for timeouts — a run that cannot get past one row is
  worth less than a run that skips it and says so.

  Kept deliberately small and file-based, like `Progress`: it has to survive the
  process that writes it.
  """

  alias Cev.Config

  @default_limit 3

  @doc "Path of the in-flight marker."
  def path, do: Config.run_path("in_flight")

  @doc """
  Record that `index` is starting, and return how many times a previous VM has
  already died on it.

  Reading and writing in one call is deliberate: the caller must not be able to
  mark a row started without also learning that it is a repeat offender.
  """
  def start(index, path \\ nil) do
    file = path || path()
    crashes = crashes_for(index, file)
    File.write!(file, "#{index} #{crashes}\n")
    crashes
  end

  @doc "Clear the marker — the row finished, however it finished."
  def finish(path \\ nil) do
    File.rm(path || path())
    :ok
  end

  @doc """
  Crash count for `index`, from a marker left behind by a dead VM.

  Zero when the marker is absent, belongs to a different row, or is unreadable —
  an unparsable marker must not be able to make a healthy row look poisoned.
  """
  def crashes_for(index, path \\ nil) do
    with {:ok, contents} <- File.read(path || path()),
         [recorded, count] <- contents |> String.trim() |> String.split(" ", parts: 2),
         {^index, ""} <- Integer.parse(recorded),
         {n, ""} <- Integer.parse(count) do
      n + 1
    else
      _ -> 0
    end
  end

  @doc """
  Whether `index` has killed the VM often enough to be skipped.

  The limit comes from `config :cev, budget: %{row_crash_limit: n}`, defaulting
  to #{@default_limit}.
  """
  def poisoned?(crashes) do
    crashes >= Map.get(Config.budget(), :row_crash_limit, @default_limit)
  end
end
