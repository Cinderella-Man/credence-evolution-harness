defmodule Cev.Classify.PromptTest do
  use ExUnit.Case, async: true
  alias Cev.Classify.Prompt

  @base [
    distilled_log: "the row log",
    closed_set: [],
    ledger: "",
    assumptions: [],
    solve_outcome: :solved,
    rule_index: ""
  ]

  test "no gold-reference section when reference is absent" do
    p = Prompt.build(@base)
    refute p =~ "Gold reference"
    refute p =~ "GOLD"
  end

  test "injects a fenced gold reference with the anti-taste guardrail when present" do
    ref = "defmodule RateLimiter do\n  def check(_k), do: :ok\nend"
    p = Prompt.build(Keyword.put(@base, :reference, ref))

    assert p =~ "Gold reference"
    assert p =~ "CONTRAST ONLY"
    assert p =~ "do NOT propose a rule"
    assert p =~ "merely enforces this reference"
    assert p =~ "defmodule RateLimiter do"
    # still contains the row log and the output contract
    assert p =~ "the row log"
    assert p =~ "===DECISION==="
  end

  test "lens forks on solve outcome" do
    solved = Prompt.build(@base)
    failed = Prompt.build(Keyword.put(@base, :solve_outcome, :failed))
    assert solved =~ "solve SUCCEEDED"
    assert failed =~ "solve FAILED"
  end
end
