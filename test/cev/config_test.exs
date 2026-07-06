defmodule Cev.ConfigTest do
  use ExUnit.Case, async: false
  alias Cev.Config

  describe "task_root/0" do
    test "CEV_TASK_ROOT env var wins and is expanded to an absolute path" do
      System.put_env("CEV_TASK_ROOT", "/tmp/some/tasks")
      on_exit(fn -> System.delete_env("CEV_TASK_ROOT") end)
      assert Config.task_root() == "/tmp/some/tasks"
    end

    test "a blank env var is ignored (falls back to config)" do
      System.put_env("CEV_TASK_ROOT", "")
      on_exit(fn -> System.delete_env("CEV_TASK_ROOT") end)
      assert Config.task_root() == Path.expand(Application.get_env(:cev, :task_root))
    end

    test "the default resolves to an absolute path" do
      System.delete_env("CEV_TASK_ROOT")
      assert Config.task_root() |> Path.type() == :absolute
    end
  end

  describe "credence_clone/0" do
    test "CEV_CREDENCE_CLONE env var wins and is absolute" do
      System.put_env("CEV_CREDENCE_CLONE", "/tmp/my-credence")
      on_exit(fn -> System.delete_env("CEV_CREDENCE_CLONE") end)
      assert Config.credence_clone() == "/tmp/my-credence"
    end

    test "the default resolves to an absolute path" do
      System.delete_env("CEV_CREDENCE_CLONE")
      assert Config.credence_clone() |> Path.type() == :absolute
    end
  end
end
