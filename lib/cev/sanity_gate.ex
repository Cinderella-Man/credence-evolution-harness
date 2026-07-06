defmodule Cev.SanityGate do
  @moduledoc """
  One-time, cached check that a task's gold `solution.ex` passes its own
  `test_harness.exs` — so a broken dataset entry is blacklisted once and skipped
  in every future pass (instead of burning solves + a Mimo classify call every
  pass, and polluting the `:failed` classify lens with a broken-harness premise).

  Salvaged from Tunex's `Pipeline.RoundTrip` (the fix-free runner) + `Cache`
  (the durable jsonl verdict store), with three empirically-motivated hardenings
  (DESIGN §4, ADR-0006):

    * **Lenient compile** — `mix compile --force` WITHOUT `--warnings-as-errors`
      (strict falsely blacklists gold code that merely warns under a newer
      Elixir; the strict bar stays on MODEL output in `Validator`).
    * **Retry-once** — a failing check re-runs once before blacklisting (the
      corpus caught a genuinely flaky timing-sensitive harness).
    * **Content-hash keys** — verdicts key on `sha256(solution.ex + test)`, so an
      upstream dataset edit auto-invalidates the cached verdict.

  Verdicts live in `var/cache/task_verdicts.jsonl` and **survive `mix cev.reset`**
  (a dataset entry doesn't get less broken on a fresh run).

  Runs as a GenServer owning the store (fast `get`/`put`); the compile+test check
  itself runs in the caller (the orchestrator) so a slow check never blocks the
  store's mailbox.
  """

  use GenServer
  require Logger

  alias Cev.{Config, Workspace}

  @name __MODULE__

  @type verdict :: :ok | :blacklist

  # ── Public API ──────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))
  end

  @doc """
  Resolve a task's sanity verdict (`:ok | :blacklist`), running the one-time
  check on a cache miss. A task with no reference solution is `:ok` (nothing to
  check — never blacklist for a missing gold file).
  """
  @spec ensure(Cev.TaskSource.t(), String.t(), GenServer.server()) :: verdict()
  def ensure(task, workspace \\ Workspace.default_path(), server \\ @name) do
    case task.reference do
      nil ->
        :ok

      reference ->
        h = hash(reference, task.test)

        case GenServer.call(server, {:get, h}) do
          nil ->
            verdict = run_check(task, reference, workspace)
            GenServer.call(server, {:put, h, task.name, verdict})
            verdict

          verdict ->
            verdict
        end
    end
  end

  @doc false
  @spec hash(binary(), binary()) :: String.t()
  def hash(reference, test) do
    :crypto.hash(:sha256, [reference, "\0", test]) |> Base.encode16(case: :lower)
  end

  # ── The fix-free check (lenient compile + test, retry-once) ─────────

  defp run_check(task, reference, workspace) do
    case check(reference, task.test, workspace) do
      :ok ->
        Logger.info("[SanityGate] #{task.name}: reference PASSES (verdict :ok)")
        :ok

      {:fail, why} ->
        Logger.warning("[SanityGate] #{task.name}: reference failed (#{why}) — retrying once")

        case check(reference, task.test, workspace) do
          :ok ->
            Logger.info("[SanityGate] #{task.name}: PASSED on retry (flaky) — verdict :ok")
            :ok

          {:fail, why2} ->
            Logger.warning("[SanityGate] #{task.name}: BLACKLISTED (#{why2}) — skipped every pass")
            :blacklist
        end
    end
  end

  # Fix-free runner: lenient compile + test only (no Credence/credo/format), so
  # the verdict is a pure function of the dataset entry.
  defp check(reference, test, workspace) do
    mod_path = Path.join(workspace, "lib/solution.ex")
    test_path = Path.join(workspace, "test/solution_test.exs")

    Workspace.clean_workspace(workspace)
    File.write!(mod_path, reference)
    File.write!(test_path, ensure_exunit_case(test))

    {compile_out, compile_code} =
      System.cmd("mix", ["compile", "--force"],
        cd: workspace,
        stderr_to_stdout: true,
        env: [{"MIX_ENV", "test"}]
      )

    if compile_code != 0 do
      Logger.debug("[SanityGate] compile failed:\n#{compile_out}")
      {:fail, "compile"}
    else
      {test_out, test_code} =
        System.cmd("mix", ["test", "test/solution_test.exs", "--no-deps-check"],
          cd: workspace,
          stderr_to_stdout: true,
          env: [{"MIX_ENV", "test"}]
        )

      if test_code == 0 do
        :ok
      else
        Logger.debug("[SanityGate] tests failed:\n#{test_out}")
        {:fail, "test"}
      end
    end
  end

  defp ensure_exunit_case(test_code) do
    if String.contains?(test_code, "use ExUnit.Case") do
      test_code
    else
      Regex.replace(
        ~r/(defmodule\s+\S+\s+do\s*\n)/,
        test_code,
        "\\1  use ExUnit.Case, async: false\n",
        global: false
      )
    end
  end

  # ── GenServer (the verdict store) ───────────────────────────────────

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, Config.cache_path("task_verdicts.jsonl"))
    File.mkdir_p!(Path.dirname(path))
    map = load(path)
    Logger.info("[SanityGate] loaded #{map_size(map)} cached verdict(s) from #{path}")
    {:ok, %{path: path, map: map}}
  end

  @impl true
  def handle_call({:get, hash}, _from, state) do
    {:reply, Map.get(state.map, hash), state}
  end

  @impl true
  def handle_call({:put, hash, name, verdict}, _from, state) do
    line = Jason.encode!(%{"hash" => hash, "name" => name, "verdict" => to_string(verdict)}) <> "\n"
    File.write!(state.path, line, [:append, :utf8])
    {:reply, :ok, %{state | map: Map.put(state.map, hash, verdict)}}
  end

  defp load(path) do
    if File.exists?(path) do
      path
      |> File.stream!()
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == ""))
      |> Stream.map(&Jason.decode!/1)
      |> Map.new(fn r -> {r["hash"], to_verdict(r["verdict"])} end)
    else
      %{}
    end
  end

  defp to_verdict("ok"), do: :ok
  defp to_verdict("blacklist"), do: :blacklist
end
