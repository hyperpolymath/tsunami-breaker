# SPDX-License-Identifier: MPL-2.0
defmodule TsunamiBreaker.Explain.Fishbone do
  @moduledoc """
  Layer 3 – the *why*, as an Ishikawa (fishbone) diagram: the effect at the
  head ("N notifications in M minutes"), cause categories as bones, and the
  specific causes, with counts, as ribs. Empty categories are left out.
  """

  alias TsunamiBreaker.Filter.Anomalies

  def build(events, timing) do
    ci = Enum.filter(events, &(&1.kind == :workflow_run))
    agent_ci = Enum.filter(ci, &(&1.source_kind == :agent_session))

    bones = [
      {"Agent sessions", top(agent_ci, & &1.session, &String.replace_prefix(&1, "claude/", ""))},
      {"Estate gates", top(Enum.filter(agent_ci, & &1.gate?), & &1.workflow)},
      {"Project checks", top(Enum.reject(agent_ci, & &1.gate?), & &1.workflow)},
      {"Main & non-agent branches",
       top(
         Enum.filter(ci, &(&1.source_kind != :agent_session)),
         &"#{Anomalies.short(&1.repo)} · #{&1.workflow}"
       )},
      {"Reviews on your PRs",
       top(
         Enum.filter(events, &(&1.kind != :workflow_run and &1.activity == :review)),
         &"#{Anomalies.short(&1.repo)} ##{&1.number}"
       )},
      {"Comments & mentions",
       top(
         Enum.filter(events, &(&1.kind != :workflow_run and &1.activity != :review)),
         &"#{Anomalies.short(&1.repo)} ##{&1.number} (#{&1.reason})"
       )}
    ]

    %{
      effect: "#{timing.total} notifications in #{timing.span_min} min",
      bones:
        for(
          {name, ribs} <- bones,
          ribs != [],
          do: %{name: name, ribs: ribs, total: ribs |> Enum.map(&elem(&1, 1)) |> Enum.sum()}
        )
    }
  end

  defp top(evs, keyf, labelf \\ & &1) do
    evs
    |> Enum.frequencies_by(keyf)
    |> Enum.sort_by(fn {k, n} -> {-n, k} end)
    |> Enum.map(fn {k, n} -> {labelf.(k), n} end)
  end
end
