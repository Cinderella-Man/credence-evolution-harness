# Filesystem task source replaces the translate + round-trip pipeline

**Status:** partially superseded by
[ADR-0006](0006-one-time-sanity-gate.md) — the "a rare broken entry simply fails
Solve's retries" reasoning below was priced for a single encounter; once
[ADR-0003](0003-continuous-repass-over-finite-corpus.md) locked continuous
re-passing, a one-time cached sanity gate was reinstated. The translate/round-trip
*pipeline* deletion stands.

**Context.** Tunex's real work is finding Credence rules; walking a dataset is just
the workload. It walks ~118k **Python** rows and, per row, spends a paid remote
Mimo call to translate Python→Elixir (instruction + tests + reference), then runs a
fix-free round-trip check to discard mistranslations, all cached in a durable
blacklist. `elixir-sft-dataset` already ships native Elixir tasks
(`prompt.md` + `solution.ex` + `test_harness.exs`).

**Decision.** Delete the entire translation data source — `Pipeline.Translate` (the
only Python-aware module), `Pipeline.RoundTrip`, `Cache`, `Dataset`, and the
name-conversion parts of `Parser` (`elixir_name`, `fix_is_prefix`, `parse_translate`).
Replace `Dataset` with a `TaskSource` that lists the 230 task dirs matching
`0*01` under `task_root` and reads `prompt.md` + `test_harness.exs`. The reference
`solution.ex` is not read in v1.

**Why.** No Python means no translation, so translationese, the truncation/blacklist
machinery, the round-trip mistranslation filter, the parquet download (and the
`explorer` dep), and the translation cache all become dead weight. The curated
dataset is trusted; a rare broken entry simply fails Solve's retries and emits
nothing, which is cheaper than gating every task.

**Consequence.** Canonical-naming logic disappears with it: the model reads the real
module name from the `test_harness.exs` it is given, and the validate/retry loop
enforces it — no `Solution`-pinning or `is_`→`?` fixup. Mimo is no longer paid for
translate; it now bills only the rule-gen stages (Classify + Implement).
