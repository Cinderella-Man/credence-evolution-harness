defmodule Cev.Pipeline.SolveTest do
  use ExUnit.Case, async: true
  alias Cev.Pipeline.Solve

  @prompt "Write me an Elixir module `RateLimiter` that enforces per-key limits."
  @harness ~S"""
  defmodule RateLimiterTest do
    use ExUnit.Case, async: false
    test "limits", do: assert {:ok, _} = RateLimiter.check(:x)
  end
  """

  describe "blind first attempt" do
    test "initial prompt contains the task but NOT the idiomatic test harness" do
      prompt = Solve.build_initial(@prompt)
      assert prompt =~ "RateLimiter"
      # The whole point of the blind attempt: the model must not see the harness.
      refute prompt =~ "RateLimiterTest"
      refute prompt =~ "use ExUnit.Case"
    end
  end

  describe "harness-guided retry" do
    test "retry prompt reveals the harness, the previous attempt, and the errors" do
      failures = [{:compile, "boom"}, {:credence, "no_sort_then_reverse: ..."}]
      prompt = Solve.build_retry(@prompt, @harness, "defmodule RateLimiter do\nend", failures)

      assert prompt =~ "RateLimiterTest"
      assert prompt =~ "use ExUnit.Case"
      assert prompt =~ "defmodule RateLimiter do"
      assert prompt =~ "boom"
      assert prompt =~ "no_sort_then_reverse"
    end
  end

  describe "no Python anywhere" do
    test "system + initial prompts are Python-free" do
      for text <- [Solve.system_prompt(), Solve.build_initial(@prompt)] do
        down = String.downcase(text)
        refute String.contains?(down, "```python")
        refute String.contains?(down, "python")
      end
    end
  end

  describe "extract_module/1" do
    test "pulls a fenced elixir block" do
      content = "Here you go:\n\n```elixir\ndefmodule RateLimiter do\n  def check(_), do: :ok\nend\n```\nDone."
      assert {:ok, code} = Solve.extract_module(content)
      assert code =~ "defmodule RateLimiter do"
      refute code =~ "Here you go"
      refute code =~ "Done."
    end

    test "joins multiple module blocks (multi-module solutions)" do
      content = """
      ```elixir
      defmodule RateLimiter do
      end
      ```
      and a helper:
      ```elixir
      defmodule RateLimiter.Bucket do
      end
      ```
      """

      assert {:ok, code} = Solve.extract_module(content)
      assert code =~ "defmodule RateLimiter do"
      assert code =~ "defmodule RateLimiter.Bucket do"
    end

    test "falls back to ---MODULE--- markers" do
      content = "---MODULE---\ndefmodule RateLimiter do\nend\n---END---"
      assert {:ok, code} = Solve.extract_module(content)
      assert code =~ "defmodule RateLimiter do"
    end

    test "accepts a bare defmodule with no fences" do
      assert {:ok, code} = Solve.extract_module("defmodule RateLimiter do\nend")
      assert code =~ "defmodule RateLimiter do"
    end

    test "rejects output with no module" do
      assert :error = Solve.extract_module("I could not solve this, sorry.")
    end
  end
end
