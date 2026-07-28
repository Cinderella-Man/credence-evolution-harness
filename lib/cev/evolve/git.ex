defmodule Cev.Evolve.Git do
  @moduledoc """
  After the Gate passes: **commit → recompile → push**.

  The app never handles credentials — git auth lives in the clone's SSH remote.
  The commit message tags the decision type and flags removals to direct human
  PR attention. Recompiling the credence path dep after committing makes the new
  rule take effect for subsequent rows (and auto-dedups the pattern from future
  output). A single push failure to `origin evolution` is **non-fatal** — boot
  reconciliation catches up later — but a *streak* is not: it means the remote is
  gone and the run has quietly become local-only, which is how a 24/7 session
  ends up with days of commits nobody else can see. Consecutive failures trip the
  same circuit breaker the transient-storm path uses (H14).
  """

  require Logger

  alias Cev.{Config, Workspace}

  @branch "evolution"

  @doc """
  Commit the staged rule change, recompile credence, and push.

  `summary` is the Gate summary (`:removes`); `opts[:decision]` enriches the
  message. Returns `:ok` (commit succeeded; push best-effort) or
  `{:error, reason}` if the commit itself failed.
  """
  def commit_and_push(idx, summary, opts \\ []) do
    clone = Keyword.get(opts, :clone, Config.credence_clone())
    msg = commit_message(idx, summary, opts)

    git(clone, ["add", "-A"])

    case git(clone, ["commit", "-m", msg]) do
      {_out, 0} ->
        Logger.info("[Git] committed: #{msg}")
        Workspace.recompile_credence()
        push(clone)
        :ok

      {out, code} ->
        Logger.error("[Git] commit failed (exit #{code}): #{out}")
        {:error, {:commit_failed, code}}
    end
  end

  @doc "Compose the tagged commit message."
  def commit_message(idx, summary, opts) do
    decision = Keyword.get(opts, :decision, "update credence rules")
    removes = Map.get(summary, :removes, [])

    removes_tag =
      case removes do
        [] -> ""
        list -> " [removes #{Enum.join(list, ", ")}]"
      end

    "cred-gen: #{decision}#{removes_tag} [row #{idx}]"
  end

  # ── Internal ────────────────────────────────────────────────────────

  defp push(clone) do
    case git(clone, ["push", "origin", @branch]) do
      {_out, 0} ->
        reset_push_failures()
        Logger.info("[Git] pushed origin/#{@branch}")
        :ok

      {out, code} ->
        streak = record_push_failure()
        limit = push_failure_limit()

        case push_breaker_step(streak, limit) do
          :halt ->
            Logger.error(
              "[Git] push failed #{streak} times consecutively (limit #{limit}) — halting. " <>
                "The run has been committing locally with no remote; fix the remote and " <>
                "restart, boot reconciliation will catch up. Last error: #{out}"
            )

            Cev.shutdown({:push_failures, streak})

          :cont ->
            Logger.error(
              "[Git] push failed (exit #{code}), streak #{streak}/#{limit} — " <>
                "commits are local only: #{out}"
            )
        end

        :ok
    end
  end

  @doc false
  # Pure breaker decision, exposed for tests exactly as
  # `Cev.Orchestrator.breaker_step/3` is: `:halt` at the limit, else `:cont`.
  # Keeping the decision pure is the difference between a breaker you can prove
  # trips and one you hope does.
  @spec push_breaker_step(non_neg_integer(), pos_integer()) :: :halt | :cont
  def push_breaker_step(streak, limit) when streak >= limit, do: :halt
  def push_breaker_step(_streak, _limit), do: :cont

  @doc false
  def push_failure_limit, do: Application.get_env(:cev, :push_failure_limit, 5)

  @push_failures {__MODULE__, :consecutive_push_failures}

  defp record_push_failure do
    n = :persistent_term.get(@push_failures, 0) + 1
    :persistent_term.put(@push_failures, n)
    n
  end

  @doc false
  def reset_push_failures, do: :persistent_term.put(@push_failures, 0)

  @doc false
  def consecutive_push_failures, do: :persistent_term.get(@push_failures, 0)

  defp git(clone, args), do: System.cmd("git", args, cd: clone, stderr_to_stdout: true)
end
