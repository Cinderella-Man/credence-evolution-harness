defmodule Cev.Evolve.RouterTest do
  use ExUnit.Case, async: false

  alias Cev.Classify.Spec
  alias Cev.Evolve.Router

  setup do
    # Isolate var/run to a temp dir so the router's outcome-dir moves don't
    # touch the real run dir.
    prev = Application.get_env(:cev, :run_dir)
    tmp = Path.join(System.tmp_dir!(), "cev_router_#{System.unique_integer([:positive])}")
    Application.put_env(:cev, :run_dir, tmp)
    Cev.RowLog.ensure_ready()

    on_exit(fn ->
      if prev,
        do: Application.put_env(:cev, :run_dir, prev),
        else: Application.delete_env(:cev, :run_dir)

      File.rm_rf!(tmp)
    end)

    %{tmp: tmp}
  end

  defp write_log(idx, body) do
    path = Path.join([Cev.Config.run_path("logs"), "#{idx}.log"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
    path
  end

  defp moved?(dir, idx), do: File.exists?(Path.join(Cev.RowLog.outcome_path(dir), "#{idx}.log"))

  test "NO_ACTION moves the log to no_action/", %{tmp: _tmp} do
    write_log(1, "no rules fired\n")
    classify = fn _log, _outcome, _opts -> {:ok, %Spec{decision: :no_action}} end

    assert %{outcome: :no_action} =
             Router.run(1, :solved, "/nonexistent_clone", classify: classify)

    assert moved?("no_action", 1)
  end

  test "SWITCH_PROPOSAL records + moves to switch_proposals/" do
    write_log(2, "log\n")

    spec = %Spec{
      decision: :switch_proposal,
      before: "defmodule B do\nend",
      proposed_switch: %{"name" => "nfc_strings", "summary" => "all NFC", :raw => "..."},
      rationale: "rare-text"
    }

    classify = fn _l, _o, _opts -> {:ok, spec} end

    assert %{outcome: :switch_proposal} = Router.run(2, :failed, "/x", classify: classify)
    assert moved?("switch_proposals", 2)
    # the proposal record file exists too
    assert File.exists?(Path.join(Cev.RowLog.outcome_path("switch_proposals"), "2.json"))
  end

  test "classifier error moves to classifier_errors/" do
    write_log(3, "log\n")
    classify = fn _l, _o, _opts -> {:error, {:classifier_errors, :missing_after, "raw"}} end

    assert %{outcome: :classifier_error} = Router.run(3, :solved, "/x", classify: classify)
    assert moved?("classifier_errors", 3)
  end

  test "POTENTIAL_NEW_RULE that is COVERED no longer skips — builds anyway (docs/10 A)" do
    write_log(4, "log\n")

    spec = %Spec{
      decision: :potential_new_rule,
      phase: :pattern,
      proposed_name: "no_foo",
      before: "defmodule B do\nend",
      after: "defmodule A do\nend"
    }

    classify = fn _l, _o, _opts -> {:ok, spec} end
    novelty = fn _before, _clone -> :covered end
    # :covered is now a non-blocking note — the row proceeds to equiv (here
    # DIVERGES), it does NOT skip to duplicate/.
    equiv = fn _spec -> {:diverges, "x"} end

    assert %{outcome: :behaviour_diverged} =
             Router.run(4, :solved, "/x", classify: classify, novelty: novelty, equiv: equiv)

    refute moved?("duplicate", 4)
    assert moved?("behaviour_diverged", 4)
  end

  test "POTENTIAL_NEW_RULE NOVEL but equiv DIVERGES moves to behaviour_diverged/" do
    write_log(5, "log\n")

    spec = %Spec{
      decision: :potential_new_rule,
      phase: :pattern,
      proposed_name: "no_foo",
      before: "defmodule B do\nend",
      after: "defmodule A do\nend"
    }

    classify = fn _l, _o, _opts -> {:ok, spec} end
    novelty = fn _b, _c -> :novel end
    equiv = fn _spec -> {:diverges, "int vs string"} end

    assert %{outcome: :behaviour_diverged} =
             Router.run(5, :solved, "/x", classify: classify, novelty: novelty, equiv: equiv)

    assert moved?("behaviour_diverged", 5)
  end

  # ── docs/10 Fix 1: transient timeout don't-consume / too_slow / fatal ───────

  test "a transient classify timeout (under the per-row limit) → :transient_abort, moves to transient/, no Ledger" do
    write_log(10, "log\n")

    classify = fn _l, _o, _opts ->
      {:error, {:classifier_errors, {:llm_error, {:network, :timeout}}, ""}}
    end

    assert %{outcome: :transient_abort} =
             Router.run(10, :solved, "/x", classify: classify, transient_attempts: fn _ -> 1 end)

    assert moved?("transient", 10)
    refute moved?("classifier_errors", 10)
    # don't-consume must NOT poison the ledger with network spam
    refute File.exists?(Cev.Config.run_path("decisions.md"))
  end

  test "a transient classify timeout AT the per-row limit → :too_slow, moves to too_slow/ (consumed)" do
    write_log(11, "log\n")

    classify = fn _l, _o, _opts ->
      {:error, {:classifier_errors, {:llm_error, {:network, :timeout}}, ""}}
    end

    limit = Cev.Config.transient_row_limit()

    assert %{outcome: :too_slow} =
             Router.run(11, :solved, "/x",
               classify: classify,
               transient_attempts: fn _ -> limit end
             )

    assert moved?("too_slow", 11)
    refute moved?("transient", 11)
  end

  test "a fatal classify error (401) → injected shutdown, :fatal_abort" do
    write_log(12, "log\n")

    classify = fn _l, _o, _opts ->
      {:error, {:classifier_errors, {:llm_error, {:http, 401, "no"}}, ""}}
    end

    me = self()
    shutdown = fn reason -> send(me, {:shutdown, reason}) end

    assert %{outcome: :fatal_abort} =
             Router.run(12, :solved, "/x", classify: classify, shutdown: shutdown)

    assert_received {:shutdown, {:fatal_api, {:llm_error, {:http, 401, "no"}}}}
  end

  test "a genuine malformed-spec classifier error still → classifier_errors/ (:other)" do
    write_log(13, "log\n")
    classify = fn _l, _o, _opts -> {:error, {:classifier_errors, :missing_after, "raw"}} end

    assert %{outcome: :classifier_error} = Router.run(13, :solved, "/x", classify: classify)
    assert moved?("classifier_errors", 13)
  end

  # ── H9: a Gate ENVIRONMENTAL failure is not a merit reject ──────────────
  #
  # Row 2: `mix test --exclude corpus` died in `Kernel.ParallelCompiler` having
  # run zero tests, the Gate logged `REJECT: :full_suite_red`, and a candidate
  # that had already passed the mutation gate was discarded. The Gate now
  # separates "the suite ran and failed" from "the suite never ran"; the Router
  # must keep that distinction all the way to the row log.

  # `RulePaths.resolve/2` only greps `lib/`, and the `:syntax` phase skips the
  # AST + diagnostic enrichment that would need a live Credence — so a two-file
  # fake clone is enough to reach the Gate through the BUGFIX lane.
  defp fake_clone do
    clone = Path.join(System.tmp_dir!(), "cev_gate_env_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(clone, "lib/syntax"))
    File.mkdir_p!(Path.join(clone, "test/syntax"))

    File.write!(
      Path.join(clone, "lib/syntax/no_foo.ex"),
      "defmodule Credence.Syntax.NoFoo do\nend\n"
    )

    File.write!(Path.join(clone, "test/syntax/no_foo_check_test.exs"), "x")
    on_exit(fn -> File.rm_rf!(clone) end)
    clone
  end

  defp bugfix_spec do
    %Spec{
      decision: :bugfix_rule,
      rule_name: Credence.Syntax.NoFoo,
      phase: :syntax,
      before: "a",
      after: "b",
      rationale: "r"
    }
  end

  defp env_detail do
    %{
      phase: :non_corpus,
      tail: "** (ErlangError) Erlang error: :terminated\n",
      patch: "diff --git a/lib/x.ex b/lib/x.ex\n"
    }
  end

  defp artefact(index, ext),
    do: Path.join(Cev.RowLog.outcome_path("gate_environmental"), "#{index}.#{ext}")

  test "a Gate ENVIRONMENTAL reject → gate_environmental/, patch preserved, NO ledger entry" do
    write_log(20, "log\n")
    detail = env_detail()

    assert %{outcome: :gate_environmental} =
             Router.run(20, :solved, fake_clone(),
               classify: fn _l, _o, _opts -> {:ok, bugfix_spec()} end,
               implement: fn _ctx -> {:ok, %{}} end,
               gate: fn _clone -> {:reject, {:environmental, detail}} end
             )

    assert moved?("gate_environmental", 20)
    refute moved?("escalated", 20)

    # The candidate was never judged, so its work survives the crash.
    assert File.read!(artefact(20, "patch")) == detail.patch
    assert File.read!(artefact(20, "environmental.md")) =~ "git apply"

    # decisions.md is inlined verbatim into every rule-gen prompt as the
    # dead-end list. A crashed test runner is not a dead-end idea.
    refute File.exists?(Cev.Config.run_path("decisions.md"))
  end

  test "an ordinary Gate reject on the same wiring is unchanged — escalated/ + a ledger entry" do
    write_log(21, "log\n")

    assert %{outcome: {:rejected, :full_suite_red}} =
             Router.run(21, :solved, fake_clone(),
               classify: fn _l, _o, _opts -> {:ok, bugfix_spec()} end,
               implement: fn _ctx -> {:ok, %{}} end,
               gate: fn _clone -> {:reject, :full_suite_red} end
             )

    assert moved?("escalated", 21)
    refute moved?("gate_environmental", 21)
    assert File.read!(Cev.Config.run_path("decisions.md")) =~ "gate_reject (:full_suite_red)"
  end
end
