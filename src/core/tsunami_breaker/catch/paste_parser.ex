defmodule TsunamiBreaker.Catch.PasteParser do
  @moduledoc """
  Reads text copied from github.com/notifications (Inbox or Done tab) and turns
  it into `TsunamiBreaker.Event`s.

  It accepts both shapes a copy can take:

    * markdown-ish, with links: `* [owner/repo – Workflow #12](https://…)`
    * plain text, without links: `owner/repo – Workflow #12`

  The page only shows *relative* times ("6 minutes ago"), so the caller passes
  `captured_at` (when the page was copied). Items with no visible time get the
  time of their neighbour and are flagged `at_estimated?: true`.
  """

  alias TsunamiBreaker.Event

  @link ~r/\[([^\]]*)\]\(([^)\s]+)\)/u
  @header ~r/^(?<repo>[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+)(?:\s+[–—-]\s+(?<wf>.+?))?\s+#(?<num>\d+)$/u
  @ci_title ~r/^(?<wf>.+?) workflow run (?<concl>failed|succeeded|cancelled|completed|timed out)(?: with [\w ]+)? for (?<branch>.+?) branch$/u
  @run_failed_title ~r/^Run (?<concl>failed|succeeded|cancelled):\s*(?<wf>.+?) - (?<branch>\S+)(?: \([0-9a-f]+\))?$/u
  @rel_time ~r/^(?<n>\d+|an?|a few)\s+(?<unit>second|minute|hour|day|week|month|year)s?\s+ago$/u
  @more ~r/^\+\d+$/

  @reasons %{
    "ci activity" => :ci_activity,
    "author" => :author,
    "commented" => :comment,
    "comment" => :comment,
    "mention" => :mention,
    "mentioned" => :mention,
    "team mention" => :team_mention,
    "review requested" => :review_requested,
    "security alert" => :security_alert,
    "assigned" => :assign,
    "assign" => :assign,
    "state change" => :state_change,
    "subscribed" => :subscribed,
    "manual" => :manual,
    "invitation" => :invitation,
    "approval requested" => :approval_requested
  }

  def reasons, do: @reasons

  @doc "Parse pasted notifications text. Options: `:captured_at` (DateTime, default now)."
  @spec parse(String.t(), keyword()) :: [Event.t()]
  def parse(text, opts \\ []) do
    captured_at =
      Keyword.get(opts, :captured_at, DateTime.utc_now()) |> DateTime.truncate(:second)

    text
    |> String.split(~r/\r?\n/)
    |> Enum.map(&prepare_line/1)
    |> chunk_items()
    |> Enum.map(&build_event(&1, captured_at))
    |> fill_missing_times()
  end

  # Each line becomes %{text: visible text, urls: [..], bullet?: started with "* "}
  defp prepare_line(line) do
    trimmed = String.trim(line)

    {bullet?, body} =
      case trimmed do
        "* " <> rest -> {true, rest}
        "*" -> {true, ""}
        other -> {false, other}
      end

    urls = for [_, _, url] <- Regex.scan(@link, body), do: url
    visible = Regex.replace(@link, body, "\\1") |> String.trim()
    %{text: visible, urls: urls, bullet?: bullet?}
  end

  defp chunk_items(lines) do
    {items, current} =
      Enum.reduce(lines, {[], nil}, fn line, {acc, cur} ->
        case header(line) do
          {:ok, h} -> {push(acc, cur), %{header: h, urls: line.urls, body: []}}
          :error when cur == nil -> {acc, nil}
          :error -> {acc, %{cur | body: cur.body ++ [line]}}
        end
      end)

    push(items, current) |> Enum.reverse()
  end

  defp push(acc, nil), do: acc
  defp push(acc, item), do: [item | acc]

  defp header(%{text: text}) do
    case Regex.named_captures(@header, text) do
      nil -> :error
      caps -> {:ok, caps}
    end
  end

  defp build_event(%{header: h, urls: urls, body: body}, captured_at) do
    body_text = body |> Enum.map(& &1.text) |> Enum.reject(&(&1 == ""))
    url = List.first(urls) || Enum.find_value(body, &List.first(&1.urls))

    {title_lines, rest} = Enum.split_while(body_text, &(not meta_line?(&1)))
    title = Enum.join(title_lines, " ") |> String.replace(~r/\s+/, " ") |> String.trim()

    reason = Enum.find_value(rest, &Map.get(@reasons, String.downcase(&1)))

    extra =
      Enum.find_value(rest, 0, fn l ->
        if Regex.match?(@more, l), do: String.to_integer(String.trim_leading(l, "+"))
      end)

    at = Enum.find_value(rest, &relative_time(&1, captured_at))

    [owner, _name] = String.split(h["repo"], "/", parts: 2)
    wf_raw = blank_to_nil(h["wf"])

    base = %Event{
      repo: h["repo"],
      owner: owner,
      number: String.to_integer(h["num"]),
      title: title,
      reason: reason || :other,
      extra_count: extra,
      at: at,
      url: url,
      source: :paste,
      raw: %{header: h, body: body_text, urls: urls}
    }

    base
    |> apply_url(url)
    |> infer_kind_without_url(wf_raw, title)
    |> apply_ci(wf_raw, title)
    |> Map.put(:id, thread_id(url) || "#{h["repo"]}##{h["num"]}:#{base.kind}")
  end

  defp meta_line?(l),
    do:
      Regex.match?(@more, l) or Regex.match?(@rel_time, l) or l in ~w(now just\ now yesterday) or
        Map.has_key?(@reasons, String.downcase(l))

  defp apply_url(event, nil), do: %{event | kind: :other}

  defp apply_url(event, url) do
    uri = URI.parse(url)
    path = uri.path || ""
    frag = uri.fragment || ""

    kind =
      cond do
        path =~ ~r{/actions/runs/\d+} -> :workflow_run
        path =~ ~r{/pull/\d+} -> :pull_request
        path =~ ~r{/issues/\d+} -> :issue
        path =~ ~r{/security/|/dependabot} -> :security_alert
        path =~ ~r{/releases/} -> :release
        path =~ ~r{/discussions/} -> :discussion
        true -> :other
      end

    activity =
      cond do
        String.starts_with?(frag, "pullrequestreview") ->
          :review

        String.starts_with?(frag, "issuecomment") or String.starts_with?(frag, "discussion_r") ->
          :comment

        kind == :workflow_run ->
          :run

        true ->
          nil
      end

    run_id =
      case Regex.run(~r{/actions/runs/(\d+)}, path) do
        [_, id] -> String.to_integer(id)
        _ -> nil
      end

    %{event | kind: kind, activity: activity, run_id: run_id}
  end

  @doc "Split a CI notification title into workflow, conclusion and branch (shared with the API path)."
  def parse_ci_title(title) do
    caps =
      Regex.named_captures(@ci_title, title || "") ||
        Regex.named_captures(@run_failed_title, title || "") || %{}

    %{
      workflow_raw: caps["wf"],
      workflow: normalise_workflow(caps["wf"]),
      branch: caps["branch"],
      conclusion: conclusion(caps["concl"])
    }
  end

  # Plain-text copies have no links; a "repo – Workflow #N" header or a CI title is enough.
  defp infer_kind_without_url(%Event{kind: :other, url: nil} = e, wf_raw, title) do
    if wf_raw || Regex.match?(@ci_title, title) || Regex.match?(@run_failed_title, title),
      do: %{e | kind: :workflow_run, activity: :run},
      else: e
  end

  defp infer_kind_without_url(e, _wf, _title), do: e

  defp apply_ci(%Event{kind: :workflow_run} = e, wf_raw, title) do
    caps =
      Regex.named_captures(@ci_title, title) || Regex.named_captures(@run_failed_title, title) ||
        %{}

    raw = wf_raw || caps["wf"]

    %{
      e
      | workflow_raw: raw,
        workflow: normalise_workflow(raw),
        branch: caps["branch"],
        conclusion: conclusion(caps["concl"]),
        actor_kind: :workflow
    }
  end

  defp apply_ci(e, _wf, _title), do: e

  @doc "Strip decorative emoji/status markers so `🟡 Check: X` and `Check: X` are one workflow."
  def normalise_workflow(nil), do: nil

  def normalise_workflow(name) do
    name
    |> String.replace(~r/^[^\p{L}\p{N}]+/u, "")
    |> String.trim()
  end

  def conclusion("failed"), do: :failure
  def conclusion("succeeded"), do: :success
  def conclusion("cancelled"), do: :cancelled
  def conclusion("timed out"), do: :timed_out
  def conclusion("completed"), do: :completed
  def conclusion(_), do: nil

  defp relative_time(line, captured_at) do
    cond do
      line in ["now", "just now"] ->
        captured_at

      line == "yesterday" ->
        DateTime.add(captured_at, -86_400, :second)

      caps = Regex.named_captures(@rel_time, line) ->
        n =
          case caps["n"] do
            "a few" -> 3
            a when a in ["a", "an"] -> 1
            d -> String.to_integer(d)
          end

        secs =
          %{
            "second" => 1,
            "minute" => 60,
            "hour" => 3600,
            "day" => 86_400,
            "week" => 604_800,
            "month" => 2_592_000,
            "year" => 31_536_000
          }[caps["unit"]]

        DateTime.add(captured_at, -n * secs, :second)

      true ->
        nil
    end
  end

  # The page lists newest first; an item with no time sits between two that have one.
  defp fill_missing_times(events) do
    times = Enum.map(events, & &1.at)

    events
    |> Enum.with_index()
    |> Enum.map(fn
      {%Event{at: nil} = e, i} ->
        neighbour = Enum.at(times, i + 1) || (i > 0 && Enum.at(times, i - 1)) || nil
        %{e | at: neighbour, at_estimated?: true}

      {e, _} ->
        e
    end)
  end

  @doc """
  GitHub's `notification_referrer_id` (`NT_…`) is base64 for
  `…Repository;<repo id>;<subject type>;<subject id>`. We use it as a stable
  thread id so the same notification pasted twice is counted once.
  """
  def thread_id(nil), do: nil

  def thread_id(url) do
    with %URI{query: q} when is_binary(q) <- URI.parse(url),
         %{"notification_referrer_id" => "NT_" <> enc} <- URI.decode_query(q),
         {:ok, bin} <- Base.url_decode64(enc, padding: false),
         [_, repo_id, type, subject_id] <- Regex.run(~r/Repository;(\d+);(\w+);(\d+)/, bin) do
      "#{type}:#{repo_id}:#{subject_id}"
    else
      _ -> nil
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(s), do: s
end
