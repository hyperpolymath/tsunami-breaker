# SPDX-License-Identifier: MPL-2.0
defmodule TsunamiBreaker.ViewerStore do
  @moduledoc """
  Remembers each viewer's own idea of noise: their overrides ("this is noise
  for me" / "not noise for me") and the failure types they've already seen
  (the baseline for "new failure type"). Kept per login, never shared between
  viewers, and saved to a local file so it survives restarts.

  These are preferences inside this tool only. Nothing here touches GitHub.
  """

  use Agent
  alias TsunamiBreaker.Viewer

  def start_link(opts) do
    path = Keyword.get(opts, :path)

    Agent.start_link(fn -> %{path: path, viewers: load(path)} end,
      name: Keyword.get(opts, :name, __MODULE__)
    )
  end

  def get(login, server \\ __MODULE__) do
    Agent.get(server, fn s -> Map.get(s.viewers, login) || Viewer.new(login: login) end)
  end

  def set_override(login, key, value, server \\ __MODULE__)
      when value in [:noise, :signal, nil] do
    update(server, login, fn v ->
      overrides =
        if value, do: Map.put(v.overrides, key, value), else: Map.delete(v.overrides, key)

      %{v | overrides: overrides}
    end)
  end

  def remember_failures(login, events, server \\ __MODULE__) do
    pairs = for e <- events, TsunamiBreaker.Event.ci_failure?(e), do: {e.repo, e.workflow}

    update(server, login, fn v -> %{v | baseline: MapSet.union(v.baseline, MapSet.new(pairs))} end)
  end

  defp update(server, login, fun) do
    Agent.get_and_update(server, fn s ->
      v = fun.(Map.get(s.viewers, login) || Viewer.new(login: login))
      s = put_in(s.viewers[login], v)
      save(s)
      {v, s}
    end)
  end

  # The file holds only what each viewer changed (overrides and baseline), as
  # JSON. Never an Erlang term: decoding a term from disk is a deserialisation
  # risk (CWE-502), and the rest of a Viewer (compiled regexes) does not
  # survive an OTP upgrade anyway.
  defp load(nil), do: %{}

  defp load(path) do
    with {:ok, bin} <- File.read(path),
         {:ok, %{} = m} <- Jason.decode(bin) do
      Map.new(m, fn {login, data} -> {login, from_json(login, data)} end)
    else
      _ -> %{}
    end
  end

  defp save(%{path: nil}), do: :ok

  defp save(%{path: path, viewers: v}) do
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      Jason.encode!(Map.new(v, fn {login, viewer} -> {login, to_json(viewer)} end))
    )
  end

  defp to_json(%Viewer{} = v) do
    %{
      "overrides" => for({k, val} <- v.overrides, do: [key_to_json(k), Atom.to_string(val)]),
      "baseline" => for({repo, wf} <- v.baseline, do: [repo, wf])
    }
  end

  # Every name a fingerprint key can hold: sources and causes (Classifier) and
  # notification reasons (PasteParser, ApiNormalizer). They are listed here on
  # purpose, not looked up with String.to_existing_atom/1: in a fresh VM the
  # modules that use those atoms may not be loaded yet, which would drop valid
  # saved corrections. The file still cannot create new atoms.
  @key_atoms ~w(agent_session human bot workflow unknown
                gate project_ci review comment mention review_request security assignment other
                ci_activity author team_mention review_requested security_alert assign
                state_change subscribed manual invitation approval_requested)a
             |> Map.new(&{Atom.to_string(&1), &1})

  @values %{"noise" => :noise, "signal" => :signal}

  defp from_json(login, data) when is_map(data) do
    overrides =
      for [k, v] <- List.wrap(data["overrides"]),
          key = key_from_json(k),
          val = Map.get(@values, v),
          into: %{},
          do: {key, val}

    baseline = for [repo, wf] <- List.wrap(data["baseline"]), into: MapSet.new(), do: {repo, wf}
    Viewer.new(login: login, overrides: overrides, baseline: baseline)
  end

  defp from_json(login, _), do: Viewer.new(login: login)

  # Fingerprint keys are {source, workflow, pattern} or {source, {cause, reason}, pattern}.
  defp key_to_json({src, {cause, reason}, pat}),
    do: [to_string(src), [to_string(cause), to_string(reason)], pat]

  defp key_to_json({src, what, pat}), do: [to_string(src), what, pat]

  # An unknown or malformed part makes the whole key nil, and the entry is skipped.
  defp key_from_json([src, [cause, reason], pat]) when is_binary(pat) do
    with {:ok, s} <- name(src), {:ok, c} <- name(cause), {:ok, r} <- name(reason) do
      {s, {c, r}, pat}
    else
      _ -> nil
    end
  end

  # A workflow can be nil when a pasted CI title did not parse.
  defp key_from_json([src, what, pat])
       when (is_binary(what) or is_nil(what)) and is_binary(pat) do
    case name(src) do
      {:ok, s} -> {s, what, pat}
      :error -> nil
    end
  end

  defp key_from_json(_), do: nil

  defp name(s), do: Map.fetch(@key_atoms, s)
end
