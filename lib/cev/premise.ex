defmodule Cev.Premise do
  @moduledoc """
  Check a proposal's premise against the compiler before spending an implementer
  run on it (docs/22 T4.2e).

  Rule premises were being asserted by the classifier and never checked, and each
  false one cost a full ~80-turn implementer run. The escalation ledger measured
  it: row 221's stated motivation — a `--warnings-as-errors` failure from
  `incompatible types given to Kernel.*/2: float(), dynamic()` — **does not
  exist**; the exact shape compiles clean, because `dynamic()` is compatible with
  `float()`. Row 150 attributed an always-invalid ETS option to "OTP 27+". Across
  nine reviewed rows that was roughly $100 of implementer budget spent on
  premises one compile would have refuted.

  ## What is checked, and what deliberately is not

  The prose rationale is not matched against the compiler output — that would need
  the claim to be machine-readable, and it is not. What *is* mechanical is the
  weaker statement that has to hold for the proposal to make any sense at all:

    * **Semantic** proposals key on a compiler diagnostic. If `BEFORE` compiles
      with no diagnostic at all, there is nothing for the rule to match, whatever
      the rationale says.
    * **Syntax** proposals only ever run on source that fails to parse
      (`lib/syntax` is skipped otherwise). If `BEFORE` parses, the rule is inert
      by construction — the G2 class, 18 of the 143 rejects.

  Pattern proposals are not checked here: they work on the AST of code that
  compiles fine, so "no diagnostic" is their normal state and would be a false
  accusation.

  ## Compiling is running

  `Code.compile_string/2` evaluates top-level expressions, so this executes
  model-supplied source. It therefore runs in a child process with a heap ceiling
  and a deadline, exactly as `Credence.RuleHelpers.compile_and_capture/1` does
  after that same hazard took a 64 GB box down seven times in one day. A premise
  check that can hang the run is worse than no premise check.
  """

  require Logger

  @compile_max_heap_words 64_000_000
  @compile_timeout_ms 15_000

  @doc """
  `:ok`, or `{:error, reason}` when the premise cannot be true.

  Unknown phases and anything unparseable-for-other-reasons return `:ok`: this
  gate exists to catch a *refuted* premise, and "we could not tell" must never
  read as "refuted".
  """
  @spec check(atom(), String.t() | nil) :: :ok | {:error, atom()}
  def check(:semantic, before) when is_binary(before) do
    case diagnostics(before) do
      {:ok, []} -> {:error, :premise_no_diagnostic}
      {:ok, _some} -> :ok
      :unknown -> :ok
    end
  end

  def check(:syntax, before) when is_binary(before) do
    case Code.string_to_quoted(before) do
      {:ok, _ast} -> {:error, :premise_syntax_parses}
      {:error, _} -> :ok
    end
  end

  def check(_phase, _before), do: :ok

  # Every diagnostic the compiler emits for `source`, or `:unknown` if the
  # compile could not be completed inside its budget.
  defp diagnostics(source) do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        Process.flag(:max_heap_size, %{
          size: @compile_max_heap_words,
          kill: true,
          error_logger: false
        })

        result =
          try do
            {out, diags} =
              Code.with_diagnostics(fn ->
                try do
                  Code.compile_string(source, "cev_premise.ex")
                rescue
                  e -> {:raised, e}
                end
              end)

            # A compile that RAISED counts, even when it emitted no diagnostic
            # struct — a `CompileError` raised rather than reported still means
            # the source does not build, so a semantic rule has something to key
            # on. Treating that as "no premise" would refute a true one.
            case out do
              {:raised, _e} -> {:ok, [:raised | diags]}
              _ -> {:ok, diags}
            end
          rescue
            _ -> :unknown
          end

        send(parent, {__MODULE__, :done, result})
      end)

    receive do
      {__MODULE__, :done, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, :process, _pid, _reason} ->
        :unknown
    after
      @compile_timeout_ms ->
        Process.exit(pid, :kill)
        Logger.warning("[Premise] BEFORE did not finish compiling in #{@compile_timeout_ms}ms")
        :unknown
    end
  end
end
