# Integration tests (tagged `:integration`) shell into the live credence clone
# and/or the local model, so their results depend on external state (the clone's
# current rule set + `mix credence.*` behaviour). Exclude them from the default
# hermetic suite; run them explicitly with `mix test --include integration` once
# the clone is on `evolution` with a known-good HEAD.
ExUnit.start(exclude: [:integration])
