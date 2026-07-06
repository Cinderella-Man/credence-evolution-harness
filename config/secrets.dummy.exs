import Config

# Template for config/secrets.exs (the real file is gitignored).
# Copy to config/secrets.exs and fill in real values.
#
# ⚠️  The application atom is `:cev` (NOT `:tunex`). If you copied a secrets.exs
#     from the opc-sft-stage2-elixir/Tunex project, change `config :tunex` →
#     `config :cev`, or Elixir warns "configured application :tunex … not
#     available" and none of your keys are seen.
config :cev,
  # Mimo chat-completions auth (Translate + Solve-remote-override).
  secret_providers: %{
    xiaomi_mimo_2_5_pro: %{
      headers: %{
        Authorization: "Bearer tp-xxxxxxxxxxxxxxxxxx"
      }
    },
    xiaomi_mimo_2_5: %{
      headers: %{
        Authorization: "Bearer tp-xxxxxxxxxxxxxxxxxx"
      }
    }
  },
  # Claude Code → Mimo Anthropic-compatible endpoint (ANTHROPIC_AUTH_TOKEN).
  claude_code_auth_token: "tp-xxxxxxxxxxxxxxxxxx",
  # OPTIONAL — MiMo console session cookie for the GROUND-TRUTH token-bucket
  # poll (`mix cev.budget`, auto-reconcile in `mix cev.diag`, the live token
  # circuit breaker). This is the Xiaomi-Account browser cookie, NOT a tp- key,
  # and it EXPIRES (re-grab from DevTools → Network → tokenPlan/usage → Copy as
  # cURL). Can also be set via the CEV_MIMO_COOKIE env var.
  mimo_console_cookie: ~s(cookie-preferences=...; api-platform_serviceToken="..."; userId=...; api-platform_slh="..."; api-platform_ph="...")
