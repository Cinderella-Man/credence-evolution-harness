defmodule Cev.EquivTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Cev.Equiv

  # Verbatim verdict lines from `var/run/logs/behaviour_diverged/<row>.log` —
  # the 13 rows the classify-time kill rejected in the 2026-07 run. Copied, not
  # reconstructed: the boundary is a boundary between these exact strings.
  @row_31 "DIVERGES input=[] before={:raise, UndefinedFunctionError} after={:raise, FunctionClauseError} minimal_set=none"
  @row_106 "DIVERGES input=[] before={:raise, UndefinedFunctionError} after={:raise, BadMapError} minimal_set=none"
  @row_205 "DIVERGES input=[] before={:raise, UndefinedFunctionError} after={:raise, ArgumentError} minimal_set=none"
  @row_105 "DIVERGES input=[] before={:raise, WithClauseError} after={:raise, UndefinedFunctionError} minimal_set=none"
  @row_185 "DIVERGES input=[1] before={:raise, UndefinedFunctionError} after={:ok, false} minimal_set=none"
  @row_33 "DIVERGES input=[] before={:ok, {:error, {%BadFunctionError{term: []}, []}}} after={:ok, {:error, {%BadFunctionError{term: []}, [{:erl_eval, :do_apply, 6, [file: ~c\"erl_eval.erl\", line: 911]}]}}} minimal_set=none"

  describe "extract/1" do
    test "pulls vars + body from a single-clause def" do
      src = """
      defmodule Bad do
        def run(s), do: String.to_charlist(s) == Enum.reverse(String.to_charlist(s))
      end
      """

      assert {:ok, ["s"], expr} = Equiv.extract(src)
      assert expr =~ "String.to_charlist(s)"
    end

    test "handles a guarded multi-arg def" do
      src = """
      defmodule Bad do
        def run(a, b) when is_list(a), do: a ++ b
      end
      """

      assert {:ok, ["a", "b"], "a ++ b"} = Equiv.extract(src)
    end

    test "returns :error for pattern-destructured params (T2 — not extractable)" do
      src = """
      defmodule Bad do
        def run(%{k: v}), do: v
      end
      """

      assert Equiv.extract(src) == :error
    end

    test "returns :error for non-module / unparseable input" do
      assert Equiv.extract("def x(") == :error
      assert Equiv.extract(nil) == :error
    end
  end

  describe "interpret/1 — the trichotomy" do
    test "EQUIVALENT carries the minimal switch set" do
      assert Equiv.interpret("EQUIVALENT minimal_set=[]") == {:equivalent, []}

      assert Equiv.interpret("EQUIVALENT minimal_set=[single_codepoint_graphemes]") ==
               {:equivalent, [:single_codepoint_graphemes]}
    end

    test "REPAIR carries the evidence string" do
      assert Equiv.interpret("REPAIR UndefinedFunctionError 85/85 minimal_set=none") ==
               {:repair, "UndefinedFunctionError 85/85 minimal_set=none"}
    end

    test "a real behaviour divergence is DIVERGES" do
      line = "DIVERGES input=\"café\" before={:ok, 4} after={:ok, 5} minimal_set=none"
      assert {:diverges, detail} = Equiv.interpret(line)
      assert detail =~ "before={:ok, 4}"
    end

    test "an un-compilable extracted expression is skipped, not diverged (docs/10)" do
      line = "DIVERGES after-does not compile: undefined function do_count/3"
      assert Equiv.interpret(line) == :skipped
    end

    test "an unrecognised line is skipped" do
      assert Equiv.interpret("") == :skipped
      assert Equiv.interpret("** (Mix) something went wrong") == :skipped
    end
  end

  describe "interpret/1 — the LD2 vacuous-probe boundary" do
    test "before=UndefinedFunctionError + an after that also raised is skipped, not diverged" do
      # The probe compared two crashes: the before calls a function that does not
      # exist (nothing to preserve) and the fixed expression never reached a value
      # because the battery has no input of the type it needs. No evidence either
      # way ⇒ defer to the Gate, exactly as for a non-compiling extract.
      capture_log(fn ->
        assert Equiv.interpret(@row_31) == :skipped
        assert Equiv.interpret(@row_106) == :skipped
        assert Equiv.interpret(@row_205) == :skipped
      end)
    end

    test "the skip is announced in the row log" do
      log = capture_log(fn -> assert Equiv.interpret(@row_106) == :skipped end)

      assert log =~ "vacuous probe"
      assert log =~ "LD2"
      # The raw verdict line survives into the log, so the row can still be
      # triaged from its log alone (the `:skipped` branch used to be silent).
      assert log =~ "before={:raise, UndefinedFunctionError} after={:raise, BadMapError}"
    end

    test "row 105's class stays DIVERGES — a before that is not UndefinedFunctionError has real behaviour" do
      # `File.stream!/1` → the nonexistent `File.stream/1`. The probe was RIGHT:
      # the before raises WithClauseError (real runtime behaviour), the after
      # invents an API. Any relaxation that lets this through is wrong.
      assert {:diverges, detail} = Equiv.interpret(@row_105)
      assert detail =~ "before={:raise, WithClauseError}"
    end

    test "two crashes are not automatically vacuous — only a missing function on the before is" do
      # The general form of row 105, with the row-105-specific tell (an after that
      # raises UndefinedFunctionError) removed. The before really does raise
      # ArithmeticError on this input — that is behaviour — and the fix changes
      # which error the caller sees. Dropping the before=UndefinedFunctionError
      # requirement would wave this through on the strength of "both sides
      # crashed", which is not evidence of anything.
      line =
        "DIVERGES input=[0] before={:raise, ArithmeticError} " <>
          "after={:raise, FunctionClauseError} minimal_set=none"

      assert {:diverges, _} = Equiv.interpret(line)
    end

    test "a hallucinated repair (after=UndefinedFunctionError) stays DIVERGES" do
      # Belt-and-braces: today `credence.equiv` reports two identical raises as
      # EQUIVALENT, so this line cannot be produced — but the predicate must not
      # depend on that.
      line =
        "DIVERGES input=[] before={:raise, UndefinedFunctionError} " <>
          "after={:raise, UndefinedFunctionError} minimal_set=none"

      assert {:diverges, _} = Equiv.interpret(line)
    end

    test "row 185's class stays DIVERGES — the after produced a value" do
      # before raised on 80/85 inputs, after returned `false` on the reported one.
      # That is REPAIR evidence the probe denied for its own reason (`repair?/1`
      # demands the before raise on EVERY input); it belongs to `credence.equiv`,
      # which sees all 85 pairs. This function sees one pair and must not rule on
      # a pair where a value was observed.
      assert {:diverges, _} = Equiv.interpret(@row_185)
    end

    test "row 33's class stays DIVERGES — neither side raised" do
      assert {:diverges, _} = Equiv.interpret(@row_33)
    end

    test "a throw/exit outcome is not the vacuous shape" do
      line =
        "DIVERGES input=[] before={:raise, UndefinedFunctionError} " <>
          "after={:throw, :boom} minimal_set=none"

      assert {:diverges, _} = Equiv.interpret(line)
    end

    test "outcomes carrying exception messages (--compare-messages) are not the vacuous shape" do
      line =
        "DIVERGES input=[] before={:raise, UndefinedFunctionError, \"function Map.empty?/1 is undefined\"} " <>
          "after={:raise, BadMapError, \"expected a map\"} minimal_set=none"

      assert {:diverges, _} = Equiv.interpret(line)
    end

    test "the vacuous shape is recognised without the --minimal-set suffix" do
      line =
        "DIVERGES input=[] before={:raise, UndefinedFunctionError} after={:raise, BadMapError}"

      capture_log(fn -> assert Equiv.interpret(line) == :skipped end)
    end
  end

  describe "check/2 (real clone — integration)" do
    @describetag :integration

    test "DIVERGES on a charlist-int vs grapheme-string rewrite" do
      spec = %Cev.Classify.Spec{
        decision: :potential_new_rule,
        before: "defmodule B do\n  def run(s), do: Enum.at(String.to_charlist(s), 0)\nend",
        after: "defmodule A do\n  def run(s), do: String.at(s, 0)\nend",
        assumptions: []
      }

      assert {:diverges, _} = Equiv.check(spec)
    end

    test "REPAIR on Keyword.get with an integer key" do
      spec = %Cev.Classify.Spec{
        decision: :potential_new_rule,
        before: "defmodule B do\n  def run(list), do: Keyword.get(list, 0)\nend",
        after: "defmodule A do\n  def run(list), do: List.first(list)\nend",
        assumptions: []
      }

      assert {:repair, _} = Equiv.check(spec)
    end

    test "EQUIVALENT with a minimal switch set on a codepoint palindrome" do
      spec = %Cev.Classify.Spec{
        decision: :potential_new_rule,
        before:
          "defmodule B do\n  def run(s), do: String.to_charlist(s) == Enum.reverse(String.to_charlist(s))\nend",
        after: "defmodule A do\n  def run(s), do: s == String.reverse(s)\nend",
        assumptions: []
      }

      assert {:equivalent, [:single_codepoint_graphemes]} = Equiv.check(spec)
    end

    test "skips a T2 (pattern-param) rewrite" do
      spec = %Cev.Classify.Spec{
        decision: :potential_new_rule,
        before: "defmodule B do\n  def run(%{a: a}), do: a\nend",
        after: "defmodule A do\n  def run(m), do: m.a\nend",
        assumptions: []
      }

      assert Equiv.check(spec) == :skipped
    end

    test "skips (NOT diverges) when the after body calls a module-local helper (docs/10)" do
      # The extracted `after` expression `do_count(n, 1, 1)` can't compile
      # standalone (the helper lives elsewhere in the module). That's not a
      # behaviour divergence — it's an inapplicable expression-level check — so
      # it must defer to the Gate's full-module equivalence test, not reject.
      spec = %Cev.Classify.Spec{
        decision: :potential_new_rule,
        before: "defmodule B do\n  def run(n), do: n + 0\nend",
        after: "defmodule A do\n  def run(n), do: do_count(n, 1, 1)\nend",
        assumptions: []
      }

      assert Equiv.check(spec) == :skipped
    end

    test "does not kill row 31's hallucinated-MapSet repair" do
      # `MapSet.empty?/1` does not exist. Whether this comes back `:skipped` (the
      # battery cannot construct a MapSet, so the probe is vacuous — LD2) or
      # `{:repair, _}` (a battery that grew one), the one verdict it must not be
      # is `{:diverges, _}`: that is the auto-kill of the hallucinated-API class.
      spec = %Cev.Classify.Spec{
        decision: :potential_new_rule,
        before: "defmodule B do\n  def check(set), do: MapSet.empty?(set)\nend",
        after: "defmodule A do\n  def check(set), do: MapSet.size(set) == 0\nend",
        assumptions: []
      }

      refute match?({:diverges, _}, Equiv.check(spec))
    end

    test "still kills row 105 — a fix that rewrites File.stream!/1 to the nonexistent File.stream/1" do
      spec = %Cev.Classify.Spec{
        decision: :potential_new_rule,
        before:
          "defmodule B do\n  def analyze(path) do\n    with {:ok, stream} <- File.stream!(path) do\n      {:ok, stream}\n    else\n      {:error, reason} -> {:error, reason}\n    end\n  end\nend",
        after:
          "defmodule A do\n  def analyze(path) do\n    with {:ok, stream} <- File.stream(path) do\n      {:ok, stream}\n    else\n      {:error, reason} -> {:error, reason}\n    end\n  end\nend",
        assumptions: []
      }

      assert {:diverges, _} = Equiv.check(spec)
    end
  end
end
