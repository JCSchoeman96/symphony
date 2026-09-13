defmodule SymphonyElixir.DependencyGraphTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Dependency.Graph

  test "builds deterministic direct dependency edges" do
    graph =
      Graph.build([
        issue("a", [%{id: "b", identifier: "SYM-B", state: "Done"}]),
        issue("b", [%{id: "c", identifier: "SYM-C", state: "Ready"}]),
        issue("c", [])
      ])

    assert graph.edges == %{"a" => ["b"], "b" => ["c"], "c" => []}
    assert graph.reverse_edges == %{"a" => [], "b" => ["a"], "c" => ["b"]}
    assert Graph.cycles(graph) == []
  end

  test "reports a stable cycle and all cycle members" do
    graph =
      Graph.build([
        issue("c", [%{id: "a", state: "Ready"}]),
        issue("a", [%{id: "b", state: "Ready"}]),
        issue("b", [%{id: "c", state: "Ready"}])
      ])

    assert Graph.cycles(graph) == [["a", "b", "c"]]
    assert Graph.cycle_members(graph) == MapSet.new(["a", "b", "c"])
    assert Graph.cyclic?(graph, "b")
    refute Graph.cyclic?(graph, "missing")
  end

  test "keeps independent branches separate and orders multiple blockers" do
    graph =
      Graph.build([
        issue("dependent", [
          %{id: "z", state: "Done"},
          %{id: "a", state: "In Progress"}
        ]),
        issue("z", []),
        issue("a", []),
        issue("independent", [])
      ])

    assert graph.edges["dependent"] == ["a", "z"]
    assert graph.edges["independent"] == []
    assert Graph.cycles(graph) == []
  end

  test "surfaces missing and malformed blocker diagnostics without guessing" do
    graph =
      Graph.build([
        issue("dependent", [
          %{id: "hidden", identifier: "SYM-HIDDEN", state: "Ready"},
          %{identifier: "SYM-MALFORMED", state: "Ready"}
        ])
      ])

    assert graph.edges["dependent"] == []
    assert Enum.any?(graph.diagnostics, &(&1.kind == :missing_blocker))
    assert Enum.any?(graph.diagnostics, &(&1.kind == :malformed_blocker))
  end

  test "fails closed for malformed issue and blocker collections" do
    assert %Graph{} = Graph.build(nil)
    refute Graph.cyclic?(%Graph{}, :not_a_binary_id)

    graph =
      Graph.build([
        :not_an_issue,
        issue("malformed-list", nil),
        issue("malformed-blocker", [:not_a_blocker]),
        issue("duplicate", []),
        issue("duplicate", [])
      ])

    assert Enum.any?(graph.diagnostics, &(&1.kind == :malformed_issue))
    assert Enum.any?(graph.diagnostics, &(&1.kind == :malformed_blocker_list))
    assert Enum.any?(graph.diagnostics, &(&1.kind == :malformed_blocker))
    assert Enum.any?(graph.diagnostics, &(&1.kind == :duplicate_issue))
  end

  defp issue(id, blocked_by) do
    %SymphonyElixir.Tracker.Issue{id: id, identifier: String.upcase(id), state: "Ready", blocked_by: blocked_by}
  end
end
