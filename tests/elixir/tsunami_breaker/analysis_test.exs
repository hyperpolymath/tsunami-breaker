defmodule TsunamiBreaker.AnalysisTest do
  use ExUnit.Case, async: true
  alias TsunamiBreaker.{Analysis, Viewer, Event}
  alias TsunamiBreaker.Filter.Fingerprint
  alias TsunamiBreaker.Fixture

  setup do
    evs = Fixture.inbox_events()
    %{events: evs, a: Analysis.run(evs, Viewer.new(login: "hyperpolymath"))}
  end

  test "reproduces the hand diagnosis of the sample", %{a: a} do
    assert a.diagnosis.headline == "11 Claude sessions, 4 gates, 1 genuine failure on main"
    assert length(a.sessions) == 11

    assert a.gates == [
             "Check: Workflow security lint",
             "Dogfood Gate",
             "Estate Rules",
             "Gate: Code quality (fmt/lint/test)"
           ]
  end

  test "singles out marches Actions lock failing on main, and nothing else", %{a: a} do
    assert [an] = a.anomalies
    assert an.key == {"hyperpolymath/marches", "Actions lock", "main"}
    assert an.rules == [:failure_on_default_branch]
    assert [%{repo: "hyperpolymath/marches"}] = a.lanes.anomaly
  end

  test "every item lands in exactly one lane: nothing is dropped", %{a: a} do
    assert a.lane_counts == %{anomaly: 1, needs_you: 1, your_work: 7, quarantine: 16, residual: 0}
    assert a.lane_counts |> Map.values() |> Enum.sum() == length(a.events)
    assert a.quarantine_by_key |> Enum.map(& &1.count) |> Enum.sum() == 16
  end

  test "the mention is rescued from under the flood", %{a: a} do
    assert [%{repo: "hyperpolymath/valence-shell", number: 223}] = a.lanes.needs_you
  end

  test "the flood is all agent-session CI on claude/* branches", %{a: a} do
    assert Enum.all?(
             a.lanes.quarantine,
             &(&1.source_kind == :agent_session and String.starts_with?(&1.branch, "claude/"))
           )
  end

  test "noise is per viewer: one viewer's override doesn't change another's view", %{events: evs} do
    key = {:agent_session, "Dogfood Gate", "claude/*"}
    gatekeeper = Viewer.new(login: "gate-maintainer", overrides: %{key => :signal})
    owner = Viewer.new(login: "hyperpolymath")

    a1 = Analysis.run(evs, gatekeeper)
    a2 = Analysis.run(evs, owner)
    assert a1.lane_counts.quarantine == 11
    assert a1.lane_counts.residual == 5
    assert a2.lane_counts.quarantine == 16
  end

  test "a viewer can call their own PR activity noise; mentions still get through", %{events: evs} do
    v =
      Viewer.new(
        login: "x",
        overrides: %{
          {:unknown, {:review, :author}, "*"} => :noise,
          {:unknown, {:mention, :mention}, "*"} => :noise
        }
      )

    a = Analysis.run(evs, v)
    assert a.lane_counts.your_work == 2
    assert a.lane_counts.needs_you == 1
  end

  test "pasting the same page twice doesn't double count", %{events: evs} do
    a = Analysis.run(evs ++ evs, Viewer.new(login: "hyperpolymath"))
    assert length(a.events) == 25
  end

  test "persistent failure: three fails in a row with no pass in between" do
    mk = fn i, c ->
      %Event{
        id: "r#{i}",
        run_id: i,
        kind: :workflow_run,
        repo: "o/r",
        owner: "o",
        workflow: "Build",
        branch: "feature-x",
        conclusion: c,
        at: DateTime.add(~U[2026-11-09 10:00:00Z], i * 600)
      }
    end

    evs = [mk.(3, :failure)]
    history = [mk.(1, :failure), mk.(2, :failure), mk.(0, :success)]
    a = Analysis.run(evs, Viewer.new(login: "v"), history: history)
    assert [%{rules: rules}] = a.anomalies
    assert :persistent_failure in rules
  end

  test "usually-passing workflow now failing" do
    base = %Event{kind: :workflow_run, repo: "o/r", owner: "o", workflow: "Build", branch: "dev"}

    history =
      for i <- 1..6,
          do: %{
            base
            | id: "h#{i}",
              run_id: i,
              conclusion: :success,
              at: DateTime.add(~U[2026-11-09 09:00:00Z], i * 60)
          }

    now = %{base | id: "n", run_id: 10, conclusion: :failure, at: ~U[2026-11-09 10:00:00Z]}
    a = Analysis.run([now], Viewer.new(login: "v"), history: history)
    assert [%{rules: [:normally_passing_now_failing]}] = a.anomalies
  end

  test "new failure type only fires once the viewer has a baseline", %{events: evs} do
    novel = %Event{
      id: "n1",
      kind: :workflow_run,
      repo: "o/new",
      owner: "o",
      workflow: "Deploy",
      branch: "release/1",
      conclusion: :failure,
      at: ~U[2026-11-09 17:44:00Z]
    }

    assert Analysis.run([novel], Viewer.new(login: "v")).anomalies == []

    seen = MapSet.new(for e <- evs, Event.ci_failure?(e), do: {e.repo, e.workflow})
    a = Analysis.run(evs ++ [novel], Viewer.new(login: "v", baseline: seen))
    assert Enum.any?(a.anomalies, &(&1.repo == "o/new" and :new_failure_type in &1.rules))
  end

  test "main is never learned as noise even when it floods" do
    evs =
      for i <- 1..20,
          do: %Event{
            id: "m#{i}",
            run_id: i,
            kind: :workflow_run,
            repo: "o/r#{rem(i, 5)}",
            owner: "o",
            workflow: "CI",
            branch: "main",
            conclusion: :failure,
            at: DateTime.add(~U[2026-11-09 10:00:00Z], i * 60)
          }

    a = Analysis.run(evs, Viewer.new(login: "v"))
    assert a.lane_counts.quarantine == 0
    assert a.lane_counts.anomaly == 20
  end

  test "fingerprint key is source × workflow × branch pattern", %{a: a} do
    e = Enum.find(a.events, &(&1.workflow == "Dogfood Gate"))
    assert Fingerprint.key(e, a.viewer) == {:agent_session, "Dogfood Gate", "claude/*"}
  end

  test "timing: rate, late workflow and bursts", %{a: a} do
    assert a.timing.total == 25
    assert a.timing.span_min == 31
    assert [%{workflow: "Dogfood Gate", count: 5}] = a.timing.late_workflows
    assert a.timing.bursts != []
  end

  test "causal chain and fishbone", %{a: a} do
    assert [%{n: 11}, %{n: 8}, %{n: 16}, %{n: 16}] = a.chain.flood.steps
    assert [%{repo: "hyperpolymath/marches", workflow: "Actions lock"}] = a.chain.others
    names = Enum.map(a.fishbone.bones, & &1.name)
    assert "Agent sessions" in names and "Estate gates" in names
  end
end
