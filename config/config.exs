import Config

config :cev,
  # ── Data source (native-Elixir tasks read straight off the filesystem) ─
  # The slice is dir-names starting `0` and ending `01` (230 tasks — the
  # first variant of each numbered problem family). Widen the glob to pull
  # more variants / families.
  #
  # `task_root` defaults to the sibling `elixir-sft-dataset/tasks`, resolved
  # relative to THIS file (`__DIR__` = the config/ dir), so it is independent of
  # the directory you launch `mix` from. Override without editing this file via
  # the `CEV_TASK_ROOT` env var, or set an absolute path string here.
  task_root: Path.expand("../../elixir-sft-dataset/tasks", __DIR__),
  task_glob: "0*01",

  # ── Retry budget ────────────────────────────────────────────────────
  # 1 blind attempt (feedstock) + 2 harness-guided (convergence). Emission is
  # gone, so retries exist only for signal; pass cadence beats tail-grinding.
  max_retries: 3,

  # ── Per-pass solve params (diversity across re-passes) ──────────────
  # Pass N uses schedule[rem(N, length)]. Cycling the temperature makes the
  # local model surface different clumsiness each pass (confident habits →
  # default variance → unstable tail). Merged into the LLM call by Solve.
  solve_params_schedule: [
    %{temperature: 0.6},
    %{temperature: 0.9},
    %{temperature: 1.2}
  ],

  # ── Validator test-step wall-clock timeout (seconds) ────────────────
  # Bounds the ONE step that runs arbitrary model code (`mix test`). Without
  # it an infinite-loop solution blocks the row forever (Tunex had no timeout).
  # 60s is safe: the slowest legitimate harness sleeps ~6s total.
  validator_test_timeout_s: 60,

  # ── Chat providers (Translate + Solve) ──────────────────────────────
  # `token_param` names the request field carrying the output-token cap
  # (Mimo: max_completion_tokens; vLLM/OpenAI-compatible Qwen: max_tokens).
  # The per-stage floor (see `stage_max_tokens`) is injected at call time by
  # LLM.for_stage; a provider-level value here is only a fallback.
  providers: %{
    xiaomi_mimo_2_5_pro: %{
      url: "https://token-plan-sgp.xiaomimimo.com/v1/chat/completions",
      model: "mimo-v2.5-pro",
      token_param: :max_completion_tokens,
      max_completion_tokens: 32_768,
      stream: false
    },
    # Non-pro V2.5 (310B MoE, 15B active) — the SOLVE model. Weaker than the pro,
    # so its less-idiomatic output is the rule-discovery feedstock; translate +
    # rule-gen stay on the stronger pro. (Replaces the deprecated mimo-v2-pro,
    # which auto-routes to V2.5 on 2026-06-01 and is removed by 2026-06-30.)
    xiaomi_mimo_2_5: %{
      url: "https://token-plan-sgp.xiaomimimo.com/v1/chat/completions",
      model: "mimo-v2.5",
      token_param: :max_completion_tokens,
      max_completion_tokens: 16_384,
      stream: false
    },
    local_qwen_non_thinking: %{
      url: "http://localhost:8000/v1/chat/completions",
      model: "unsloth/Qwen3-Coder-Next-GGUF-UD-Q6_K_XL",
      token_param: :max_tokens,
      max_tokens: 256_000,
      chat_template_kwargs: %{enable_thinking: false},
      stream: false
    },
    local_qwen_thinking: %{
      url: "http://localhost:8000/v1/chat/completions",
      model: "unsloth/Qwen3-Coder-Next-GGUF-UD-Q6_K_XL",
      token_param: :max_tokens,
      max_tokens: 256_000,
      stream: false
    },
    # Optional alternative CLASSIFIER provider (07 §3.1, 08 T0.1b). Claude Opus
    # via an **OpenAI-compatible** endpoint ONLY — Cev.LLM speaks OpenAI Chat
    # Completions; native Anthropic /v1/messages won't parse. Use Anthropic's
    # /v1/chat/completions compat layer or a gateway (OpenRouter / LiteLLM).
    # The auth header (Authorization/x-api-key) lives in config/secrets.exs
    # under secret_providers[:anthropic_opus] — absent by default, so this
    # provider is inert unless stages.classify is repointed at it.
    anthropic_opus: %{
      url: "https://api.anthropic.com/v1/chat/completions",
      model: "claude-opus-4-8",
      token_param: :max_tokens,
      max_tokens: 16_384,
      stream: false
    }
  },

  # ── Stage → provider (the rule-gen stage is hardcoded, not here) ────
  # Overridable per-stage via CEV_SOLVE_PROVIDER / CEV_CLASSIFY_PROVIDER.
  stages: %{
    # Solve runs a LOCAL model — free, and its weaker/less-idiomatic output is
    # the rule-discovery feedstock. The remote :xiaomi_mimo_2_5 path is the
    # GPU-less dev fallback (CEV_SOLVE_PROVIDER=xiaomi_mimo_2_5).
    solve: :local_qwen_thinking,
    # Classifier-split rebuild (07 §3.1). The classifier carries the hardest
    # judgment — default to the strong Mimo-pro (in-bucket, thinking on by
    # default); repoint at :anthropic_opus (or CEV_CLASSIFY_PROVIDER) to pay
    # for Opus brains. The implementer is the solver-style fill loop.
    classify: :xiaomi_mimo_2_5_pro,
    implement: :xiaomi_mimo_2_5_pro
  },

  # ── Per-stage output-token floors ───────────────────────────────────
  # Solve emits one module. The classifier emits a marker-fenced spec
  # (decision + before/after); the implementer emits whole rule + test files.
  # Tune against truncation (08 T0.1 / 07 §14).
  stage_max_tokens: %{
    solve: 16_384,
    classify: 16_384,
    implement: 32_768
  },

  # ── Implementer loop bounds (07 §5.5, 08 T5.5) ──────────────────────
  # Dedicated knobs (NOT shared with solve's max_retries). The ceilings are a
  # cheap local string guard (char-length proxy for tokens) that kills the
  # 552-line-rule pathology — zero console poll, no max_turns.
  rule_gen_max_retries: 5,
  rule_gen_input_ceiling: 240_000,
  rule_gen_output_ceiling: 480_000,

  # ── Implement driver (docs/10) ──────────────────────────────────────
  # :cc = hand the rich context to the Claude Code agent (Mimo via the
  # Anthropic-compatible endpoint); it fills the on-disk stubs, runs `mix test`,
  # and loops itself (config under `claude_code:` below). :pi = the same agentic
  # loop driven by the `pi` CLI instead. :llm = the old single-shot
  # emit→write→test loop. All three re-verify with our own focused `mix test`.
  implement_driver: :cc,
  pi: %{
    extension: "pi/mimo_provider.ts",
    provider: "mimo",
    model: "mimo-v2.5-pro",
    # Reasoning level for rule authoring; "off" was only for the speed smoke —
    # rules need some reasoning. Tune against speed/quality.
    thinking: "low",
    tools: "read,bash,edit,write",
    timeout_ms: 1_800_000,
    # Idle cutoff: kill if NO agent event arrives for this long (a stalled Mimo
    # stream otherwise burns the full timeout_ms — docs/10). Streaming emits
    # deltas every few seconds during a real turn, so this only trips on a true
    # stall; keep it well above the slowest single Mimo turn (~4.5 min observed).
    idle_ms: 360_000
  },

  # ── Claude Code (rule-gen) — Mimo via the Anthropic-compatible endpoint
  # auth_token lives in secrets.exs (see claude_code_auth_token).
  claude_code: %{
    base_url: "https://token-plan-sgp.xiaomimimo.com/anthropic",
    model: "mimo-v2.5-pro[1m]",
    # Generous — this runs 24/7 and an hour/rule is still superhuman. These are
    # backstops, not budgets: a thorough rule-write session (read files → write
    # rule + test → iterate `mix test`) needs turns, and Mimo is slow. The
    # runaway-$ ceiling still guards true runaways. `max_turns` is Claude Code's
    # own turn count (NOT the per-message "step N" in logs).
    max_turns: 80,
    # Wall-clock safety cap for one rule-gen session; a hung session is killed →
    # treated as gave_up.
    timeout_ms: 3_600_000
  },

  # ── Credence clone (path dep target + push origin) ──────────────────
  # OPTIONAL: when unset, defaults to a sibling `credence/` dir next to this
  # project (`../credence`). Set an absolute path only to override that.
  # credence_clone: "/home/car/projects/credence",

  # Commit identity the app sets on the clone (Preflight). MUST use a GitHub
  # *noreply* email — a real email triggers GH007 "push would publish a private
  # email address" when the account has email-privacy protection, which silently
  # fails the (non-fatal) push and strands commits locally. Find yours at
  # GitHub → Settings → Emails (format: <id>+<login>@users.noreply.github.com).
  git_identity: %{
    name: "Kamil Skowron",
    email: "1019893+Cinderella-Man@users.noreply.github.com"
  },

  # ── Storage layout (keep-vs-wipe split, see plan #16) ───────────────
  cache_dir: "var/cache",
  run_dir: "var/run",

  # ── Budget — Mimo is the only paid dependency ───────────────────────
  # Prices are USD per token (Mimo ≤256K tier: $1/M in, $3/M out).
  # runaway_ceiling_usd is a safety abort only (catches loops, not rationing);
  # tune for a CC rule-gen session on every row. PLACEHOLDER — see plan
  # "Unresolved": confirm the real ceiling after first runs.
  budget: %{
    # ── Per-provider token prices (USD per token) ───────────────────────
    # CORRECTED to the real May-27-2026 token-plan pay-as-you-go rates. The
    # OLD flat 1/0.3/3 was ~83x too high on cache_read and wrong on in/out;
    # it inflated spend tracking and mis-sized the runaway ceiling.
    #   mimo-v2.5-pro : in $0.435/M  cache_read $0.0036/M  out $0.87/M
    #   mimo-v2.5     : in $1.00/M   cache_read $0.20/M     out $3.00/M
    #   :cc (rule-gen) = mimo-v2.5-pro[1m] → pro prices
    # NOTE: these are pay-as-you-go USD. The actual $50/mo plan meters
    # discounted "Credits", so derived $ is a RELATIVE estimate — the raw
    # token COUNTS logged to var/run/usage.jsonl are the ground truth.
    prices: %{
      xiaomi_mimo_2_5_pro: %{in: 0.435 / 1_000_000, cache_read: 0.0036 / 1_000_000, out: 0.87 / 1_000_000},
      xiaomi_mimo_2_5: %{in: 1.0 / 1_000_000, cache_read: 0.20 / 1_000_000, out: 3.0 / 1_000_000},
      cc: %{in: 0.435 / 1_000_000, cache_read: 0.0036 / 1_000_000, out: 0.87 / 1_000_000},
      # Anthropic public pay-as-you-go for Opus (per-token). Only used when the
      # classifier is repointed at :anthropic_opus; logged $ is a relative
      # estimate either way (token COUNTS are exact). (08 T0.1b)
      anthropic_opus: %{in: 15.0 / 1_000_000, cache_read: 1.5 / 1_000_000, out: 75.0 / 1_000_000}
    },
    # Fallback price for an unknown provider (uses pro rates).
    default_price: %{in: 0.435 / 1_000_000, cache_read: 0.0036 / 1_000_000, out: 0.87 / 1_000_000},
    runaway_ceiling_usd: 500.0,
    # 429-streak → fatal; transient (5xx/network) retry/backoff before halt.
    max_consecutive_429: 5,
    transient_retries: 5,
    transient_backoff_ms: 2_000,
    # ── Rule-gen resilience (docs/10_log_review_fixes.md) ───────────────
    # llm_timeout_ms is the receive_timeout for EVERY LLM call. Raised from the
    # old hardcoded 600_000 after the logs showed the 26/28 escalated + the
    # classifier_error were slow `implement` generations cut off at the 10-min
    # ceiling (NOT network blips: Mimo succeeded earlier in the same row 28/28).
    # 1_800_000 (30 min) is the PROBE value — set production = the measured
    # completion-time ceiling + ~30% after re-running the 28 timed-out rows.
    llm_timeout_ms: 1_800_000,
    # Consecutive rule-gen :transient_abort rows → graceful halt (a real Mimo
    # outage halts cleanly instead of churning the whole pending list).
    transient_storm_limit: 5,
    # Per-row persisted :transient_abort count → give the row up to too_slow/
    # (so a consistently-too-slow row can't re-run + time out forever).
    transient_row_limit: 3
  }

config :logger,
  level: :debug

if File.exists?("config/secrets.exs") do
  import_config "secrets.exs"
end
