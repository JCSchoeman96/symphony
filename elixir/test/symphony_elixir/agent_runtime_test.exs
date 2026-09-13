defmodule SymphonyElixir.AgentRuntimeTestFake do
  @spec start_session(Path.t(), keyword()) :: {:ok, map()}
  def start_session(workspace, opts) do
    send(Keyword.fetch!(opts, :test_pid), {:runtime_started, workspace, opts})
    {:ok, %{session_id: "fake-session", workspace: workspace}}
  end

  @spec run_turn(map(), String.t(), map(), keyword()) :: {:ok, map()}
  def run_turn(session, prompt, issue, opts) do
    send(Keyword.fetch!(opts, :test_pid), {:runtime_turn, session, prompt, issue})
    {:ok, %{session_id: session.session_id, thread_id: "fake-thread", turn_id: "fake-turn"}}
  end

  @spec stop_session(map()) :: :ok
  def stop_session(session) do
    send(Process.get(:agent_runtime_test_pid), {:runtime_stopped, session})
    :ok
  end
end

defmodule SymphonyElixir.AgentRuntimeTest do
  use SymphonyElixir.TestSupport

  test "AgentRunner executes an injected runtime through the runtime contract" do
    test_pid = self()
    issue = %Issue{id: "runtime-contract", identifier: "SYM-RUNTIME", title: "Runtime contract", state: "In Progress"}

    Process.put(:agent_runtime_test_pid, test_pid)

    assert :ok =
             AgentRunner.run(issue, test_pid,
               runtime: SymphonyElixir.AgentRuntimeTestFake,
               test_pid: test_pid,
               max_turns: 1,
               issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end
             )

    assert_receive {:runtime_started, workspace, opts}
    assert is_binary(workspace)
    assert opts[:test_pid] == test_pid
    assert_receive {:runtime_turn, _session, _prompt, ^issue}
    assert_receive {:runtime_stopped, %{session_id: "fake-session"}}
  end
end
