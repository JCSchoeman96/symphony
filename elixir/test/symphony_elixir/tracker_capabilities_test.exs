defmodule SymphonyElixir.TrackerCapabilitiesContradictoryAdapter do
  def capabilities, do: [:dependency_graph]
end

defmodule SymphonyElixir.TrackerCapabilitiesUnknownAdapter do
  def capabilities, do: [:not_a_capability]
end

defmodule SymphonyElixir.TrackerCapabilitiesDuplicateAdapter do
  def capabilities, do: [:current_issue_refresh, :current_issue_refresh]
end

defmodule SymphonyElixir.TrackerCapabilitiesTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config
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
             SymphonyElixir.Config.Schema.parse(%{
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
             SymphonyElixir.Config.Schema.parse(%{
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
