# Blind first solve attempt — the harness is revealed only on retries

**Context.** Tunex's solve prompt always included the tests, which was harmless
there: its tests were machine-translated. Ours are hand-written, *idiomatic*
ExUnit — showing them to the local model lets it crib idioms from the harness,
suppressing exactly the clumsiness that is this project's product (rule
feedstock). Verified against the 230-task slice: 230/230 prompts name the target
module and 226/230 fully spell out the API in prose, so a prompt-only solve is
well-specified; 29/230 harnesses assert on implementation internals
(`:sys.get_state`) that no blind model can guess.

**Decision.** Solve attempt 1 sees **`prompt.md` only**. From attempt 2 onward the
retry prompt adds the **full `test_harness.exs`** alongside the previous attempt
and the validator errors (Tunex's retry shape plus the harness).

**Why.** The row log captures every attempt with its Credence fix trace, so
attempt 1 contributes maximally-clumsy *unanchored* feedstock even when it fails,
while harness-guided retries still converge to a passing solution — and
"passing + non-idiomatic" is the gold rule-gen signal. Always-blind was rejected
because the 29 internals-asserting tasks would fail every retry and degrade their
signal to the weaker `:failed` classify lens; always-shown was rejected because it
anchors the model and starves the loop of feedstock.

**Consequence.** Do not "fix" this by adding the tests back to the initial prompt —
lower attempt-1 pass rates are intentional. Attempt counts will look worse than a
tests-in-prompt baseline; judge the change by rule yield, not solve pass rate.
