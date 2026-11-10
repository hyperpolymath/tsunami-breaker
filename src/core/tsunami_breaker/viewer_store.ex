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

  defp load(nil), do: %{}

  defp load(path) do
    with {:ok, bin} <- File.read(path), {:ok, m} <- safe_decode(bin), do: m, else: (_ -> %{})
  end

  defp safe_decode(bin) do
    {:ok, :erlang.binary_to_term(bin, [:safe])}
  rescue
    _ -> :error
  end

  defp save(%{path: nil}), do: :ok

  defp save(%{path: path, viewers: v}) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, :erlang.term_to_binary(v))
  end
end
