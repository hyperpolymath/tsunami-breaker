defmodule TsunamiBreaker.Filter.Anomalies do
  @moduledoc """
  Rules that make something stand out even inside a flood.

    * `:failure_on_default_branch` – a check failing on main/master/trunk.
    * `:persistent_failure` – the same repo × workflow × branch failing again
      and again with no pass in between.
    * `:normally_passing_now_failing` – a workflow that usually passes (from
      run history) has just failed.
    * `:new_failure_type` – a repo × workflow failure this viewer has never
      seen before (needs a baseline from an earlier session; silent on the first).

  Each anomaly is one *failing check* (repo × workflow × branch), however many
  notifications it produced.
  """

  alias TsunamiBreaker.{Event, Viewer}

  def detect(residual_failures, %Viewer{} = v, history \\ []) do
    residual_failures
    |> Enum.group_by(&Event.failure_key/1)
    |> Enum.map(fn {key, evs} -> {key, evs, rules(key, evs, v, history)} end)
    |> Enum.reject(fn {_k, _e, rules} -> rules == [] end)
    |> Enum.map(fn {{repo, wf, branch} = key, evs, rules} ->
      %{
        key: key,
        repo: repo,
        workflow: wf,
        branch: branch,
        rules: rules,
        events: evs,
        count: length(evs),
        last_at:
          evs |> Enum.map(& &1.at) |> Enum.reject(&is_nil/1) |> Enum.max(DateTime, fn -> nil end),
        summary: summary(repo, wf, branch, rules, length(evs))
      }
    end)
    |> Enum.sort_by(&{-length(&1.rules), &1.repo})
  end

  defp rules({repo, wf, branch}, evs, v, history) do
    [
      Viewer.default_branch?(v, branch) && :failure_on_default_branch,
      persistent?(evs, {repo, wf, branch}, history, v) && :persistent_failure,
      normally_passing?({repo, wf}, history) && :normally_passing_now_failing,
      new_type?({repo, wf}, v) && :new_failure_type
    ]
    |> Enum.filter(& &1)
  end

  defp persistent?(evs, {repo, wf, branch}, history, v) do
    hist = Enum.filter(history, &(&1.repo == repo and &1.workflow == wf and &1.branch == branch))

    runs =
      (evs ++ hist)
      |> Enum.uniq_by(&(&1.run_id || &1.id))
      |> Enum.sort_by(& &1.at, {:desc, DateTime})

    streak = Enum.take_while(runs, &Event.ci_failure?/1)
    length(streak) >= v.persistent_min_failures
  end

  defp normally_passing?({repo, wf}, history) do
    past =
      Enum.filter(
        history,
        &(&1.repo == repo and &1.workflow == wf and &1.conclusion in [:success, :failure])
      )

    n = length(past)
    n >= 5 and Enum.count(past, &(&1.conclusion == :success)) / n >= 0.8
  end

  defp new_type?(pair, %Viewer{baseline: b}),
    do: MapSet.size(b) > 0 and not MapSet.member?(b, pair)

  @labels %{
    failure_on_default_branch: "failing on the default branch",
    persistent_failure: "keeps failing (no pass in between)",
    normally_passing_now_failing: "usually passes, now failing",
    new_failure_type: "a failure you haven't seen before"
  }
  def label(rule), do: @labels[rule]

  defp summary(repo, wf, branch, rules, n) do
    "#{short(repo)} · #{wf} on #{branch}: " <>
      Enum.map_join(rules, ", ", &label/1) <> if(n > 1, do: " (#{n} pings)", else: "")
  end

  def short(repo), do: repo |> String.split("/") |> List.last()
end
