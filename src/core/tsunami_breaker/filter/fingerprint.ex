# SPDX-License-Identifier: MPL-2.0
defmodule TsunamiBreaker.Filter.Fingerprint do
  @moduledoc """
  The noise filter's memory: what the flood *looks like*, so it can be subtracted.

  A fingerprint key is **source × workflow × branch pattern**, e.g.
  `{:agent_session, "Dogfood Gate", "claude/*"}`. Keys are grouped into
  *families* (`{source, :any, branch pattern}`): twelve sessions failing six
  different gates is one family even if each single key is rare.

  Something is learned as noise when its key repeats (`noise_min_key`) or its
  family is big and spread across repos. It is **never** noise if it is on a
  default branch, asks for the viewer (mention, review request, security), or
  the viewer has overridden it to `:signal`.
  """

  alias TsunamiBreaker.Viewer

  def key(%{kind: :workflow_run} = e, v),
    do: {e.source_kind, e.workflow, branch_pattern(e.branch, v)}

  def key(e, _v), do: {e.source_kind, {e.cause, e.reason}, "*"}

  def family({source, _what, pattern}), do: {source, :any, pattern}

  def branch_pattern(nil, _v), do: "*"

  def branch_pattern(branch, %Viewer{} = v) do
    cond do
      Viewer.default_branch?(v, branch) -> branch
      p = Enum.find(v.agent_branch_prefixes, &String.starts_with?(branch, &1)) -> p <> "*"
      String.contains?(branch, "/") -> (branch |> String.split("/") |> hd()) <> "/*"
      true -> branch
    end
  end

  @doc "Learn the flood's shape from a batch of classified events."
  def learn(events, %Viewer{} = v) do
    keyed = Enum.map(events, &{key(&1, v), &1})
    key_counts = keyed |> Enum.frequencies_by(&elem(&1, 0))

    families =
      keyed
      |> Enum.group_by(fn {k, _} -> family(k) end, fn {_, e} -> e end)
      |> Map.new(fn {f, es} ->
        {f, %{count: length(es), repos: es |> Enum.map(& &1.repo) |> Enum.uniq() |> length()}}
      end)

    noisy_keys =
      for {k, n} <- key_counts, n >= v.noise_min_key, learnable?(k, v), into: MapSet.new(), do: k

    noisy_families =
      for {f, %{count: n, repos: r}} <- families,
          n >= v.noise_min_family and r >= v.noise_min_family_repos,
          learnable?(f, v),
          into: MapSet.new(),
          do: f

    %{
      key_counts: key_counts,
      families: families,
      noisy_keys: noisy_keys,
      noisy_families: noisy_families
    }
  end

  # Default-branch traffic is never learned as "normal noise".
  defp learnable?({_s, _w, pattern}, v), do: not Viewer.default_branch?(v, pattern)

  @doc "Does this event match the learned flood (after the viewer's own overrides)?"
  def matches?(e, fp, %Viewer{} = v) do
    k = key(e, v)

    case Map.get(v.overrides, k) do
      :noise -> true
      :signal -> false
      nil -> MapSet.member?(fp.noisy_keys, k) or MapSet.member?(fp.noisy_families, family(k))
    end
  end

  def describe({source, what, pattern}) do
    who =
      %{
        agent_session: "agent sessions",
        human: "people",
        bot: "bots",
        workflow: "workflows",
        unknown: "unknown actors"
      }[source] || to_string(source)

    w =
      case what do
        :any -> "anything"
        {cause, _reason} -> to_string(cause) |> String.replace("_", " ")
        name -> name
      end

    "#{w} · #{who} · #{pattern}"
  end
end
