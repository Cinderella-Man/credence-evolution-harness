defmodule Cev.Pipeline.Solve do
  @moduledoc """
  Solve a native-Elixir task with the local model — producing the clumsy-but-
  correct feedstock the rule-gen loop mines.

  **Blind first attempt.** The dataset's `test_harness.exs` is hand-written and
  *idiomatic*; showing it to the model lets it crib those idioms, suppressing the
  clumsiness that is the product. So:

    * attempt 1 sees the `prompt.md` ONLY (unanchored, max-clumsiness);
    * attempts 2+ add the full `test_harness.exs` + the previous attempt + the
      validator errors, so rows still converge to a PASSING solution
      ("passing + non-idiomatic" is the gold rule-gen signal).

  Either way the module is validated against the **dataset** harness (never a
  model-emitted test), and the model reads the required module name from the
  prompt (attempt 1) / harness (attempts 2+); the compile/test loop enforces it —
  so there is no canonical-naming machinery.

  Per-pass solve params (a temperature schedule) arrive via `opts` and are merged
  into the LLM call. Truncation/empty is a normal failed attempt (re-roll); an
  API `{:error, _}` bubbles up for Budget classification.

  Returns `{:ok, %{elixir_code, attempts}}` / `{:failed, %{reason, attempts,
  last}}` / `{:error, reason}`.
  """

  require Logger

  alias Cev.{Config, LLM, Parser, Report, Validator}

  @system ~S"""
  You write Elixir. Given a problem statement, implement the module(s) it asks
  for so the described behaviour works.

  - Produce a single self-contained solution (one or more modules in one file).
  - Name the module exactly as the problem statement asks.
  - Use only the OTP standard library unless the problem says otherwise.

  OUTPUT: the complete Elixir source in ONE fenced code block:

  ```elixir
  <your module(s)>
  ```

  No prose, no explanation — just the code block.
  """

  @doc "The Solve system prompt."
  def system_prompt, do: @system

  @doc "Blind initial prompt — the problem statement only (no test harness)."
  def build_initial(prompt) do
    """
    Implement this Elixir task.

    #{prompt}

    Output the complete module(s) in one ```elixir code block.
    """
  end

  @doc "Retry prompt — reveals the harness + the previous attempt + the errors."
  def build_retry(prompt, test, previous_code, failures) do
    """
    Your previous Elixir solution did not pass. Fix it so it compiles cleanly and
    passes the test suite below.

    ## Task
    #{prompt}

    ## Test suite (your module MUST pass these — do not modify them)
    ```elixir
    #{test}
    ```

    ## Your previous attempt
    ```elixir
    #{previous_code}
    ```

    ## What failed
    #{Report.format_errors(failures)}

    Output the corrected module(s) in one ```elixir code block.
    """
  end

  @doc """
  Run the Solve loop. `prompt` is the task's `prompt.md`, `test` its
  `test_harness.exs` (the authoritative validation harness). `opts` are merged
  into the LLM call (e.g. the per-pass `temperature`).
  """
  def run(prompt, test, workspace, opts \\ []) do
    user = build_initial(prompt)
    attempt(prompt, test, user, workspace, opts, 1, nil)
  end

  # ── Attempt loop ────────────────────────────────────────────────────

  defp attempt(prompt, test, user, ws, opts, n, last) do
    if n > Config.max_retries() do
      Logger.warning("[Solve] giving up after #{n - 1} attempts")
      {:failed, %{reason: "exceeded retries", attempts: n - 1, last: last}}
    else
      do_attempt(prompt, test, user, ws, opts, n, last)
    end
  end

  defp do_attempt(prompt, test, user, ws, opts, n, last) do
    Logger.info("[Solve attempt #{n}] generating (#{if n == 1, do: "blind", else: "harness-guided"})")

    case LLM.for_stage(:solve, user, system_prompt(), opts) do
      {:ok, content, _usage} ->
        handle_content(content, prompt, test, ws, opts, n, last)

      {:truncated, _content, _usage} ->
        Logger.warning("[Solve attempt #{n}] truncated — re-roll")
        attempt(prompt, test, build_initial(prompt), ws, opts, n + 1, last)

      {:empty, reason} ->
        Logger.warning("[Solve attempt #{n}] empty (#{reason}) — retry")
        attempt(prompt, test, build_initial(prompt), ws, opts, n + 1, last)

      {:error, reason} ->
        Logger.error("[Solve attempt #{n}] API error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp handle_content(content, prompt, test, ws, opts, n, last) do
    case extract_module(content) do
      {:ok, module_code} ->
        {fails, final_mod, _final_test} = Validator.run(module_code, test, ws)

        current = %{elixir_code: final_mod, validation_failures: fails}

        if fails == [] do
          Logger.info("[Solve attempt #{n}] validation PASSED")
          {:ok, %{elixir_code: final_mod, attempts: n}}
        else
          Logger.warning(
            "[Solve attempt #{n}] validation FAILED: #{inspect(Enum.map(fails, &elem(&1, 0)))}"
          )

          retry = build_retry(prompt, test, module_code, fails)
          attempt(prompt, test, retry, ws, opts, n + 1, current)
        end

      :error ->
        Logger.warning("[Solve attempt #{n}] no code found in output — re-roll")
        attempt(prompt, test, build_initial(prompt), ws, opts, n + 1, last)
    end
  end

  # ── Module extraction ───────────────────────────────────────────────

  # Pull the Elixir source out of the model's reply. Prefers fenced ```elixir
  # blocks (joined, for multi-module solutions); falls back to `---MODULE---`
  # markers; else the whole stripped content. Requires a `defmodule` to accept.
  @doc false
  def extract_module(content) do
    code =
      cond do
        (blocks = fenced_blocks(content)) != [] -> Enum.join(blocks, "\n\n")
        String.contains?(content, "---MODULE---") -> between_markers(content)
        true -> Parser.strip_outer_fences(content)
      end

    code = String.trim(code)
    if String.contains?(code, "defmodule"), do: {:ok, code}, else: :error
  end

  defp fenced_blocks(content) do
    ~r/```(?:elixir|ex)?\s*\n(.*?)\n```/s
    |> Regex.scan(content, capture: :all_but_first)
    |> Enum.map(fn [body] -> String.trim(body) end)
    |> Enum.filter(&String.contains?(&1, "defmodule"))
  end

  defp between_markers(content) do
    content
    |> String.split("---MODULE---", parts: 2)
    |> List.last()
    |> String.split("---END---", parts: 2)
    |> List.first()
    |> Parser.strip_outer_fences()
  end
end
