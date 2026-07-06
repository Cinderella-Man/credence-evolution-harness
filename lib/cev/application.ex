defmodule Cev.Application do
  @moduledoc """
  OTP application entry point + supervision tree.

  `Cev.SanityGate` (the dataset-verdict store) and `Cev.Budget` always run. The
  `Cev.Orchestrator` (which drives the continuous pass over the task corpus,
  including the halting preflight) starts **only** when `CEV_RUN=1` — so
  `mix test`, `mix run -e …`, and other dev invocations boot the app without
  kicking off a real run.

  The per-row `:logger` file handler is managed by `Cev.RowLog` (fresh handler
  per row); `RowLog.ensure_ready/0` creates its dirs at boot.

  Real run: `CEV_RUN=1 mix run --no-halt`
  (GPU-less: add `CEV_SOLVE_PROVIDER=xiaomi_mimo_2_5_pro`).
  """

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    Cev.RowLog.ensure_ready()

    children = [Cev.SanityGate, Cev.Budget] ++ orchestrator_child()

    opts = [strategy: :one_for_one, name: Cev.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp orchestrator_child do
    if System.get_env("CEV_RUN") == "1" do
      Logger.info("[Application] CEV_RUN=1 — starting Orchestrator")
      [Cev.Orchestrator]
    else
      []
    end
  end
end
