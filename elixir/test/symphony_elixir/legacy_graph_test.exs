defmodule SymphonyElixir.LegacyGraphClient do
  alias SymphonyElixir.Tracker.Issue
  def fetch_issues_by_states(_), do: {:ok, [issue()]}
  def fetch_issues_by_ids(_), do: {:ok, [issue()]}

  defp issue do
    %Issue{id: "legacy-graph", identifier: "LEGACY-1", title: "Legacy", state: "open", dispatchable: true, blocked_by: Process.get(:legacy_blockers, [])}
  end
end

defmodule SymphonyElixir.LegacyGraphRunner do
  def run(issue, recipient, opts), do: send(recipient, {:legacy_dispatch, issue.id, opts[:route]})
end

defmodule SymphonyElixir.LegacyGraphTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Dependency.Graph
  alias SymphonyElixir.Tracker.Capabilities

  setup do
    previous = Application.get_env(:symphony_elixir, :github_client_module)
    Application.put_env(:symphony_elixir, :github_client_module, SymphonyElixir.LegacyGraphClient)

    on_exit(fn ->
      if previous do
        Application.put_env(:symphony_elixir, :github_client_module, previous)
      else
        Application.delete_env(:symphony_elixir, :github_client_module)
      end
    end)

    :ok
  end

  test "legacy dispatch preserves per-issue semantics without fabricating a complete graph" do
    write_provider_workflow("legacy")
    state = poll()
    assert_receive {:legacy_dispatch, "legacy-graph", %{profile_name: "legacy"}}
    assert state.running["legacy-graph"].responsibility == "implementation"
    refute Graph.complete?(state.dependency_graph)
  end

  test "routed configuration rejects providers without the capability contract" do
    assert {:error, {:routed_provider_capabilities_missing, "github", missing}} =
             write_provider_workflow("routed")

    assert missing == Capabilities.required_routed()
    refute_receive {:legacy_dispatch, _, _}
  end

  test "legacy graph exception still enforces unresolved per-issue blockers" do
    write_provider_workflow("legacy")
    Process.put(:legacy_blockers, [%{id: "other", state: "open"}])
    assert poll().running == %{}
    refute_receive {:legacy_dispatch, _, _}
  end

  defp poll do
    {:noreply, result} =
      Orchestrator.handle_info(:run_poll_cycle, %Orchestrator.State{
        poll_interval_ms: 60_000,
        max_concurrent_agents: 10,
        agent_runner: SymphonyElixir.LegacyGraphRunner
      })

    if result.tick_timer_ref, do: Process.cancel_timer(result.tick_timer_ref)
    result
  end

  defp write_provider_workflow(routing) do
    File.write!(Workflow.workflow_file_path(), """
    ---
    tracker:
      kind: github
      provider:
        repo: octo/repo
        token: test-token
      active_states: [open]
      terminal_states: [closed]
    agent:
      routing: #{routing}
    polling:
      interval_ms: 60000
    ---
    Test {{ issue.identifier }}.
    """)

    WorkflowStore.force_reload()
  end
end
