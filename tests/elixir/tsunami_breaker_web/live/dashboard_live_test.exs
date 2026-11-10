# SPDX-License-Identifier: MPL-2.0
defmodule TsunamiBreakerWeb.DashboardLiveTest do
  use TsunamiBreakerWeb.ConnCase
  import Phoenix.LiveViewTest

  test "opens on the sample with the diagnosis", %{conn: conn} do
    {:ok, view, html} = live(conn, "/")
    assert html =~ "11 Claude sessions, 4 gates, 1 genuine failure on main"
    assert html =~ "Actions lock"
    assert has_element?(view, "svg[aria-label^='Fishbone']")
  end

  test "pasting a page re-analyses it", %{conn: conn} do
    {:ok, view, _} = live(conn, "/")
    view |> element("button", "Paste a notifications page") |> render_click()

    html =
      view
      |> form("form[phx-submit=analyse_paste]", %{
        "text" =>
          "hyperpolymath/marches – Actions lock #14\nActions lock workflow run failed for main branch\n2 minutes ago\nci activity",
        "minutes_ago" => "0"
      })
      |> render_submit()

    assert html =~ "pasted page (1 items)"
    assert html =~ "1 genuine failure on main"
  end

  test "a viewer's 'not noise for me' moves items out of their quarantine only", %{conn: conn} do
    login = "test-viewer-#{System.unique_integer([:positive])}"
    key = TsunamiBreakerWeb.DashboardLive.encode_key({:agent_session, "Dogfood Gate", "claude/*"})

    {:ok, view, _} = live(conn, "/")
    view |> form("form[phx-submit=set_viewer]", %{"login" => login}) |> render_submit()
    assert render(view) =~ "Quarantine · 16"

    html =
      view |> element("button[phx-value-key='#{key}'][phx-value-value=signal]") |> render_click()

    assert html =~ "Quarantine · 11"
    assert html =~ "not noise for me"

    # Another viewer is unaffected.
    {:ok, other, _} = live(conn, "/")

    other
    |> form("form[phx-submit=set_viewer]", %{"login" => login <> "-other"})
    |> render_submit()

    assert render(other) =~ "Quarantine · 16"

    # And it's reversible.
    html =
      view |> element("button[phx-value-key='#{key}'][phx-value-value=clear]") |> render_click()

    assert html =~ "Quarantine · 16"
  end
end
