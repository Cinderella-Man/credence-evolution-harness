defmodule Cev.Classify.Verdicts do
  @moduledoc """
  Per-task memory of prior Classify verdicts (H8, docs/16 Phase 8.4).

  `decisions.md` records only dead-ends (`gave_up`, `gate_reject`, phantoms). A
  row that was NO_ACTION'd leaves no trace at all, so pass N+1 re-judges the same
  task **from scratch** — Mimo cost (ADR-0003 accepts that) but also *decision
  churn*: nothing anchors this pass's judgment to the last one, so a borderline
  task eventually produces a bad proposal by sampling noise. This module is the
  anchor: one compact line per classified row, inlined into the next pass's
  prompt.

  ## Storage

  `var/cache/classify_verdicts.jsonl`, one JSON object per line:

      {"key":"001_001_rate_limiter_01@9f2c…","decision":"NO_ACTION",
       "subject":null,"rationale":"reduce/3 is idiomatic here","ts":1785000000}

  Cache-scoped on purpose — `mix cev.reset` wipes `var/run/` and keeps
  `var/cache/` (same reasoning as the sanity-gate verdicts: a judgment about a
  dataset entry does not become less true on a fresh run).

  ## Keys invalidate on a dataset edit

  The key is `<task name>@<digest>`, where the digest is a sha256 over the task
  dir's `prompt.md` + `test_harness.exs` + `solution.ex` — the same
  content-hash discipline as `Cev.SanityGate`. Edit the dataset entry and the
  key changes, so the stale history is simply never looked up (it is not
  deleted; nothing here ever rewrites the file).

  Note the honest limit: the digest covers the *task*, not the *rule set*. A
  committed rule changes the landscape without changing the key — that is
  deliberate. The verdict memory is advisory prose in the prompt, never control
  flow, and the prompt tells the classifier in as many words that a genuinely
  new defect in this row outranks the memory.

  ## Advisory only

  Nothing in this module can skip, veto or short-circuit a classification. The
  "skip Classify after K consecutive NO_ACTIONs" policy that IMPROVEMENTS.md
  sketches on top of this is deliberately NOT implemented — it was declined in
  DESIGN §11 and is to be adopted only if Mimo spend becomes the bottleneck.

  Every entry point is total: a missing/corrupt store, an unreadable dataset dir
  or an unwritable cache degrades to "no memory", never to a failed
  classification.
  """

  require Logger

  alias Cev.Config

  @store "classify_verdicts.jsonl"

  # The orchestrator's own first line of every row log:
  #   `12:00:00.123 [info] [idx=7] task=001_001_rate_limiter_01`
  @task_line ~r/\[idx=\d+\]\s+task=(\S+)/
  @ansi ~r/\e\[[0-9;]*[a-zA-Z]/

  # The dataset files a task's identity is made of (Cev.TaskSource.load/1).
  @task_files ["prompt.md", "test_harness.exs", "solution.ex"]

  @rationale_limit 200

  @typedoc "One remembered verdict, normalized out of the jsonl store."
  @type entry :: %{
          decision: String.t(),
          subject: String.t() | nil,
          rationale: String.t(),
          ts: integer() | nil
        }

  # ── Identity ────────────────────────────────────────────────────────

  @doc """
  The task name carried by a row log, or `nil`.

  Read out of the orchestrator's own `[idx=N] task=<name>` line, which is
  emitted before the `===SOLVE_BOUNDARY===` sentinel (so it survives in the raw
  log the Router hands to Classify, and is absent from the distilled log the
  model sees). ANSI colouring is stripped defensively — the current row handler
  writes plain text, an older one did not.

  Returns `nil` rather than raising when the line is absent: no task name means
  no memory, which is exactly the pre-H8 behaviour.
  """
  @spec task_name(String.t() | nil) :: String.t() | nil
  def task_name(nil), do: nil

  def task_name(log) when is_binary(log) do
    case Regex.run(@task_line, log) do
      [_, name] -> name |> String.replace(@ansi, "") |> String.trim() |> presence()
      _ -> nil
    end
  end

  @doc """
  Content-hashed memory key for a task name, or `nil` for a nil name.

  `opts[:task_root]` overrides `Cev.Config.task_root/0` (tests).
  """
  @spec key(String.t() | nil, keyword()) :: String.t() | nil
  def key(task_name, opts \\ [])
  def key(nil, _opts), do: nil
  def key(name, opts) when is_binary(name), do: name <> "@" <> digest(name, opts)

  @doc "`task_name/1` composed with `key/2` — the one call the classifier makes."
  @spec key_from_log(String.t() | nil, keyword()) :: String.t() | nil
  def key_from_log(log, opts \\ []), do: log |> task_name() |> key(opts)

  # ── Read ────────────────────────────────────────────────────────────

  @doc """
  Every remembered verdict for `key`, oldest first (`[]` for a nil key).

  The caller decides how many to show; the list is one entry per classified pass
  of one task, so it stays short by construction.
  """
  @spec history(String.t() | nil, keyword()) :: [entry()]
  def history(key, opts \\ [])
  def history(nil, _opts), do: []

  def history(key, opts) when is_binary(key) do
    path = path(opts)

    if File.exists?(path) do
      path
      |> File.stream!()
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == ""))
      |> Stream.map(&safe_decode/1)
      |> Stream.filter(fn entry -> is_map(entry) and entry["key"] == key end)
      |> Enum.map(&to_entry/1)
    else
      []
    end
  rescue
    e ->
      Logger.warning(
        "[Classify.Verdicts] history unreadable (#{Exception.message(e)}) — no memory"
      )

      []
  end

  # ── Write ───────────────────────────────────────────────────────────

  @doc """
  Append one verdict for `key`. A nil key is a no-op (`:ok`).

  Called once per successful classification, with the spec the classifier
  actually emitted — so the memory records what was *judged*, not what the Gate
  later did with it. Downstream fate already reaches the prompt by two other
  routes: a Gate rejection lands in `decisions.md`, and a committed rule lands
  in the rule index.
  """
  @spec record(String.t() | nil, map(), keyword()) :: :ok
  def record(key, spec, opts \\ [])
  def record(nil, _spec, _opts), do: :ok

  def record(key, spec, opts) when is_binary(key) do
    path = path(opts)
    File.mkdir_p!(Path.dirname(path))

    line =
      Jason.encode!(%{
        "key" => key,
        "decision" => decision_token(spec),
        "subject" => subject(spec),
        "rationale" => rationale(spec),
        "ts" => System.os_time(:second)
      })

    File.write!(path, line <> "\n", [:append, :utf8])
    :ok
  rescue
    e ->
      Logger.warning("[Classify.Verdicts] could not record verdict: #{Exception.message(e)}")
      :ok
  end

  @doc "Store path (`opts[:verdicts_path]` overrides; tests point it at a tmp file)."
  @spec path(keyword()) :: String.t()
  def path(opts \\ []), do: Keyword.get(opts, :verdicts_path) || Config.cache_path(@store)

  # ── Internal ────────────────────────────────────────────────────────

  # sha256 over the dataset entry, truncated. `"nodata"` when the task dir holds
  # none of the three files (a bare unit test, or a task_root that is not
  # mounted) — still a stable key, so memory works, it just cannot invalidate.
  defp digest(name, opts) do
    root = Keyword.get(opts, :task_root) || Config.task_root()
    dir = Path.join(root, name)
    contents = Enum.map(@task_files, fn f -> read_or_empty(Path.join(dir, f)) end)

    if Enum.all?(contents, &(&1 == "")) do
      "nodata"
    else
      :sha256
      |> :crypto.hash(Enum.intersperse(contents, "\0"))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)
    end
  rescue
    _ -> "nodata"
  end

  defp read_or_empty(path) do
    case File.read(path) do
      {:ok, content} -> content
      {:error, _} -> ""
    end
  end

  # A hand-edited or half-written line must not take the whole memory with it.
  defp safe_decode(line) do
    case Jason.decode(line) do
      {:ok, %{} = map} -> map
      _ -> nil
    end
  end

  defp to_entry(raw) do
    %{
      decision: to_string(raw["decision"] || "UNKNOWN"),
      subject: presence(raw["subject"]),
      rationale: to_string(raw["rationale"] || ""),
      ts: raw["ts"]
    }
  end

  # The uppercase tokens the prompt's output contract uses, so a remembered
  # verdict reads back in exactly the vocabulary the classifier emits.
  defp decision_token(%{decision: :no_action}), do: "NO_ACTION"
  defp decision_token(%{decision: :bugfix_rule}), do: "BUGFIX_RULE"
  defp decision_token(%{decision: :potential_new_rule}), do: "POTENTIAL_NEW_RULE"
  defp decision_token(%{decision: :switch_proposal}), do: "SWITCH_PROPOSAL"
  defp decision_token(%{decision: other}), do: other |> to_string() |> String.upcase()
  defp decision_token(_), do: "UNKNOWN"

  # What the verdict was ABOUT — the proposed snake_case name, or the module a
  # BUGFIX accused. This is what makes "already proposed here, under a different
  # name" checkable by the next pass.
  defp subject(%{decision: :potential_new_rule, proposed_name: n}) when is_binary(n), do: n

  defp subject(%{decision: :bugfix_rule, rule_name: m}) when is_atom(m) and not is_nil(m),
    do: m |> Atom.to_string() |> String.replace_prefix("Elixir.", "")

  defp subject(_), do: nil

  defp rationale(%{rationale: r}) when is_binary(r) do
    r |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.join(" ") |> truncate()
  end

  defp rationale(_), do: ""

  defp truncate(s) when byte_size(s) <= @rationale_limit, do: s
  defp truncate(s), do: String.slice(s, 0, @rationale_limit) <> "…"

  defp presence(nil), do: nil
  defp presence(s) when is_binary(s), do: if(String.trim(s) == "", do: nil, else: s)
  defp presence(_), do: nil
end
