defmodule TsunamiBreaker.Explain.Timing do
  @moduledoc """
  Layer 3 – the *when*: frequency, bursts, onset and duration.

  Times from a pasted page have one-minute resolution and are relative to when
  the page was copied, so treat them as approximate.
  """

  @burst_gap_s 60
  @burst_min 4

  def analyse(events) do
    timed = events |> Enum.filter(& &1.at) |> Enum.sort_by(& &1.at, DateTime)

    case timed do
      [] ->
        %{
          total: 0,
          span_min: 0,
          per_30_min: 0.0,
          buckets: [],
          bucket_min: 5,
          bursts: [],
          onsets: [],
          late_workflows: [],
          mean_gap_min: nil,
          max_gap_min: nil
        }

      [first | _] ->
        last = List.last(timed)
        span_s = max(DateTime.diff(last.at, first.at), 60)
        bucket_min = bucket_size(span_s)

        %{
          total: length(timed),
          first_at: first.at,
          last_at: last.at,
          span_min: div(span_s + 59, 60),
          per_30_min: Float.round(length(timed) / (span_s / 1800), 1),
          bucket_min: bucket_min,
          buckets: buckets(timed, first.at, last.at, bucket_min),
          bursts: bursts(timed),
          mean_gap_min: Float.round(span_s / 60 / max(length(timed) - 1, 1), 1),
          max_gap_min:
            timed
            |> Enum.chunk_every(2, 1, :discard)
            |> Enum.map(fn [a, b] -> DateTime.diff(b.at, a.at) end)
            |> Enum.max(fn -> 0 end)
            |> div(60),
          onsets: onsets(timed),
          late_workflows: late_workflows(events)
        }
    end
  end

  defp bucket_size(span_s) when span_s <= 2 * 3600, do: 5
  defp bucket_size(span_s) when span_s <= 24 * 3600, do: 30
  defp bucket_size(_), do: 360

  # Counts per time bucket, split by lane so the chart can show flood vs signal.
  defp buckets(timed, first, last, bucket_min) do
    size = bucket_min * 60
    start = first |> DateTime.to_unix() |> div(size) |> Kernel.*(size)
    n = div(DateTime.to_unix(last) - start, size) + 1

    grouped = Enum.group_by(timed, fn e -> div(DateTime.to_unix(e.at) - start, size) end)

    for i <- 0..(n - 1) do
      evs = Map.get(grouped, i, [])

      %{
        at: DateTime.from_unix!(start + i * size),
        total: length(evs),
        by_lane: Enum.frequencies_by(evs, &Map.get(&1, :lane, :residual))
      }
    end
  end

  @doc "A burst: at least #{@burst_min} pings with no more than #{div(@burst_gap_s, 60)} minutes between them."
  def bursts(timed) do
    timed
    |> Enum.chunk_while(
      [],
      fn e, acc ->
        case acc do
          [] ->
            {:cont, [e]}

          [prev | _] ->
            if DateTime.diff(e.at, prev.at) <= @burst_gap_s,
              do: {:cont, [e | acc]},
              else: {:cont, Enum.reverse(acc), [e]}
        end
      end,
      fn acc -> {:cont, Enum.reverse(acc), []} end
    )
    |> Enum.filter(&(length(&1) >= @burst_min))
    |> Enum.map(fn evs ->
      %{
        start: hd(evs).at,
        finish: List.last(evs).at,
        size: length(evs),
        sessions:
          evs |> Enum.map(& &1.session) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> length(),
        workflows:
          evs
          |> Enum.map(& &1.workflow)
          |> Enum.reject(&is_nil/1)
          |> Enum.frequencies()
          |> Enum.sort_by(&(-elem(&1, 1)))
      }
    end)
  end

  # When each source first appeared, and for how long it has been going.
  defp onsets(timed) do
    timed
    |> Enum.group_by(& &1.source_kind)
    |> Enum.map(fn {src, evs} ->
      first = hd(evs).at
      last = List.last(evs).at

      %{
        source: src,
        count: length(evs),
        first_at: first,
        last_at: last,
        duration_min: div(DateTime.diff(last, first), 60)
      }
    end)
    |> Enum.sort_by(& &1.first_at, DateTime)
  end

  @doc """
  GitHub hands out run IDs in creation order. If every run of a workflow has a
  lower ID than the median of the others, its runs *started* earlier than the
  rest even though they pinged at the same time: the workflow is slow or being
  re-run, so its pings arrive well after the push that caused them.
  """
  def late_workflows(events) do
    runs = Enum.filter(events, &(&1.kind == :workflow_run and is_integer(&1.run_id)))

    runs
    |> Enum.group_by(& &1.workflow)
    |> Enum.filter(fn {_w, rs} -> length(rs) >= 2 end)
    |> Enum.flat_map(fn {w, rs} ->
      others = runs |> Enum.reject(&(&1.workflow == w)) |> Enum.map(& &1.run_id) |> Enum.sort()

      if others != [] and
           Enum.max(Enum.map(rs, & &1.run_id)) < Enum.at(others, div(length(others), 2)),
         do: [%{workflow: w, count: length(rs)}],
         else: []
    end)
  end
end
