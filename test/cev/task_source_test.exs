defmodule Cev.TaskSourceTest do
  use ExUnit.Case, async: false
  alias Cev.TaskSource

  setup do
    root = Path.join(System.tmp_dir!(), "cev_ts_#{System.unique_integer([:positive])}")

    write = fn dir, files ->
      File.mkdir_p!(Path.join(root, dir))
      Enum.each(files, fn {name, body} -> File.write!(Path.join([root, dir, name]), body) end)
    end

    # two matching tasks (0*01), one with a reference, one without
    write.("001_001_foo_01", %{
      "prompt.md" => "do foo",
      "test_harness.exs" => "defmodule FooTest do\nend",
      "solution.ex" => "defmodule Foo do\nend"
    })

    write.("002_001_baz_01", %{"prompt.md" => "do baz", "test_harness.exs" => "x"})

    # non-matching: ends in 02, and a t-prefixed family
    write.("001_002_bar_02", %{"prompt.md" => "no"})
    write.("t001_001_qux_01", %{"prompt.md" => "no"})

    prev_root = Application.get_env(:cev, :task_root)
    prev_glob = Application.get_env(:cev, :task_glob)
    Application.put_env(:cev, :task_root, root)
    Application.put_env(:cev, :task_glob, "0*01")

    on_exit(fn ->
      restore(:task_root, prev_root)
      restore(:task_glob, prev_glob)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "list/0 selects only 0*01 dirs, sorted; count matches" do
    assert TaskSource.list() |> Enum.map(& &1.name) == ["001_001_foo_01", "002_001_baz_01"]
    assert TaskSource.count() == 2
  end

  test "load/1 reads all three files; reference is nil when solution.ex is absent" do
    [foo, baz] = TaskSource.list()

    lf = TaskSource.load(foo)
    assert lf.name == "001_001_foo_01"
    assert lf.prompt == "do foo"
    assert lf.test =~ "FooTest"
    assert lf.reference =~ "defmodule Foo"

    assert TaskSource.load(baz).reference == nil
  end

  defp restore(key, nil), do: Application.delete_env(:cev, key)
  defp restore(key, val), do: Application.put_env(:cev, key, val)
end
