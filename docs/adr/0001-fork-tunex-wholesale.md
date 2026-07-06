# Fork Tunex wholesale rather than build fresh

**Context.** The harness needs the exact same solve → validate → rule-gen → gate →
push loop that `opc-sft-stage2-elixir` ("Tunex") already implements across ~51
modules. Only the data source differs.

**Decision.** Copy the Tunex `lib/` tree verbatim (a single `Tunex` → `Cev`
namespace rename), then surgically delete the Python-translation data source and
swap in a filesystem task reader. ~45 of 51 modules are unchanged; the entire
rule-evolution spine (`Router`, `Classify.*`, `Implement.*`, `Novelty`, `Equiv`,
`Gate`, `Corpus`, `Git`) and the model/cost layer (`LLM`, `ClaudeCode`, `Pi`,
`Credence`, `MimoConsole`, `Budget`) are taken as-is.

**Why.** The rule-gen spine is the hard, proven, expensive-to-rebuild part and is
identical to what we want. Rewriting it would risk regressions in the Gate's
safety contract (mutation check, corpus ratchet, pure-deletion guard) for no
benefit. The cost is a namespace map when porting future Tunex fixes — accepted.

**Consequence.** Tunex's `docs/01`–`12` remain the authoritative reference for every
copied module's behaviour; this repo's docs describe only the delta. `v1/`-style
snapshotting is unnecessary — the upstream repo is the reference.
