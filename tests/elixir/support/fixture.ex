# SPDX-License-Identifier: MPL-2.0
defmodule TsunamiBreaker.Fixture do
  @moduledoc false
  alias TsunamiBreaker.Catch.PasteParser

  def path(name), do: Path.expand("../../../priv/fixtures/#{name}", __DIR__)

  def inbox_events,
    do:
      PasteParser.parse(File.read!(path("hyperpolymath_inbox_2026-11-09.md")),
        captured_at: ~U[2026-11-09 17:45:00Z]
      )
end
