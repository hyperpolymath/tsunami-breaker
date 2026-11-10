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

      repos =
        events
        |> Enum.filter(&(&1.kind == :workflow_run))
        |> Enum.map(& &1.repo)
        |> Enum.uniq()
        |> Enum.take(max_repos)

      history =
        Enum.flat_map(repos, fn repo ->
          case GitHub.workflow_runs(c, repo) do
            {:ok, runs} ->
              Enum.map(
                runs,
                &ApiNormalizer.workflow_run(Map.put_new(&1, "repository", %{"full_name" => repo}))
              )

            {:error, _} ->
              []
          end
        end)

      {:ok,
       %{
         login: user["login"],
         events: events,
         history: history,
         repos_scanned: length(repos),
         fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
       }}
    end
  end
end
