defmodule TsunamiBreaker.Viewer do
  @moduledoc """
  Who is looking. "Noise" is decided per viewer, never globally: the same
  Dogfood Gate failure can be noise to the estate owner and signal to the
  person maintaining that gate.

  * `agent_branch_prefixes` – branches made by agent sessions (e.g. `claude/`).
  * `default_branches` – where a failure is never treated as routine.
  * `gate_patterns` – how this estate names its gates (editable, not hard-coded truth).
  * `focus_repos` / `own_branches` – work that should always be lifted for this viewer.
  * `overrides` – the viewer's own corrections: fingerprint key => :noise | :signal.
  * `baseline` – failure types seen in earlier sessions, used for "new failure type".
  """

  defstruct login: nil,
            agent_branch_prefixes: ["claude/"],
            default_branches: ["main", "master", "trunk"],
            gate_patterns: [~r/\bgate\b/i, ~r/\brules\b/i, ~r/^check:/i],
            gate_min_repos: 3,
            focus_repos: [],
            own_branches: [],
            overrides: %{},
            baseline: MapSet.new(),
            noise_min_key: 3,
            noise_min_family: 8,
            noise_min_family_repos: 3,
            persistent_min_failures: 3

  @type t :: %__MODULE__{}

  def new(attrs \\ []), do: struct(__MODULE__, attrs)

  def agent_branch?(%__MODULE__{agent_branch_prefixes: ps}, branch) when is_binary(branch),
    do: Enum.any?(ps, &String.starts_with?(branch, &1))

  def agent_branch?(_, _), do: false

  def default_branch?(%__MODULE__{default_branches: bs}, branch), do: branch in bs
end
