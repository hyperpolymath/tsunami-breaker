# SPDX-License-Identifier: MPL-2.0
defmodule TsunamiBreaker.Catch.ApiNormalizer do
  @moduledoc "Turns GitHub API JSON (notifications, workflow runs) into `TsunamiBreaker.Event`s."

  alias TsunamiBreaker.Event
  alias TsunamiBreaker.Catch.PasteParser

  @kinds %{
    "CheckSuite" => :workflow_run,
    "WorkflowRun" => :workflow_run,
    "PullRequest" => :pull_request,
    "Issue" => :issue,
    "RepositoryVulnerabilityAlert" => :security_alert,
    "RepositoryDependabotAlertsThread" => :security_alert,
    "SecretScanningAlert" => :security_alert,
    "RepositoryAdvisory" => :security_alert,
    "Release" => :release,
    "Discussion" => :discussion
  }

  @api_reasons %{
    "ci_activity" => :ci_activity,
    "author" => :author,
    "comment" => :comment,
    "mention" => :mention,
    "team_mention" => :team_mention,
    "review_requested" => :review_requested,
    "security_alert" => :security_alert,
    "assign" => :assign,
    "state_change" => :state_change,
    "subscribed" => :subscribed,
    "manual" => :manual,
    "invitation" => :invitation,
    "approval_requested" => :approval_requested,
    "member_feature_requested" => :other,
    "security_advisory_credit" => :other
  }

  @triggers ~w(push pull_request pull_request_target schedule workflow_dispatch merge_group workflow_run release)

  def notification(
        %{"id" => id, "subject" => subj, "repository" => %{"full_name" => repo}} = n,
        actor \\ nil
      ) do
    kind = Map.get(@kinds, subj["type"], :other)
    [owner, _] = String.split(repo, "/", parts: 2)

    number =
      case Regex.run(~r{/(\d+)$}, subj["url"] || "") do
        [_, d] -> String.to_integer(d)
        _ -> nil
      end

    base = %Event{
      id: "thread:" <> to_string(id),
      repo: repo,
      owner: owner,
      number: number,
      kind: kind,
      title: subj["title"],
      reason: Map.get(@api_reasons, n["reason"], :other),
      activity: activity(subj["latest_comment_url"], kind),
      actor: actor,
      at: parse_time(n["updated_at"]),
      url: html_url(subj["url"]) || get_in(n, ["repository", "html_url"]),
      source: :api_notification,
      raw: n
    }

    if kind == :workflow_run,
      do:
        Map.merge(
          base,
          Map.put(PasteParser.parse_ci_title(subj["title"]), :actor_kind, :workflow)
        ),
      else: base
  end

  def workflow_run(%{"id" => id} = r) do
    repo = get_in(r, ["repository", "full_name"])
    [owner | _] = String.split(repo || "/", "/")

    %Event{
      id: "run:#{id}",
      run_id: id,
      repo: repo,
      owner: owner,
      number: r["run_number"],
      kind: :workflow_run,
      title: r["display_title"] || r["name"],
      workflow_raw: r["name"],
      workflow: PasteParser.normalise_workflow(r["name"]),
      branch: r["head_branch"],
      conclusion: run_conclusion(r["conclusion"], r["status"]),
      reason: :ci_activity,
      activity: :run,
      actor: get_in(r, ["triggering_actor", "login"]) || get_in(r, ["actor", "login"]),
      trigger: if(r["event"] in @triggers, do: String.to_existing_atom(r["event"]), else: :other),
      at: parse_time(r["updated_at"] || r["created_at"]),
      url: r["html_url"],
      source: :api_run,
      raw:
        Map.take(
          r,
          ~w(id name head_branch head_sha event status conclusion run_attempt created_at updated_at html_url)
        )
    }
  end

  defp run_conclusion("failure", _), do: :failure
  defp run_conclusion("success", _), do: :success
  defp run_conclusion("cancelled", _), do: :cancelled
  defp run_conclusion("timed_out", _), do: :timed_out
  defp run_conclusion("startup_failure", _), do: :startup_failure
  defp run_conclusion("skipped", _), do: :skipped
  defp run_conclusion(nil, _status), do: :in_progress
  defp run_conclusion(_, _), do: :other

  defp activity(nil, :workflow_run), do: :run
  defp activity(nil, _), do: nil

  defp activity(url, _) do
    cond do
      url =~ "/reviews/" -> :review
      url =~ "/comments/" -> :comment
      true -> nil
    end
  end

  defp html_url(nil), do: nil

  defp html_url(api) do
    api
    |> String.replace("https://api.github.com/repos/", "https://github.com/")
    |> String.replace(~r{/pulls/(\d+)$}, "/pull/\\1")
  end

  defp parse_time(nil), do: nil

  defp parse_time(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  # Ensure trigger atoms exist for String.to_existing_atom/1.
  def __triggers__,
    do: [
      :push,
      :pull_request,
      :pull_request_target,
      :schedule,
      :workflow_dispatch,
      :merge_group,
      :workflow_run,
      :release
    ]
end
