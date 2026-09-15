defmodule RetryRefreshRunner do
  def run(issue, recipient, opts), do: send(recipient, {:probe_dispatch, issue.state, opts[:route].responsibility})
end

defmodule SymphonyElixir.RetryRefreshTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.AgentRuntime.AttemptPolicy

  setup do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Ready", "In Review", "Changes Requested"],
      poll_interval_ms: 60_000
    )

    :ok
  end

  defp retry_state(counters \\ AttemptPolicy.new()) do
    token = make_ref()
    issue_state = Process.get(:graph_state, "Canceled")
    blockers = Process.get(:graph_blockers, [])

    Application.put_env(
      :symphony_elixir,
      :memory_tracker_issues,
      [
        %Issue{
          id: "probe",
          identifier: "PROBE-1",
          title: "Probe",
          state: issue_state,
          blocked_by: blockers,
          dispatchable: true
        }
        | Enum.map(blockers, fn blocker ->
            %Issue{
              id: Map.fetch!(blocker, :id),
              identifier: Map.get(blocker, :identifier, Map.fetch!(blocker, :id)),
              title: "Blocker",
              state: Map.fetch!(blocker, :state),
              dispatchable: false
            }
          end)
      ]
    )

    state = %Orchestrator.State{
      poll_interval_ms: 60_000,
      max_concurrent_agents: 10,
      agent_runner: RetryRefreshRunner,
      claimed: MapSet.new(["probe"]),
      attempt_counters: %{"probe" => counters},
      retry_attempts: %{
        "probe" => %{
          attempt: 1,
          retry_token: token,
          responsibility: "review",
          profile_name: "reviewer",
          delay_type: :continuation
        }
      }
    }

    {state, token}
  end

  test "retry rejects terminal issue discovered in final graph refresh" do
    {state, token} = retry_state()
    {:noreply, result} = Orchestrator.handle_info({:retry_issue, "probe", token}, state)
    assert result.running == %{}
    refute MapSet.member?(result.claimed, "probe")
    refute_receive {:probe_dispatch, _, _}
  end

  test "retry resolves role from final graph issue" do
    Process.put(:graph_state, "In Review")
    {state, token} = retry_state()
    {:noreply, _} = Orchestrator.handle_info({:retry_issue, "probe", token}, state)
    assert_receive {:probe_dispatch, "In Review", "review"}
  end

  test "review cycle limit applies to transitions during retry wait" do
    Process.put(:lookup_state, "Changes Requested")
    Process.put(:graph_state, "Changes Requested")
    {state, token} = retry_state(%{AttemptPolicy.new() | review_cycles: 3})
    {:noreply, result} = Orchestrator.handle_info({:retry_issue, "probe", token}, state)
    refute_receive {:probe_dispatch, _, _}
    assert result.attempt_counters["probe"].review_cycles == 3
    assert result.blocked["probe"].termination_reason == :review_cycle_exhausted
  end

  test "dependency denial cannot discard an exhausted review cycle" do
    Process.put(:lookup_state, "Changes Requested")
    Process.put(:graph_state, "Changes Requested")
    Process.put(:graph_blockers, [%{id: "blocker", state: "Ready"}])
    {state, token} = retry_state(%{AttemptPolicy.new() | review_cycles: 3})
    {:noreply, result} = Orchestrator.handle_info({:retry_issue, "probe", token}, state)
    assert result.blocked["probe"].termination_reason == :review_cycle_exhausted
    assert MapSet.member?(result.claimed, "probe")
    refute_receive {:probe_dispatch, _, _}
  end
end
