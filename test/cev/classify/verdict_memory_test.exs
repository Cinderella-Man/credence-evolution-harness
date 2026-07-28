defmodule Cev.Classify.VerdictMemoryTest do
  @moduledoc """
  H8 (docs/16 Phase 8.4): verdict memory + positive exemplars + the
  rejected-over-fire list seeded by MECHANISM.

  The three gates worth having here are not "the string is in the prompt":

    * `describe "rejected-over-fire list"` enforces the *shape* the escalation
      ledger demanded — mechanism in the header, rule name only as provenance —
      because a list of names "teaches the generator nothing, because the next
      proposal has a different name".
    * `describe "positive exemplars"` re-derives each exemplar's PHASE from
      whether its `before` actually parses, so a hand-edited or hallucinated
      exemplar cannot sit in the prompt teaching a shape the pipeline rejects.
    * `describe "Classify.run/3 round trip"` proves a verdict recorded on one
      pass is inlined into the next pass's prompt — the actual feature.
  """

  use ExUnit.Case, async: true

  alias Cev.Classify
  alias Cev.Classify.{Prompt, Spec, Verdicts}
  alias Cev.Markers

  @snake_rule_name ~r/\b(?:no|prefer|avoid|fix)_[a-z0-9_]+/

  setup do
    dir = Path.join(System.tmp_dir!(), "cev_h8_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, dir: dir, store: Path.join(dir, "classify_verdicts.jsonl"), task_root: dir}
  end

  defp row_log(task_name, idx \\ 7) do
    """
    10:30:01.001 [info] [idx=#{idx}] task=#{task_name}
    10:30:01.002 [info] ===SOLVE_BOUNDARY===
    10:30:02.500 [debug] [Solve attempt 1] ...
    """
  end

  defp write_task!(root, name, files) do
    dir = Path.join(root, name)
    File.mkdir_p!(dir)
    Enum.each(files, fn {file, content} -> File.write!(Path.join(dir, file), content) end)
    dir
  end

  defp spec(fields), do: struct!(Spec, fields)

  # ── Identity ────────────────────────────────────────────────────────

  describe "Verdicts.task_name/1" do
    test "reads the orchestrator's own row-log line" do
      assert Verdicts.task_name(row_log("001_001_rate_limiter_01")) == "001_001_rate_limiter_01"
    end

    test "strips ANSI colouring (an older row handler emitted it)" do
      log = "08:16:08.382 \e[22m[info] [idx=3] task=002_007_lru_cache_01\e[0m\n"
      assert Verdicts.task_name(log) == "002_007_lru_cache_01"
    end

    test "is nil — not an error — when the line is absent" do
      refute Verdicts.task_name("no task line here")
      refute Verdicts.task_name(nil)
    end

    test "takes the row's OWN line, not a later echo of the word task=" do
      log = row_log("real_task") <> "10:31:00.000 [debug] model wrote: task=hallucinated\n"
      assert Verdicts.task_name(log) == "real_task"
    end
  end

  describe "Verdicts.key/2 (content-hashed, like the sanity-gate verdicts)" do
    test "a dataset edit invalidates the key", %{task_root: root} do
      write_task!(root, "t1", %{"prompt.md" => "solve it", "test_harness.exs" => "assert true"})
      before_key = Verdicts.key("t1", task_root: root)

      write_task!(root, "t1", %{"prompt.md" => "solve it DIFFERENTLY"})
      after_key = Verdicts.key("t1", task_root: root)

      assert before_key != after_key
      assert String.starts_with?(before_key, "t1@")
      assert String.starts_with?(after_key, "t1@")
    end

    test "is stable when nothing changed", %{task_root: root} do
      write_task!(root, "t2", %{"solution.ex" => "defmodule T do\nend\n"})
      assert Verdicts.key("t2", task_root: root) == Verdicts.key("t2", task_root: root)
    end

    test "distinct tasks never share a key", %{task_root: root} do
      write_task!(root, "t3", %{"prompt.md" => "same"})
      write_task!(root, "t4", %{"prompt.md" => "same"})
      assert Verdicts.key("t3", task_root: root) != Verdicts.key("t4", task_root: root)
    end

    test "an unmounted dataset still yields a usable (non-invalidating) key", %{task_root: root} do
      key = Verdicts.key("never_written", task_root: root)
      assert key == "never_written@nodata"
    end

    test "nil name ⇒ nil key ⇒ memory simply off" do
      refute Verdicts.key(nil)
      refute Verdicts.key_from_log("a log with no task line")
    end
  end

  # ── Store ───────────────────────────────────────────────────────────

  describe "Verdicts.record/3 + history/2" do
    test "round-trips oldest-first and keeps other tasks out", %{store: store} do
      opts = [verdicts_path: store]

      Verdicts.record("a@1", spec(decision: :no_action, rationale: "reduce/3 is idiomatic"), opts)
      Verdicts.record("b@1", spec(decision: :no_action, rationale: "other task"), opts)

      Verdicts.record(
        "a@1",
        spec(decision: :potential_new_rule, proposed_name: "no_foo", rationale: "second pass"),
        opts
      )

      assert [first, second] = Verdicts.history("a@1", opts)
      assert first.decision == "NO_ACTION"
      assert first.rationale == "reduce/3 is idiomatic"
      refute first.subject
      assert second.decision == "POTENTIAL_NEW_RULE"
      assert second.subject == "no_foo"
      assert second.rationale == "second pass"

      assert [%{rationale: "other task"}] = Verdicts.history("b@1", opts)
    end

    test "a BUGFIX verdict remembers the module it accused", %{store: store} do
      opts = [verdicts_path: store]

      Verdicts.record(
        "a@1",
        spec(
          decision: :bugfix_rule,
          rule_name: :"Elixir.Credence.Syntax.NoPythonMultiReturn",
          rationale: "over-fired on a child-spec tuple"
        ),
        opts
      )

      assert [%{decision: "BUGFIX_RULE", subject: "Credence.Syntax.NoPythonMultiReturn"}] =
               Verdicts.history("a@1", opts)
    end

    test "a multi-line rationale is flattened to one line", %{store: store} do
      opts = [verdicts_path: store]
      Verdicts.record("a@1", spec(decision: :no_action, rationale: "line one\n  line two"), opts)

      assert [%{rationale: rationale}] = Verdicts.history("a@1", opts)
      assert rationale == "line one line two"
      refute rationale =~ "\n"
    end

    test "a corrupt line does not take the rest of the memory with it", %{store: store} do
      opts = [verdicts_path: store]
      Verdicts.record("a@1", spec(decision: :no_action, rationale: "good one"), opts)
      File.write!(store, "{not json at all\n", [:append])
      Verdicts.record("a@1", spec(decision: :no_action, rationale: "good two"), opts)

      assert ["good one", "good two"] = Enum.map(Verdicts.history("a@1", opts), & &1.rationale)
    end

    test "a nil key is a no-op on both sides", %{store: store} do
      opts = [verdicts_path: store]
      assert Verdicts.record(nil, spec(decision: :no_action, rationale: "x"), opts) == :ok
      assert Verdicts.history(nil, opts) == []
      refute File.exists?(store)
    end

    @tag :capture_log
    test "an unwritable store degrades to no memory instead of failing the row", %{dir: dir} do
      # A directory where the file should be: File.write! raises :eisdir.
      store = Path.join(dir, "blocked.jsonl")
      File.mkdir_p!(store)
      opts = [verdicts_path: store]

      assert Verdicts.record("a@1", spec(decision: :no_action, rationale: "x"), opts) == :ok
      assert Verdicts.history("a@1", opts) == []
    end

    test "a missing store reads as empty" do
      assert Verdicts.history("a@1", verdicts_path: "/nonexistent/nope.jsonl") == []
    end
  end

  # ── Prompt: the memory section ──────────────────────────────────────

  describe "Prompt verdict-memory section" do
    @base [
      distilled_log: "the row log",
      closed_set: [],
      ledger: "",
      assumptions: [],
      solve_outcome: :solved
    ]

    defp entry(decision, rationale, subject \\ nil),
      do: %{decision: decision, subject: subject, rationale: rationale, ts: 1_785_000_000}

    test "is omitted entirely on a task's first pass" do
      p = Prompt.build(@base)
      refute p =~ "Prior passes judged THIS TASK"
      # and the pre-H8 sections are untouched
      assert p =~ "Dead-ends already tried"
      assert p =~ "===DECISION==="
    end

    test "renders a tally, the lines, and the not-a-veto policy" do
      history = [
        entry("NO_ACTION", "reduce/3 is idiomatic here"),
        entry("NO_ACTION", "still nothing rule-worthy"),
        entry("POTENTIAL_NEW_RULE", "bare comma tuple", "no_python_multi_return")
      ]

      p = Prompt.build(Keyword.put(@base, :verdict_history, history))

      assert p =~ "Prior passes judged THIS TASK"
      assert p =~ "NO_ACTION ×2"
      assert p =~ "POTENTIAL_NEW_RULE ×1"
      assert p =~ "(3 prior verdicts"
      assert p =~ "- POTENTIAL_NEW_RULE (no_python_multi_return) — bare comma tuple"
      assert p =~ "- NO_ACTION — reduce/3 is idiomatic here"
      # the stickiness AND the guardrail against it becoming a ratchet
      assert p =~ "uncertain is NO_ACTION"
      assert p =~ "It is NOT a veto"
    end

    test "newest verdicts are shown last-first and the display is capped, but the tally is not" do
      history = for n <- 1..9, do: entry("NO_ACTION", "pass #{n}")
      p = Prompt.build(Keyword.put(@base, :verdict_history, history))

      assert p =~ "NO_ACTION ×9"
      assert p =~ "(9 prior verdicts; newest 6 shown"
      assert p =~ "pass 9"
      assert p =~ "pass 4"
      refute p =~ "pass 3"
    end

    test "a verdict with no rationale still renders a line" do
      p = Prompt.build(Keyword.put(@base, :verdict_history, [entry("NO_ACTION", "")]))
      assert p =~ "- NO_ACTION — (no rationale recorded)"
    end
  end

  # ── Prompt: the rejected-over-fire list (mechanism, not name) ───────

  describe "rejected-over-fire list" do
    defp mechanism_entries do
      Prompt.rejected_mechanisms()
      |> String.split(~r/^ *R\d+\. /m)
      |> Enum.drop(1)
    end

    test "is injected verbatim into the prompt" do
      p =
        Prompt.build(
          distilled_log: "x",
          closed_set: [],
          ledger: "",
          assumptions: [],
          solve_outcome: :failed
        )

      assert p =~ Prompt.rejected_mechanisms()
      assert p =~ "never re-propose, under ANY name"
    end

    test "carries at least the seven mechanisms the Phase 5 triage produced" do
      assert length(mechanism_entries()) >= 7
    end

    test "every entry leads with a MECHANISM — no rule name in the header line" do
      for entry <- mechanism_entries() do
        header = entry |> String.split("\n") |> hd()

        refute Regex.match?(@snake_rule_name, header),
               "rejected-over-fire header names a rule instead of a mechanism: #{inspect(header)}"
      end
    end

    test "every entry still carries the rule name as provenance, so a maintainer can trace it" do
      for entry <- mechanism_entries() do
        assert entry =~ "(seen as:",
               "entry has no provenance tag: #{inspect(String.slice(entry, 0, 80))}"

        provenance = Regex.run(~r/\(seen as: ([^)]+)\)/, entry) |> Enum.at(1)
        assert Regex.match?(@snake_rule_name, provenance)
      end
    end

    test "every entry carries measured evidence, not an opinion" do
      for entry <- mechanism_entries() do
        assert entry =~ "Measured:",
               "entry has no measurement: #{inspect(String.slice(entry, 0, 80))}"
      end
    end

    test "the two mechanisms the escalation ledger named verbatim are present" do
      text = Prompt.rejected_mechanisms()
      # ledger, cluster "escalated 144-225", finding 1:
      #   "no :ets.new/2 scope on a leaf-atom match", "vacuous nil == nil guard"
      assert text =~ "LEAF-TOKEN MATCH WITH NO ENCLOSING-CALL SCOPE"
      assert text =~ ":ets.new/2"
      assert text =~ "nil == nil"
    end

    test "the three massive corpus over-fires are recorded with their hit counts" do
      text = Prompt.rejected_mechanisms()
      # docs/16 Phase 5, cluster 1 — the three dropped rules 8.4 says to seed with
      assert text =~ "810 corpus hits"
      assert text =~ "1064 corpus hits"
      assert text =~ "35 corpus hits"
    end

    test "says out loud that a green suite did not save any of them" do
      assert Prompt.rejected_mechanisms() =~ "GREEN check/fix/equivalence suite"
    end
  end

  # ── Prompt: the positive exemplars ──────────────────────────────────

  describe "positive exemplars" do
    defp exemplar_specs do
      Prompt.exemplars()
      |> String.split("### Example ")
      |> Enum.drop(1)
      |> Enum.map(&Markers.to_map/1)
    end

    test "is injected verbatim into the prompt" do
      p =
        Prompt.build(
          distilled_log: "x",
          closed_set: [],
          ledger: "",
          assumptions: [],
          solve_outcome: :solved
        )

      assert p =~ Prompt.exemplars()
      assert p =~ "Worked examples of ACCEPTED specs"
    end

    test "covers one rule per phase" do
      phases = exemplar_specs() |> Enum.map(& &1["PHASE"]) |> Enum.sort()
      assert phases == ["pattern", "semantic", "syntax"]
    end

    test "each exemplar is a COMPLETE spec in the prompt's own output contract" do
      for s <- exemplar_specs() do
        assert s["DECISION"] == "POTENTIAL_NEW_RULE"
        assert s["PROPOSED_NAME"] =~ ~r/^[a-z][a-z0-9_]*$/
        assert s["BEFORE"] =~ "defmodule"
        assert s["AFTER"] =~ "defmodule"
        assert String.trim(s["RATIONALE"]) != ""
        refute String.contains?(s["RATIONALE"], "\n")
      end
    end

    test "each exemplar's PHASE is the one its own BEFORE forces (the phase taxonomy, applied)" do
      for s <- exemplar_specs() do
        parses? = match?({:ok, _}, Code.string_to_quoted(s["BEFORE"]))

        case s["PHASE"] do
          # syntax = `before` WON'T PARSE
          "syntax" ->
            refute parses?, "syntax exemplar's before parses: #{s["PROPOSED_NAME"]}"

          # semantic/pattern = `before` PARSES (semantic then fails to compile)
          _ ->
            assert parses?, "non-syntax exemplar's before does not parse: #{s["PROPOSED_NAME"]}"
        end
      end
    end

    test "every exemplar's AFTER parses — a rewrite that does not is not a rewrite" do
      for s <- exemplar_specs() do
        assert {:ok, _} = Code.string_to_quoted(s["AFTER"])
      end
    end

    test "exemplars are labelled as form, not as targets (they are already shipped rules)" do
      text = Prompt.exemplars()
      assert text =~ "ALREADY EXIST in Credence"
      assert text =~ "NO_ACTION class 2"
    end

    test "the pattern exemplar teaches the narrowing, not just the rewrite" do
      assert Prompt.exemplars() =~ "NARROWING"
      assert Prompt.exemplars() =~ "ArithmeticError"
    end
  end

  # ── The feature, end to end ─────────────────────────────────────────

  describe "Classify.run/3 round trip" do
    defp llm_returning(text), do: fn _u, _s -> {:ok, text, %{}} end

    defp capturing_llm(text, owner) do
      fn user, _system ->
        send(owner, {:prompt, user})
        {:ok, text, %{}}
      end
    end

    defp classify_opts(ctx, extra) do
      Keyword.merge(
        [
          closed_set: [],
          ledger: "",
          assumptions: [],
          rule_index: "",
          clone: ctx.dir,
          verdicts_path: ctx.store,
          task_root: ctx.task_root
        ],
        extra
      )
    end

    @no_action "===DECISION===\nNO_ACTION\n===RATIONALE===\nreduce/3 is idiomatic here\n===END==="

    test "a verdict recorded on pass 1 is inlined into pass 2's prompt", ctx do
      write_task!(ctx.task_root, "task_a", %{"prompt.md" => "do the thing"})
      log = row_log("task_a")

      assert {:ok, %Spec{decision: :no_action}} =
               Classify.run(log, :solved, classify_opts(ctx, llm: llm_returning(@no_action)))

      assert {:ok, _} =
               Classify.run(
                 log,
                 :failed,
                 classify_opts(ctx, llm: capturing_llm(@no_action, self()))
               )

      assert_received {:prompt, second_prompt}
      assert second_prompt =~ "Prior passes judged THIS TASK"
      assert second_prompt =~ "NO_ACTION ×1"
      assert second_prompt =~ "reduce/3 is idiomatic here"
    end

    test "pass 1's own prompt carries no memory section", ctx do
      write_task!(ctx.task_root, "task_b", %{"prompt.md" => "do the thing"})

      assert {:ok, _} =
               Classify.run(
                 row_log("task_b"),
                 :solved,
                 classify_opts(ctx, llm: capturing_llm(@no_action, self()))
               )

      assert_received {:prompt, first_prompt}
      refute first_prompt =~ "Prior passes judged THIS TASK"
    end

    test "editing the dataset entry invalidates the memory", ctx do
      write_task!(ctx.task_root, "task_c", %{"prompt.md" => "version one"})
      log = row_log("task_c")

      assert {:ok, _} =
               Classify.run(log, :solved, classify_opts(ctx, llm: llm_returning(@no_action)))

      write_task!(ctx.task_root, "task_c", %{"prompt.md" => "version two — rewritten task"})

      assert {:ok, _} =
               Classify.run(
                 log,
                 :solved,
                 classify_opts(ctx, llm: capturing_llm(@no_action, self()))
               )

      assert_received {:prompt, prompt}
      refute prompt =~ "Prior passes judged THIS TASK"
    end

    test "a classifier ERROR is not remembered — no judgment was reached", ctx do
      write_task!(ctx.task_root, "task_d", %{"prompt.md" => "do the thing"})
      bad = "===DECISION===\nBUGFIX_RULE\n===RULE_NAME===\nCredence.Pattern.Foo\n===END==="

      assert {:error, {:classifier_errors, _, _}} =
               Classify.run(
                 row_log("task_d"),
                 :solved,
                 classify_opts(ctx, llm: llm_returning(bad))
               )

      assert Verdicts.history(Verdicts.key("task_d", task_root: ctx.task_root),
               verdicts_path: ctx.store
             ) == []
    end

    test "a log with no task line classifies exactly as before and writes nothing", ctx do
      assert {:ok, %Spec{decision: :no_action}} =
               Classify.run(
                 "a log with no idx line",
                 :solved,
                 classify_opts(ctx, llm: llm_returning(@no_action))
               )

      refute File.exists?(ctx.store)
    end

    test "memory is per-task, not per-row", ctx do
      write_task!(ctx.task_root, "task_e", %{"prompt.md" => "e"})
      write_task!(ctx.task_root, "task_f", %{"prompt.md" => "f"})

      assert {:ok, _} =
               Classify.run(
                 row_log("task_e", 11),
                 :solved,
                 classify_opts(ctx, llm: llm_returning(@no_action))
               )

      assert {:ok, _} =
               Classify.run(
                 row_log("task_f", 12),
                 :solved,
                 classify_opts(ctx, llm: capturing_llm(@no_action, self()))
               )

      assert_received {:prompt, prompt}
      refute prompt =~ "Prior passes judged THIS TASK"
    end

    test "the same task seen at a different row index shares one memory", ctx do
      write_task!(ctx.task_root, "task_g", %{"prompt.md" => "g"})

      assert {:ok, _} =
               Classify.run(
                 row_log("task_g", 21),
                 :solved,
                 classify_opts(ctx, llm: llm_returning(@no_action))
               )

      assert {:ok, _} =
               Classify.run(
                 row_log("task_g", 99),
                 :failed,
                 classify_opts(ctx, llm: capturing_llm(@no_action, self()))
               )

      assert_received {:prompt, prompt}
      assert prompt =~ "NO_ACTION ×1"
    end
  end
end
