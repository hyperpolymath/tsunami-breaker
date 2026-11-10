defmodule TsunamiBreaker.PasteParserTest do
  use ExUnit.Case, async: true
  alias TsunamiBreaker.Catch.PasteParser
  alias TsunamiBreaker.Fixture

  setup do: %{events: Fixture.inbox_events()}

  test "reads every item on the real pasted page", %{events: evs} do
    assert length(evs) == 25
    assert Enum.count(evs, &(&1.kind == :workflow_run)) == 17
    assert Enum.count(evs, &(&1.kind == :pull_request)) == 8
    assert evs |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 25
  end

  test "splits CI titles into workflow, branch and conclusion", %{events: [first | _]} do
    assert first.repo == "hyperpolymath/trope-checker"
    assert first.workflow == "Check: Workflow security lint"
    assert first.workflow_raw == "🟡 Check: Workflow security lint"
    assert first.branch == "claude/new-session-snuoro"
    assert first.conclusion == :failure
    assert first.run_id == 42_650_289_405
    assert first.at == ~U[2026-11-09 17:43:00Z]
  end

  test "decodes the notification referrer id into a stable thread id", %{events: evs} do
    marches = Enum.find(evs, &(&1.repo == "hyperpolymath/marches"))
    assert marches.id == "CheckSuite:1292521859:115512851800"
    assert marches.branch == "main"
  end

  test "PR items keep reason, activity, extra count; a title split by inline code is joined", %{
    events: evs
  } do
    vs = Enum.find(evs, &(&1.repo == "hyperpolymath/valence-shell"))
    assert {vs.reason, vs.activity, vs.extra_count, vs.number} == {:mention, :comment, 3, 223}

    h = Enum.find(evs, &(&1.number == 1039))
    assert h.title == "fix(research_extensions): read `on:` brackets outside comments and quotes"
    assert h.reason == :author
  end

  test "an item with no visible time borrows its neighbour's and is marked estimated", %{
    events: evs
  } do
    h = Enum.find(evs, &(&1.number == 1036))
    assert h.at_estimated?
    assert h.at == ~U[2026-11-09 17:14:00Z]
  end

  test "plain-text copies (no links) parse too" do
    text = """
    hyperpolymath/marches – Actions lock #14
    Actions lock workflow run failed for main branch
    23 minutes ago
    ci activity
    """

    [e] = PasteParser.parse(text, captured_at: ~U[2026-11-09 17:45:00Z])

    assert {e.repo, e.workflow, e.branch, e.conclusion, e.number} ==
             {"hyperpolymath/marches", "Actions lock", "main", :failure, 14}
  end

  test "garbage gives nothing rather than crashing" do
    assert PasteParser.parse("Select all\nProTip! nothing here") == []
  end
end
