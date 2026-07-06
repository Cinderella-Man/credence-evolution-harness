defmodule Cev.RuleIndex do
  @moduledoc """
  A compact, deterministic (0-token) index of the existing Credence rules —
  `<phase>/<name> — <one-line intent>` per line — read straight from each rule
  file's `@moduledoc` first sentence.

  Fed to the classifier so it can recognise when a proposed idiom is ALREADY
  covered — even under a differently-worded name — and emit NO_ACTION instead of
  a duplicate. Name-only lists miss renamed duplicates (row 42678:
  `prefer_reduce_when_never_halting` duplicated `no_reduce_while_without_halt`;
  row 82807 shipped `no_doc_false_on_private` a second time), so the one-line
  INTENT is the point.
  """

  @phases ~w(pattern syntax semantic)

  @doc """
  Build the index string for `clone`. Each line is
  `<phase>/<name> — <intent>`, sorted, intents clipped to ~`width` chars.
  """
  def build(clone \\ Cev.Config.credence_clone(), width \\ 110) do
    for phase <- @phases,
        file <- Path.wildcard(Path.join(clone, "lib/#{phase}/*.ex")) do
      name = Path.basename(file, ".ex")
      "#{phase}/#{name} — #{intent(file, width)}"
    end
    |> Enum.sort()
    |> Enum.join("\n")
  end

  # First non-blank line of the `@moduledoc`, whitespace-collapsed and clipped.
  # Falls back to "" when a rule has no moduledoc (still lists the name).
  defp intent(file, width) do
    with {:ok, src} <- File.read(file),
         [_, body] <- Regex.run(~r/@moduledoc\s+"""(.*?)"""/s, src) do
      body
      |> String.split("\n", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.find("", &(&1 != ""))
      |> String.slice(0, width)
    else
      _ -> ""
    end
  end
end
