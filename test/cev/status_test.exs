defmodule Cev.StatusTest do
  use ExUnit.Case, async: true

  doctest Cev.Status

  alias Cev.Status

  @moduledoc """
  T4.1 — the mode interlock that `STATUS.md` and docs/21 have described since
  the Rule Standard landed, and that nothing implemented.

  `Cev.Preflight.check_status_mode!/0` itself cannot be tested — `fail/1` is
  `System.halt(1)` — so, as with `needs_cc_token?/1`, what gets pinned here is
  the decision the check delegates.
  """

  describe "parse_mode/1" do
    test "reads the mode from the real STATUS.md shape (a fenced MODE line)" do
      contents = """
      # STATUS

      The mode file (docs/19 §4). One question: **can rules be generated right now?**

      ```
      MODE: CATCHING UP
      ```
      """

      assert Status.parse_mode(contents) == {:ok, "CATCHING UP"}
    end

    test "the first MODE line wins" do
      assert Status.parse_mode("MODE: PRODUCING\nMODE: CATCHING UP\n") == {:ok, "PRODUCING"}
    end

    test "a file with no MODE line is an error, not a default" do
      assert Status.parse_mode("# STATUS\n\nnothing to see\n") == {:error, :no_mode_line}
    end

    test "a MODE line with no value does not parse as an empty mode" do
      assert Status.parse_mode("MODE:   \n") == {:error, :no_mode_line}
    end
  end

  describe "blocks_generation?/1" do
    test "CATCHING UP blocks" do
      assert Status.blocks_generation?("CATCHING UP")
    end

    test "PRODUCING allows" do
      refute Status.blocks_generation?("PRODUCING")
    end

    test "case and internal whitespace do not change the answer" do
      refute Status.blocks_generation?("producing")
      assert Status.blocks_generation?("catching   up")
    end

    # The control that matters. Enumerating the *blocking* value would make
    # every one of these read as permission to generate — a typo in a file
    # edited by hand, or a mode added later by someone who did not know this
    # function existed. Permission has to be stated.
    test "CONTROL: an unrecognised mode blocks rather than permitting" do
      assert Status.blocks_generation?("CATCHNG UP")
      assert Status.blocks_generation?("PAUSED")
      assert Status.blocks_generation?("")
      assert Status.blocks_generation?("PRODUCING (soon)")
    end
  end

  describe "mode/1" do
    @tag :tmp_dir
    test "reads a STATUS.md from disk", %{tmp_dir: dir} do
      path = Path.join(dir, "STATUS.md")
      File.write!(path, "MODE: PRODUCING\n")

      assert Status.mode(path) == {:ok, "PRODUCING"}
    end

    @tag :tmp_dir
    test "a missing file is an error, so the caller can fail closed", %{tmp_dir: dir} do
      assert Status.mode(Path.join(dir, "STATUS.md")) == {:error, :missing}
    end
  end

  describe "the live accepting repo" do
    test "its STATUS.md is readable and currently closes generation" do
      path = Path.join(Cev.Config.accepting_repo(), "STATUS.md")

      # Not a hypothetical: this is the file the preflight will consult, and it
      # says CATCHING UP today. If this ever fails because the mode was flipped
      # to PRODUCING, that is the maintainer's deliberate act — update the
      # assertion then, and only then.
      assert {:ok, mode} = Status.mode(path)
      assert Status.blocks_generation?(mode)
    end
  end
end
