defmodule Cev.PreflightTest do
  use ExUnit.Case, async: true

  alias Cev.Preflight

  # H13. `check_secrets!/0` gated the Claude Code auth-token check on
  # `implement_driver() == :claude_code`. Nothing produces that atom — the
  # canonical one is `:cc` — so the branch was dead, `needs_cc` was permanently
  # false, and a run configured for the CC driver with no token in
  # `config/secrets.exs` sailed past the check whose whole job is to say so.
  # The failure surfaced later in `cc_smoke!/0` as an opaque agent error.
  #
  # `check_secrets!/0` cannot be called from a test — `fail/1` is
  # `System.halt(1)` — so the predicate is what gets pinned here.
  describe "needs_cc_token?/1" do
    test "the Claude Code driver needs the token" do
      assert Preflight.needs_cc_token?(:cc)
    end

    test "the other drivers do not" do
      refute Preflight.needs_cc_token?(:pi)
      refute Preflight.needs_cc_token?(:llm)
    end

    test "the dead `:claude_code` atom is not treated as the CC driver" do
      # The regression itself: if someone reintroduces the old spelling as an
      # alias, the mapping is ambiguous again and the next reader cannot tell
      # which one the config produces.
      refute Preflight.needs_cc_token?(:claude_code)
    end

    test "agrees with what Cev.Implement actually dispatches on" do
      # The bug was a divergence between two places that must name the same
      # atom. Pin them together so they cannot drift apart again silently.
      source = File.read!("lib/cev/implement.ex")

      assert source =~ ~r/^\s*:cc ->/m,
             "Cev.Implement.run/2 no longer dispatches on :cc — needs_cc_token?/1 must follow it"

      refute source =~ ~r/^\s*:claude_code ->/m,
             "Cev.Implement.run/2 now dispatches on :claude_code — needs_cc_token?/1 must follow it"
    end

    test "agrees with the configured driver being a known one" do
      # Not asserting a particular driver (config is the maintainer's choice),
      # only that whatever is configured is one this module knows about — a
      # typo'd driver atom would otherwise silently mean "needs no secrets".
      assert Cev.Config.implement_driver() in [:cc, :pi, :llm]
    end
  end
end
