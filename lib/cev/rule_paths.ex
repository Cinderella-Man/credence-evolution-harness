defmodule Cev.RulePaths do
  @moduledoc """
  Resolve a rule module → its source file + test glob in the clone (08 T2.4).

  `resolve/2` greps the clone for `defmodule <Mod> do` (the total, deterministic
  name→path mapping the BUGFIX lane relies on) and returns the single
  `lib/<phase>/<name>.ex` plus its `test/<phase>/<name>*_test.exs` glob. Exactly
  one source match is required — 0 or >1 is an error (a phantom or ambiguous
  rule must never send the implementer chasing the wrong file).
  """

  alias Cev.Config

  @type resolved :: %{
          module: module(),
          phase: String.t(),
          rule_path: String.t(),
          test_paths: [String.t()]
        }

  @spec resolve(module(), String.t()) :: {:ok, resolved()} | {:error, term()}
  def resolve(module, clone \\ Config.credence_clone()) when is_atom(module) do
    modname = module |> Atom.to_string() |> String.replace_prefix("Elixir.", "")

    case grep_defmodule(modname, clone) do
      [rel] ->
        name = Path.basename(rel, ".ex")
        phase = rel |> Path.dirname() |> Path.basename()

        tests =
          Path.join(clone, "test/#{phase}/#{name}*_test.exs")
          |> Path.wildcard()
          |> Enum.map(&Path.relative_to(&1, clone))

        {:ok, %{module: module, phase: phase, rule_path: rel, test_paths: tests}}

      [] ->
        # Fall back to the file BASENAME. The model gets the phase wrong far more
        # often than it gets the rule wrong — `Credence.Pattern.FixDivRem` for a
        # rule that lives in `lib/syntax/` — and the module name embeds the phase,
        # so the grep above cannot find it (docs/22 T4.3, ledger row 95). The
        # basename is the part it had right, and it is unique across phases.
        #
        # Resolved from the file directly rather than by re-entering `resolve/2`:
        # the fallback derives its answer from the same file it would search for,
        # so a recursive call that missed again would loop forever on it.
        case by_basename(modname, clone) do
          {:ok, real, rel} -> {:ok, describe(real, rel, clone)}
          :error -> {:error, {:not_found, modname}}
        end

      many ->
        {:error, {:ambiguous, modname, many}}
    end
  end

  # The rule whose FILE matches the last segment of `modname`, whatever phase it
  # actually lives in. Only accepted when exactly one file matches and it really
  # does define a module: a guess that resolves to two candidates is not a repair,
  # and reading the name out of the file means the answer is the tree's, not ours.
  defp by_basename(modname, clone) do
    snake = modname |> String.split(".") |> List.last() |> Macro.underscore()

    case Path.wildcard(Path.join(clone, "lib/*/#{snake}.ex")) do
      [abs] ->
        case Regex.run(~r/^defmodule\s+([A-Za-z0-9_.]+)\s+do\s*$/m, File.read!(abs)) do
          [_, real] -> {:ok, String.to_atom("Elixir." <> real), Path.relative_to(abs, clone)}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  # The same shape `resolve/2` returns for a grep hit, built from a known path.
  defp describe(module, rel, clone) do
    name = Path.basename(rel, ".ex")
    phase = rel |> Path.dirname() |> Path.basename()

    tests =
      Path.join(clone, "test/#{phase}/#{name}*_test.exs")
      |> Path.wildcard()
      |> Enum.map(&Path.relative_to(&1, clone))

    %{module: module, phase: phase, rule_path: rel, test_paths: tests}
  end

  # grep -rl returns clone-relative paths (cwd = clone). Exit 1 = no match.
  defp grep_defmodule(modname, clone) do
    case System.cmd("grep", ["-rl", "defmodule #{modname} do", "lib/"],
           cd: clone,
           stderr_to_stdout: true
         ) do
      {out, 0} -> String.split(out, "\n", trim: true)
      _ -> []
    end
  end
end
