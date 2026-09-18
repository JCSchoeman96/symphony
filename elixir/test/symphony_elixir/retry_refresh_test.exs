defmodule RetryRefreshRunner do
  def run(issue, recipient, opts), do: send(recipient, {:probe_dispatch, issue.state, opts[:route].responsibility})
end

defmodule SymphonyElixir.RetryRefreshTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.AgentRuntime.AttemptPolicy
  alias SymphonyElixir.Dependency.Graph
  alias SymphonyElixir.WorkControl.{GuardClass, WorkItem}

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

    issues = [
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

    Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)

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
      },
      dependency_graph: Graph.build(issues),
      work_control: trusted_work_control(issues)
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

  test "routed retry refreshes cancellation before discarding stale completion evidence" do
    {state, token} = retry_state()

    completed_issue = %Issue{id: "probe", identifier: "PROBE-1", title: "Probe", state: "Done"}

    {:ok, completed_work_item} =
      WorkItem.from_issue(completed_issue, %{
        provider: :memory,
        prior_validated_lifecycle_state: :merging,
        evidence: [GuardClass.requirement(:mechanical_guard, :completion_proof_verified)]
      })

    state = %{state | work_control: %{"probe" => completed_work_item}}

    {:noreply, result} = Orchestrator.handle_info({:retry_issue, "probe", token}, state)

    assert result.work_control["probe"].lifecycle_assessment.status == :authority_reducing
    assert result.work_control["probe"].validated_lifecycle_state == :canceled
    refute WorkItem.dependency_satisfying?(result.work_control["probe"])
  end

  test "retry resolves role from final graph issue" do
    Process.put(:graph_state, "In Review")
    {state, token} = retry_state()
    {:noreply, _} = Orchestrator.handle_info({:retry_issue, "probe", token}, state)
    assert_receive {:probe_dispatch, "In Review", "review"}
  end

  test "routed retry suspends instead of retrying an unvalidated forward observation" do
    Process.put(:graph_state, "Ready")
    {state, token} = retry_state()
    state = %{state | work_control: %{}}

    {:noreply, result} = Orchestrator.handle_info({:retry_issue, "probe", token}, state)

    refute_receive {:probe_dispatch, _, _}
    assert result.blocked["probe"].error =~ "routed lifecycle authority suspended"
    assert result.work_control["probe"].lifecycle_assessment.status == :validation_required
    refute Map.has_key?(result.retry_attempts, "probe")
  end

  test "routed retry releases a claim when the provider removes its routing label" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_required_labels: ["symphony"]
    )

    Process.put(:graph_state, "Ready")
    {state, token} = retry_state()

    {:noreply, result} = Orchestrator.handle_info({:retry_issue, "probe", token}, state)

    refute MapSet.member?(result.claimed, "probe")
    refute Map.has_key?(result.retry_attempts, "probe")
  end

  test "retry releases its claim when the provider no longer returns the issue" do
    {state, token} = retry_state()
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    {:noreply, result} = Orchestrator.handle_info({:retry_issue, "probe", token}, state)

    refute MapSet.member?(result.claimed, "probe")
    refute Map.has_key?(result.retry_attempts, "probe")
  end

  test "routed retry suspends when a trusted lifecycle state is contradicted" do
    Process.put(:graph_state, "In Review")
    {state, token} = retry_state()

    prior_issue = %Issue{
      id: "probe",
      identifier: "PROBE-1",
      title: "Probe",
      state: "Ready",
      dispatchable: true
    }

    state = %{state | work_control: %{"probe" => trusted_work_item(prior_issue)}}

    {:noreply, result} = Orchestrator.handle_info({:retry_issue, "probe", token}, state)

    refute_receive {:probe_dispatch, _, _}
    assert result.blocked["probe"].error =~ "routed lifecycle authority suspended"
    assert result.work_control["probe"].lifecycle_assessment.status == :invalid
    refute Map.has_key?(result.retry_attempts, "probe")
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

  defp trusted_work_control(issues) do
    Map.new(issues, fn issue -> {issue.id, trusted_work_item(issue)} end)
  end

  defp trusted_work_item(%Issue{} = issue) do
    {:ok, work_item} =
      WorkItem.from_issue(issue, %{
        provider: :memory,
        prior_validated_lifecycle_state: issue.state
      })

    work_item
  end
end
