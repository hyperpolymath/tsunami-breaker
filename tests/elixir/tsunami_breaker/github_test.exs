defmodule TsunamiBreaker.GitHubTest do
  use ExUnit.Case, async: true
  alias TsunamiBreaker.Catch.{GitHub, ApiNormalizer, Fetch}

  @notif %{
    "id" => "991",
    "reason" => "ci_activity",
    "updated_at" => "2026-11-09T17:22:00Z",
    "subject" => %{
      "title" => "Actions lock workflow run failed for main branch",
      "type" => "CheckSuite",
      "url" => nil,
      "latest_comment_url" => nil
    },
    "repository" => %{
      "full_name" => "hyperpolymath/marches",
      "html_url" => "https://github.com/hyperpolymath/marches"
    }
  }

  @mention %{
    "id" => "992",
    "reason" => "mention",
    "updated_at" => "2026-11-09T17:13:00Z",
    "subject" => %{
      "title" => "proofs: ground-truth audit",
      "type" => "PullRequest",
      "url" => "https://api.github.com/repos/hyperpolymath/valence-shell/pulls/223",
      "latest_comment_url" =>
        "https://api.github.com/repos/hyperpolymath/valence-shell/issues/comments/6745208550"
    },
    "repository" => %{"full_name" => "hyperpolymath/valence-shell"}
  }

  @run %{
    "id" => 42_649_192_140,
    "name" => "Actions lock",
    "head_branch" => "main",
    "conclusion" => "success",
    "status" => "completed",
    "event" => "schedule",
    "run_number" => 13,
    "actor" => %{"login" => "hyperpolymath"},
    "created_at" => "2026-11-09T16:00:00Z",
    "updated_at" => "2026-11-09T16:02:00Z",
    "html_url" => "https://github.com/hyperpolymath/marches/actions/runs/1",
    "repository" => %{"full_name" => "hyperpolymath/marches"}
  }

  test "notification JSON normalises like the pasted page" do
    e = ApiNormalizer.notification(@notif)

    assert {e.kind, e.workflow, e.branch, e.conclusion, e.reason} ==
             {:workflow_run, "Actions lock", "main", :failure, :ci_activity}

    m = ApiNormalizer.notification(@mention, "coderabbitai[bot]")

    assert {m.kind, m.number, m.activity, m.actor} ==
             {:pull_request, 223, :comment, "coderabbitai[bot]"}

    assert m.url == "https://github.com/hyperpolymath/valence-shell/pull/223"
  end

  test "workflow runs carry trigger and actor" do
    e = ApiNormalizer.workflow_run(@run)

    assert {e.trigger, e.actor, e.conclusion, e.source} ==
             {:schedule, "hyperpolymath", :success, :api_run}
  end

  test "a full fetch only ever sends GET, and follows pagination" do
    test_pid = self()

    Req.Test.stub(:gh, fn conn ->
      send(test_pid, {:req, conn.method, conn.request_path, conn.query_string})

      case conn.request_path do
        "/user" ->
          Req.Test.json(conn, %{"login" => "hyperpolymath"})

        "/notifications" ->
          if conn.query_string =~ "page=2" do
            Req.Test.json(conn, [@mention])
          else
            conn
            |> Plug.Conn.put_resp_header(
              "link",
              ~s(<https://api.github.com/notifications?page=2>; rel="next")
            )
            |> Plug.Conn.put_resp_header("x-poll-interval", "60")
            |> Req.Test.json([@notif])
          end

        "/repos/hyperpolymath/marches/actions/runs" ->
          Req.Test.json(conn, %{"workflow_runs" => [@run]})

        "/repos/hyperpolymath/valence-shell/issues/comments/6745208550" ->
          Req.Test.json(conn, %{"user" => %{"login" => "a-human"}})
      end
    end)

    assert {:ok, res} = Fetch.run("dummy", plug: {Req.Test, :gh})
    assert res.login == "hyperpolymath"
    assert length(res.events) == 2
    assert [%{conclusion: :success}] = res.history
    assert Enum.find(res.events, &(&1.reason == :mention)).actor == "a-human"

    methods = collect_methods([])
    assert methods != []
    assert Enum.all?(methods, &(&1 == "GET"))
  end

  test "stops paginating when the API budget is low" do
    Req.Test.stub(:gh_low, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("x-ratelimit-remaining", "50")
      |> Plug.Conn.put_resp_header(
        "link",
        ~s(<https://api.github.com/notifications?page=2>; rel="next")
      )
      |> Req.Test.json([@notif])
    end)

    c = GitHub.new("dummy", plug: {Req.Test, :gh_low})
    assert {:ok, [_one]} = GitHub.notifications(c)
  end

  test "the client module has no way to write" do
    exported = GitHub.__info__(:functions) |> Keyword.keys()
    refute Enum.any?(exported, &(&1 in [:post, :patch, :put, :delete, :mark_done, :cancel]))
    src = File.read!("src/core/tsunami_breaker/catch/github.ex")
    refute src =~ ~r/Req\.(post|patch|put|delete|request)\b/
  end

  defp collect_methods(acc) do
    receive do
      {:req, m, _, _} -> collect_methods([m | acc])
    after
      0 -> acc
    end
  end
end
