defmodule Cev.Evolve.GateContractTest do
  use ExUnit.Case, async: true

  alias Cev.Evolve.Gate

  @moduledoc """
  T4.6 / H5 — contract tests for the Gate's reject paths.

  Three of the Gate's rejects are decided **purely from the staged diff**: no
  clone, no suite, no LLM. Those are pinned here directly, each with the shape
  that must be accepted alongside the shape that must be rejected — a check that
  has only ever been seen green is a check nobody has verified.

  The remaining two (`:full_suite_red`, `{:corpus, …}`) run a suite and are
  covered by `gate_test.exs`'s triage tests plus `gate_corpus_dispatch_test.exs`.
  """

  # A staged-diff entry as `staged_entries/1` produces it.
  defp entry(status, paths), do: %{status: status, paths: paths}

  describe "check_scope/1 — only lib/ and test/ may be touched" do
    test "accepts a rule and its tests" do
      entries = [
        entry("A", ["lib/pattern/no_thing.ex"]),
        entry("A", ["test/pattern/no_thing_test.exs"])
      ]

      assert Gate.check_scope(entries) == :ok
    end

    test "rejects a change to the build files, naming the offender" do
      entries = [
        entry("A", ["lib/pattern/no_thing.ex"]),
        entry("M", ["mix.exs"])
      ]

      assert {:reject, {:scope, ["mix.exs"]}} = Gate.check_scope(entries)
    end

    test "rejects a change to config, which no rule needs" do
      assert {:reject, {:scope, ["config/config.exs"]}} =
               Gate.check_scope([entry("M", ["config/config.exs"])])
    end

    test "a rename carries both paths, and both are scoped" do
      # `staged_entries/1` emits `R` with [old, new]; a rename that moves a file
      # OUT of lib/ must not slip through on the strength of its old path.
      entries = [entry("R", ["lib/pattern/a.ex", "priv/a.ex"])]

      assert {:reject, {:scope, ["priv/a.ex"]}} = Gate.check_scope(entries)
    end
  end

  describe "check_not_pure_deletion/1 — a candidate may not be only deletions" do
    test "rejects when every lib/ entry is a deletion" do
      entries = [
        entry("D", ["lib/pattern/old_rule.ex"]),
        entry("D", ["lib/pattern/other_rule.ex"]),
        entry("M", ["test/pattern/old_rule_test.exs"])
      ]

      assert {:reject, {:pure_deletion, paths}} = Gate.check_not_pure_deletion(entries)
      assert "lib/pattern/old_rule.ex" in paths
      assert "lib/pattern/other_rule.ex" in paths
    end

    test "accepts a deletion alongside a real lib/ change" do
      entries = [
        entry("D", ["lib/pattern/old_rule.ex"]),
        entry("A", ["lib/pattern/new_rule.ex"])
      ]

      assert Gate.check_not_pure_deletion(entries) == :ok
    end

    test "a test-only diff is not a pure deletion — there are no lib entries" do
      # The guard is about gutting the library, not about touching nothing. A
      # test-only diff is a different decision (LD3, T2.3) and must not be
      # swallowed here.
      assert Gate.check_not_pure_deletion([entry("D", ["test/pattern/a_test.exs"])]) == :ok
    end
  end

  describe "check_touches/3 — the candidate must touch the area it claims" do
    test "accepts when something under the prefix changed" do
      assert Gate.check_touches([entry("A", ["lib/pattern/x.ex"])], "lib/", :no_lib_change) == :ok
    end

    test "rejects with the caller's reason when nothing does" do
      assert {:reject, :no_lib_change} =
               Gate.check_touches(
                 [entry("A", ["test/pattern/x_test.exs"])],
                 "lib/",
                 :no_lib_change
               )
    end

    test "an empty diff cannot satisfy the requirement" do
      assert {:reject, :no_test_change} = Gate.check_touches([], "test/", :no_test_change)
    end
  end

  # The mutation check reverts lib/ to HEAD, runs the changed tests, and puts the
  # working tree back. If the restore half is wrong the Gate destroys the
  # candidate it was judging — so the round-trip is pinned independently of git.
  describe "mutation snapshot/restore round-trip" do
    @tag :tmp_dir
    test "restores byte-identical content for a tracked file", %{tmp_dir: dir} do
      rel = "lib/pattern/thing.ex"
      abs = Path.join(dir, rel)
      File.mkdir_p!(Path.dirname(abs))
      original = "defmodule Thing do\n  # éà unicode + trailing space \nend\n"
      File.write!(abs, original)

      snapshot = Gate.snapshot_lib(dir, [rel])

      # Whatever the revert did to the file, restore must undo it.
      File.write!(abs, "CLOBBERED")
      Gate.restore_lib(snapshot)

      assert File.read!(abs) == original
    end

    @tag :tmp_dir
    test "a file that does not exist is snapshotted as absent, not as empty", %{tmp_dir: dir} do
      rel = "lib/pattern/ghost.ex"

      assert [%{content: nil}] = Gate.snapshot_lib(dir, [rel])

      # Restoring an absent file must not create it: writing "" would leave an
      # empty module file behind in the candidate's tree.
      Gate.restore_lib(Gate.snapshot_lib(dir, [rel]))
      refute File.exists?(Path.join(dir, rel))
    end
  end
end
