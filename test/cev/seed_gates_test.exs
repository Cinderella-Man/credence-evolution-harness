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

  # ── H6/T4.8: the corpus repair brief ────────────────────────────────
  #
  # The Router re-seeds the implementer once after a corpus over-fire. Without
  # this block the second run gets the identical prompt to the first, which is
  # the whole point of the retry thrown away.

  describe "the corpus repair brief" do
    defp repair_ctx(repair) do
      %{
        mode: :new,
        phase: :pattern,
        driver: :llm,
        spec: %{proposed_name: "no_thing", before: "a", after: "b", rationale: "r"},
        scaffold: %{phase: :pattern, snake: "no_thing", files: [], module: "X"},
        corpus_repair: repair
      }
    end

    test "the findings appear, and as the mechanical trigger rather than a gate name" do
      seed =
        Cev.Implement.Seed.build(
          repair_ctx(%{new: ["jason/lib/codegen.ex:42  no_thing"], gone: []})
        )

      assert seed =~ "SECOND ATTEMPT"
      assert seed =~ "jason/lib/codegen.ex:42  no_thing"
      # It must say what matched, not merely that a gate objected.
      assert seed =~ "your rule fires here and the previous rule set did not"
      assert seed =~ "NARROW the matcher"
    end

    test "GONE findings are labelled as the opposite problem" do
      seed = Cev.Implement.Seed.build(repair_ctx(%{new: [], gone: ["a.ex:1  no_thing"]}))

      assert seed =~ "no longer produces them"
      assert seed =~ "a.ex:1  no_thing"
    end

    # A long finding list must not become the whole prompt.
    test "the listing is capped and says how many it dropped" do
      many = for i <- 1..25, do: "f#{i}.ex:#{i}  no_thing"
      seed = Cev.Implement.Seed.build(repair_ctx(%{new: many, gone: []}))

      assert seed =~ "f20.ex:20"
      refute seed =~ "f21.ex:21"
      assert seed =~ "5 more"
    end

    # CONTROL: a first attempt has no brief, so the block must be absent
    # entirely — an empty "second attempt" heading would tell the model it has
    # already failed once when it has not.
    test "CONTROL: a first attempt carries no repair block" do
      seed =
        Cev.Implement.Seed.build(Map.delete(repair_ctx(%{new: [], gone: []}), :corpus_repair))

      refute seed =~ "SECOND ATTEMPT"
    end

    test "CONTROL: an empty brief carries no repair block either" do
      seed = Cev.Implement.Seed.build(repair_ctx(%{new: [], gone: []}))

      refute seed =~ "SECOND ATTEMPT"
    end
  end
end
