defmodule Cev.PremiseTest do
  use ExUnit.Case, async: true

  alias Cev.Premise

  @moduledoc """
  docs/22 T4.2e — one compile, before an ~80-turn implementer run is spent on a
  premise that cannot be true.

  The measured cost this replaces: row 221's stated motivation, a
  `--warnings-as-errors` failure from `incompatible types … float(), dynamic()`,
  does not exist — the exact shape compiles clean. Across nine reviewed rows the
  ledger put unchecked premises at roughly $100 of implementer budget.
  """

  describe "semantic proposals must have a diagnostic to key on" do
    test "clean source refutes the premise" do
      before = """
      defmodule PremiseClean do
        def add(a, b), do: a + b
      end
      """

      assert {:error, :premise_no_diagnostic} = Premise.check(:semantic, before)
    end

    test "source that warns satisfies it" do
      before = """
      defmodule PremiseWarns do
        def run(x) do
          unused = x
          :ok
        end
      end
      """

      assert :ok = Premise.check(:semantic, before)
    end

    test "source that does not compile satisfies it" do
      assert :ok =
               Premise.check(
                 :semantic,
                 "defmodule PremiseBad do\n  def a, do: undefined_fn()\nend\n"
               )
    end

    # A CompileError is often RAISED rather than reported as a diagnostic
    # struct. Reading that as "no diagnostic" would refute a premise that is
    # plainly true — the source does not build at all.
    test "source whose compile raises satisfies it" do
      assert :ok = Premise.check(:semantic, "@moduledoc \"outside a module\"")
    end
  end

  describe "syntax proposals must have source that does not parse" do
    test "source that parses refutes the premise (the G2 class)" do
      assert {:error, :premise_syntax_parses} = Premise.check(:syntax, "x = 1")
    end

    test "source that fails to parse satisfies it" do
      assert :ok = Premise.check(:syntax, "def f(a, b do\n")
    end
  end

  describe "what the gate deliberately does not judge" do
    # Pattern rules work on the AST of code that compiles fine, so "no
    # diagnostic" is their NORMAL state — checking them here would be a false
    # accusation against every correct proposal.
    test "pattern proposals are not premise-checked" do
      assert :ok = Premise.check(:pattern, "defmodule P do\n  def a, do: 1\nend\n")
    end

    test "a missing BEFORE is not a refuted premise" do
      assert :ok = Premise.check(:semantic, nil)
    end
  end

  describe "compiling is running, so it is bounded" do
    # The premise check executes model-supplied source. Unbounded, that is the
    # defect that took a 64 GB box down seven times in one day (credence T3.11).
    test "source that never finishes is inconclusive, not fatal" do
      assert :ok = Premise.check(:semantic, "Enum.flat_map(1..10, &Stream.cycle([&1]))")
      assert Process.alive?(self())
    end
  end
end
