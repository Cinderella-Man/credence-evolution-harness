defmodule Cev.MixProject do
  use Mix.Project

  def project do
    [
      app: :cev,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      dialyzer: dialyzer(),
      aliases: aliases()
    ]
  end

  # `mix quality` runs the full gate: zero-warning compile, strict Credo, the
  # test suite, then type analysis. Dialyzer is LAST because `mix dialyzer`
  # halts the VM on completion, which would skip any step after it.
  defp aliases do
    [
      quality: [
        "compile --warnings-as-errors --force",
        "credo --strict",
        "test",
        "dialyzer"
      ]
    ]
  end

  # The mix tasks reference Mix.Task / Mix.shell, so :mix must be in the PLT or
  # Dialyzer reports them as unknown functions.
  defp dialyzer do
    # :unmatched_returns is intentionally omitted — the harness shells out a lot
    # (System.cmd for git/mix), and flagging every fire-and-forget call adds
    # noise without catching real bugs. The kept flags are high-value.
    [
      plt_add_apps: [:mix, :ex_unit],
      flags: [:error_handling, :extra_return, :missing_return]
    ]
  end

  # A supervised OTP application. It does NOT depend on credence — it shells
  # into the local credence clone via the workspace. The dataset is read
  # straight off the filesystem (Cev.TaskSource), so there is no parquet/HTTP
  # data source and no `explorer` dependency.
  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Cev.Application, []}
    ]
  end

  # Run the whole `mix quality` alias in :test so its `test` step is happy (Mix
  # refuses `mix test` in :dev). credo + dialyxir are available in :test too.
  def cli do
    [preferred_envs: [quality: :test]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
