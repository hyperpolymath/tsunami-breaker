defmodule TsunamiBreaker.Explain.Chain do
  @moduledoc """
  Layer 3 – the *how*: push → gate → failure → ping.

  Builds one chain per kind of trouble: the agent-session flood, and each
  default-branch failure, so the genuine problem is never drawn inside the flood.
  Also returns session→workflow links (with counts) for the flow diagram.
  """

  def build(events, gates) do
    ci = Enum.filter(events, &(&1.kind == :workflow_run))
    agent = Enum.filter(ci, &(&1.source_kind == :agent_session))
    other = Enum.reject(ci, &(&1.source_kind == :agent_session))

    %{
      flood: flood_chain(agent, gates),
      others:
        other |> Enum.group_by(&{&1.repo, &1.workflow, &1.branch}) |> Enum.map(&other_chain/1),
      links:
        agent
        |> Enum.frequencies_by(&{&1.session, &1.workflow})
        |> Enum.map(fn {{s, w}, n} -> %{session: s, workflow: w, count: n, gate?: w in gates} end)
    }
  end

  defp flood_chain([], _), do: nil

  defp flood_chain(agent, gates) do
    sessions = agent |> Enum.map(& &1.session) |> Enum.uniq()
    wfs = agent |> Enum.frequencies_by(& &1.workflow) |> Enum.sort_by(&(-elem(&1, 1)))
    {g, p} = Enum.split_with(wfs, fn {w, _} -> w in gates end)
    failed = agent |> Enum.filter(&TsunamiBreaker.Event.ci_failure?/1)
    runs = failed |> Enum.map(&(&1.run_id || &1.id)) |> Enum.uniq() |> length()
    prefix = agent |> hd() |> Map.get(:branch) |> String.split("/") |> hd()

    %{
      steps: [
        %{
          stage: :push,
          n: length(sessions),
          text: "#{length(sessions)} agent sessions push to their own #{prefix}/… branches"
        },
        %{
          stage: :gate,
          n: length(g) + length(p),
          text:
            "each push runs the estate's gates (#{length(g)}) and the repo's own checks (#{length(p)})"
        },
        %{stage: :failure, n: runs, text: "#{runs} runs fail"},
        %{
          stage: :ping,
          n: length(agent),
          text: "#{length(agent)} notifications land in your inbox"
        }
      ],
      gates: g,
      project_checks: p
    }
  end

  defp other_chain({{repo, wf, branch}, evs}) do
    %{
      repo: repo,
      workflow: wf,
      branch: branch,
      count: length(evs),
      trigger: evs |> Enum.map(& &1.trigger) |> Enum.reject(&is_nil/1) |> List.first(),
      steps: [
        %{stage: :push, text: "a change lands on #{branch}" <> trigger_note(evs)},
        %{stage: :gate, text: "#{wf} runs"},
        %{
          stage: :failure,
          text: "it fails" <> if(length(evs) > 1, do: " (#{length(evs)}×)", else: "")
        },
        %{
          stage: :ping,
          text: "#{length(evs)} notification" <> if(length(evs) == 1, do: "", else: "s")
        }
      ]
    }
  end

  defp trigger_note(evs) do
    case Enum.find_value(evs, & &1.trigger) do
      nil -> " (push or schedule: not visible in a pasted page)"
      t -> " (#{t})"
    end
  end
end
