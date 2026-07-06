defmodule Cev.Config do
  @moduledoc """
  Resolves per-stage providers (with env overrides), Claude Code settings,
  storage paths, and Budget knobs from application config.

  The configurable chat stages are `:solve`, `:classify`, and `:implement`.
  (Translate is gone — the data source is native-Elixir tasks, no Python.)
  """

  @configurable_stages [:solve, :classify, :implement]

  @doc """
  Provider atom for a chat stage. `CEV_<STAGE>_PROVIDER` env wins over the
  configured `stages[stage]`.
  """
  def provider_for(stage) when stage in @configurable_stages do
    case env_provider(stage) do
      nil -> Map.fetch!(stages(), stage)
      provider -> provider
    end
  end

  @doc "Output-token floor for a chat stage (solve 16k, classify 16k, implement 32k)."
  def stage_max_tokens(stage) when stage in @configurable_stages do
    Application.get_env(:cev, :stage_max_tokens, %{}) |> Map.fetch!(stage)
  end

  @doc "Max solve validation retries (1 blind + N-1 harness-guided)."
  def max_retries, do: Application.get_env(:cev, :max_retries, 3)

  # ── Data source (native-Elixir tasks) ───────────────────────────────

  @doc """
  Absolute path to the dataset tasks dir. Resolution order (first wins):

    1. `CEV_TASK_ROOT` env var
    2. `:task_root` in config (config.exs resolves the sibling via `__DIR__`)
    3. sibling `../elixir-sft-dataset/tasks` relative to the current dir

  A relative value (from the env var or config) is expanded against the current
  working directory.
  """
  def task_root do
    (env("CEV_TASK_ROOT") || Application.get_env(:cev, :task_root) ||
       "../elixir-sft-dataset/tasks")
    |> Path.expand()
  end

  @doc "Glob (relative to task_root) selecting task dirs. Default `0*01` = 230 tasks."
  def task_glob, do: Application.get_env(:cev, :task_glob, "0*01")

  @doc "Per-pass solve param maps; pass N uses `Enum.at(schedule, rem(N, length))`."
  def solve_params_schedule do
    Application.get_env(:cev, :solve_params_schedule, [%{temperature: 0.7}])
  end

  @doc "Solve params for a given pass number (cycled through the schedule)."
  def solve_params_for_pass(pass) do
    schedule = solve_params_schedule()
    Enum.at(schedule, rem(pass, length(schedule)))
  end

  @doc "Wall-clock timeout (seconds) for the validator's `mix test` step."
  def validator_test_timeout_s, do: Application.get_env(:cev, :validator_test_timeout_s, 60)

  # ── Implementer loop bounds (07 §5.5) ───────────────────────────────
  def rule_gen_max_retries, do: Application.get_env(:cev, :rule_gen_max_retries, 5)
  def rule_gen_input_ceiling, do: Application.get_env(:cev, :rule_gen_input_ceiling, 240_000)
  def rule_gen_output_ceiling, do: Application.get_env(:cev, :rule_gen_output_ceiling, 480_000)

  # ── Claude Code (rule-gen) ──────────────────────────────────────────

  def claude_code, do: Application.get_env(:cev, :claude_code, %{})
  def cc_base_url, do: Map.fetch!(claude_code(), :base_url)
  def cc_model, do: Map.fetch!(claude_code(), :model)
  def cc_max_turns, do: Map.get(claude_code(), :max_turns, 30)
  def cc_timeout_ms, do: Map.get(claude_code(), :timeout_ms, 1_200_000)
  def cc_auth_token, do: Application.fetch_env!(:cev, :claude_code_auth_token)

  # ── pi agent (alternative implement driver — docs/10) ───────────────
  # pi is a coding-agent CLI (@earendil-works/pi-coding-agent) pointed at Mimo
  # via the custom-provider extension in `pi/mimo_provider.ts`. Used as the
  # agentic implement driver (`implement_driver: :pi`) — many small fast turns
  # instead of one huge slow generation that times out (docs/10 Fix-1 follow-up).
  def pi, do: Application.get_env(:cev, :pi, %{})
  def pi_extension, do: Path.expand(Map.get(pi(), :extension, "pi/mimo_provider.ts"))
  def pi_provider, do: Map.get(pi(), :provider, "mimo")
  def pi_model, do: Map.get(pi(), :model, "mimo-v2.5-pro")
  def pi_thinking, do: Map.get(pi(), :thinking, "low")
  def pi_tools, do: Map.get(pi(), :tools, "read,bash,edit,write")
  def pi_timeout_ms, do: Map.get(pi(), :timeout_ms, 1_800_000)
  def pi_idle_ms, do: Map.get(pi(), :idle_ms, 360_000)

  @doc "Which implement driver: `:llm` (single-call, default) or `:pi` (agent)."
  def implement_driver, do: Application.get_env(:cev, :implement_driver, :llm)

  @doc """
  Bearer key for pi's Mimo provider — reused from the existing
  `secret_providers` (no new secret). Returns the raw token (no `Bearer ` prefix)
  for injection via the `CEV_MIMO_KEY` env var the pi extension reads.
  """
  def pi_mimo_key do
    Application.get_env(:cev, :secret_providers, %{})
    |> get_in([:xiaomi_mimo_2_5_pro, :headers, :Authorization])
    |> case do
      "Bearer " <> key -> key
      other -> other
    end
  end

  # ── Paths ───────────────────────────────────────────────────────────

  @doc """
  Absolute path to the Credence clone (path-dep target + push origin).

  Resolution order (first wins): the `CEV_CREDENCE_CLONE` env var, the
  `:credence_clone` config key, else the sibling `../credence` relative to the
  current dir — so a fresh deploy needs no path edit.
  """
  def credence_clone do
    (env("CEV_CREDENCE_CLONE") || Application.get_env(:cev, :credence_clone) ||
       "../credence")
    |> Path.expand()
  end

  # Read an env var, treating unset/blank as absent.
  defp env(name) do
    case System.get_env(name) do
      nil -> nil
      "" -> nil
      value -> value
    end
  end
  def git_identity, do: Application.get_env(:cev, :git_identity, %{})
  def cache_dir, do: Application.get_env(:cev, :cache_dir, "var/cache")
  def run_dir, do: Application.get_env(:cev, :run_dir, "var/run")

  def cache_path(name), do: Path.join(cache_dir(), name)
  def run_path(name), do: Path.join(run_dir(), name)

  # ── Budget ──────────────────────────────────────────────────────────

  def budget, do: Application.get_env(:cev, :budget, %{})

  @doc "receive_timeout (ms) for every LLM call (docs/10). Probe default 30 min."
  def llm_timeout_ms, do: Map.get(budget(), :llm_timeout_ms, 1_800_000)

  @doc "Consecutive rule-gen :transient_abort rows before a graceful halt."
  def transient_storm_limit, do: Map.get(budget(), :transient_storm_limit, 5)

  @doc "Per-row persisted :transient_abort count before giving the row up to too_slow/."
  def transient_row_limit, do: Map.get(budget(), :transient_row_limit, 3)

  # ── Internal ────────────────────────────────────────────────────────

  defp stages, do: Application.get_env(:cev, :stages, %{})

  defp env_provider(stage) do
    case System.get_env("CEV_#{stage |> to_string() |> String.upcase()}_PROVIDER") do
      nil ->
        nil

      "" ->
        nil

      name ->
        # Provider atoms exist as keys in the providers map (loaded at boot),
        # so to_existing_atom is safe and rejects typos. Resolve first, then
        # raise a friendly error OUTSIDE the rescue (preserves no stacktrace we
        # care about — the input is a typo, not a bug).
        case existing_atom(name) do
          {:ok, atom} ->
            atom

          :error ->
            raise ArgumentError,
                  "CEV_#{String.upcase(to_string(stage))}_PROVIDER=#{name} is not a known provider"
        end
    end
  end

  defp existing_atom(name) do
    {:ok, String.to_existing_atom(name)}
  rescue
    ArgumentError -> :error
  end
end
