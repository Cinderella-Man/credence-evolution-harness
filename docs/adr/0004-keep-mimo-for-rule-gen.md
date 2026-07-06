# Keep Mimo for the paid rule-gen stages

**Context.** The rule-gen spine has two model-driven stages — Classify (triage) and
Implement (author the rule + tests). Tunex drives both with Xiaomi **Mimo** via its
Anthropic- and OpenAI-compatible endpoints, carrying Mimo-specific machinery:
`MimoConsole` (the ground-truth token-bucket meter behind a browser cookie), a
token-bucket `Budget`, and `ANTHROPIC_MODEL=mimo-v2.5-pro[1m]`. This machine has no
Mimo credentials but a working `claude` CLI — so real Anthropic Claude was the
lower-friction option.

**Decision.** Keep Mimo for Classify + Implement, matching Tunex exactly. Retain
`MimoConsole`, the token-bucket `Budget`, the cookie meter, and the `[1m]` model
verbatim. Setup gains a step: obtain a Mimo `tp-` token + console cookie.

**Why.** Chosen deliberately over real Claude despite the environment nudging the
other way: Mimo's token-bucket pricing is dramatically cheaper for a 24/7 loop, and
keeping it means zero divergence from Tunex's cost/observability layer — every Mimo
module copies unchanged, and Tunex's hard-won cost tooling (`mix cev.budget`,
`usage.jsonl`, the console reconciliation) transfers intact.

**Consequence.** The harness inherits Tunex's cost caveats: the in-band ledger
undercounts the bucket ~20–50×, so `mix cev.budget` (the console) is the only
ground truth. Solve stays free on the local model; Mimo is the only paid dependency.
