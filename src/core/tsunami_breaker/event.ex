# SPDX-License-Identifier: MPL-2.0
defmodule TsunamiBreaker.Event do
  @moduledoc """
  One normalised thing that pinged (or could ping) the viewer.

  Every source (pasted notifications page, notifications API, workflow-runs API)
  is converted into this one shape so the later layers never care where an
  event came from. `raw` keeps the original so nothing is lost.
  """

  @type kind ::
          :workflow_run
          | :pull_request
          | :issue
          | :security_alert
          | :release
          | :discussion
          | :other
  @type actor_kind :: :human | :bot | :agent_session | :workflow | :unknown

  defstruct [
    :id,
    :repo,
    :owner,
    :number,
    :kind,
    :title,
    :workflow,
    :workflow_raw,
    :branch,
    :conclusion,
    :reason,
    :activity,
    :actor,
    :trigger,
    :at,
    :url,
    :run_id,
    :raw,
    actor_kind: :unknown,
    source_kind: :unknown,
    cause: nil,
    session: nil,
    gate?: false,
    extra_count: 0,
    at_estimated?: false,
    source: :paste
  ]

  @type t :: %__MODULE__{}

  @doc "True for a CI run that did not pass."
  def ci_failure?(%__MODULE__{kind: :workflow_run, conclusion: c}),
    do: c in [:failure, :timed_out, :startup_failure]

  def ci_failure?(_), do: false

  @doc "Stable key for one failing check: same repo, same workflow, same branch."
  def failure_key(%__MODULE__{repo: r, workflow: w, branch: b}), do: {r, w, b}
end
