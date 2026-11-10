defmodule TsunamiBreakerWeb.Charts do
  @moduledoc """
  The three pictures, drawn on the server as SVG (the browser's built-in
  vector drawing format). No JavaScript charting library: every coordinate is
  computed here in Elixir, so the pictures are testable like any other output.

  Each chart has a `<title>` on its marks (hover shows exact numbers) and a
  table view beside it, so nothing depends on colour alone.
  """

  use Phoenix.Component

  @series [
    {:stands_out, "Stands out", "var(--series-stands)"},
    {:your_work, "Your work", "var(--series-yours)"},
    {:residual, "Other, unmatched", "var(--series-other)"},
    {:quarantine, "Flood (quarantined)", "var(--series-flood)"}
  ]

  def series, do: @series

  # ---------------------------------------------------------------- timing

  attr :timing, :map, required: true

  def timing_bars(assigns) do
    buckets = assigns.timing.buckets
    w = 720
    h = 180
    pad_l = 30
    pad_b = 24
    n = max(length(buckets), 1)
    max_total = buckets |> Enum.map(& &1.total) |> Enum.max(fn -> 1 end) |> max(1)
    slot = (w - pad_l) / n
    bar_w = max(min(slot - 2, 48), 4)
    scale = (h - pad_b - 10) / max_total

    bars =
      buckets
      |> Enum.with_index()
      |> Enum.map(fn {b, i} ->
        x = pad_l + i * slot + (slot - bar_w) / 2

        {segs, _} =
          Enum.map_reduce(@series, h - pad_b, fn {key, label, color}, y ->
            count = series_count(b.by_lane, key)
            seg_h = count * scale
            # 2px surface gap between stacked segments
            seg = %{
              x: x,
              y: y - seg_h,
              h: max(seg_h - 2, 0),
              color: color,
              count: count,
              label: label
            }

            {seg, y - seg_h}
          end)

        %{
          x: x,
          w: bar_w,
          segs: Enum.filter(segs, &(&1.count > 0)),
          at: b.at,
          total: b.total,
          label: if(rem(i, label_every(n)) == 0, do: Calendar.strftime(b.at, "%H:%M"))
        }
      end)

    ticks =
      for t <- Enum.uniq([0, div(max_total, 2), max_total]), do: %{v: t, y: h - pad_b - t * scale}

    assigns =
      assign(assigns,
        w: w,
        h: h,
        bars: bars,
        ticks: ticks,
        pad_l: pad_l,
        pad_b: pad_b,
        bucket_min: assigns.timing.bucket_min
      )

    ~H"""
    <div class="legend">
      <span :for={{_k, label, color} <- series()}><i class="swatch" style={"background:#{color}"}></i>{label}</span>
    </div>
    <svg
      class="chart"
      viewBox={"0 0 #{@w} #{@h}"}
      role="img"
      aria-label={"Notifications per #{@bucket_min} minutes"}
    >
      <line :for={t <- @ticks} class="axis" x1={@pad_l} x2={@w} y1={t.y} y2={t.y} />
      <text :for={t <- @ticks} x={@pad_l - 6} y={t.y + 4} text-anchor="end">{t.v}</text>
      <g :for={b <- @bars}>
        <rect :for={s <- b.segs} x={b.x} y={s.y} width={b.w} height={s.h} rx="2" fill={s.color}>
          <title>{Calendar.strftime(b.at, "%H:%M")} · {s.label}: {s.count}</title>
        </rect>
        <text :if={b.label} x={b.x + b.w / 2} y={@h - 6} text-anchor="middle">{b.label}</text>
      </g>
    </svg>
    """
  end

  defp label_every(n) when n <= 12, do: 1
  defp label_every(n), do: div(n, 8) + 1

  defp series_count(by_lane, :stands_out),
    do: Map.get(by_lane, :anomaly, 0) + Map.get(by_lane, :needs_you, 0)

  defp series_count(by_lane, key), do: Map.get(by_lane, key, 0)

  # ---------------------------------------------------------------- flow

  attr :links, :list, required: true

  @doc "Which agent session tripped which workflow: lines thicken with the number of pings."
  def flow(assigns) do
    sessions = assigns.links |> Enum.map(& &1.session) |> Enum.uniq() |> Enum.sort()

    wfs =
      assigns.links
      |> Enum.group_by(& &1.workflow)
      |> Enum.map(fn {w, ls} ->
        {w, Enum.any?(ls, & &1.gate?), ls |> Enum.map(& &1.count) |> Enum.sum()}
      end)
      |> Enum.sort_by(fn {w, g, n} -> {not g, -n, w} end)

    row = 22
    h = max(length(sessions), length(wfs)) * row + 20
    w = 720
    lx = 230
    rx = 470

    s_y =
      sessions
      |> Enum.with_index()
      |> Map.new(fn {s, i} -> {s, 18 + i * row + (h - 20 - length(sessions) * row) / 2} end)

    w_y =
      wfs
      |> Enum.with_index()
      |> Map.new(fn {{wf, _, _}, i} -> {wf, 18 + i * row + (h - 20 - length(wfs) * row) / 2} end)

    lines =
      for l <- assigns.links,
          do: %{
            y1: s_y[l.session],
            y2: w_y[l.workflow],
            width: 1 + l.count * 1.5,
            title: "#{l.session} → #{l.workflow}: #{l.count}"
          }

    assigns =
      assign(assigns,
        w: w,
        h: h,
        lx: lx,
        rx: rx,
        sessions: sessions,
        wfs: wfs,
        s_y: s_y,
        w_y: w_y,
        lines: lines
      )

    ~H"""
    <div class="scroll-x">
      <svg
        class="chart"
        viewBox={"0 0 #{@w} #{@h}"}
        role="img"
        aria-label="Agent sessions to workflows"
      >
        <path
          :for={l <- @lines}
          d={"M#{@lx + 6} #{l.y1} C #{(@lx + @rx) / 2} #{l.y1}, #{(@lx + @rx) / 2} #{l.y2}, #{@rx - 6} #{l.y2}"}
          fill="none"
          stroke="var(--series-flood)"
          stroke-width={l.width}
          stroke-linecap="round"
          opacity="0.85"
        >
          <title>{l.title}</title>
        </path>
        <g :for={s <- @sessions}>
          <circle cx={@lx} cy={@s_y[s]} r="4" fill="var(--text-secondary)" />
          <text x={@lx - 10} y={@s_y[s] + 4} text-anchor="end" class="mono">{s}</text>
        </g>
        <g :for={{wf, gate?, n} <- @wfs}>
          <circle
            cx={@rx}
            cy={@w_y[wf]}
            r="4"
            fill={if gate?, do: "var(--text-primary)", else: "var(--text-muted)"}
          />
          <text x={@rx + 10} y={@w_y[wf] + 4} class={if gate?, do: "strong", else: ""}>
            {wf} · {n}{if gate?, do: "  (gate)", else: ""}
          </text>
        </g>
      </svg>
    </div>
    """
  end

  # ---------------------------------------------------------------- fishbone

  attr :fishbone, :map, required: true

  @doc """
  Ishikawa diagram. Spine runs left→right into the effect (the head). Bones
  alternate above and below; each bone's ribs are its specific causes with counts.
  """
  def fishbone(assigns) do
    bones = assigns.fishbone.bones
    cols = max(div(length(bones) + 1, 2), 1)
    col_w = 270
    head_w = 190
    w = 40 + cols * col_w + head_w
    h = 440
    spine_y = h / 2
    head_x = 40 + cols * col_w

    drawn =
      bones
      |> Enum.with_index()
      |> Enum.map(fn {b, i} ->
        col = div(i, 2)
        top? = rem(i, 2) == 0
        x_end = 40 + (col + 1) * col_w - 20
        x0 = x_end - 120
        y0 = if top?, do: 34, else: h - 34
        shown = Enum.take(b.ribs, 6)
        more = length(b.ribs) - length(shown)

        ribs =
          shown
          |> Enum.with_index()
          |> Enum.map(fn {{label, n}, j} ->
            t = (j + 1) / (length(shown) + 1)
            px = x0 + (x_end - x0) * t
            py = y0 + (spine_y - y0) * t

            %{
              x1: px - 12,
              x2: px,
              y: py,
              text: "#{truncate(label, 26)} · #{n}",
              title: "#{label}: #{n}"
            }
          end)

        %{
          name: b.name,
          total: b.total,
          x0: x0,
          y0: y0,
          x_end: x_end,
          top?: top?,
          ribs: ribs,
          more: more
        }
      end)

    assigns =
      assign(assigns,
        w: w,
        h: h,
        spine_y: spine_y,
        head_x: head_x,
        head_w: head_w,
        drawn: drawn,
        effect: assigns.fishbone.effect
      )

    ~H"""
    <div class="scroll-x">
      <svg
        class="chart"
        viewBox={"0 0 #{@w} #{@h}"}
        role="img"
        aria-label={"Fishbone: causes of #{@effect}"}
        style="min-width: 640px"
      >
        <line
          x1="30"
          x2={@head_x}
          y1={@spine_y}
          y2={@spine_y}
          stroke="var(--text-secondary)"
          stroke-width="2.5"
        />
        <rect
          x={@head_x}
          y={@spine_y - 34}
          width={@head_w - 10}
          height="68"
          rx="8"
          fill="var(--surface-0)"
          stroke="var(--text-secondary)"
        />
        <text x={@head_x + (@head_w - 10) / 2} y={@spine_y - 4} text-anchor="middle" class="strong">
          The flood
        </text>
        <text x={@head_x + (@head_w - 10) / 2} y={@spine_y + 14} text-anchor="middle">{@effect}</text>
        <g :for={b <- @drawn}>
          <line
            x1={b.x0}
            y1={b.y0}
            x2={b.x_end}
            y2={@spine_y}
            stroke="var(--text-muted)"
            stroke-width="1.5"
          />
          <text
            x={b.x0}
            y={if b.top?, do: b.y0 - 10, else: b.y0 + 20}
            text-anchor="middle"
            class="strong"
          >
            {b.name} ({b.total})
          </text>
          <g :for={r <- b.ribs}>
            <line x1={r.x1} x2={r.x2} y1={r.y} y2={r.y} stroke="var(--text-muted)" />
            <text x={r.x1 - 4} y={r.y + 4} text-anchor="end"><title>{r.title}</title>{r.text}</text>
          </g>
          <text
            :if={b.more > 0}
            x={b.x_end - 4}
            y={if b.top?, do: @spine_y - 8, else: @spine_y + 18}
            text-anchor="end"
            class="muted"
          >
            +{b.more} more
          </text>
        </g>
      </svg>
    </div>
    """
  end

  defp truncate(s, n) do
    if String.length(s) > n, do: String.slice(s, 0, n - 1) <> "…", else: s
  end
end
