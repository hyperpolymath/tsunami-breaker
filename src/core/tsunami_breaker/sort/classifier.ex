defmodule TsunamiBreaker.Sort.Classifier do
  @moduledoc """
  Layer 2 – Sort. Says *who started* each event (source) and *why it reached
  the viewer* (cause).

  Sources: `:agent_session`, `:human`, `:bot`, `:workflow`, `:unknown`.
  Causes:  `:gate`, `:project_ci`, `:review`, `:comment`, `:mention`,
           `:review_request`, `:security`, `:assignment`, `:other`.
  Trigger: what kicked a CI run off (`:push`, `:pull_request`, `:schedule`, …)
           when known; a pasted page doesn't show it, so it is `:unknown` there.
  """

  alias TsunamiBreaker.{Event, Viewer}

  @known_bots ~w(coderabbitai sonarqubecloud sonarcloud chatgpt-codex-connector codex copilot
                 dependabot renovate github-actions github-advanced-security mergify codecov)

  def classify(%Event{} = e, %Viewer{} = v, gates) do
    source = source(e, v)
    cause = cause(e, gates)
    session = if source == :agent_session, do: e.branch
    %{e | source_kind: source, cause: cause, session: session, gate?: cause == :gate}
  end

  defp source(%Event{kind: :workflow_run, branch: b} = e, v) do
    cond do
      Viewer.agent_branch?(v, b) -> :agent_session
      bot?(e.actor) -> :bot
      e.actor -> :human
      true -> :workflow
    end
  end

  defp source(%Event{kind: :security_alert}, _v), do: :bot
  defp source(%Event{actor: a}, _v) when is_binary(a), do: if(bot?(a), do: :bot, else: :human)
  defp source(_e, _v), do: :unknown

  def bot?(nil), do: false

  def bot?(login) do
    l = String.downcase(login)
    String.ends_with?(l, "[bot]") or Enum.any?(@known_bots, &String.starts_with?(l, &1))
  end

  defp cause(%Event{kind: :workflow_run, workflow: w}, gates),
    do: if(w in gates, do: :gate, else: :project_ci)

  defp cause(%Event{kind: :security_alert}, _), do: :security
  defp cause(%Event{reason: :security_alert}, _), do: :security
  defp cause(%Event{reason: r}, _) when r in [:mention, :team_mention], do: :mention
  defp cause(%Event{reason: :review_requested}, _), do: :review_request
  defp cause(%Event{reason: :assign}, _), do: :assignment
  defp cause(%Event{activity: :review}, _), do: :review
  defp cause(%Event{activity: :comment}, _), do: :comment
  defp cause(_, _), do: :other

  @doc """
  Which workflows are *gates*: estate-wide checks rather than one project's own CI.

  A workflow counts as a gate if its name follows the viewer's gate naming
  (`gate_patterns`) **or** it fails in at least `gate_min_repos` different repos.
  Both rules are shown in the UI so the count can be argued with.
  """
  def gates(events, %Viewer{} = v) do
    ci = Enum.filter(events, &(&1.kind == :workflow_run and &1.workflow))

    by_name =
      ci
      |> Enum.map(& &1.workflow)
      |> Enum.uniq()
      |> Enum.filter(fn w -> Enum.any?(v.gate_patterns, &Regex.match?(&1, w)) end)

    by_spread =
      ci
      |> Enum.group_by(& &1.workflow, & &1.repo)
      |> Enum.filter(fn {_w, repos} -> length(Enum.uniq(repos)) >= v.gate_min_repos end)
      |> Enum.map(&elem(&1, 0))

    (by_name ++ by_spread) |> Enum.uniq() |> Enum.sort()
  end

  def gate_reason(workflow, events, v) do
    named? = Enum.any?(v.gate_patterns, &Regex.match?(&1, workflow))

    repos =
      events
      |> Enum.filter(&(&1.workflow == workflow))
      |> Enum.map(& &1.repo)
      |> Enum.uniq()
      |> length()

    cond do
      named? and repos >= v.gate_min_repos -> "named like a gate, and fails in #{repos} repos"
      named? -> "named like a gate"
      true -> "fails in #{repos} repos"
    end
  end
end
