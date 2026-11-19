# SPDX-License-Identifier: MPL-2.0
defmodule TsunamiBreaker.Catch.Fetch do
  @moduledoc """
  Layer 1 – Catch, live. One button press = one bounded, read-only sweep:

    1. who am I (`/user`),
    2. notifications (read and unread; up to 10 pages),
    3. for the repos those notifications touch (max `:max_repos`), one page of
       recent workflow runs: the history behind the Done tab, used for
       "usually passes" and "keeps failing",
    4. for items that might need a person (mentions, review requests, your PRs),
       who actually acted (max `:max_actor_lookups`), so bots can be told apart.

  Marking threads done is **not** done here: this version is read-only.
  """

  alias TsunamiBreaker.Event
  alias TsunamiBreaker.Catch.{GitHub, ApiNormalizer}

  def run(token, opts \\ []) do
    c = GitHub.new(token, Keyword.take(opts, [:plug, :base_url]))
    max_repos = Keyword.get(opts, :max_repos, 25)
    max_lookups = Keyword.get(opts, :max_actor_lookups, 20)

    with {:ok, user} <- GitHub.user(c),
         {:ok, raw} <- GitHub.notifications(c, Keyword.take(opts, [:since, :max_pages])) do
      lookups =
        raw
        |> Enum.filter(
          &(&1["reason"] in ~w(mention team_mention review_requested author comment assign))
        )
        |> Enum.take(max_lookups)
        |> Map.new(&{&1["id"], GitHub.actor_of(c, &1)})

      events = Enum.map(raw, &ApiNormalizer.notification(&1, Map.get(lookups, &1["id"])))

      # Recently pushed repos are read too, so the sweep still sees runs when
      # Actions notifications are off (a failed lookup only narrows the sweep).
      {recent, recent_error} =
        case GitHub.recent_repos(c, max_repos) do
          {:ok, rs} -> {rs, nil}
          {:error, reason} -> {[], reason}
        end

      repos =
        events
        |> Enum.filter(&(&1.kind == :workflow_run))
        |> Enum.map(& &1.repo)
        |> Kernel.++(recent)
        |> Enum.uniq()
        |> Enum.take(max_repos)

      lookups_by_repo = Enum.map(repos, &{&1, GitHub.workflow_runs(c, &1)})

      # A repo whose runs could not be read is named, so a partial sweep is
      # never shown as a clean one.
      repos_unread = for {repo, {:error, _}} <- lookups_by_repo, do: repo

      history =
        for {repo, {:ok, runs}} <- lookups_by_repo,
            r <- runs,
            do: ApiNormalizer.workflow_run(Map.put_new(r, "repository", %{"full_name" => repo}))

      # A failed run that no notification reported becomes an event of its own,
      # so the lanes work from the runs and not only from the inbox.
      # snip: matched per check (repo, workflow, branch), not per run; a check
      # with one notification keeps its notification count. Match on run id
      # when the notifications API gives one.
      heard = MapSet.new(events, &Event.failure_key/1)

      unheard =
        Enum.filter(
          history,
          &(Event.ci_failure?(&1) and not MapSet.member?(heard, Event.failure_key(&1)))
        )

      {:ok,
       %{
         login: user["login"],
         events: events ++ unheard,
         unheard: length(unheard),
         history: history,
         repos_scanned: length(repos),
         recent_error: recent_error,
         repos_unread: repos_unread,
         fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
       }}
    end
  end
end
