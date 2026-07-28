defmodule Cev.Implement.SeedGatesTest do
  use ExUnit.Case, async: true

  alias Cev.Implement.Seed

  @moduledoc """
  docs/22 T4.4 — six gates the model previously learned about only by failing
  them. Each is a rejection this loop has already paid for, so each is stated up
  front now.

  These assert the seed *carries* the teaching. That is deliberately a weak
  property — it cannot show the model heeds it — but the failure mode being
  guarded is concrete and has happened: a section gets refactored out and nobody
  notices the loop went back to teaching by rejection.

  `gates_block/0` takes no context and is added unconditionally in `build/2`, so
  it reaches the bugfix seed by construction — there is nothing mode-specific to
  pin separately.
  """

  @ctx %{
    mode: :new,
    phase: :semantic,
    spec: %{
      before: "defmodule B do\nend",
      after: "defmodule A do\nend",
      rationale: "x",
      assumptions: []
    },
    scaffold_files: %{
      "lib/semantic/fix_thing.ex" => "defmodule Credence.Semantic.FixThing do\nend"
    },
    ast_before: "{:defmodule, ...}",
    ast_after: "{:defmodule, ...}",
    minimal_set: [],
    repair?: false
  }

  defp seed, do: Seed.build(@ctx)

  test "1. the C2.2 dimension mapping is stated with its actual trigger" do
    s = seed()

    assert s =~ "Enum.sort"
    assert s =~ "integer and a float"
    # The trap itself, not just the name of the gate.
    assert s =~ "[1, 1.0, 2]"
    assert s =~ "multi-codepoint grapheme"
    assert s =~ ":single_codepoint_graphemes"
  end

  test "2. an over-fire is taught as a drop, not an accept" do
    assert seed() =~ "over-fire is a DROP"
  end

  test "3. one-diagnostic-one-owner and the decline guard are both taught" do
    s = seed()

    assert s =~ "first match wins"
    assert s =~ "should_report?"
    assert s =~ "starves"
  end

  test "4. the leaf-token and sentinel-guard anti-patterns are stated verbatim" do
    s = seed()

    # The exact line the escalation ledger prescribes.
    assert s =~ "must name the construct that encloses it"
    assert s =~ "`f(a) == f(b)` is invalid if `f` can return a"
  end

  test "5. there is a worked example, not only prohibitions" do
    s = seed()

    assert s =~ "def match?(%{severity: :error, message: msg})"
    assert s =~ "def match?(_), do: false"
    assert s =~ "Sourceror.patch_string"
  end

  test "6. dispatch competition is made concrete" do
    assert seed() =~ "competes with"
  end
end
