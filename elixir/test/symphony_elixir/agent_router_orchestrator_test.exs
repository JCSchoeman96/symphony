defmodule SymphonyElixir.AgentRouterOrchestratorRunnerFake do
  @spec run(map(), pid() | nil, keyword()) :: :ok
  def run(issue, _recipient, opts) do
    send(Process.whereis(:symphony_agent_router_capture), {:fake_agent_run, issue, opts})
    :ok
  end
end

defmodule SymphonyElixir.AgentRouterOrchestratorTest do
  use SymphonyElixir.TestSupport

  test "orchestrator resolves and passes the selected route to a worker attempt" do
    test_pid = self()
    Process.register(test_pid, :symphony_agent_router_capture)

    issue = %Issue{
      id: "orchestrator-route",
      identifier: "SYM-ORCH-ROUTE",
      title: "Route an issue",
      state: "Planning",
      dispatchable: true
    }

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Planning"],
      poll_interval_ms: 60_000
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    orchestrator_name = Module.concat(__MODULE__, "Orchestrator#{System.unique_integer([:positive])}")

    {:ok, pid} =
      Orchestrator.start_link(
        name: orchestrator_name,
        agent_runner: SymphonyElixir.AgentRouterOrchestratorRunnerFake
      )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      if Process.whereis(:symphony_agent_router_capture) == test_pid, do: Process.unregister(:symphony_agent_router_capture)
    end)

    assert_receive {:fake_agent_run, ^issue, opts}, 1_000
    assert opts[:route].profile_name == "planner"
    assert opts[:route].runtime_name == "codex"
    assert opts[:route].responsibility == "planning"
  end
end
