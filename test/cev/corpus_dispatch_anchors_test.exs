defmodule Cev.Evolve.CorpusDispatchAnchorsTest do
  use ExUnit.Case, async: true

  alias Cev.Evolve.CorpusDispatch, as: CD

  @moduledoc """
  The anchors probe: parse the **real** stdout of
  `mix credence.corpus --only-rule`, not a hand-written approximation.

  Every other test of this parser feeds it output a person wrote, which is the
  blind spot this program keeps rediscovering — the fixture and the parser share
  an author, so they agree by construction and both can be wrong about what
  credence actually prints. These two fixtures were captured by running the task:
  the clean one as-is, the drift one by dropping a single line from
  `test/corpus/accepted_findings.txt` (restored immediately after) so the rule
  reported one genuine NEW finding.

  What they pin that an invented fixture would not:

  * a NEW bullet is followed by an **indented source excerpt** — three lines of
    it, each of which looks like a finding to a loose anchor. `@new_bullet`
    requires the `•`, and the mutant that drops that requirement is killed here
    by real output rather than by assertion.
  * the GONE section really does render `  (none)` when empty, so rejecting that
    placeholder is load-bearing and not defensive coding.
  * the clean run prints **no** NEW/GONE sections at all, so the parser has to
    cope with the headers being absent rather than empty.
  """

  @clean File.read!("test/fixtures/corpus_only_rule_clean.txt")
  @drift File.read!("test/fixtures/corpus_only_rule_drift.txt")

  describe "real `mix credence.corpus --only-rule` output" do
    test "a clean run reports no drift in either direction" do
      assert CD.new_lines(@clean) == []
      assert CD.gone_lines(@clean) == []
    end

    test "a drift run yields the finding identity and not its source excerpt" do
      assert CD.new_lines(@drift) == [
               "archethic/lib/archethic/election.ex:592  no_uniq_then_count"
             ]
    end

    test "the `(none)` placeholder is not read as a GONE finding" do
      # The fixture really does contain it — if this stops being true the
      # assertion below passes for the wrong reason.
      assert @drift =~ "(none)"
      assert CD.gone_lines(@drift) == []
    end

    test "the RESULT line is interpreted, with its counts" do
      assert {:drift, meta} = CD.interpret(1, @drift)
      assert meta.rule == "no_uniq_then_count"
      assert meta.new == ["archethic/lib/archethic/election.ex:592  no_uniq_then_count"]
      assert meta.gone == []
    end

    test "a clean RESULT line is only believed on a zero exit" do
      assert {:clean, meta} = CD.interpret(0, @clean)
      assert meta.rule == "no_uniq_then_count"
      assert meta.live == 19
      assert meta.accepted == 19

      # Same output, non-zero exit: the task failed for some other reason and
      # its summary line cannot be taken at face value.
      refute match?({:clean, _}, CD.interpret(1, @clean))
    end
  end
end
