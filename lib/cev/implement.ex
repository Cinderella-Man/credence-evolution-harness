defmodule Cev.Implement do
  @moduledoc """
  The solver-style implementer loop (07 §5; 08 T5.3). Same shape as solve: LLM
  emits whole files → we write them into the clone → focused `mix test` →
  trimmed failures fed back → flat (non-accumulating) retry ≤ `rule_gen_max_retries`.
  No tools, no harness, no token breaker — a local input/output size ceiling
  kills the oversize-row pathology.

  Returns `{:ok, %{module, paths}}` (the Gate runs next, Phase 6) or
  `{:gave_up, reason}` (the router discards the clone + escalates).

  `ctx` (built by the router, Phase 6) carries: `:mode`, `:phase`, `:spec`,
  `:scaffold` (new) / `:bugfix` (bugfix), `:clone`, plus the seed ingredients
  (`:scaffold_files`, `:ast_before/after`, `:real_diagnostic`, `:minimal_set`,
  `:repair?`).
  """

  require Logger

  alias Cev.{ClaudeCode, Config, LLM, Pi}
  alias Cev.Implement.{Output, Seed}

  @doc """
  Implement the rule for `ctx`. Two drivers (docs/10), chosen by
  `opts[:driver]` (defaults to `Config.implement_driver/0`):

    * `:llm` — the single-shot emit→write→test→retry loop below.
    * `:pi` — hand the SAME context to the `pi` coding agent, which fills the
      already-on-disk stubs, runs `mix test`, and loops itself; we then verify
      with the same `focused_test/1` (never trust the agent's word).

  Both return `{:ok, %{module, paths}}` or `{:gave_up, reason}` — the Gate runs next.
  """
  def run(ctx, opts \\ []) do
    case Keyword.get(opts, :driver, Config.implement_driver()) do
      :pi -> run_agent(ctx, opts, agent_fun(opts, &Pi.run/2), :pi)
      :cc -> run_agent(ctx, opts, agent_fun(opts, &cc_run/2), :cc)
      _ -> run_llm(ctx, opts)
    end
  end

  # The agent fn is injectable (tests pass `:pi`); otherwise the driver default.
  defp agent_fun(opts, default), do: Keyword.get(opts, :pi, default)

  defp run_llm(ctx, opts) do
    emit = Keyword.get(opts, :emit, &default_emit/2)
    seed = Seed.build(ctx)
    loop(ctx, seed, seed, 1, 0, emit)
  end

  # Agentic driver (`:pi` or `:cc`): the router already wrote the scaffold stubs
  # into the clone (new mode) or the rule+tests are already there (bugfix), so the
  # agent edits them in place. After it finishes we re-run the focused tests
  # ourselves — a green claim from the agent is not trusted. The prompt and
  # verification are harness-agnostic; `tag` (`:pi`/`:cc`) only labels the
  # give-up reason so the router classifies a `{tag, "timeout"}` as transient.
  defp run_agent(ctx, _opts, agent, tag) do
    prompt = Seed.build(ctx, driver: :pi)

    case agent.(prompt, cwd: ctx.clone, row: ctx[:row]) do
      {:ok, _result} ->
        # H9 / T4.5 row 6. An agent that made 25 read-only steps and never wrote
        # anything leaves the scaffold placeholders exactly as we generated them.
        # Running the tests then fails — of course it does, the stub is a stub —
        # and the row was booked `cc_tests_red`, a MERIT failure. That poisons
        # decisions.md with a dead-end idea nobody ever attempted. Checked BEFORE
        # the canonicalisers, which rewrite files themselves.
        if wrote_nothing?(ctx) do
          Logger.warning("[Implement] agent finished having written nothing — null run")
          {:gave_up, {tag, "no_writes"}}
        else
          canonicalize_fix_tests(ctx)
          normalize_test_heredocs(ctx)

          case focused_test(ctx) do
            :pass ->
              {:ok, result(ctx)}

            {:fail, leg, failures} ->
              {:gave_up, {tests_red_tag(tag), "[#{leg}] " <> trim(failures)}}
          end
        end

      {:gave_up, reason} ->
        {:gave_up, {tag, reason}}
    end
  end

  # True when every file we handed the agent is byte-identical to what we wrote.
  # A missing file counts as CHANGED (it was deleted), not as a null run — the
  # question is "did the agent do anything", not "is the tree pristine".
  defp wrote_nothing?(%{mode: :new, scaffold_files: files, clone: clone}) do
    files != %{} and Enum.all?(files, &unchanged?(clone, &1))
  end

  # `rule_src`, not `rule_source`. `Router.bugfix_ctx/5` writes `rule_src` and
  # `Implement.Seed` reads `rule_src`; this was the only `rule_source` in either
  # `lib/` or `test/`, so the map access raised `KeyError` on EVERY bugfix row.
  # The raise escapes into `Orchestrator.safe_rule_gen/3`'s rescue, which throws
  # away a completed implementer session — ~25 minutes of agent work — and books
  # the row `:raised` with a log that the crash handler then deletes.
  #
  # It never ran in anger: it was introduced after the 3rd evolution finished.
  # The test below is the positive control it shipped without.
  defp wrote_nothing?(%{mode: :bugfix, bugfix: bf, clone: clone}) do
    unchanged?(clone, {bf.rule_path, bf.rule_src}) and
      Enum.all?(bf.test_files, &unchanged?(clone, &1))
  end

  defp wrote_nothing?(_ctx), do: false

  defp unchanged?(clone, {rel, original}) do
    case File.read(Path.join(clone, rel)) do
      {:ok, current} -> current == original
      {:error, _} -> false
    end
  end

  defp tests_red_tag(:pi), do: :pi_tests_red
  defp tests_red_tag(:cc), do: :cc_tests_red

  # Adapter: map the ClaudeCode contract onto the agent contract `run_agent`
  # expects (`{:ok, result}` | `{:gave_up, reason}`). CC reports a hung/over-long
  # session inside the result `subtype` (NOT a top-level `:gave_up`), and its
  # `:decision` is generator-flow-specific (it parses a `DECISION` line the
  # implement agent never emits), so we key off `subtype` and otherwise hand the
  # result to `focused_test`, which is the real judge.
  defp cc_run(prompt, opts) do
    case ClaudeCode.run(prompt, opts) do
      {:ok, %{subtype: "error_timeout"}} -> {:gave_up, "timeout"}
      {:ok, %{subtype: "error_max_turns"}} -> {:gave_up, "max turns reached"}
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:gave_up, "cc_error: #{inspect(reason)}"}
    end
  end

  # Deterministic cleanup before the Gate (docs/10): the agent can't byte-predict
  # the rule's exact output, so its `expected =` heredocs are often wrong → the
  # fix test fails → the (often correct) rule is rejected. `mix credence.fix_tests`
  # rewrites `expected` to the rule's REAL output (the project's own convention),
  # for free, no agent turns. Best-effort: a rule that doesn't compile is skipped
  # there and caught by focused_test/the Gate as before.
  defp canonicalize_fix_tests(ctx) do
    fix_tests = ctx |> test_paths() |> Enum.filter(&String.ends_with?(&1, "_fix_test.exs"))

    if fix_tests != [] do
      System.cmd("mix", ["credence.fix_tests" | fix_tests],
        cd: ctx.clone,
        stderr_to_stdout: true,
        env: [{"MIX_ENV", "test"}]
      )
    end
  rescue
    _ -> :ok
  end

  # Strip gratuitous heredoc trailing `\` from the rule's test files before the
  # Gate (docs/10). Verified-safe per file (it re-runs each test, reverts on red),
  # so it can only tidy — never break a green suite.
  defp normalize_test_heredocs(ctx) do
    tests = ctx |> test_paths() |> Enum.filter(&String.ends_with?(&1, "_test.exs"))

    if tests != [] do
      System.cmd("mix", ["credence.normalize_tests" | tests],
        cd: ctx.clone,
        stderr_to_stdout: true,
        env: [{"MIX_ENV", "test"}]
      )
    end
  rescue
    _ -> :ok
  end

  defp loop(ctx, seed, user, attempt, out_total, emit) do
    cond do
      String.length(user) > Config.rule_gen_input_ceiling() ->
        {:gave_up, {:input_ceiling, String.length(user)}}

      out_total > Config.rule_gen_output_ceiling() ->
        {:gave_up, {:output_ceiling, out_total}}

      true ->
        do_attempt(ctx, seed, user, attempt, out_total, emit)
    end
  end

  defp do_attempt(ctx, seed, user, attempt, out_total, emit) do
    case emit.(user, Seed.system()) do
      {tag, content, _usage} when tag in [:ok, :truncated] ->
        out_total = out_total + String.length(content)

        case Output.parse(content, output_opts(ctx)) do
          {:ok, files} ->
            write_files(ctx, files)

            case focused_test(ctx) do
              :pass ->
                {:ok, result(ctx)}

              # The leg is prepended so the retry seed tells the model WHICH bar
              # it missed: its own tests, or a cross-rule invariant it has never
              # been told about. Those need different repairs.
              {:fail, leg, failures} ->
                retry(ctx, seed, content, "[#{leg}] " <> failures, attempt, out_total, emit)
            end

          {:error, reason} ->
            retry(
              ctx,
              seed,
              content,
              "INVALID EMIT: #{inspect(reason)}",
              attempt,
              out_total,
              emit
            )
        end

      {:error, reason} ->
        {:gave_up, {:llm_error, reason}}
    end
  end

  defp retry(ctx, seed, last, failures, attempt, out_total, emit) do
    if attempt >= Config.rule_gen_max_retries() do
      # The TAIL, not the head: ExUnit prints its failure detail at the end, so
      # the first 400 bytes were reliably the least informative 400 bytes.
      {:gave_up, {:retries_exhausted, trim(failures)}}
    else
      # Flat retry: seed + the LAST attempt + the LAST failures (not the whole
      # history) — keeps per-retry size flat, not quadratic (§5.5).
      user =
        "#{seed}\n\n## YOUR LAST ATTEMPT (FAILED)\n#{last}\n\n## FAILURES (fix these)\n#{trim(failures)}"

      loop(ctx, seed, user, attempt + 1, out_total, emit)
    end
  end

  # ── Output → opts ─────────────────────────────────────────────────────────

  defp output_opts(%{mode: :new, phase: phase} = ctx) do
    [mode: :new, phase: phase, assumptions?: ctx[:minimal_set] not in [nil, []]]
  end

  defp output_opts(%{mode: :bugfix, bugfix: bf}) do
    [mode: :bugfix, test_glob: Map.keys(bf.test_files)]
  end

  # ── Write ─────────────────────────────────────────────────────────────────

  defp write_files(%{mode: :new, scaffold: sc, clone: clone}, %{rule: rule, tests: tests}) do
    roles = role_paths(sc.paths, sc.snake, sc.phase)
    write(clone, roles["RULE"], rule)

    Enum.each(tests, fn {role, content} ->
      case roles[role] do
        nil ->
          # PROPERTY_TEST has no scaffold file; derive its path by convention.
          if role == "PROPERTY_TEST",
            do: write(clone, "test/#{sc.phase}/#{sc.snake}_property_test.exs", content)

        path ->
          write(clone, path, content)
      end
    end)
  end

  defp write_files(%{mode: :bugfix, bugfix: bf, clone: clone}, %{rule: rule, tests: tests}) do
    write(clone, bf.rule_path, rule)
    Enum.each(tests, fn {path, content} -> write(clone, path, content) end)
  end

  # Map scaffold paths to role markers by filename suffix.
  defp role_paths(paths, _snake, _phase) do
    Enum.reduce(paths, %{}, fn rel, acc ->
      cond do
        String.starts_with?(rel, "lib/") -> Map.put(acc, "RULE", rel)
        String.ends_with?(rel, "_check_test.exs") -> Map.put(acc, "CHECK_TEST", rel)
        String.ends_with?(rel, "_analyze_test.exs") -> Map.put(acc, "CHECK_TEST", rel)
        String.ends_with?(rel, "_fix_test.exs") -> Map.put(acc, "FIX_TEST", rel)
        String.ends_with?(rel, "_equivalence_test.exs") -> Map.put(acc, "EQUIVALENCE_TEST", rel)
        true -> acc
      end
    end)
  end

  defp write(clone, rel, content) do
    path = Path.join(clone, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  # ── Focused test ──────────────────────────────────────────────────────────

  # Two-phase: the rule's own tests first (small, targeted retry feedback for the
  # common failure), then the corpus-free suite — all meta + cross-rule invariants
  # (DSL-safety, equivalence/fix/check-meta, scope-parity), ~15s. The latter is the
  # Gate's fail-fast bar; making it the implementer's finishing bar means a rule
  # that trips a cross-rule invariant (e.g. an unclassified `==`/`if` fix) is fixed
  # in-loop — the `:llm` driver retries on the failure, the agent driver is told to
  # run it too (Seed) — instead of dying at the Gate. The ~8-min corpus stays
  # Gate-only; here it is excluded so the loop never re-sends its output.
  # Reports WHICH leg failed. Both legs used to collapse into one 400-character
  # slice with no exit code and no attribution, so "the rule's own tests are red"
  # and "the rule trips a cross-rule invariant" — different problems needing
  # different repairs — arrived at the router indistinguishable (rows 100/119).
  defp focused_test(%{clone: clone} = ctx) do
    case run_mix_test(clone, test_paths(ctx)) do
      :pass ->
        case run_mix_test(clone, ["--exclude", "corpus"]) do
          :pass -> :pass
          {:fail, out} -> {:fail, :cross_rule_invariants, out}
        end

      {:fail, out} ->
        {:fail, :own_tests, out}
    end
  end

  defp run_mix_test(clone, args) do
    case Cev.MixTest.run(clone, args) do
      {:ok, 0, _out} ->
        :pass

      {:ok, _code, out} ->
        {:fail, out}

      # Reported as a failure so the implementer loop reacts, but labelled so the
      # retry feedback says "the suite hung" rather than handing the model a
      # truncated log to guess at. Routing it as environmental rather than merit
      # is T4.5's scope, not this one's.
      {:timeout, secs, out} ->
        {:fail, out <> "\n[Implement] `mix test` exceeded the #{secs}s cap and was killed.\n"}
    end
  end

  defp test_paths(%{mode: :new, scaffold: sc, clone: clone}) do
    Path.wildcard(Path.join(clone, "test/#{sc.phase}/#{sc.snake}*_test.exs"))
    |> Enum.map(&Path.relative_to(&1, clone))
  end

  defp test_paths(%{mode: :bugfix, bugfix: bf}), do: Map.keys(bf.test_files)

  # ── Result ────────────────────────────────────────────────────────────────

  defp result(%{mode: :new, scaffold: sc}), do: %{module: sc.module, paths: sc.paths}

  defp result(%{mode: :bugfix, bugfix: bf}),
    do: %{module: bf.module, paths: [bf.rule_path | Map.keys(bf.test_files)]}

  defp trim(failures), do: String.slice(failures, -3000, 3000)

  defp default_emit(user, system), do: LLM.for_stage(:implement, user, system)
end
