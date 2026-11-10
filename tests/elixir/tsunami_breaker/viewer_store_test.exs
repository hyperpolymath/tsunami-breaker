# SPDX-License-Identifier: MPL-2.0
defmodule TsunamiBreaker.ViewerStoreTest do
  use ExUnit.Case, async: true
  alias TsunamiBreaker.ViewerStore

  @tag :tmp_dir
  test "overrides and baseline survive a restart, stored as JSON", %{tmp_dir: dir} do
    path = Path.join(dir, "viewers.json")
    key = {:agent_session, "Dogfood Gate", "claude/*"}
    review = {:unknown, {:review, :author}, "*"}

    {:ok, s1} = ViewerStore.start_link(path: path, name: nil)
    ViewerStore.set_override("v", key, :signal, s1)
    ViewerStore.set_override("v", review, :noise, s1)

    ViewerStore.remember_failures(
      "v",
      [
        %TsunamiBreaker.Event{
          kind: :workflow_run,
          conclusion: :failure,
          repo: "o/r",
          workflow: "CI"
        }
      ],
      s1
    )

    Agent.stop(s1)

    assert {:ok, %{"v" => _}} = Jason.decode(File.read!(path))

    {:ok, s2} = ViewerStore.start_link(path: path, name: nil)
    v = ViewerStore.get("v", s2)
    assert v.overrides == %{key => :signal, review => :noise}
    assert MapSet.member?(v.baseline, {"o/r", "CI"})
  end

  @tag :tmp_dir
  test "a hand-edited file cannot create new atoms", %{tmp_dir: dir} do
    path = Path.join(dir, "viewers.json")

    File.write!(
      path,
      ~s({"v":{"overrides":[[["no_such_atom_x9","CI","*"],"noise"],[["agent_session","CI","*"],"noise"]],"baseline":[]}})
    )

    {:ok, s} = ViewerStore.start_link(path: path, name: nil)
    assert ViewerStore.get("v", s).overrides == %{{:agent_session, "CI", "*"} => :noise}
  end
end
