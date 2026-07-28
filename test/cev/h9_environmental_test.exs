defmodule Cev.H9EnvironmentalTest do
  use ExUnit.Case, async: true

  alias Cev.Evolve.Router

  @moduledoc """
  docs/22 T4.5 / H9 — environmental kills were being booked as merit failures.

  An agent driver reports its failures as a STRING, so a quota kill or a provider
  refusal arrived at `rulegen_error_class/1` as `{:cc, "…"}` and fell through to
  `:other` — a judgment that the *idea* failed. `Budget.classify_error/1` already
  treats HTTP 429 as transient, but only for `{:http, 429, _}`, which the agent
  path never produces.

  The cost of getting this wrong is not a lost row: it is a wrong entry in
  decisions.md, which then teaches the next pass that a fine idea is a dead end.
  """

  describe "agent failures that are the machine's fault, not the idea's" do
    test "a quota kill is transient (row 55)" do
      assert Router.rulegen_error_class({:cc, "API error 429: rate limit exceeded"}) == :transient
      assert Router.rulegen_error_class({:pi, "Too Many Requests"}) == :transient
      assert Router.rulegen_error_class({:cc, "provider overloaded"}) == :transient
    end

    test "a provider refusal is transient (row 169)" do
      assert Router.rulegen_error_class({:cc, "I cannot assist with that request"}) == :transient
    end

    test "a null run is transient (row 6)" do
      assert Router.rulegen_error_class({:cc, "no_writes"}) == :transient
    end

    test "the timeouts that already worked still do" do
      assert Router.rulegen_error_class({:pi, "timeout"}) == :transient
      assert Router.rulegen_error_class({:cc, "idle_timeout"}) == :transient
    end
  end

  describe "failures that really are the idea's" do
    # The controls. If everything is transient the row never converges — it just
    # burns the per-row limit and lands on too_slow, which is a different lie.
    test "a red suite is still a merit failure" do
      assert Router.rulegen_error_class({:cc_tests_red, "[own_tests] 3 tests, 3 failures"}) ==
               :other
    end

    test "an ordinary agent error is still a merit failure" do
      assert Router.rulegen_error_class({:cc, "cc_error: {:invalid_json, 3}"}) == :other
    end

    test "a refusal phrase is not matched loosely enough to catch compiler output" do
      # "cannot" alone appears in real Elixir errors — e.g.
      # "cannot compile module Foo" — and must not be read as a refusal.
      assert Router.rulegen_error_class({:cc, "cannot compile module Credence.Pattern.NoFoo"}) ==
               :other
    end
  end
end
