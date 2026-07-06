defmodule Cev.Orchestrator do
  @moduledoc """
  The continuous-pass loop over the native-Elixir task corpus.

  Boot: preflight (fail fast) → reconciliation → load the task list → resume the
  current pass from the `Progress` file.

  Per task (in a per-pass shuffled order): sanity-gate skip if the dataset entry
  is blacklisted; else Solve (local model — blind first attempt, then
  harness-guided) → rule-gen (Router reads the row log and routes its fate) →
  `Progress.mark_done` **LAST**. A throwing task is logged, the clone discarded,
  and the task skipped — never crashing the loop.

  When a pass over all tasks completes, the loop rolls into the next pass (new
  shuffle order, next scheduled solve temperature) and runs again — the corpus
  is finite and small, and re-passes yield fresh feedstock (the local model is
  non-deterministic and committed rules change the landscape). Runs until killed.
  """

  use GenServer, restart: :transient
  require Logger

  alias Cev.{Budget, Config, Preflight, Progress, RowLog, SanityGate, TaskSource, Workspace}
  alias Cev.Evolve.Router
  alias Cev.Pipeline.Solve

  # ── Lifecycle ───────────────────────────────────────────────────────

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts), do: {:ok, %{opts: opts}, {:continue, :boot}}

  @impl true
  def handle_continue(:boot, %{opts: _opts}) do
    Preflight.run!()

    tasks = TaskSource.list()
    total = length(tasks)

    if total == 0 do
      Logger.error("[Orchestrator] no tasks matched #{Config.task_root()}/#{Config.task_glob()}")
      System.halt(1)
    end

    pass = load_pass()
    progress_path = Config.run_path("progress")
    completed = Progress.load(progress_path)
    order = permutation(pass, total)
    pending = Enum.reject(order, &MapSet.member?(completed, &1))

    Logger.info(
      "[Orchestrator] pass=#{pass} total=#{total} done=#{MapSet.size(completed)} pending=#{length(pending)}"
    )

    rowstat = open_synced(Config.run_path("rows.jsonl"))

    RowLog.ensure_ready()
    budget = Config.budget()

    state = %{
      tasks: List.to_tuple(tasks),
      total: total,
      pass: pass,
      pending: pending,
      solve_params: Enum.into(Config.solve_params_for_pass(pass), []),
      workspace: Workspace.default_path(),
      progress_path: progress_path,
      rowstat: rowstat,
      transient_retries: Map.get(budget, :transient_retries, 5),
      transient_backoff_ms: Map.get(budget, :transient_backoff_ms, 2_000),
      transient_storm_limit: Config.transient_storm_limit(),
      consecutive_transient: 0,
      started_mono: System.monotonic_time(:millisecond),
      done: 0
    }

    Logger.info("[Orchestrator] pass #{pass} solve params: #{inspect(state.solve_params)}")
    send(self(), :next)
    {:noreply, state}
  end

  # ── Pass loop ───────────────────────────────────────────────────────

  @impl true
  def handle_info(:next, %{pending: []} = state) do
    # Pass complete → roll into the next pass (finite corpus, continuous re-pass).
    next_pass = state.pass + 1
    save_pass(next_pass)
    Progress.clear(state.progress_path)

    order = permutation(next_pass, state.total)
    params = Enum.into(Config.solve_params_for_pass(next_pass), [])

    Logger.info(
      "[Orchestrator] ── pass #{state.pass} complete (#{state.total} tasks) → starting pass #{next_pass} " <>
        "(solve params #{inspect(params)}) ──"
    )

    state = %{state | pass: next_pass, pending: order, solve_params: params}
    send(self(), :next)
    {:noreply, state}
  end

  def handle_info(:next, %{pending: [idx | rest]} = state) do
    outcome = run_row(idx, state)
    state = apply_breaker(state, outcome, idx)
    state = %{state | pending: rest, done: state.done + 1}
    log_progress(state)
    send(self(), :next)
    {:noreply, state}
  end

  # Consecutive-:transient_abort circuit breaker: a real Mimo outage halts
  # cleanly instead of churning the pending list. A blacklisted/skipped task
  # carries no Mimo signal (left unchanged); any real outcome resets the streak.
  defp apply_breaker(state, outcome, idx) do
    case breaker_step(state.consecutive_transient, state.transient_storm_limit, outcome) do
      :halt ->
        Cev.shutdown({:transient_storm, idx})
        state

      {:cont, n} ->
        if n > 0, do: Logger.warning("[Orchestrator] transient_abort streak #{n}/#{state.transient_storm_limit}")
        %{state | consecutive_transient: n}
    end
  end

  @doc false
  # Pure breaker decision (exposed for tests): `:halt` at the limit, else the new
  # consecutive count. Blacklist holds; any non-abort real outcome resets to 0.
  def breaker_step(consecutive, limit, outcome) do
    case outcome do
      :transient_abort -> if consecutive + 1 >= limit, do: :halt, else: {:cont, consecutive + 1}
      :blacklist -> {:cont, consecutive}
      _ -> {:cont, 0}
    end
  end

  # Live trajectory line after every row: throughput + projected daily burn.
  defp log_progress(state) do
    hrs = max((System.monotonic_time(:millisecond) - state.started_mono) / 3_600_000, 1.0e-9)
    spent = Budget.spent()
    rate = state.done / hrs

    Logger.info(
      "[progress] pass=#{state.pass} session_rows=#{state.done} (#{length(state.pending)} left this pass) " <>
        "elapsed=#{Float.round(hrs, 2)}h rate=#{Float.round(rate, 1)} rows/hr " <>
        "est=$#{Float.round(spent, 4)} → ~$#{Float.round(spent / hrs * 24, 2)}/day"
    )
  end

  # ── Per-task ────────────────────────────────────────────────────────

  # Returns the breaker-relevant outcome (`:transient_abort` / `:blacklist` /
  # a real rule-gen outcome / `:exception`) for the consecutive-abort breaker.
  defp run_row(idx, state) do
    do_row(idx, state)
  rescue
    e ->
      Logger.error("[idx=#{idx}] EXCEPTION: #{Exception.format(:error, e, __STACKTRACE__)}")
      discard_clone()
      safe_close_log(idx)
      write_row_stat(state, %{index: idx, ts: System.os_time(:second), outcome: :exception})
      Progress.mark_done(state.progress_path, idx)
      :exception
  end

  defp do_row(idx, state) do
    t0 = System.monotonic_time(:millisecond)
    spent0 = Budget.spent()
    Budget.set_row(idx)
    RowLog.open(idx)
    task = TaskSource.load(elem(state.tasks, idx))
    Logger.info("[idx=#{idx}] task=#{task.name}")

    stat =
      case SanityGate.ensure(task, state.workspace) do
        :blacklist ->
          Logger.info("[idx=#{idx}] sanity blacklist — skipping")
          RowLog.close(idx)
          Progress.mark_done(state.progress_path, idx)
          %{task: task.name, sanity: :blacklist}

        :ok ->
          solve_and_finish(idx, task, state)
      end

    elapsed = Float.round((System.monotonic_time(:millisecond) - t0) / 1000, 1)
    cost_est = Float.round(Budget.spent() - spent0, 6)

    write_row_stat(
      state,
      Map.merge(%{index: idx, ts: System.os_time(:second), elapsed_s: elapsed, cost_est: cost_est}, stat)
    )

    Logger.info("[idx=#{idx}] finished in #{elapsed}s (est $#{cost_est})")
    breaker_outcome(stat)
  end

  # The breaker watches the rule-gen outcome; a blacklisted/skipped task never
  # reached Mimo (own signal); a solve row's outcome resets the streak. Every
  # `stat` from `do_row` carries exactly one of these keys.
  defp breaker_outcome(%{sanity: _}), do: :blacklist
  defp breaker_outcome(%{rulegen: o}), do: o

  defp solve_and_finish(idx, task, state) do
    # Distillation boundary: the classifier keeps everything BELOW this sentinel
    # (the solve attempts + fix traces). Emitted unconditionally, immediately
    # before the solve stage.
    Logger.info("===SOLVE_BOUNDARY===")

    solve =
      stage(
        fn -> Solve.run(task.prompt, task.test, state.workspace, state.solve_params) end,
        state
      )

    # Rule-gen runs on EVERY task that reached Solve (success or failed); the
    # Router reads the row log and routes its fate itself. The solve outcome
    # forks the classifier lens; the task's gold solution.ex is threaded in as
    # the Classify gold-contrast.
    rg = safe_rule_gen(idx, router_outcome(solve), task.reference)

    if rg_outcome(rg) == :transient_abort do
      # Don't-consume: a recoverable rule-gen timeout — skip mark_done so the
      # task re-runs cleanly next pass. The log already moved to transient/.
      Logger.info("[idx=#{idx}] transient_abort — NOT consuming (re-runs next pass)")
    else
      Progress.mark_done(state.progress_path, idx)
    end

    %{
      task: task.name,
      solve: solve_tag(solve),
      solve_attempts: solve_attempts(solve),
      temperature: state.solve_params[:temperature],
      rulegen: rg_outcome(rg),
      decision: rg_decision(rg)
    }
  end

  defp safe_rule_gen(idx, solve_outcome, reference) do
    Router.run(idx, solve_outcome, Config.credence_clone(), reference: reference)
  rescue
    e ->
      Logger.error("[idx=#{idx}] router raised: #{Exception.message(e)} — discarding clone")
      discard_clone()
      safe_close_log(idx)
      %{outcome: :raised, decision: nil}
  end

  # The classifier lens forks on solve outcome: :solved judges the clean final
  # for idiomatic residual; :failed judges the attempts for an unfixed issue.
  defp router_outcome({:ok, _}), do: :solved
  defp router_outcome(_), do: :failed

  # `stage/2` consumes any `{:error, _}` (retry or halt), so a resolved solve is
  # always `{:ok, _}` or `{:failed, _}`.
  defp solve_tag({:ok, _}), do: :ok
  defp solve_tag({:failed, _}), do: :failed

  defp solve_attempts({:ok, sr}), do: sr[:attempts]
  defp solve_attempts({:failed, info}), do: info[:attempts]

  defp rg_outcome(%{outcome: o}), do: o

  defp rg_decision(%{decision: d}) when not is_nil(d), do: inspect(d)
  defp rg_decision(_), do: nil

  defp write_row_stat(state, map), do: append_synced(state.rowstat, map)

  # ── API-error retry / backoff / shutdown ────────────────────────────

  defp stage(fun, state, attempt \\ 1) do
    case fun.() do
      {:error, reason} ->
        Logger.error("[stage] API error (attempt #{attempt}): #{inspect(reason)}")

        case Budget.classify_error(reason) do
          :fatal ->
            Cev.shutdown({:fatal_api, reason})

          :transient ->
            if attempt > state.transient_retries do
              Cev.shutdown({:transient_exhausted, reason})
            else
              Process.sleep(backoff(state, attempt))
              stage(fun, state, attempt + 1)
            end
        end

      other ->
        Budget.note_success()
        other
    end
  end

  defp backoff(state, attempt), do: state.transient_backoff_ms * Integer.pow(2, attempt - 1)

  # ── Pass state ──────────────────────────────────────────────────────

  defp load_pass do
    path = Config.run_path("pass")

    if File.exists?(path) do
      path |> File.read!() |> String.trim() |> String.to_integer()
    else
      0
    end
  end

  defp save_pass(pass) do
    path = Config.run_path("pass")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Integer.to_string(pass))
  end

  # Deterministic per-pass permutation of the task indices (seed = pass number),
  # so each pass rotates which tasks meet the evolving ruleset, and a crash-resume
  # within a pass re-derives the same order.
  defp permutation(pass, n) do
    seed = pass + 1
    :rand.seed(:exsss, {seed, seed, seed})
    Enum.shuffle(0..(n - 1))
  end

  # ── Low-level ───────────────────────────────────────────────────────

  defp open_synced(path) do
    File.mkdir_p!(Path.dirname(path))
    {:ok, handle} = :file.open(String.to_charlist(path), [:append, :raw, :binary])
    handle
  end

  defp append_synced(handle, map) do
    :ok = :file.write(handle, [Jason.encode!(map), "\n"])
    :file.sync(handle)
  end

  defp discard_clone do
    clone = Config.credence_clone()
    System.cmd("git", ["checkout", "--", "."], cd: clone, stderr_to_stdout: true)
    System.cmd("git", ["clean", "-fd"], cd: clone, stderr_to_stdout: true)
  end

  defp safe_close_log(idx) do
    RowLog.close(idx)
  rescue
    _ -> :ok
  end
end
