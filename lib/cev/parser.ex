defmodule Cev.Parser do
  @moduledoc """
  Parses structured LLM output delimited by `---SECTION---` markers.

  Supports these output formats:
  - Module+Test only: `---MODULE--- / ---TEST--- / ---END---`
  - Instruction only: `---INSTRUCTION--- / ---END---`
  """

  @doc "Parse output with module and test sections only (no instruction)."
  def parse_module_test(content) do
    content = strip_outer_fences(content)

    case split_markers(content) do
      {:ok, module_code, test_code} -> {:ok, module_code, test_code}
      :error -> split_bare_modules(content)
    end
  end

  defp split_markers(content) do
    with [_, rest] <- String.split(content, "---MODULE---", parts: 2),
         [module_code, rest] <- String.split(rest, "---TEST---", parts: 2) do
      test_code = rest |> String.split("---END---", parts: 2) |> List.first() |> strip_fences()
      module_code = strip_fences(module_code)

      if module_code != "" and test_code != "" do
        {:ok, module_code, test_code}
      else
        :error
      end
    else
      _ -> :error
    end
  end

  # Fallback: the model dropped the markers and emitted two bare modules (common
  # on retries). Split at the test module — `defmodule …Test do`, which is also
  # the block carrying `use ExUnit.Case`. Everything before it is the solution.
  defp split_bare_modules(content) do
    case Regex.split(~r/\n(?=defmodule\s+[\w.]*Test\b)/, content, parts: 2) do
      [module_code, test_code] ->
        module_code = String.trim(module_code)
        test_code = String.trim(test_code)

        if String.contains?(module_code, "defmodule") and
             String.contains?(test_code, "use ExUnit.Case") do
          {:ok, module_code, test_code}
        else
          :error
        end

      _ ->
        :error
    end
  end

  @doc "Parse output with instruction section only."
  def parse_instruction(content) do
    content = strip_outer_fences(content)

    case String.split(content, "---INSTRUCTION---", parts: 2) do
      [_, rest] ->
        instruction = rest |> String.split("---END---", parts: 2) |> List.first() |> String.trim()
        if instruction != "", do: {:ok, instruction}, else: :error

      _ ->
        :error
    end
  end

  # ── Internal ───────────────────────────────────────────────────────

  @doc """
  Strip a single outer markdown code fence (first + last only) off `s`.

  Non-multiline by design: only the leading ```` ```lang ```` and the trailing
  ```` ``` ```` are removed, so a mid-content fence (e.g. inside a rule's
  `@moduledoc`) is preserved. Used by the rule-gen output/spec parsers to undo
  the model wrapping whole files in fences (docs/10 Fix 2).
  """
  def strip_outer_fences(s) do
    s
    |> String.replace(~r/^```\w*\n?/, "")
    |> String.replace(~r/\n?```$/, "")
    |> String.trim()
  end

  defp strip_fences(s) do
    s
    |> String.replace(~r/^```\w*\n?/m, "")
    |> String.replace(~r/\n?```\s*$/m, "")
    |> String.trim()
  end
end
