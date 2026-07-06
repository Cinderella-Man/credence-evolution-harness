# Credence Evolution Harness (`:cev`)

A 24/7, human-free OTP loop that feeds native-Elixir coding tasks to a local
model, validates the output with **Credence**, and drives an agent to write or
fix Credence rules. The product is **Credence rules** — running the dataset is
just the workload that surfaces where Credence is weak.

It is a fork of [`opc-sft-stage2-elixir`](../opc-sft-stage2-elixir) ("Tunex")
with the Python-translation data source replaced by a direct read of the
[`elixir-sft-dataset`](../elixir-sft-dataset) tasks. Full design and rationale:
**[`docs/DESIGN.md`](docs/DESIGN.md)** (+ [`CONTEXT.md`](CONTEXT.md) glossary and
[`docs/adr/`](docs/adr/)).

## The loop, per task

```
pick task (prompt.md + test_harness.exs + solution.ex)
  → Sanity gate  reference passes its own harness? (once ever, cached)  → else blacklist
  → Solve        local model; attempt 1 BLIND (prompt only), retries add the harness
  → Validate     credence-fix → compile → format → credo → credence-check → test
  → Rule-gen     Router → Classify (Mimo) → Novelty → Equiv → Implement → Gate
  → Gate         5-part contract + mutation + full suite (incl. corpus)
  → Git          commit → recompile credence → push evolution
  → next task; on exhaustion → new pass (new shuffle, next temperature)
```

## Setup

1. **Sibling repos** (all under the same parent dir):
   - `elixir-sft-dataset` — the task corpus (`tasks/0*01` → 230 tasks).
   - `credence` — the linter being evolved, checked out on branch **`evolution`**
     with a clean tree and a pre-authenticated push remote.
2. **Deps:** `mix deps.get`
3. **Secrets:** `cp config/secrets.dummy.exs config/secrets.exs` and fill in the
   Mimo `tp-…` token (classify + implement) and, for the ground-truth budget
   meter, the Mimo console cookie.
4. **Local model:** serve an OpenAI-compatible endpoint for Solve (llama.cpp /
   vLLM) at the URL in `config.exs` (`providers.local_qwen_thinking.url`).
5. **`claude` CLI** on `PATH` if `implement_driver: :cc` (the default).

Key config knobs (`config/config.exs`): `task_root` / `task_glob` (data source),
`solve_params_schedule` (per-pass temperature), `max_retries` (3), `stages`
(solve = local, classify/implement = Mimo), `validator_test_timeout_s` (60).

Paths default to siblings of this project (resolved via `__DIR__`, so they don't
depend on where you launch `mix` from) and can be overridden per-run without
editing config:

| Env var | Overrides | Default |
|---|---|---|
| `CEV_TASK_ROOT` | dataset tasks dir | `../elixir-sft-dataset/tasks` |
| `CEV_CREDENCE_CLONE` | the Credence clone | `../credence` |
| `CEV_SOLVE_PROVIDER` / `CEV_CLASSIFY_PROVIDER` | per-stage model provider | from `config.exs` |

> **Secrets note:** `config/secrets.exs` must use `config :cev, …`. If you copied
> it from the Tunex project, rename `config :tunex` → `config :cev`.

## Run

```
CEV_RUN=1 mix run --no-halt          # start the continuous loop (boots preflight first)
CEV_SOLVE_PROVIDER=xiaomi_mimo_2_5 CEV_RUN=1 mix run --no-halt   # GPU-less: solve on Mimo
```

The orchestrator starts **only** under `CEV_RUN=1`, so `mix test` / dev never
kick off a run. Kill it when a pass goes dry, PR `evolution` → `main` in the
credence clone, then `mix cev.reset` for a fresh run.

### Operator tasks

| Task | Purpose |
|---|---|
| `mix cev.preflight` | Validate clone/branch, tasks, secrets, endpoints — without running. |
| `mix cev.reset` | Wipe `var/run/` (keeps `var/cache/` = sanity-gate verdicts). |
| `mix cev.budget` | Live Mimo token-bucket balance (ground truth). |
| `mix cev.usage` | Cost by stage / outcome from the in-band ledger (undercounts; relative). |
| `mix cev.diag` | One rule-gen session, measuring the ledger-vs-console undercount. |

## Test & quality

```
mix test                         # hermetic unit suite (integration tests excluded)
mix test --include integration   # also run tests that shell into the live credence clone
mix quality                      # compile --warnings-as-errors + credo --strict + dialyzer + test
```

The codebase is warning-clean, passes `mix credo --strict`, and type-checks
under Dialyzer (`mix quality` gates all four).

## Storage (`var/`, gitignored)

- `var/cache/task_verdicts.jsonl` — sanity-gate verdicts, keyed by content hash;
  **survives `mix cev.reset`**.
- `var/run/` — regenerable: the `pass` counter, `progress` (done indices this
  pass), `rows.jsonl`, the `logs/` tree (live row file + `committed/`,
  `escalated/`, `no_action/`, … outcome dirs), and the validation `workspace/`.

Committed rules are pushed to the `evolution` branch of the credence clone; a
human PRs `evolution` → `main`.
