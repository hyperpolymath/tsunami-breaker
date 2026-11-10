# SPDX-License-Identifier: MPL-2.0
defmodule TsunamiBreaker.Analysis do
  @moduledoc """
  Runs layers 2–4 over a batch of caught events for one viewer and returns
  everything the UI needs. Pure: no network, no side effects, so the same
  input always gives the same diagnosis (which is what the tests rely on).
  """

  alias TsunamiBreaker.{Event, Viewer, Rescue}
  alias TsunamiBreaker.Sort.Classifier
  alias TsunamiBreaker.Filter.{Fingerprint, Anomalies}
  alias TsunamiBreaker.Explain.{Timing, Chain, Fishbone}

  defstruct [
    :viewer,
    :events,
    :gates,
    :gate_reasons,
    :sessions,
    :fingerprint,
    :anomalies,
    :lanes,
    :lane_counts,
    :quarantine_by_key,
    :timing,
    :chain,
    :fishbone,
    :diagnosis,
    :proposals
  ]

  @doc "Options: `:history` – earlier workflow runs (successes too) for the 'usually passes' rule."
  def run(events, %Viewer{} = v, opts \\ []) do
    history = Keyword.get(opts, :history, [])
    events = dedupe(events)
    gates = Classifier.gates(events, v)
    classified = Enum.map(events, &Classifier.classify(&1, v, gates))
    fp = Fingerprint.learn(classified, v)

    residual_failures =
      Enum.filter(classified, &(Event.ci_failure?(&1) and not Fingerprint.matches?(&1, fp, v)))

    anomalies = Anomalies.detect(residual_failures, v, history)
    anomaly_keys = MapSet.new(anomalies, & &1.key)

    laned = Enum.map(classified, &Map.put(&1, :lane, Rescue.lane(&1, anomaly_keys, fp, v)))
    lanes = Map.new(Rescue.lanes(), fn l -> {l, Enum.filter(laned, &(&1.lane == l))} end)
    timing = Timing.analyse(laned)

    sessions =
      laned |> Enum.map(& &1.session) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort()

    a = %__MODULE__{
      viewer: v,
      events: laned,
      gates: gates,
      gate_reasons: Map.new(gates, &{&1, Classifier.gate_reason(&1, classified, v)}),
      sessions: sessions,
      fingerprint: fp,
      anomalies: anomalies,
      lanes: lanes,
      lane_counts: Map.new(lanes, fn {l, es} -> {l, length(es)} end),
      quarantine_by_key:
        lanes.quarantine
        |> Enum.group_by(&Fingerprint.key(&1, v))
        |> Enum.map(fn {k, es} ->
          %{key: k, label: Fingerprint.describe(k), count: length(es), events: es}
        end)
        |> Enum.sort_by(&(-&1.count)),
      timing: timing,
      chain: Chain.build(laned, gates),
      fishbone: Fishbone.build(laned, timing)
    }

    %{a | diagnosis: diagnose(a), proposals: proposals(a)}
  end

  # The same thread pasted twice (e.g. Inbox and Done) is one event: keep the newest.
  defp dedupe(events) do
    events
    |> Enum.sort_by(& &1.at, {:desc, DateTime})
    |> Enum.uniq_by(& &1.id)
  end

  @doc "The one-line answer, plus a plain-language paragraph for a non-specialist."
  def diagnose(%__MODULE__{} = a) do
    v = a.viewer

    agent_name =
      v.agent_branch_prefixes |> hd() |> String.trim_trailing("/") |> String.capitalize()

    on_default = Enum.filter(a.anomalies, &Viewer.default_branch?(v, &1.branch))
    off_default = a.anomalies -- on_default
    n_sessions = length(a.sessions)
    n_gates = length(a.gates)

    genuine =
      [
        on_default != [] &&
          "#{length(on_default)} genuine failure#{s(length(on_default))} on #{on_default |> Enum.map(& &1.branch) |> Enum.uniq() |> Enum.join("/")}",
        off_default != [] &&
          "#{length(off_default)} other genuine failure#{s(length(off_default))}",
        a.anomalies == [] && "no genuine failures"
      ]
      |> Enum.filter(& &1)

    headline =
      [
        n_sessions > 0 && "#{n_sessions} #{agent_name} session#{s(n_sessions)}",
        n_gates > 0 && "#{n_gates} gate#{s(n_gates)}" | genuine
      ]
      |> Enum.filter(& &1)
      |> Enum.join(", ")
      |> then(fn h -> String.upcase(String.first(h)) <> String.slice(h, 1..-1//1) end)

    flood = Enum.count(a.events, &(&1.source_kind == :agent_session))
    total = length(a.events)
    needs = a.lane_counts.needs_you
    yours = a.lane_counts.your_work

    plain =
      [
        flood > 0 &&
          "#{flood} of the #{total} notifications come from #{n_sessions} #{agent_name} sessions, each working on its own branch. Every time one of them saves work (a push), the estate's checks run on it, fail, and each failure pings you. That's the flood: it's expected traffic, not #{n_sessions} separate problems.",
        Enum.map(a.anomalies, &"Real problem: #{&1.summary}."),
        needs > 0 &&
          "#{needs} item#{s(needs)} actually ask#{if needs == 1, do: "s", else: ""} for you (see Needs you).",
        yours > 0 &&
          "#{yours} item#{s(yours)} #{if yours == 1, do: "is", else: "are"} activity on PRs and threads from your account, mostly reviews. Kept visible, not filtered."
      ]
      |> List.flatten()
      |> Enum.filter(& &1)

    %{headline: headline, plain: plain}
  end

  # Read-only build: these are proposals only. Nothing here is ever executed.
  defp proposals(a) do
    q = a.lane_counts.quarantine
    flood_gates = (a.chain.flood && a.chain.flood.gates) || []

    [
      q > 0 &&
        %{
          title: "Mark #{q} quarantined notification#{s(q)} as done on GitHub",
          detail:
            "Your GitHub inbox would go quiet; every item stays here in quarantine. Needs a token with notification write access (a later version).",
          reversible: "Yes: done threads come back if there is new activity."
        },
      flood_gates != [] &&
        %{
          title:
            "Stop #{length(flood_gates)} gate#{s(length(flood_gates))} firing on #{hd(a.viewer.agent_branch_prefixes)}* pushes",
          detail:
            "Run them when a PR is opened instead of on every push, so agent sessions don't trigger them per commit. (Layer 5, not in this version.)",
          reversible: "Yes: it is a workflow config change you can revert."
        }
    ]
    |> Enum.filter(& &1)
  end

  defp s(1), do: ""
  defp s(_), do: "s"
end
