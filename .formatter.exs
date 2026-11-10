# SPDX-License-Identifier: MPL-2.0
[
  import_deps: [:phoenix],
  plugins: [Phoenix.LiveView.HTMLFormatter],
  inputs: [
    "*.{heex,ex,exs}",
    "build/config/*.exs",
    "src/core/**/*.{heex,ex,exs}",
    "tests/elixir/**/*.{heex,ex,exs}"
  ]
]
