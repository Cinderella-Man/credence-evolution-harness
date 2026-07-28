defmodule Cev.ParserTest do
  use ExUnit.Case, async: true
  alias Cev.Parser

  doctest Cev.Parser

  describe "parse_module_test/1" do
    test "parses marker form" do
      content =
        "---MODULE---\ndefmodule Solution do\n  def f, do: 1\nend\n---TEST---\ndefmodule SolutionTest do\n  use ExUnit.Case\nend\n---END---"

      assert {:ok, mod, test} = Parser.parse_module_test(content)
      assert mod =~ "def f"
      assert test =~ "use ExUnit.Case"
    end

    # Regression: on retries the model drops the ---MODULE---/---TEST--- markers
    # and emits two bare defmodules. Must still parse (else valid fixes are lost).
    test "falls back to bare two-module output (no markers)" do
      content = """
      defmodule Solution do
        def convert(str, num_rows) when num_rows >= byte_size(str), do: str
        def convert(str, _num_rows), do: str
      end

      defmodule SolutionTest do
        use ExUnit.Case, async: false

        test "convert with one row" do
          assert Solution.convert("A", 1) == "A"
        end
      end
      """

      assert {:ok, mod, test} = Parser.parse_module_test(content)
      assert mod =~ "def convert"
      assert mod =~ "byte_size"
      refute mod =~ "defmodule SolutionTest"
      assert test =~ "use ExUnit.Case"
      assert test =~ "Solution.convert"
    end

    test "returns :error when only a module is present" do
      assert :error = Parser.parse_module_test("defmodule Solution do\n  def f, do: 1\nend")
    end
  end

  describe "strip_outer_fences/1 (docs/10 Fix 2)" do
    test "removes a single outer ```lang fence" do
      assert Parser.strip_outer_fences("```elixir\ndefmodule A do\nend\n```") ==
               "defmodule A do\nend"
    end

    test "removes a bare ``` fence" do
      assert Parser.strip_outer_fences("```\nx\n```") == "x"
    end

    test "no-op when there is no fence" do
      assert Parser.strip_outer_fences("defmodule A do\nend") == "defmodule A do\nend"
    end

    test "preserves a mid-content fence (only the FIRST/LAST are stripped)" do
      s = "defmodule A do\n  @moduledoc \"x\\n```\\ny\"\nend"
      assert Parser.strip_outer_fences(s) == s
    end
  end
end
