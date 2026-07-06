defmodule Cev.TaskSource do
  @moduledoc """
  The data source: native-Elixir coding tasks read straight off the filesystem.

  Replaces Tunex's HuggingFace-parquet `Dataset` (and the whole Python→Elixir
  translation + round-trip pipeline). Each task dir under `Cev.Config.task_root`
  matching `Cev.Config.task_glob` (default `0*01` → 230 tasks) contains:

    * `prompt.md`        — the natural-language Elixir request (fed to Solve)
    * `test_harness.exs` — the ExUnit module that judges a solution
    * `solution.ex`      — the idiomatic reference (Sanity gate + Classify
                           gold-contrast; NEVER shown to Solve)

  `list/0` returns the tasks in a stable sorted order; the orchestrator indexes
  into that list. `load/1` reads a task's files on demand.
  """

  alias Cev.Config

  @typedoc "A task's identity on disk (before its files are read)."
  @type ref :: %{name: String.t(), path: String.t()}

  @typedoc "A loaded task: its prompt, harness, and (optional) gold reference."
  @type t :: %{
          name: String.t(),
          prompt: String.t(),
          test: String.t(),
          reference: String.t() | nil
        }

  @doc "All matching task dirs, sorted by name, as `%{name, path}` maps."
  @spec list() :: [ref()]
  def list do
    Path.wildcard(Path.join(Config.task_root(), Config.task_glob()))
    |> Enum.filter(&File.dir?/1)
    |> Enum.sort()
    |> Enum.map(fn dir -> %{name: Path.basename(dir), path: dir} end)
  end

  @doc "Number of matching tasks."
  @spec count() :: non_neg_integer()
  def count, do: length(list())

  @doc """
  Read a task's files. Returns `%{name, prompt, test, reference}` where
  `reference` is the gold `solution.ex` (or `nil` if absent).
  """
  @spec load(ref()) :: t()
  def load(%{name: name, path: path}) do
    %{
      name: name,
      prompt: File.read!(Path.join(path, "prompt.md")),
      test: File.read!(Path.join(path, "test_harness.exs")),
      reference: read_optional(Path.join(path, "solution.ex"))
    }
  end

  defp read_optional(path) do
    case File.read(path) do
      {:ok, content} -> content
      {:error, _} -> nil
    end
  end
end
