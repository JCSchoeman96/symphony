defmodule SymphonyElixir.PlaneClientTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Plane.Client

  @config %{base_url: "https://api.plane.so", workspace_id: "workspace-1", project_id: "project-1", api_key: "secret"}

  test "uses bounded GET requests with scoped paths and state expansion" do
    parent = self()

    request_fun = fn request ->
      send(parent, {:request, request})
      {:ok, %{status: 200, body: %{"id" => "item-1"}}}
    end

    assert {:ok, %{"id" => "item-1"}} =
             Client.get_work_item(@config, "item-1", request_fun: request_fun)

    assert_receive {:request, %{method: :get, path: path, params: params, headers: headers}}
    assert path == "/api/v1/workspaces/workspace-1/projects/project-1/work-items/item-1/"
    assert params == %{"fields" => "state", "expand" => "state"}
    assert {"X-API-Key", "secret"} in headers
  end

  test "combines every work-item page and rejects incomplete cursor pagination" do
    parent = self()

    request_fun = fn request ->
      send(parent, {:request, request})

      case request.params["cursor"] do
        nil ->
          {:ok, %{status: 200, body: %{"results" => [%{"id" => "one"}], "next_page_results" => true, "next_cursor" => "c1"}}}

        "c1" ->
          {:ok, %{status: 200, body: %{"results" => [%{"id" => "two"}], "next_page_results" => false, "next_cursor" => nil}}}
      end
    end

    assert {:ok, [%{"id" => "one"}, %{"id" => "two"}]} =
             Client.list_work_items(@config, request_fun: request_fun)

    assert_receive {:request, %{params: first_params}}
    assert first_params["per_page"] == 100
    assert first_params["expand"] == "state"
    assert_receive {:request, %{params: second_params}}
    assert second_params["cursor"] == "c1"

    assert {:error, :snapshot_incomplete} =
             Client.list_work_items(@config,
               request_fun: fn _request ->
                 {:ok, %{status: 200, body: %{"results" => [], "next_page_results" => true, "next_cursor" => nil}}}
               end
             )
  end

  test "lists states with cursor progression and bounded malformed pages" do
    request_fun = fn request ->
      case request.params["cursor"] do
        nil ->
          {:ok,
           %{
             status: 200,
             body: %{
               "results" => [%{"id" => "s1"}],
               "next_page_results" => true,
               "next_cursor" => "state-page-2"
             }
           }}

        "state-page-2" ->
          {:ok,
           %{
             status: 200,
             body: %{"results" => [%{"id" => "s2"}], "next_page_results" => false, "next_cursor" => nil}
           }}
      end
    end

    assert {:ok, [%{"id" => "s1"}, %{"id" => "s2"}]} = Client.list_states(@config, request_fun: request_fun)

    assert {:error, :snapshot_incomplete} =
             Client.list_states(@config,
               request_fun: fn _request ->
                 {:ok, %{status: 200, body: %{"results" => [], "next_page_results" => false, "next_cursor" => "stale"}}}
               end
             )

    assert {:error, :provider_malformed} =
             Client.list_states(@config,
               request_fun: fn _request ->
                 {:ok, %{status: 200, body: %{"results" => [%{"id" => "ok"}, :bad], "next_page_results" => false}}}
               end
             )

    too_many_states = Enum.map(1..65, &%{"id" => "state-#{&1}"})

    assert {:error, :snapshot_incomplete} =
             Client.list_states(@config,
               request_fun: fn _request ->
                 {:ok, %{status: 200, body: %{"results" => too_many_states, "next_page_results" => false}}}
               end
             )
  end

  test "maps HTTP and transport failures without exposing provider bodies" do
    for {status, expected} <- [
          {401, :unauthorized},
          {403, :unauthorized},
          {404, :not_found},
          {500, :provider_unavailable},
          {502, :provider_unavailable},
          {503, :provider_unavailable},
          {504, :provider_unavailable}
        ] do
      assert {:error, ^expected} =
               Client.get_project(@config,
                 request_fun: fn _request ->
                   {:ok, %{status: status, body: %{"token" => "do-not-return"}}}
                 end
               )
    end

    assert {:error, {:rate_limited, %{retry_after: 12}}} =
             Client.get_project(@config,
               request_fun: fn _request ->
                 {:ok, %{status: 429, headers: %{"retry-after" => "12"}, body: %{"secret" => "hidden"}}}
               end
             )

    assert {:error, :provider_unavailable} =
             Client.get_project(@config, request_fun: fn _request -> {:error, :timeout} end)
  end

  test "rejects unsafe production base URLs while allowing HTTP only through an injected test request" do
    assert {:error, :invalid_base_url} =
             Client.get_project(%{@config | base_url: "http://user:pass@example.invalid/api?x=1"})

    assert {:ok, _project} =
             Client.get_project(%{@config | base_url: "http://localhost:4000"},
               request_fun: fn _request -> {:ok, %{status: 200, body: %{}}} end
             )
  end

  test "normalizes malformed success bodies and strict configuration failures" do
    assert {:ok, %{"id" => "project-1"}} =
             Client.get_project(@config,
               request_fun: fn _request -> {:ok, %{status: 200, body: "{\"id\":\"project-1\"}"}} end
             )

    assert {:error, :provider_malformed} =
             Client.get_project(@config,
               request_fun: fn _request -> {:ok, %{status: 200, body: "not-json"}} end
             )

    assert {:error, :provider_malformed} =
             Client.get_project(@config,
               request_fun: fn _request -> {:ok, %{status: 200, body: []}} end
             )

    assert {:error, :provider_malformed} =
             Client.get_project(@config,
               request_fun: fn _request -> {:ok, %{status: 418, body: %{}}} end
             )

    assert {:error, :invalid_scope} =
             Client.get_work_item(@config, "", request_fun: fn _request -> {:ok, %{status: 200, body: %{}}} end)

    assert {:error, :invalid_scope} = Client.get_project(%{@config | workspace_id: ""}, request_fun: fn _ -> :ok end)
    assert {:error, :missing_credential} = Client.get_project(%{@config | api_key: nil}, request_fun: fn _ -> :ok end)
    assert {:error, :provider_unavailable} = Client.get_project(@config, request_fun: :not_a_function)
  end

  test "supports bounded request-double arities and sanitizes transport failures" do
    assert {:ok, %{}} =
             Client.get_project(@config,
               request_fun: fn :get, _path, _params, _headers -> {:ok, %{status: 200, body: %{}}} end
             )

    assert {:ok, %{}} =
             Client.get_project(@config,
               request_fun: fn :get, _path, _params, nil, _config -> {:ok, %{status: 200, body: %{}}} end
             )

    assert {:error, :provider_unavailable} =
             Client.get_project(@config, request_fun: fn _request -> raise "contains secret token" end)

    assert {:error, :provider_unavailable} =
             Client.get_project(@config, request_fun: fn _request -> throw(:transport_failure) end)

    assert {:error, :provider_unavailable} =
             Client.get_project(@config,
               request_fun: fn _request -> {:error, %Client.Error{kind: :provider_unavailable}} end
             )

    assert {:error, {:rate_limited, %{retry_after: 7}}} =
             Client.get_project(@config,
               request_fun: fn _request ->
                 {:ok, %{status: 429, headers: [{"x-ratelimit-reset", ["7"]}], body: %{}}}
               end
             )

    assert {:error, {:rate_limited, %{retry_after: 12}}} =
             Client.get_project(@config,
               request_fun: fn _request -> {:ok, %{status: 429, headers: %{"retry-after" => 12}, body: %{}}} end
             )

    assert {:error, {:rate_limited, %{retry_after: nil}}} =
             Client.get_project(@config,
               request_fun: fn _request -> {:ok, %{status: 429, headers: :not_headers, body: %{}}} end
             )
  end

  test "rejects malformed pagination and transport-double shapes" do
    assert {:error, :snapshot_incomplete} =
             Client.list_work_items(@config,
               request_fun: fn _request ->
                 {:ok, %{status: 200, body: %{"results" => [], "next_page_results" => :unknown, "next_cursor" => nil}}}
               end
             )

    assert {:error, :snapshot_incomplete} =
             Client.list_work_items(@config,
               request_fun: fn request ->
                 {:ok,
                  %{
                    status: 200,
                    body: %{
                      "results" => [],
                      "next_page_results" => true,
                      "next_cursor" => if(request.params["cursor"], do: request.params["cursor"], else: "same")
                    }
                  }}
               end
             )

    assert {:error, :provider_malformed} =
             Client.list_work_items(@config,
               request_fun: fn _request ->
                 {:ok, %{status: 200, body: %{"results" => :not_a_list, "next_page_results" => false}}}
               end
             )

    assert {:error, :provider_malformed} =
             Client.get_project(@config,
               request_fun: fn _request -> {:ok, %{status: 200, body: :not_json}} end
             )

    assert {:error, :provider_unavailable} =
             Client.get_project(@config,
               request_fun: fn _request -> {:ok, %{status: "200", body: %{}}} end
             )

    assert {:error, :provider_unavailable} =
             Client.get_project(@config,
               request_fun: fn _first, _second -> {:ok, %{status: 200, body: %{}}} end
             )

    assert {:error, :invalid_base_url} =
             Client.get_project(%{@config | base_url: 42},
               request_fun: fn _request -> {:ok, %{status: 200, body: %{}}} end
             )
  end

  test "rejects a pagination stream that reaches the page safety ceiling" do
    parent = self()

    request_fun = fn request ->
      page =
        case request.params["cursor"] do
          nil -> 1
          "cursor-" <> value -> String.to_integer(value) + 1
        end

      send(parent, {:page, page})

      {:ok,
       %{
         status: 200,
         body: %{"results" => [%{"id" => "item-#{page}"}], "next_page_results" => true, "next_cursor" => "cursor-#{page}"}
       }}
    end

    assert {:error, :snapshot_incomplete} = Client.list_work_items(@config, request_fun: request_fun)
    assert_receive {:page, 100}
    refute_receive {:page, 101}
  end

  test "every Plane operation is a scoped GET and exposes no future-phase endpoint" do
    parent = self()

    request_fun = fn request ->
      send(parent, {:request, request.method, request.path})

      body =
        if String.ends_with?(request.path, "/work-items/") or String.ends_with?(request.path, "/states/") do
          %{"results" => [], "next_page_results" => false, "next_cursor" => nil}
        else
          %{"id" => "project-1", "workspace" => %{"slug" => "workspace-1"}}
        end

      {:ok, %{status: 200, body: body}}
    end

    assert {:ok, _} = Client.get_project(@config, request_fun: request_fun)
    assert {:ok, _} = Client.get_work_item(@config, "item-1", request_fun: request_fun)
    assert {:ok, _} = Client.list_work_items(@config, request_fun: request_fun)
    assert {:ok, _} = Client.list_states(@config, request_fun: request_fun)

    requests =
      Enum.map(1..4, fn _ ->
        receive do
          {:request, method, path} -> {method, path}
        end
      end)

    assert Enum.all?(requests, fn {method, path} -> method == :get and not String.contains?(path, ["dependency", "relation", "transition", "webhook"]) end)
  end
end
