defmodule SymphonyElixir.ObservabilityContractTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentRuntime.Router
  alias SymphonyElixir.Dependency.Graph
  alias SymphonyElixirWeb.Presenter

  defmodule StaticOrchestrator do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
    end

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def handle_call(:snapshot, _from, state), do: {:reply, Keyword.fetch!(state, :snapshot), state}

    @impl true
    def handle_call(:request_refresh, _from, state), do: {:reply, :unavailable, state}
  end

  test "snapshot exposes route safety, counters, completeness, and bounded history" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    issue = %Issue{
      id: "issue-observability",
      identifier: "SYM-OBS",
      title: "Observability contract",
      state: "In Progress",
      url: "https://example.org/issues/SYM-OBS"
    }

    assert {:ok, route} = Router.resolve(issue, Config.settings!().agent.profiles)

    counters = %{
      ordinary_failures: 2,
      ordinary_retries: 2,
      review_cycles: 1,
      capacity_waits: 3,
      continuations: 1,
      route_changes: 2
    }

    now = DateTime.utc_now()

    running_entry = %{
      pid: nil,
      ref: nil,
      identifier: issue.identifier,
      issue: issue,
      route: route,
      profile_name: route.profile_name,
      runtime_name: route.runtime_name,
      responsibility: route.responsibility,
      route_fingerprint: route.fingerprint,
      worker_host: "worker-a",
      workspace_path: "/workspaces/SYM-OBS",
      session_id: "session-observability",
      codex_app_server_pid: nil,
      codex_input_tokens: 4,
      codex_output_tokens: 5,
      codex_total_tokens: 9,
      turn_count: 2,
      started_at: now,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil
    }

    recent_attempts =
      Enum.map(1..25, fn index ->
        %{
          issue_id: issue.id,
          identifier: issue.identifier,
          issue_url: issue.url,
          termination_reason: if(index == 1, do: :normal_completion, else: :route_changed),
          attempt: index,
          at: now,
          error: nil
        }
      end)

    state = %Orchestrator.State{
      running: %{issue.id => running_entry},
      claimed: MapSet.new([issue.id]),
      attempt_counters: %{issue.id => counters},
      dependency_graph: Graph.unavailable(:provider_timeout),
      dependency_diagnostics: %{
        issue.id => %{
          issue_id: issue.id,
          identifier: issue.identifier,
          responsibility: route.responsibility,
          dependency_status: :complete,
          reason: :allowed,
          allowed?: true
        }
      },
      recent_attempts: recent_attempts,
      codex_totals: %{input_tokens: 4, output_tokens: 5, total_tokens: 9, seconds_running: 2}
    }

    {:reply, snapshot, _state} = Orchestrator.handle_call(:snapshot, {self(), make_ref()}, state)
    [entry] = snapshot.running

    assert entry.sandbox == "workspace-write"
    assert entry.profile_name == "builder"
    assert entry.responsibility == "implementation"
    assert entry.session_id == "session-observability"
    assert entry.workspace_path == "/workspaces/SYM-OBS"
    assert entry.attempt_counters == counters
    assert entry.dependency_completeness == {:unavailable, :provider_timeout}
    assert entry.termination_reason == nil
    assert snapshot.dependency_graph.completeness == {:unavailable, :provider_timeout}
    assert length(snapshot.recent_attempts) == 20
    assert hd(snapshot.recent_attempts).attempt == 1
    assert List.last(snapshot.recent_attempts).attempt == 20
  end

  test "normal completion leaves a classified history entry after running disappears" do
    issue = %Issue{
      id: "issue-normal-history",
      identifier: "SYM-NORMAL",
      title: "Normal history",
      state: "In Progress",
      url: "https://example.org/issues/SYM-NORMAL"
    }

    ref = make_ref()

    state = %Orchestrator.State{
      running: %{
        issue.id => %{
          pid: nil,
          ref: ref,
          identifier: issue.identifier,
          issue: issue,
          session_id: "session-normal",
          turn_count: 1,
          last_codex_message: nil,
          last_codex_timestamp: nil,
          last_codex_event: :turn_completed,
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue.id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    {:noreply, updated_state} =
      Orchestrator.handle_info({:DOWN, ref, :process, self(), :normal}, state)

    on_exit(fn ->
      case updated_state.retry_attempts[issue.id] do
        %{timer_ref: timer_ref} when is_reference(timer_ref) -> Process.cancel_timer(timer_ref)
        _ -> :ok
      end
    end)

    refute Map.has_key?(updated_state.running, issue.id)
    assert updated_state.retry_attempts[issue.id].delay_type == :continuation

    assert [%{issue_id: "issue-normal-history", termination_reason: :normal_completion}] =
             updated_state.recent_attempts
  end

  test "dependency stop is represented as dependency blocked, not a generic failure" do
    issue = %Issue{
      id: "issue-dependency-history",
      identifier: "SYM-DEPENDENCY",
      title: "Dependency history",
      state: "In Progress",
      url: "https://example.org/issues/SYM-DEPENDENCY"
    }

    decision = %{
      issue_id: issue.id,
      identifier: issue.identifier,
      responsibility: "implementation",
      dependency_status: :unresolved,
      reason: :unresolved_hard_dependency,
      allowed?: false,
      unresolved_blockers: [%{id: "blocker", identifier: "SYM-BLOCKER", state: "In Progress"}]
    }

    state = %Orchestrator.State{
      running: %{
        issue.id => %{
          pid: nil,
          ref: nil,
          identifier: issue.identifier,
          issue: issue,
          profile_name: "builder",
          runtime_name: "codex",
          responsibility: "implementation",
          sandbox: "workspace-write",
          session_id: "session-dependency",
          last_codex_message: nil,
          last_codex_timestamp: nil,
          last_codex_event: nil,
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue.id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    {:noreply, updated_state} =
      Orchestrator.handle_info({:agent_dependency_blocked, issue.id, decision}, state)

    assert updated_state.blocked[issue.id].termination_reason == :dependency_blocked
    assert [%{termination_reason: :dependency_blocked}] = updated_state.recent_attempts
  end

  test "terminal retry reconciliation leaves terminal history and resets counters" do
    issue = %Issue{
      id: "issue-terminal-history",
      identifier: "SYM-TERMINAL",
      title: "Terminal history",
      state: "Done",
      url: "https://example.org/issues/SYM-TERMINAL"
    }

    state = %Orchestrator.State{
      attempt_counters: %{
        issue.id => %{
          ordinary_failures: 2,
          ordinary_retries: 2,
          review_cycles: 1,
          capacity_waits: 1,
          continuations: 0,
          route_changes: 0
        }
      },
      retry_attempts: %{
        issue.id => %{
          attempt: 2,
          identifier: issue.identifier,
          issue_url: issue.url,
          error: "agent exited: :boom",
          sandbox: "workspace-write"
        }
      },
      claimed: MapSet.new([issue.id])
    }

    updated_state =
      Orchestrator.handle_retry_issue_lookup_for_test(
        issue,
        state,
        issue.id,
        2,
        %{identifier: issue.identifier, issue_url: issue.url, sandbox: "workspace-write"}
      )

    assert [%{termination_reason: :terminal, issue_id: "issue-terminal-history"}] =
             updated_state.recent_attempts

    assert updated_state.attempt_counters == %{}
  end

  test "ordinary retry exhaustion is visible as a retry-exhausted blocked reason" do
    issue = %Issue{
      id: "issue-retry-history",
      identifier: "SYM-RETRY-HISTORY",
      title: "Retry history",
      state: "In Progress",
      url: "https://example.org/issues/SYM-RETRY-HISTORY"
    }

    state = %Orchestrator.State{
      claimed: MapSet.new([issue.id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    updated_state =
      Enum.reduce(1..4, state, fn _index, state ->
        ref = make_ref()

        state =
          Map.put(state, :running, %{
            issue.id => %{
              pid: nil,
              ref: ref,
              identifier: issue.identifier,
              issue: issue,
              session_id: "session-retry-history",
              last_codex_message: nil,
              last_codex_timestamp: nil,
              last_codex_event: nil,
              started_at: DateTime.utc_now()
            }
          })

        {:noreply, state} =
          Orchestrator.handle_info({:DOWN, ref, :process, self(), :boom}, state)

        state
      end)

    on_exit(fn ->
      case updated_state.retry_attempts[issue.id] do
        %{timer_ref: timer_ref} when is_reference(timer_ref) -> Process.cancel_timer(timer_ref)
        _ -> :ok
      end
    end)

    assert updated_state.blocked[issue.id].termination_reason == :retry_exhausted
    assert [%{termination_reason: :retry_exhausted} | _rest] = updated_state.recent_attempts
  end

  test "orchestrator snapshot redacts runtime messages and errors before they leave state" do
    secret = "snapshot-secret-456"
    issue = %Issue{id: "issue-redacted", identifier: "SYM-REDACTED", state: "In Progress"}

    message = %{
      event: :notification,
      message: %{
        "method" => "item/commandExecution/requestApproval",
        "params" => %{
          "parsedCmd" => "mix test --trace token=#{secret}",
          "environment" => %{"API_KEY" => secret}
        },
        "raw_graphql" => "query Issue { id } #{secret}"
      },
      timestamp: DateTime.utc_now()
    }

    state = %Orchestrator.State{
      running: %{
        issue.id => %{
          pid: nil,
          ref: nil,
          identifier: issue.identifier,
          issue: issue,
          session_id: "session-redacted",
          last_codex_message: message,
          last_codex_timestamp: message.timestamp,
          last_codex_event: "run command token=#{secret}",
          codex_input_tokens: 0,
          codex_output_tokens: 0,
          codex_total_tokens: 0,
          started_at: message.timestamp
        }
      },
      retry_attempts: %{
        "issue-retry-redacted" => %{
          attempt: 1,
          due_at_ms: System.monotonic_time(:millisecond) + 1_000,
          identifier: "SYM-RETRY-REDACTED",
          error: "raw GraphQL provider response #{secret}"
        }
      },
      codex_rate_limits: %{
        "limit_id" => "codex",
        "primary" => %{"remaining" => 10, "limit" => 20},
        "raw_provider_field" => secret
      },
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    {:reply, snapshot, _state} = Orchestrator.handle_call(:snapshot, {self(), make_ref()}, state)

    refute inspect(snapshot) =~ secret
    refute inspect(snapshot) =~ "parsedCmd"
    refute inspect(snapshot) =~ "API_KEY"
    refute inspect(snapshot) =~ "raw_graphql"
    refute inspect(snapshot) =~ "run command"
    refute inspect(snapshot) =~ "raw_provider_field"
    assert snapshot.running |> hd() |> Map.fetch!(:last_codex_event) == "[redacted]"
    assert snapshot.rate_limits == %{"limit_id" => "codex", "primary" => %{"remaining" => 10, "limit" => 20}}
    assert snapshot.running |> hd() |> Map.fetch!(:last_codex_message) |> inspect() =~ "redacted"
    assert snapshot.retrying |> hd() |> Map.fetch!(:error) == "runtime error details redacted"
  end

  test "presenter exposes observability fields and redacts unsafe provider data" do
    secret = "super-secret-token-123"
    server = Module.concat(__MODULE__, :RedactionOrchestrator)

    sensitive_message = %{
      event: :notification,
      message: %{
        "method" => "item/commandExecution/requestApproval",
        "params" => %{
          "parsedCmd" => "curl https://example.org?token=#{secret}",
          "environment" => %{"LINEAR_API_KEY" => secret}
        },
        "raw_graphql" => "query Issue { id } #{secret}"
      },
      timestamp: DateTime.utc_now()
    }

    snapshot = %{
      running: [
        %{
          issue_id: "issue-presenter",
          identifier: "SYM-PRESENTER",
          issue_url: "https://example.org/issues/SYM-PRESENTER",
          state: "In Progress",
          worker_host: "worker-b",
          workspace_path: "/workspaces/SYM-PRESENTER",
          session_id: "session-presenter",
          turn_count: 3,
          last_codex_message: sensitive_message,
          last_codex_timestamp: DateTime.utc_now(),
          codex_input_tokens: 1,
          codex_output_tokens: 2,
          codex_total_tokens: 3,
          started_at: DateTime.utc_now(),
          profile_name: "builder",
          runtime_name: "codex",
          responsibility: "implementation",
          sandbox: "workspace-write",
          last_codex_event: "run command token=#{secret}",
          route_change: %{
            previous: %{profile_name: "reviewer", command: "git push token=#{secret}"},
            next: %{profile_name: "builder", raw_graphql: secret}
          },
          attempt_counters: %{
            ordinary_failures: 1,
            ordinary_retries: 1,
            review_cycles: 0,
            capacity_waits: 2,
            continuations: 1,
            route_changes: 0
          },
          dependency_completeness: :complete,
          termination_reason: nil
        }
      ],
      retrying: [
        %{
          issue_id: "issue-retry-presenter",
          identifier: "SYM-RETRY-PRESENTER",
          issue_url: "https://example.org/issues/SYM-RETRY-PRESENTER",
          attempt: 3,
          due_in_ms: 1_000,
          error: "raw provider GraphQL response: #{secret}",
          session_id: "session-retry",
          sandbox: "workspace-write",
          termination_reason: :runtime_unavailable,
          attempt_counters: %{ordinary_failures: 2}
        }
      ],
      blocked: [
        %{
          issue_id: "issue-blocked-presenter",
          identifier: "SYM-BLOCKED-PRESENTER",
          issue_url: "https://example.org/issues/SYM-BLOCKED-PRESENTER",
          state: "In Progress",
          error: "provider error #{secret}",
          session_id: "session-blocked",
          blocked_at: DateTime.utc_now(),
          last_codex_event: :notification,
          last_codex_message: sensitive_message,
          last_codex_timestamp: DateTime.utc_now(),
          sandbox: "workspace-write",
          termination_reason: :retry_exhausted,
          attempt_counters: %{ordinary_failures: 3}
        }
      ],
      recent_attempts: [
        %{
          issue_id: "issue-presenter",
          identifier: "SYM-PRESENTER",
          termination_reason: :capacity_wait,
          error: "no available orchestrator slots",
          at: DateTime.utc_now(),
          attempt_counters: %{capacity_waits: 2},
          sandbox: "workspace-write"
        }
      ],
      dependency_diagnostics: [
        %{
          issue_id: "issue-presenter",
          identifier: "SYM-PRESENTER",
          allowed?: true,
          reason: :planning_allowed_with_unresolved_dependencies,
          diagnostic: {:provider_error, secret}
        }
      ],
      dependency_graph: %{
        completeness: {:unavailable, secret},
        cycles: [[secret]],
        diagnostics: [%{kind: :provider_error, blocker: %{id: secret}}]
      },
      codex_totals: %{input_tokens: 3, output_tokens: 2, total_tokens: 5, seconds_running: 1},
      rate_limits: nil
    }

    {:ok, _pid} = StaticOrchestrator.start_link(name: server, snapshot: snapshot)
    payload = Presenter.state_payload(server, 50)

    [running] = payload.running
    assert running.sandbox == "workspace-write"
    assert running.attempt_counters.capacity_waits == 2
    assert running.dependency_completeness == :complete
    assert payload.retrying |> hd() |> Map.fetch!(:termination_reason) == :runtime_unavailable
    assert payload.recent_attempts |> hd() |> Map.fetch!(:termination_reason) == :capacity_wait
    assert payload.dependency_graph.completeness == {:unavailable, :redacted}
    assert payload.running |> hd() |> Map.fetch!(:last_message) == "codex event details redacted"
    assert payload.running |> hd() |> Map.fetch!(:last_event) == "[redacted]"
    refute inspect(payload) =~ "git push"
    refute inspect(payload) =~ secret
    refute inspect(payload) =~ "curl"
    refute inspect(payload) =~ "raw_graphql"
    refute inspect(payload) =~ "LINEAR_API_KEY"
  end

  test "presenter does not label an allowed dependency observation as blocked" do
    server = Module.concat(__MODULE__, :AllowedDependencyOrchestrator)

    snapshot = %{
      running: [],
      retrying: [],
      blocked: [],
      dependency_diagnostics: [
        %{
          issue_id: "issue-observed",
          identifier: "SYM-OBSERVED",
          allowed?: true,
          reason: :planning_allowed_with_unresolved_dependencies
        }
      ],
      recent_attempts: [],
      dependency_graph: %{completeness: :complete, cycles: [], diagnostics: []},
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      rate_limits: nil
    }

    {:ok, _pid} = StaticOrchestrator.start_link(name: server, snapshot: snapshot)

    assert {:ok, payload} = Presenter.issue_payload("SYM-OBSERVED", server, 50)
    assert payload.status == "observed"
    assert payload.status_reason == :observed
    refute payload.status == "dependency_blocked"
  end

  test "dashboard renders safe reason and sandbox fields for retry history" do
    content =
      StatusDashboard.format_snapshot_content_for_test(
        {:ok,
         %{
           running: [
             %{
               identifier: "SYM-DASH-OBS",
               state: "In Progress",
               profile_name: "builder",
               sandbox: "workspace-write",
               responsibility: "implementation",
               session_id: "session-dashboard",
               codex_app_server_pid: nil,
               codex_total_tokens: 0,
               runtime_seconds: 0,
               turn_count: 1,
               last_codex_event: nil,
               last_codex_message: nil
             }
           ],
           retrying: [
             %{
               issue_id: "issue-capacity",
               identifier: "SYM-CAPACITY",
               attempt: 2,
               due_in_ms: 1_000,
               error: "no available orchestrator slots",
               termination_reason: :capacity_wait,
               sandbox: "workspace-write"
             }
           ],
           blocked: [
             %{
               issue_id: "issue-blocked",
               identifier: "SYM-BLOCKED-OBS",
               state: "In Progress",
               error: "automatic retry limit reached",
               termination_reason: :retry_exhausted,
               sandbox: "workspace-write"
             }
           ],
           recent_attempts: [
             %{
               issue_id: "issue-capacity",
               identifier: "SYM-CAPACITY",
               attempt: 2,
               termination_reason: :capacity_wait,
               sandbox: "workspace-write",
               error: "no available orchestrator slots"
             }
           ],
           codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
           rate_limits: nil
         }},
        0.0,
        115
      )

    assert content =~ "sandbox=workspace-write"
    assert content =~ "reason=capacity_wait"
    assert content =~ "reason=retry_exhausted"
    assert content =~ "Recent attempt history"
  end
end
