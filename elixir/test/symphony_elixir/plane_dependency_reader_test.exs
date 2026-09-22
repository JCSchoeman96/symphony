defmodule SymphonyElixir.PlaneDependencyReaderTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Dependency.{Graph, Policy}
  alias SymphonyElixir.Plane.Adapter
  alias SymphonyElixir.Plane.DependencyReader

  @settings %{
    kind: "plane",
    api_key: "secret",
    endpoint: "https://api.plane.so",
    provider: %{
      "workspace_slug" => "workspace-1",
      "workspace_id" => "workspace-stable-1",
      "project_id" => "project-1",
      "api_key" => "$PLANE_API_KEY"
    },
    secret_environment_names: ["PLANE_API_KEY"]
  }

  test "accepts provider issue_id relations and normalizes both directions" do
    requests = start_request_log()

    assert {:ok, %Graph{} = graph} =
             Adapter.fetch_dependency_graph_for_test(
               @settings,
               dependency_request_fun(requests, %{
                 "a" => %{"blocked_by" => [%{"issue_id" => "b", "project_id" => "project-1"}], "blocking" => []},
                 "b" => %{"blocked_by" => [], "blocking" => [%{"issue_id" => "a", "project_id" => "project-1"}]}
               })
             )

    assert graph.edges == %{"a" => [], "b" => ["a"]}
    assert graph.nodes["a"].blocked_by == [%{id: "b", identifier: "B", state: "Ready"}]
    assert graph.nodes["b"].blocked_by == []
    assert Graph.complete?(graph)
    assert request_count(requests, "/relations/") == 2
  end

  test "rejects invalid acquisition inputs before transport" do
    config = %{
      base_url: "https://api.plane.so",
      workspace_slug: "workspace-1",
      workspace_id: "workspace-stable-1",
      project_id: "project-1",
      api_key: "secret"
    }

    assert {:error, :provider_unavailable} = DependencyReader.fetch(:invalid)
    assert {:error, :provider_unavailable} = DependencyReader.fetch(config, :invalid_opts)
    assert {:error, :item_enumeration_incomplete} = DependencyReader.fetch(Map.delete(config, :workspace_slug))
    assert {:error, :item_enumeration_incomplete} = DependencyReader.fetch(Map.put(config, :workspace_id, nil))
    assert {:error, :provider_unavailable} = DependencyReader.fetch(Map.put(config, :api_key, ""))

    assert {:error, :provider_unavailable} =
             DependencyReader.fetch(Map.put(config, :base_url, "http://plane.invalid"))

    request_fun = fn request ->
      if String.ends_with?(request.path, "/work-items/"),
        do: {:ok, %{status: 200, body: page([])}},
        else: {:ok, %{status: 200, body: empty_relations()}}
    end

    assert {:ok, %Graph{}} =
             DependencyReader.fetch_for_test(
               config,
               request_fun,
               max_concurrency: 0,
               relation_task_timeout_ms: 0
             )
  end

  test "maps item enumeration failures to safe acquisition reasons" do
    responses = [
      {{:ok, %{status: 429, headers: %{}, body: %{}}}, :rate_limited},
      {{:ok, %{status: 503, headers: %{}, body: %{}}}, :provider_unavailable},
      {{:ok, %{status: 401, headers: %{}, body: %{}}}, :item_enumeration_incomplete},
      {{:ok, %{status: 200, body: %{"results" => :invalid}}}, :item_enumeration_incomplete}
    ]

    for {response, expected_reason} <- responses do
      assert {:error, ^expected_reason} =
               Adapter.fetch_dependency_graph_for_test(@settings, fn request ->
                 if String.ends_with?(request.path, "/work-items/"), do: response, else: {:error, :unexpected_path}
               end)
    end

    assert {:error, :item_enumeration_incomplete} =
             Adapter.fetch_dependency_graph_for_test(
               @settings,
               dependency_request_fun(start_request_log(), %{}, items: [Map.delete(item("bad"), "state")])
             )
  end

  test "enumerates every work-item page before reading relations" do
    requests = start_request_log()

    request_fun = fn request ->
      Agent.update(requests, fn state -> update_request_state(state, request.path) end)

      cond do
        String.ends_with?(request.path, "/work-items/") and is_nil(request.params["cursor"]) ->
          {:ok, %{status: 200, body: page([item("a")], 2, true, "page-2")}}

        String.ends_with?(request.path, "/work-items/") and request.params["cursor"] == "page-2" ->
          {:ok, %{status: 200, body: page([item("b")], 2, false, nil)}}

        String.ends_with?(request.path, "/relations/") ->
          {:ok, %{status: 200, body: empty_relations()}}

        true ->
          {:error, :unexpected_path}
      end
    end

    assert {:ok, graph} = Adapter.fetch_dependency_graph_for_test(@settings, request_fun)
    assert Map.keys(graph.nodes) == ["a", "b"]
    assert request_count(requests, "/relations/") == 2
  end

  test "rejects an enumerated item outside the configured project scope" do
    requests = start_request_log()
    foreign_item = Map.put(item("foreign"), "project", "other-project")

    assert {:error, :item_enumeration_incomplete} =
             Adapter.fetch_dependency_graph_for_test(
               @settings,
               dependency_request_fun(requests, %{}, items: [foreign_item])
             )
  end

  test "retains more than one hundred prerequisites without truncation" do
    ids = Enum.map(1..106, &"b-#{&1}")
    items = [item("dependent") | Enum.map(ids, &item/1)]
    relations = %{"dependent" => %{"blocked_by" => Enum.map(ids, &%{"issue_id" => &1, "project_id" => "project-1"}), "blocking" => []}}
    requests = start_request_log()

    assert {:ok, graph} =
             Adapter.fetch_dependency_graph_for_test(
               @settings,
               dependency_request_fun(requests, relations, items: items)
             )

    assert length(graph.nodes["dependent"].blocked_by) == 106
    assert Enum.map(graph.nodes["dependent"].blocked_by, & &1.id) == Enum.sort(ids)
  end

  test "fails closed for a rate-limited relation read" do
    requests = start_request_log()

    assert {:error, :rate_limited} =
             Adapter.fetch_dependency_graph_for_test(
               @settings,
               dependency_request_fun(requests, %{}, relation_error: {:ok, %{status: 429, headers: %{}, body: %{}}})
             )
  end

  test "fails closed for provider relation errors and 5xx responses" do
    for relation_error <- [{:error, :transport_failed}, {:ok, %{status: 503, headers: %{}, body: %{}}}] do
      requests = start_request_log()

      assert {:error, reason} =
               Adapter.fetch_dependency_graph_for_test(
                 @settings,
                 dependency_request_fun(requests, %{}, relation_error: relation_error)
               )

      assert reason in [:relation_read_failed, :provider_unavailable]
    end

    requests = start_request_log()

    assert {:error, :relation_read_failed} =
             Adapter.fetch_dependency_graph_for_test(
               @settings,
               dependency_request_fun(requests, %{}, relation_error: {:ok, %{status: 401, headers: %{}, body: %{}}})
             )

    for {response, expected_reason} <- [
          {{:ok, %{status: 200, body: "not-an-object"}}, :relation_malformed},
          {{:ok, %{status: 200, body: String.duplicate("x", 4_000_001)}}, :relation_read_failed}
        ] do
      requests = start_request_log()

      assert {:error, ^expected_reason} =
               Adapter.fetch_dependency_graph_for_test(
                 @settings,
                 dependency_request_fun(requests, %{}, relation_error: response)
               )
    end
  end

  test "fails closed for malformed, cross-project, and unknown targets" do
    for relation_body <- [
          %{"blocked_by" => %{}, "blocking" => []},
          %{"blocked_by" => ["not-a-target"], "blocking" => []},
          %{"blocked_by" => [%{"issue_id" => "b"}], "blocking" => []},
          %{"blocked_by" => [%{"issue_id" => "", "project_id" => "project-1"}], "blocking" => []},
          %{"blocked_by" => [%{"issue_id" => 123, "project_id" => "project-1"}], "blocking" => []},
          %{"blocked_by" => [%{"id" => "b", "project_id" => "project-1"}], "blocking" => []},
          %{"blocked_by" => [%{"issue_id" => "b", "project_id" => "other-project"}], "blocking" => []},
          %{"blocked_by" => [%{"issue_id" => "missing", "project_id" => "project-1"}], "blocking" => []}
        ] do
      requests = start_request_log()

      assert {:error, reason} =
               Adapter.fetch_dependency_graph_for_test(
                 @settings,
                 dependency_request_fun(requests, %{"a" => relation_body})
               )

      assert reason in [:relation_malformed, :cross_project_dependency, :missing_dependency_target]
    end
  end

  test "publishes a complete provider-shaped two-item cycle" do
    requests = start_request_log()

    assert {:ok, graph} =
             Adapter.fetch_dependency_graph_for_test(
               @settings,
               dependency_request_fun(requests, %{
                 "a" => %{
                   "blocked_by" => [%{"issue_id" => "b", "project_id" => "project-1"}],
                   "blocking" => [%{"issue_id" => "b", "project_id" => "project-1"}]
                 },
                 "b" => %{
                   "blocked_by" => [%{"issue_id" => "a", "project_id" => "project-1"}],
                   "blocking" => [%{"issue_id" => "a", "project_id" => "project-1"}]
                 }
               })
             )

    assert Graph.complete?(graph)
    assert Graph.cycles(graph) == [["a", "b"]]
    assert graph.edges == %{"a" => ["b"], "b" => ["a"]}
  end

  test "fails closed when the closing node set changes" do
    requests = start_request_log()
    changed_items = [item("a"), item("b")]

    assert {:error, :node_set_changed} =
             Adapter.fetch_dependency_graph_for_test(
               @settings,
               dependency_request_fun(
                 requests,
                 %{"a" => empty_relations()},
                 items: [item("a")],
                 closing_items: changed_items
               )
             )
  end

  test "never resolves a foreign dependency by display name" do
    requests = start_request_log()
    same_name = Map.put(item("b"), "name", "Shared name")

    assert {:error, :missing_dependency_target} =
             Adapter.fetch_dependency_graph_for_test(
               @settings,
               dependency_request_fun(
                 requests,
                 %{
                   "a" => %{
                     "blocked_by" => [%{"issue_id" => "foreign-id", "project_id" => "project-1"}],
                     "blocking" => []
                   }
                 },
                 items: [item("a"), same_name]
               )
             )
  end

  test "publishes an empty complete epoch for an empty project" do
    requests = start_request_log()

    assert {:ok, %Graph{nodes: nodes} = graph} =
             Adapter.fetch_dependency_graph_for_test(
               @settings,
               dependency_request_fun(requests, %{}, items: [])
             )

    assert nodes == %{}
    assert Graph.complete?(graph)
  end

  test "rejects duplicate stable work-item IDs and incomplete enumeration" do
    requests = start_request_log()

    assert {:error, :duplicate_work_item} =
             Adapter.fetch_dependency_graph_for_test(
               @settings,
               dependency_request_fun(requests, %{}, items: [item("a"), item("a")])
             )

    assert {:error, :item_enumeration_incomplete} =
             Adapter.fetch_dependency_graph_for_test(@settings, fn request ->
               if String.ends_with?(request.path, "/work-items/") do
                 {:ok, %{status: 200, body: %{"results" => [], "count" => 0, "total_results" => 1, "next_page_results" => false, "next_cursor" => nil}}}
               else
                 {:ok, %{status: 200, body: empty_relations()}}
               end
             end)
  end

  test "ignores unsupported relation groups and rejects paginated relation envelopes" do
    requests = start_request_log()

    assert {:ok, graph} =
             Adapter.fetch_dependency_graph_for_test(
               @settings,
               dependency_request_fun(requests, %{"a" => Map.merge(empty_relations(), %{"relates_to" => [%{"issue_id" => "b", "project_id" => "project-1"}]})})
             )

    assert graph.nodes["a"].blocked_by == []

    assert {:ok, atom_key_graph} =
             Adapter.fetch_dependency_graph_for_test(
               @settings,
               dependency_request_fun(requests, %{"a" => %{blocked_by: [], blocking: []}})
             )

    assert atom_key_graph.nodes["a"].blocked_by == []

    assert {:error, :relation_shape_unsupported} =
             Adapter.fetch_dependency_graph_for_test(
               @settings,
               dependency_request_fun(requests, %{"a" => %{"results" => [], "next_page_results" => false}})
             )

    assert {:error, :relation_shape_unsupported} =
             Adapter.fetch_dependency_graph_for_test(
               @settings,
               dependency_request_fun(requests, %{"a" => Map.put(empty_relations(), "next_cursor", nil)})
             )

    assert {:error, :relation_shape_unsupported} =
             Adapter.fetch_dependency_graph_for_test(
               @settings,
               dependency_request_fun(requests, %{"a" => %{"blocked_by" => %{"results" => []}, "blocking" => []}})
             )

    assert {:error, :relation_malformed} =
             Adapter.fetch_dependency_graph_for_test(
               @settings,
               dependency_request_fun(requests, %{"a" => %{"blocked_by" => :invalid, "blocking" => []}})
             )

    assert {:error, :relation_shape_unsupported} =
             Adapter.fetch_dependency_graph_for_test(
               @settings,
               dependency_request_fun(requests, %{"a" => %{"results" => [], "blocking" => []}})
             )

    assert {:error, :relation_malformed} =
             Adapter.fetch_dependency_graph_for_test(
               @settings,
               dependency_request_fun(requests, %{"a" => %{"blocking" => []}})
             )
  end

  test "collapses duplicate observations deterministically" do
    requests = start_request_log()

    assert {:ok, graph} =
             Adapter.fetch_dependency_graph_for_test(
               @settings,
               dependency_request_fun(requests, %{
                 "a" => %{
                   "blocked_by" => [
                     %{"issue_id" => "b", "project_id" => "project-1"},
                     %{"issue_id" => "b", "project_id" => "project-1"}
                   ],
                   "blocking" => []
                 },
                 "b" => %{"blocked_by" => [], "blocking" => [%{"issue_id" => "a", "project_id" => "project-1"}]}
               })
             )

    assert graph.edges == %{"a" => [], "b" => ["a"]}
    assert Enum.map(graph.nodes["a"].blocked_by, & &1.id) == ["b"]
  end

  test "bounds relation fan-out and task timeouts" do
    entries = Enum.map(1..10_001, &%{"issue_id" => "target-#{&1}", "project_id" => "project-1"})
    requests = start_request_log()

    assert {:error, :relation_fanout_exceeded} =
             Adapter.fetch_dependency_graph_for_test(
               @settings,
               dependency_request_fun(requests, %{"a" => %{"blocked_by" => entries, "blocking" => []}})
             )

    assert {:error, :relation_read_failed} =
             Adapter.fetch_dependency_graph_for_test(
               @settings,
               dependency_request_fun(requests, %{}, relation_sleep_ms: 25),
               relation_task_timeout_ms: 1
             )
  end

  test "raw provider Done does not satisfy a dependency while trusted completion does" do
    assert Policy.classify_state("Done") == :unresolved
  end

  defp dependency_request_fun(log, relation_map, opts \\ []) do
    opening_items = Keyword.get(opts, :items, [item("a"), item("b")])
    closing_items = Keyword.get(opts, :closing_items, opening_items)
    relation_error = Keyword.get(opts, :relation_error)
    relation_sleep_ms = Keyword.get(opts, :relation_sleep_ms, 0)

    fn request ->
      enumeration_count = Agent.get(log, & &1.enumeration_count)
      Agent.update(log, fn state -> update_request_state(state, request.path) end)

      cond do
        String.ends_with?(request.path, "/work-items/") ->
          {:ok, %{status: 200, body: page(enumerated_items(opening_items, closing_items, enumeration_count))}}

        String.ends_with?(request.path, "/relations/") and relation_error ->
          relation_error

        String.ends_with?(request.path, "/relations/") ->
          maybe_sleep(relation_sleep_ms)
          id = request.path |> String.split("/") |> Enum.at(-3)
          {:ok, %{status: 200, body: Map.get(relation_map, id, empty_relations())}}

        true ->
          {:error, :unexpected_path}
      end
    end
  end

  defp maybe_sleep(milliseconds) when milliseconds > 0, do: Process.sleep(milliseconds)
  defp maybe_sleep(_milliseconds), do: :ok

  defp enumerated_items(opening_items, _closing_items, 0), do: opening_items
  defp enumerated_items(_opening_items, closing_items, _enumeration_count), do: closing_items

  defp start_request_log do
    Agent.start_link(fn -> %{enumeration_count: 0, relation_calls: 0} end)
    |> elem(1)
  end

  defp update_request_state(state, path) do
    cond do
      String.ends_with?(path, "/work-items/") -> %{state | enumeration_count: state.enumeration_count + 1}
      String.ends_with?(path, "/relations/") -> %{state | relation_calls: state.relation_calls + 1}
      true -> state
    end
  end

  defp request_count(agent, suffix), do: Agent.get(agent, fn state -> if suffix == "/relations/", do: state.relation_calls, else: 0 end)

  defp page(items, total \\ nil, next? \\ false, next_cursor \\ nil) do
    %{
      "results" => items,
      "count" => length(items),
      "total_results" => total || length(items),
      "next_page_results" => next?,
      "next_cursor" => next_cursor
    }
  end

  defp empty_relations, do: %{"blocked_by" => [], "blocking" => []}

  defp item(id), do: %{"id" => id, "name" => String.upcase(id), "state" => state(id), "project" => "project-1", "workspace" => "workspace-stable-1", "updated_at" => "2026-09-17T08:09:10Z"}

  defp state(_id), do: %{"id" => "state-ready", "name" => "Ready", "group" => "unstarted"}
end
