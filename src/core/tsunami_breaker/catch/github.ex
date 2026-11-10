defmodule TsunamiBreaker.Catch.GitHub do
  @moduledoc """
  Read-only GitHub client. **It can only send GET requests**: there is no
  function here that changes anything on GitHub, so this version cannot mark
  threads done, cancel runs or edit workflows, even by mistake.

  Being a good citizen (the tool must never become another source of flood):

    * stops early when the hourly API budget runs low (`@rate_floor`),
    * reports GitHub's `X-Poll-Interval` so the UI won't refetch sooner,
    * caps pages and repos per fetch,
    * never polls on its own: a fetch only happens when someone presses the button.

  Token: a classic personal access token with `notifications` and `repo`
  (read) scopes. As far as we know, fine-grained tokens can't read the
  notifications API.
  """

  require Logger
  @rate_floor 200
  @api "https://api.github.com"

  defstruct [:req]

  def new(token, opts \\ []) do
    req =
      Req.new(
        base_url: Keyword.get(opts, :base_url, @api),
        auth: {:bearer, token},
        headers: [
          {"accept", "application/vnd.github+json"},
          {"x-github-api-version", "2022-11-28"},
          {"user-agent", "tsunami-breaker"}
        ],
        retry: :transient,
        max_retries: 2
      )
      |> Req.merge(Keyword.take(opts, [:plug]))

    %__MODULE__{req: req}
  end

  @doc "The signed-in user (who the viewer is)."
  def user(c), do: get(c, "/user", []) |> body()

  @doc "Notifications, newest first. `all: true` also returns read ones (not ones marked done)."
  def notifications(c, opts \\ []) do
    params = [all: Keyword.get(opts, :all, true), per_page: 50] ++ since(opts)
    paginate(c, "/notifications", params, Keyword.get(opts, :max_pages, 10))
  end

  @doc """
  Workflow runs for one repo: successes too, and regardless of whether the
  notification was marked done. This is how history behind the Done tab is recovered.
  """
  def workflow_runs(c, repo, opts \\ []) do
    params =
      [per_page: 100] ++
        case Keyword.get(opts, :created_since) do
          nil -> []
          %DateTime{} = d -> [created: ">=" <> DateTime.to_iso8601(d)]
        end

    with {:ok, pages} <-
           paginate(c, "/repos/#{repo}/actions/runs", params, Keyword.get(opts, :max_pages, 1)) do
      {:ok,
       Enum.flat_map(pages, fn
         %{"workflow_runs" => runs} -> runs
         other when is_list(other) -> other
         _ -> []
       end)}
    end
  end

  @doc "The comment or review behind a notification, to learn who the actor was (bot or human)."
  def actor_of(c, %{"subject" => %{"latest_comment_url" => url}}) when is_binary(url) do
    if url =~ ~r{/(comments|reviews)/\d+$} do
      case get(c, url, []) |> body() do
        {:ok, %{"user" => %{"login" => login}}} -> login
        _ -> nil
      end
    end
  end

  def actor_of(_c, _n), do: nil

  # ---- GET only ----------------------------------------------------------

  defp get(%__MODULE__{req: req}, url, params) do
    case Req.get(req, url: url, params: params) do
      {:ok, %Req.Response{status: s} = r} when s in 200..299 -> {:ok, r}
      {:ok, %Req.Response{status: 304} = r} -> {:ok, r}
      {:ok, %Req.Response{status: s, body: b}} -> {:error, {:http, s, message(b)}}
      {:error, e} -> {:error, {:transport, Exception.message(e)}}
    end
  end

  defp body({:ok, %Req.Response{body: b}}), do: {:ok, b}
  defp body(err), do: err

  defp paginate(c, url, params, max_pages, acc \\ [], page \\ 1) do
    with {:ok, resp} <- get(c, url, if(page == 1, do: params, else: [])) do
      acc = acc ++ List.wrap(resp.body)
      remaining = header_int(resp, "x-ratelimit-remaining")

      cond do
        remaining != nil and remaining < @rate_floor ->
          Logger.warning(
            "tsunami-breaker: stopping early, GitHub API budget low (#{remaining} left)"
          )

          {:ok, acc}

        page >= max_pages ->
          {:ok, acc}

        next = next_link(resp) ->
          paginate(c, next, params, max_pages, acc, page + 1)

        true ->
          {:ok, acc}
      end
    end
  end

  def poll_interval(%Req.Response{} = r), do: header_int(r, "x-poll-interval")

  defp header_int(resp, name) do
    case Req.Response.get_header(resp, name) do
      [v | _] -> String.to_integer(v)
      _ -> nil
    end
  end

  defp next_link(resp) do
    with [link | _] <- Req.Response.get_header(resp, "link"),
         [_, url] <- Regex.run(~r/<([^>]+)>;\s*rel="next"/, link) do
      url
    else
      _ -> nil
    end
  end

  defp since(opts) do
    case Keyword.get(opts, :since) do
      %DateTime{} = d -> [since: DateTime.to_iso8601(d)]
      _ -> []
    end
  end

  defp message(%{"message" => m}), do: m
  defp message(b), do: inspect(b) |> String.slice(0, 200)
end
