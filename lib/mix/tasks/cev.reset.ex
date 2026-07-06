defmodule Mix.Tasks.Cev.Reset do
  @moduledoc """
  Re-initialize a run: wipe `var/run/` and recreate the empty run dirs.

  `var/cache/` (the sanity-gate `task_verdicts.jsonl`) is left intact — a dataset
  entry doesn't get less broken on a fresh run, so its verdict survives re-init.
  Run-scoped state (decisions.md, Progress, the pass counter, the whole `logs/`
  tree — the live row file + its categorised `escalated/`, `committed/`, …
  subfolders — and the validation workspace) is regenerable and gets wiped.
  """
  use Mix.Task

  @shortdoc "Wipe var/run/ (keeps var/cache/) to start a fresh evolution run"

  @run_dir "var/run"
  @cache_dir "var/cache"
  # workspace + logs/ and every classifier-split outcome dir nested under it
  # (07 §8, 08 T6.5). Outcome dirs now live under logs/, so the live row file
  # and its categorised destinations share one tree.
  @run_subdirs ["workspace", "logs" | Enum.map(Cev.RowLog.outcome_dirs(), &Path.join("logs", &1))]

  @impl true
  def run(_args) do
    _ = File.rm_rf!(@run_dir)
    File.mkdir_p!(@run_dir)
    for sub <- @run_subdirs, do: File.mkdir_p!(Path.join(@run_dir, sub))
    File.mkdir_p!(@cache_dir)

    Mix.shell().info("cev.reset: wiped #{@run_dir}/ (kept #{@cache_dir}/)")
  end
end
