defmodule Cev.Status do
  @moduledoc """
  The shared mode file (`STATUS.md` in the accepting credence repo, docs/19 §4).

  It answers one question — **can rules be generated right now?** — so that a
  standard bump cannot be outrun by new rules born under the old bar. While the
  mode reads `CATCHING UP`, the existing rule population is still being brought
  up to the current Rule Standard and a generation run would add to the backlog
  it is trying to clear.

  Until docs/22 T4.1 (this module) the interlock was **prose**: `STATUS.md` and
  docs/21 both described `mix cev.preflight` refusing to start, and nothing in
  the harness read the file at all. A rule enforced by nobody is a rule that has
  already been broken; the point of this module is that the mode line now stops
  a run rather than describing an intention to.

  ## Which copy is authoritative

  The mode is a property of *the standard*, and the standard lives in the
  **accepting** repo — the one where rule bases are reviewed and merged. That is
  deliberately not necessarily the sister clone the Gate builds in: the clone
  sits on the `evolution` branch and its checked-out `STATUS.md` is whatever
  that branch last saw, which can trail the accepting branch by an entire
  standard revision. `Cev.Config.accepting_repo/0` therefore resolves
  independently and only *falls back* to the clone.

  Parsing is deliberately dumb — the first `MODE:` line wins — because the file
  is written for people first. Anything unreadable is an error, never a silent
  pass: a preflight that shrugs when it cannot find the file it exists to check
  is the failure this task was filed to fix.
  """

  @mode_line ~r/^\s*MODE:\s*(?<mode>\S.*?)\s*$/m

  # The ALLOWING value is enumerated, not the blocking one — permission is the
  # thing that has to be stated. Enumerating `CATCHING UP` instead would mean a
  # typo (`CATCHNG UP`), a mode added later, or an empty value all read as
  # permission to generate, which is the failure this interlock exists to
  # prevent wearing a different hat. Compared case-insensitively with internal
  # whitespace collapsed, so `producing` and `PRODUCING` are one answer.
  @allowing "PRODUCING"

  @doc """
  The mode declared by the `STATUS.md` at `path`.

  `{:ok, mode}` with the raw text of the first `MODE:` line, or
  `{:error, :missing}` / `{:error, :no_mode_line}`.
  """
  @spec mode(Path.t()) :: {:ok, String.t()} | {:error, :missing | :no_mode_line}
  def mode(path) do
    case File.read(path) do
      {:ok, contents} -> parse_mode(contents)
      {:error, _} -> {:error, :missing}
    end
  end

  @doc """
  The first `MODE:` line's value, from the file's contents.

      iex> Cev.Status.parse_mode("# STATUS\\n\\nMODE: PRODUCING\\n")
      {:ok, "PRODUCING"}

      iex> Cev.Status.parse_mode("no mode here")
      {:error, :no_mode_line}
  """
  @spec parse_mode(String.t()) :: {:ok, String.t()} | {:error, :no_mode_line}
  def parse_mode(contents) when is_binary(contents) do
    case Regex.named_captures(@mode_line, contents) do
      %{"mode" => mode} -> {:ok, mode}
      nil -> {:error, :no_mode_line}
    end
  end

  @doc """
  Whether `mode` forbids starting a generation run.

  Only `PRODUCING` permits one. Everything else blocks, including a mode this
  module has never heard of — see `@allowing`.

      iex> Cev.Status.blocks_generation?("CATCHING UP")
      true

      iex> Cev.Status.blocks_generation?("PRODUCING")
      false

      iex> Cev.Status.blocks_generation?("CATCHNG UP")
      true
  """
  @spec blocks_generation?(String.t()) :: boolean()
  def blocks_generation?(mode) when is_binary(mode) do
    normalize(mode) != @allowing
  end

  defp normalize(mode) do
    mode
    |> String.upcase()
    |> String.split(~r/\s+/, trim: true)
    |> Enum.join(" ")
  end
end
