defmodule SymphonyElixir.TrackerCapabilitiesContradictoryAdapter do
  def capabilities, do: [:dependency_graph]
end

defmodule SymphonyElixir.TrackerCapabilitiesUnknownAdapter do
  def capabilities, do: [:not_a_capability]
end

defmodule SymphonyElixir.TrackerCapabilitiesDuplicateAdapter do
  def capabilities, do: [:current_issue_refresh, :current_issue_refresh]
end

defmodule SymphonyElixir.TrackerCapabilitiesInvalidListAdapter do
  def capabilities, do: :not_a_list
end

defmodule SymphonyElixir.TrackerCapabilitiesRaisingAdapter do
  def capabilities, do: raise("capability declaration failed")
end

defmodule SymphonyElixir.TrackerCapabilitiesThrowingAdapter do
  def capabilities, do: throw(:capability_declaration_failed)
end

defmodule SymphonyElixir.TrackerCapabilitiesTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Tracker
  alias SymphonyElixir.Tracker.Capabilities

  test "owns the complete ordered routed capability requirement set" do
    assert Capabilities.required_routed() == [
             :current_issue_refresh,
             :dependency_graph,
             :dependency_completeness,
             :controlled_transition,
             :transition_verification,
             :agent_read_tools,
             :agent_transition_tools
           ]
  end

  test "exposes the complete local capability vocabulary" do
    assert :conditional_transition in Capabilities.vocabulary()
    assert length(Capabilities.vocabulary()) == 8
  end

  test "resolves adapter declarations locally without invoking provider clients" do
    Application.put_env(:symphony_elixir, :linear_client_module, SymphonyElixir.TrackerCapabilitiesProbeClient)

    assert {:ok, declared} = Tracker.capabilities_for_kind("linear")
    assert :current_issue_refresh in declared
    refute_received :provider_request
  end

  test "Linear does not over-claim capabilities owned by later phases" do
    assert {:ok, declared} = Tracker.capabilities_for_kind("linear")
    refute :transition_verification in declared
    refute :agent_read_tools in declared
  end

  test "missing routed capabilities reject configuration before dispatch" do
    assert {:ok, settings} =
             Schema.parse(%{
               "tracker" => %{
                 "kind" => "linear",
                 "endpoint" => "https://api.linear.app/graphql",
                 "api_key" => "token",
                 "project_slug" => "project"
               },
               "agent" => %{"routing" => "routed"}
             })

    assert {:error, {:routed_provider_capabilities_missing, "linear", missing}} =
             Config.validate_settings(settings)

    assert missing == [:transition_verification, :agent_read_tools]
  end

  test "legacy configuration remains valid for an adapter without the routed contract" do
    assert {:ok, settings} =
             Schema.parse(%{
               "tracker" => %{
                 "kind" => "github",
                 "provider" => %{"repo" => "octo/repo", "token" => "token"},
                 "active_states" => ["open"],
                 "terminal_states" => ["closed"]
               },
               "agent" => %{"routing" => "legacy"}
             })

    assert :ok = Config.validate_settings(settings)
  end

  test "structurally contradictory declarations are rejected" do
    assert {:error, {:invalid_provider_capability_declaration, adapter, reason}} =
             Capabilities.validate_adapter(SymphonyElixir.TrackerCapabilitiesContradictoryAdapter)

    assert adapter == SymphonyElixir.TrackerCapabilitiesContradictoryAdapter
    assert reason == {:missing_callback, :dependency_graph, :fetch_dependency_graph, 0}
  end

  test "unknown and duplicate declarations are rejected" do
    assert {:error, {:invalid_provider_capability_declaration, _, {:unknown_capability, :not_a_capability}}} =
             Capabilities.validate_adapter(SymphonyElixir.TrackerCapabilitiesUnknownAdapter)

    assert {:error, {:invalid_provider_capability_declaration, _, {:duplicate_capability, :current_issue_refresh}}} =
             Capabilities.validate_adapter(SymphonyElixir.TrackerCapabilitiesDuplicateAdapter)

    assert {:error, {:invalid_provider_capability_declaration, _, {:invalid_capability_list, :not_a_list}}} =
             Capabilities.validate_adapter(SymphonyElixir.TrackerCapabilitiesInvalidListAdapter)
  end

  test "a failing capability callback is rejected without escaping validation" do
    assert {:error, {:invalid_provider_capability_declaration, _, :capabilities_callback_failed}} =
             Capabilities.validate_adapter(SymphonyElixir.TrackerCapabilitiesRaisingAdapter)

    assert {:error, {:invalid_provider_capability_declaration, _, :capabilities_callback_failed}} =
             Capabilities.validate_adapter(SymphonyElixir.TrackerCapabilitiesThrowingAdapter)
  end

  test "tracker identity projects each provider scope without secrets" do
    assert Tracker.identity(%{
             kind: "linear",
             project_slug: " linear-project ",
             provider: %{"project_slug" => "fallback", "api_key" => "secret"}
           }) == %{
             tracker_kind: "linear",
             provider_scope: %{project_slug: "linear-project"}
           }

    assert Tracker.identity(%{
             kind: "linear",
             project_slug: nil,
             provider: %{project_slug: " fallback-project "}
           }).provider_scope == %{project_slug: "fallback-project"}

    assert Tracker.identity(%{kind: "github", provider: %{"repo" => " octo/repo "}}).provider_scope == %{
             repo: "octo/repo"
           }

    assert Tracker.identity(%{kind: "gitlab", provider: %{repo: "group/project"}}).provider_scope == %{
             repo: "group/project"
           }

    assert Tracker.identity(%{kind: "jira", provider: %{"project_key" => " JIRA "}}).provider_scope == %{
             project_key: "JIRA"
           }

    assert Tracker.identity(%{kind: "asana", provider: %{project_gid: " 123 "}}).provider_scope == %{
             project_gid: "123"
           }

    assert Tracker.identity(%{kind: "memory", provider: nil}).provider_scope == %{}
    assert Tracker.identity(%{kind: "linear", project_slug: nil, provider: nil}).provider_scope == %{}
    assert Tracker.identity(%{kind: "github", provider: %{"repo" => 123}}).provider_scope == %{}
    assert Tracker.identity(%{kind: "other", provider: %{}}).provider_scope == %{}
  end

  test "tracker capability facade follows the configured adapter" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    assert {:ok, declared} = Tracker.capabilities()
    assert :agent_read_tools in declared

    assert {:error, {:unsupported_tracker_kind, "future-tracker"}} =
             Tracker.capabilities_for_kind("future-tracker")

    assert :ok = Tracker.validate_routed_capabilities(%{agent: %{routing: "legacy"}})
    assert :ok = Tracker.validate_routed_capabilities(%{})
  end

  test "tracker rejects bound tools when the adapter lacks an executor" do
    response =
      Tracker.execute_bound_agent_tool(
        %{adapter: SymphonyElixir.TrackerCapabilitiesUnknownAdapter, tracker_settings: %{}},
        "unsupported",
        %{}
      )

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["supportedTools"] == []
  end
end

defmodule SymphonyElixir.TrackerCapabilitiesProbeClient do
  def fetch_issues_by_states(_states) do
    send(self(), :provider_request)
    {:ok, []}
  end

  def fetch_issues_by_ids(_issue_ids) do
    send(self(), :provider_request)
    {:ok, []}
  end

  def fetch_dependency_graph do
    send(self(), :provider_request)
    {:ok, []}
  end
end
