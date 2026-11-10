# SPDX-License-Identifier: MPL-2.0
defmodule TsunamiBreaker.Rescue do
  @moduledoc """
  Layer 4 – Rescue. Sorts every event into exactly one lane, so nothing is
  dropped and every lane can be counted:

    1. `:anomaly`    – a failing check that breaks the flood's pattern
    2. `:needs_you`  – mentions, review requests, security alerts, assignments
    3. `:your_work`  – activity on the viewer's own PRs, branches or focus repos
    4. `:quarantine` – matches the learned flood fingerprint (kept, countable, releasable)
    5. `:residual`   – doesn't match the flood and no rule fired: worth a glance

  An explicit "this is noise for me" override beats `:your_work`, but never
  beats `:anomaly` or `:needs_you`.
  """

  alias TsunamiBreaker.{Event, Viewer}
  alias TsunamiBreaker.Filter.Fingerprint

  @needs_you [:mention, :review_request, :security, :assignment]
  @lanes [:anomaly, :needs_you, :your_work, :quarantine, :residual]
  def lanes, do: @lanes

  def lane(e, anomaly_keys, fp, %Viewer{} = v) do
    k = Fingerprint.key(e, v)

    cond do
      Event.ci_failure?(e) and MapSet.member?(anomaly_keys, Event.failure_key(e)) -> :anomaly
      e.cause in @needs_you or e.reason == :approval_requested -> :needs_you
      Map.get(v.overrides, k) == :noise -> :quarantine
      your_work?(e, v) -> :your_work
      Fingerprint.matches?(e, fp, v) -> :quarantine
      true -> :residual
    end
  end

  defp your_work?(e, v) do
    e.reason in [:author, :comment, :state_change] or e.repo in v.focus_repos or
      (is_binary(e.branch) and e.branch in v.own_branches)
  end

  def why(:needs_you, e) do
    %{
      mention: "you were mentioned",
      review_request: "your review was requested",
      security: "security alert",
      assignment: "assigned to you"
    }[e.cause] || "asks for you"
  end

  def why(:your_work, e) do
    case e.reason do
      :author ->
        "activity on a PR/issue opened from your account" <>
          if(e.activity == :review, do: " (a review)", else: "")

      :comment ->
        "a thread you commented on"

      _ ->
        "touches your work"
    end
  end

  def why(_, _), do: nil
end
