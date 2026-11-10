# SPDX-License-Identifier: MPL-2.0
defmodule TsunamiBreakerWeb.DashboardLive do
  @moduledoc """
  The one screen. Load a flood (sample, pasted page, or a read-only GitHub
  fetch), then read it top to bottom: diagnosis → lanes → what stands out →
  timing → causal chain → fishbone → quarantine → proposals.

  Read-only: the only things a button here can change are this viewer's own
  noise preferences inside the tool. Nothing is sent to GitHub except GETs.
  """

  use TsunamiBreakerWeb, :live_view

  alias TsunamiBreaker.{Analysis, ViewerStore, Rescue}
  alias TsunamiBreaker.Catch.{PasteParser, Fetch}
  alias TsunamiBreaker.Filter.{Anomalies, Fingerprint}
  alias TsunamiBreakerWeb.Charts

  @sample "hyperpolymath_inbox_2026-11-09.md"
  # The sample was copied at about this time; the page only shows "N minutes ago".
  @sample_captured_at ~U[2026-11-09 17:45:00Z]
  @min_refetch_s 60

  @lane_meta [
    anomaly: {"Stands out", "breaks the flood's pattern", "var(--series-stands)"},
    needs_you: {"Needs you", "mentions, review requests, security", "var(--series-stands)"},
    your_work: {"Your work", "your PRs and threads", "var(--series-yours)"},
    quarantine: {"Quarantine", "matches the flood · kept, not deleted", "var(--series-flood)"},
    residual: {"Unmatched", "not flood, no rule fired", "var(--series-other)"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "tsunami-breaker",
       login: "hyperpolymath",
       source: nil,
       raw_events: [],
       history: [],
       analysis: nil,
       lane: nil,
       open_groups: MapSet.new(),
       show_paste: false,
       error: nil,
       fetching: false,
       last_fetch_at: nil,
       token?: token() != nil,
       lane_meta: @lane_meta
     )
     |> load_sample()}
  end

  # ------------------------------------------------------------------ events

  @impl true
  def handle_event("load_sample", _, socket), do: {:noreply, load_sample(socket)}

  def handle_event("toggle_paste", _, socket), do: {:noreply, update(socket, :show_paste, &(!&1))}

  def handle_event("analyse_paste", %{"text" => text, "minutes_ago" => mins}, socket) do
    offset =
      case Integer.parse(mins || "") do
        {n, _} when n >= 0 -> n
        _ -> 0
      end

    captured_at = DateTime.utc_now() |> DateTime.add(-offset * 60, :second)

    case PasteParser.parse(text, captured_at: captured_at) do
      [] ->
        {:noreply,
         assign(socket,
           error:
             "Couldn't find any notifications in that text. Copy the list from github.com/notifications (Inbox or Done) and paste it as-is."
         )}

      events ->
        {:noreply,
         socket
         |> assign(
           source: "pasted page (#{length(events)} items)",
           raw_events: events,
           history: [],
           show_paste: false,
           error: nil
         )
         |> analyse()}
    end
  end

  def handle_event("set_viewer", %{"login" => login}, socket) do
    login = String.trim(login)
    {:noreply, if(login == "", do: socket, else: socket |> assign(login: login) |> analyse())}
  end

  def handle_event("fetch_github", _, socket) do
    cond do
      socket.assigns.fetching ->
        {:noreply, socket}

      not refetch_allowed?(socket) ->
        {:noreply,
         assign(socket,
           error: "Please wait a minute between fetches. This tool shouldn't add load of its own."
         )}

      true ->
        t = token()

        {:noreply,
         socket
         |> assign(fetching: true, error: nil)
         |> start_async(:fetch, fn -> Fetch.run(t) end)}
    end
  end

  def handle_event("lane", %{"lane" => lane}, socket) do
    lane = String.to_existing_atom(lane)
    {:noreply, assign(socket, lane: if(socket.assigns.lane == lane, do: nil, else: lane))}
  end

  def handle_event("toggle_group", %{"key" => k}, socket) do
    open = socket.assigns.open_groups

    {:noreply,
     assign(socket,
       open_groups:
         if(MapSet.member?(open, k), do: MapSet.delete(open, k), else: MapSet.put(open, k))
     )}
  end

  def handle_event("override", %{"key" => enc, "value" => value}, socket) do
    value = %{"noise" => :noise, "signal" => :signal, "clear" => nil}[value]
    ViewerStore.set_override(socket.assigns.login, decode_key(enc), value)
    {:noreply, analyse(socket)}
  end

  @impl true
  def handle_async(:fetch, {:ok, {:ok, res}}, socket) do
    {:noreply,
     socket
     |> assign(
       fetching: false,
       last_fetch_at: res.fetched_at,
       login: res.login || socket.assigns.login,
       raw_events: res.events,
       history: res.history,
       source:
         "GitHub (#{length(res.events)} notifications, run history from #{res.repos_scanned} repos)"
     )
     |> analyse()}
  end

  def handle_async(:fetch, {:ok, {:error, reason}}, socket),
    do:
      {:noreply,
       assign(socket,
         fetching: false,
         last_fetch_at: DateTime.utc_now(),
         error: "GitHub fetch failed: #{format_error(reason)}"
       )}

  def handle_async(:fetch, {:exit, reason}, socket),
    do:
      {:noreply,
       assign(socket, fetching: false, error: "GitHub fetch crashed: #{inspect(reason)}")}

  # ------------------------------------------------------------------ helpers

  defp load_sample(socket) do
    path = Application.app_dir(:tsunami_breaker, Path.join("priv/fixtures", @sample))
    events = PasteParser.parse(File.read!(path), captured_at: @sample_captured_at)

    socket
    |> assign(
      source: "sample: hyperpolymath inbox, 9 Nov 2026 (#{length(events)} items)",
      raw_events: events,
      history: [],
      error: nil
    )
    |> analyse()
  end

  defp analyse(%{assigns: %{raw_events: []}} = socket), do: assign(socket, analysis: nil)

  defp analyse(socket) do
    viewer = ViewerStore.get(socket.assigns.login)
    analysis = Analysis.run(socket.assigns.raw_events, viewer, history: socket.assigns.history)
    # Remember what this viewer has now seen, for "new failure type" next time.
    ViewerStore.remember_failures(socket.assigns.login, analysis.events)
    assign(socket, analysis: analysis)
  end

  defp refetch_allowed?(%{assigns: %{last_fetch_at: nil}}), do: true

  defp refetch_allowed?(%{assigns: %{last_fetch_at: t}}),
    do: DateTime.diff(DateTime.utc_now(), t) >= @min_refetch_s

  defp token, do: Application.get_env(:tsunami_breaker, :github_token)

  def encode_key(k), do: k |> :erlang.term_to_binary() |> Base.url_encode64(padding: false)

  defp decode_key(s),
    do: s |> Base.url_decode64!(padding: false) |> :erlang.binary_to_term([:safe])

  defp format_error({:http, 401, _}),
    do: "the token was refused (401). Check it's a classic token with the notifications scope."

  defp format_error({:http, 403, m}), do: "forbidden (403): #{m}"
  defp format_error({:http, s, m}), do: "HTTP #{s}: #{m}"
  defp format_error({:transport, m}), do: "network: #{m}"
  defp format_error(other), do: inspect(other)

  defp ago(nil, _), do: "time unknown"

  defp ago(at, %Analysis{timing: %{last_at: last}}) do
    m = div(DateTime.diff(last, at), 60)
    if m == 0, do: "latest", else: "#{m} min before latest"
  end

  defp short(repo), do: Anomalies.short(repo)

  defp item_title(e) do
    case e.kind do
      :workflow_run -> "#{short(e.repo)} · #{e.workflow} on #{e.branch}"
      _ -> "#{short(e.repo)} ##{e.number} · #{e.title}"
    end
  end

  defp source_label(:agent_session), do: "agent session"
  defp source_label(:unknown), do: "actor not visible"
  defp source_label(s), do: to_string(s)

  # ------------------------------------------------------------------ render

  @impl true
  def render(assigns) do
    ~H"""
    <div class="topbar">
      <div>
        <span class="brand">tsunami-breaker</span>
        <span class="badge">read-only</span>
        <span :if={@source} class="muted small">· {@source}</span>
      </div>
      <form phx-submit="set_viewer" class="row">
        <label class="small muted" for="login">Viewing as</label>
        <input id="login" name="login" value={@login} size="16" />
        <button type="submit">Switch</button>
      </form>
    </div>

    <div class="card">
      <div class="row">
        <button phx-click="load_sample">Use the sample</button>
        <button phx-click="toggle_paste">Paste a notifications page…</button>
        <button
          phx-click="fetch_github"
          disabled={!@token? or @fetching}
          title={if !@token?, do: "Set TSUNAMI_GITHUB_TOKEN before starting the server"}
        >
          {if @fetching, do: "Fetching…", else: "Fetch from GitHub"}
        </button>
        <span :if={!@token?} class="muted small">No token set: GitHub fetch is off.</span>
      </div>
      <form :if={@show_paste} phx-submit="analyse_paste" style="margin-top: 10px">
        <textarea
          name="text"
          placeholder="Select all on github.com/notifications (Inbox or Done), copy, paste here."
        ></textarea>
        <div class="row" style="margin-top: 6px">
          <label class="small">Copied
          <input name="minutes_ago" type="number" min="0" value="0" style="width: 70px" />
          minutes ago</label>
          <button type="submit" class="primary">Analyse</button>
        </div>
      </form>
      <p :if={@error} class="error small">{@error}</p>
    </div>

    <%= if @analysis do %>
      <% a = @analysis %>
      <section class="card hero">
        <h3>Diagnosis</h3>
        <h1>{a.diagnosis.headline}</h1>
        <ul>
          <li :for={p <- a.diagnosis.plain}>{p}</li>
        </ul>
      </section>

      <div class="lanes">
        <button
          :for={{lane, {label, desc, color}} <- @lane_meta}
          class={["lane", @lane == lane && "active"]}
          style={"--lane-color: #{color}"}
          phx-click="lane"
          phx-value-lane={lane}
        >
          <span class="n">{a.lane_counts[lane]}</span>
          <span class="label">{label}</span>
          <span class="desc">{desc}</span>
        </button>
      </div>

      <section :if={@lane} class="card">
        <h2>{elem(@lane_meta[@lane], 0)} · {a.lane_counts[@lane]}</h2>
        <.item_list events={a.lanes[@lane]} analysis={a} />
        <p :if={a.lane_counts[@lane] == 0} class="muted">Nothing here.</p>
      </section>

      <div class="grid-2">
        <section class="card">
          <h2>What stands out</h2>
          <p :if={a.anomalies == []} class="muted">Nothing breaks the flood's pattern.</p>
          <ul class="items">
            <li :for={an <- a.anomalies}>
              <span
                :for={r <- an.rules}
                class={["tag", r == :failure_on_default_branch && "critical"]}
              >
                {if r == :failure_on_default_branch, do: "▲ ", else: "● "}{Anomalies.label(r)}
              </span>
              <div><strong>{short(an.repo)} · {an.workflow}</strong> on <code>{an.branch}</code></div>
              <div class="meta">
                {an.count} ping{if an.count == 1, do: "", else: "s"} ·
                <a :for={e <- Enum.take(an.events, 1)} href={e.url} target="_blank" rel="noopener">open the run</a>
              </div>
            </li>
          </ul>
        </section>
        <section class="card">
          <h2>Needs you</h2>
          <p :if={a.lanes.needs_you == []} class="muted">
            No mentions, review requests or security alerts.
          </p>
          <.item_list events={a.lanes.needs_you} analysis={a} />
        </section>
      </div>

      <section class="card">
        <h2>When: timing</h2>
        <p class="small">
          <strong>{a.timing.total}</strong>
          notifications over <strong>{a.timing.span_min} min</strong>:
          about <strong>{a.timing.per_30_min}</strong>
          per half hour, one every <strong>{a.timing.mean_gap_min} min</strong>
          on average. Longest quiet spell: {a.timing.max_gap_min} min.
          <span class="muted">(Times from a pasted page are to the minute, relative to when it was copied.)</span>
        </p>
        <Charts.timing_bars timing={a.timing} />
        <ul class="small">
          <li :for={b <- a.timing.bursts}>
            Burst {Calendar.strftime(b.start, "%H:%M")}–{Calendar.strftime(b.finish, "%H:%M")}: {b.size} pings from {b.sessions} session{if b.sessions ==
                                                                                                                                              1,
                                                                                                                                            do:
                                                                                                                                              "",
                                                                                                                                            else:
                                                                                                                                              "s"} (mostly {b.workflows
            |> Enum.take(2)
            |> Enum.map_join(", ", &elem(&1, 0))}).
          </li>
          <li :for={l <- a.timing.late_workflows}>
            <strong>{l.workflow}</strong>: its {l.count} pings are for runs that
            <em>started earlier</em>
            than the rest
            (lower run numbers). It's slow or being re-run, so its pings arrive well after the push that caused them.
          </li>
          <li :for={o <- a.timing.onsets}>
            {String.capitalize(source_label(o.source))}: first seen {Calendar.strftime(
              o.first_at,
              "%H:%M"
            )}, {o.count} ping{if o.count == 1, do: "", else: "s"}{if o.duration_min > 0,
              do: " over #{o.duration_min} min",
              else: ""}.
          </li>
        </ul>
        <details>
          <summary>Show as table</summary>
          <table>
            <tr>
              <th>From</th><th class="num">Total</th><th class="num">Stands out</th><th class="num">
                Your work
              </th><th class="num">Unmatched</th><th class="num">Flood</th>
            </tr>
            <tr :for={b <- a.timing.buckets}>
              <td>{Calendar.strftime(b.at, "%H:%M")}</td>
              <td class="num">{b.total}</td>
              <td class="num">
                {Map.get(b.by_lane, :anomaly, 0) + Map.get(b.by_lane, :needs_you, 0)}
              </td>
              <td class="num">{Map.get(b.by_lane, :your_work, 0)}</td>
              <td class="num">{Map.get(b.by_lane, :residual, 0)}</td>
              <td class="num">{Map.get(b.by_lane, :quarantine, 0)}</td>
            </tr>
          </table>
        </details>
      </section>

      <section class="card">
        <h2>How: the causal chain</h2>
        <%= if f = a.chain.flood do %>
          <h3>The flood</h3>
          <div class="chain">
            <%= for {s, i} <- Enum.with_index(f.steps) do %>
              <span :if={i > 0} class="arrow">→</span>
              <div class="step"><b>{s.stage}</b>{s.text}</div>
            <% end %>
          </div>
          <Charts.flow links={a.chain.links} />
          <p class="small muted">
            Left: each agent session (its branch). Right: the workflows it tripped; gates in bold. Thicker line = more pings.
          </p>
        <% end %>
        <div :for={o <- a.chain.others}>
          <h3>Separately: {short(o.repo)}</h3>
          <div class="chain">
            <%= for {s, i} <- Enum.with_index(o.steps) do %>
              <span :if={i > 0} class="arrow">→</span>
              <div class="step"><b>{s.stage}</b>{s.text}</div>
            <% end %>
          </div>
        </div>
      </section>

      <section class="card">
        <h2>Why: fishbone</h2>
        <p class="small muted">
          The effect is on the right. Each bone is a kind of cause; the short lines on it are specific causes, with how many pings each produced.
        </p>
        <Charts.fishbone fishbone={a.fishbone} />
      </section>

      <section class="card">
        <h2>Gates</h2>
        <p class="small">
          A <em>gate</em>
          here means an estate-wide check rather than one project's own CI. A workflow counts if it's named like one (contains “Gate”, “Rules”, or starts “Check:”) or fails in 3+ repos. Not right? The rule is per viewer and can be changed.
        </p>
        <table>
          <tr>
            <th>Gate</th><th>Why it counts</th>
          </tr>
          <tr :for={g <- a.gates}>
            <td>{g}</td><td class="muted">{a.gate_reasons[g]}</td>
          </tr>
        </table>
      </section>

      <section class="card">
        <h2>Quarantine · {a.lane_counts.quarantine}</h2>
        <p class="small muted">
          Matches the flood's fingerprint (who × workflow × branch pattern) for <strong>{@login}</strong>. Nothing here is deleted or hidden:
          every item is counted and can be released. Your choices only affect what <em>you</em> see.
        </p>
        <table>
          <tr>
            <th>Fingerprint</th><th class="num">Pings</th><th></th>
          </tr>
          <%= for g <- a.quarantine_by_key do %>
            <% k = encode_key(g.key) %>
            <tr>
              <td>
                <button class="link" phx-click="toggle_group" phx-value-key={k}>{if MapSet.member?(
                                                                                      @open_groups,
                                                                                      k
                                                                                    ),
                                                                                    do: "▾",
                                                                                    else: "▸"} {g.label}</button>
              </td>
              <td class="num">{g.count}</td>
              <td>
                <button class="link" phx-click="override" phx-value-key={k} phx-value-value="signal">Not noise for me</button>
              </td>
            </tr>
            <tr :if={MapSet.member?(@open_groups, k)}>
              <td colspan="3"><.item_list events={g.events} analysis={a} /></td>
            </tr>
          <% end %>
        </table>
        <.overrides analysis={a} />
      </section>

      <section class="card">
        <h2>Proposed next steps</h2>
        <p class="small muted">
          This version is read-only: these are shown for you to consider. Nothing here runs.
        </p>
        <div :for={p <- a.proposals} class="proposal">
          <strong>{p.title}</strong>
          <div class="small">{p.detail}</div>
          <div class="small muted">Reversible: {p.reversible}</div>
        </div>
      </section>
    <% end %>
    """
  end

  attr :events, :list, required: true
  attr :analysis, :any, required: true

  defp item_list(assigns) do
    ~H"""
    <ul class="items">
      <li :for={e <- Enum.sort_by(@events, & &1.at, {:desc, DateTime})}>
        <a href={e.url} target="_blank" rel="noopener">{item_title(e)}</a>
        <div class="meta">
          {ago(e.at, @analysis)}{if e.at_estimated?, do: " (estimated)", else: ""} · {source_label(
            e.source_kind
          )}
          <span :if={why = Rescue.why(e.lane, e)}>· {why}</span>
          <span :if={e.extra_count > 0}>· +{e.extra_count} more</span>
          <span :if={e.lane == :your_work}>
            ·
            <button
              class="link"
              phx-click="override"
              phx-value-key={encode_key(Fingerprint.key(e, @analysis.viewer))}
              phx-value-value="noise"
            >noise for me</button>
          </span>
        </div>
      </li>
    </ul>
    """
  end

  attr :analysis, :any, required: true

  defp overrides(assigns) do
    ~H"""
    <div :if={map_size(@analysis.viewer.overrides) > 0} style="margin-top: 10px">
      <h3>Your corrections</h3>
      <ul class="small">
        <li :for={{k, v} <- @analysis.viewer.overrides}>
          {Fingerprint.describe(k)}:
          <strong>{if v == :noise, do: "noise for me", else: "not noise for me"}</strong>
          <button
            class="link"
            phx-click="override"
            phx-value-key={encode_key(k)}
            phx-value-value="clear"
          >undo</button>
        </li>
      </ul>
    </div>
    """
  end
end
