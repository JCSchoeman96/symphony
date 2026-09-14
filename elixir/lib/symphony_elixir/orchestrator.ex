defmodule SymphonyElixir.Orchestrator do
  @moduledoc """
  Polls the configured issue tracker and dispatches repository copies to Codex-backed workers.
  """

  use GenServer
  require Logger
  import Bitwise, only: [<<<: 2]

  alias SymphonyElixir.{AgentRunner, Config, StatusDashboard, Tracker, Workspace}
  alias SymphonyElixir.AgentRuntime.{AttemptLedger, AttemptPolicy, Route, Router}
  alias SymphonyElixir.Dependency.{Graph, Guard}
  alias SymphonyElixir.Tracker.Issue

  @continuation_retry_delay_ms 1_000
  @failure_retry_base_ms 10_000
  @durable_attempt_events [:ordinary_failure, :review_cycle, :ci_failure]
  @recent_attempt_limit 20
  @observability_text_limit 240
  @observability_rate_limit_keys ["limit_id", "limit_name", "primary", "secondary", "credits"]
  @observability_rate_bucket_keys [
    "remaining",
    "limit",
    "reset_in_seconds",
    "resetinseconds",
    "reset_at",
    "resetat",
    "resets_at",
    "resetsat",
    "usedpercent",
    "windowdurationmins"
  ]
  @observability_rate_credit_keys ["has_credits", "unlimited", "balance"]
  @blocked_termination_rules [
    {"review cycle limit", :review_cycle_exhausted},
    {"retry limit", :retry_exhausted},
    {"CI retry", :ci_retry_disabled},
    {"runtime", :runtime_unavailable},
    {"operator input", :operator_input_required},
    {"approval", :operator_approval_required}
  ]
  @observability_termination_reasons [
    :normal_completion,
    :route_changed,
    :dependency_blocked,
    :retry_exhausted,
    :review_cycle_exhausted,
    :ci_retry_disabled,
    :capacity_wait,
    :runtime_failure,
    :runtime_unavailable,
    :runtime_stalled,
    :operator_input_required,
    :operator_approval_required,
    :terminal,
    :shutdown,
    :not_routable,
    :non_active,
    :tracker_missing,
    :blocked,
    :invalid_attempt,
    :observed
  ]
  # Slightly above the dashboard render interval so "checking now…" can render.
  @poll_transition_render_delay_ms 20
  @empty_codex_totals %{
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0
  }

  defmodule State do
    @moduledoc """
    Runtime state for the orchestrator polling loop.
    """

    @type t :: %__MODULE__{}

    defstruct [
      :poll_interval_ms,
      :max_concurrent_agents,
      :next_poll_due_at_ms,
      :poll_check_in_progress,
      :tick_timer_ref,
      :tick_token,
      task_supervisor: SymphonyElixir.TaskSupervisor,
      agent_runner: AgentRunner,
      running: %{},
      completed: MapSet.new(),
      claimed: MapSet.new(),
      blocked: %{},
      dependency_graph: %Graph{},
      dependency_diagnostics: %{},
      retry_attempts: %{},
      attempt_counters: %{},
      attempt_ledger: nil,
      attempt_ledger_status: :disabled,
      attempt_ledger_opts: [],
      durable_exhausted: %{},
      recent_attempts: [],
      codex_totals: nil,
      codex_rate_limits: nil
    ]
  end

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    case Config.settings() do
      {:ok, config} ->
        now_ms = System.monotonic_time(:millisecond)

        state = %State{
          poll_interval_ms: config.polling.interval_ms,
          max_concurrent_agents: config.agent.max_concurrent_agents,
          next_poll_due_at_ms: now_ms,
          poll_check_in_progress: false,
          tick_timer_ref: nil,
          tick_token: nil,
          task_supervisor: Keyword.get(opts, :task_supervisor, SymphonyElixir.TaskSupervisor),
          agent_runner: Keyword.get(opts, :agent_runner, AgentRunner),
          codex_totals: @empty_codex_totals,
          codex_rate_limits: nil
        }

        state = initialize_attempt_ledger(state, config, opts)

        if autonomous_dispatch_allowed?(state) do
          run_terminal_workspace_cleanup()
        else
          Logger.error("Autonomous dispatch is held: #{inspect(ledger_block_reason(state))}")
        end

        state = schedule_tick(state, 0)

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, %State{attempt_ledger: nil}), do: :ok

  def terminate(_reason, %State{attempt_ledger: ledger}) do
    case AttemptLedger.close(ledger) do
      :ok -> :ok
      {:error, reason} -> Logger.error("Failed to close attempt ledger: #{inspect(reason)}")
    end

    :ok
  end

  defp initialize_attempt_ledger(%State{} = state, %{agent: %{routing: "legacy"}}, _opts) do
    %{state | attempt_ledger_status: :disabled, attempt_ledger_opts: []}
  end

  defp initialize_attempt_ledger(%State{} = state, config, opts) do
    project_id = config.symphony.project_id
    tracker_identity = Tracker.identity(config.tracker)
    ledger_opts = Keyword.get(opts, :attempt_ledger_opts, [])

    case AttemptLedger.open(project_id, tracker_identity, ledger_opts) do
      {:ok, ledger} ->
        case reconcile_attempt_ledger(state, ledger) do
          {:ok, state} ->
            %{
              state
              | attempt_ledger: ledger,
                attempt_ledger_status: :ready,
                attempt_ledger_opts: ledger_opts
            }

          {:blocked, state, reason} ->
            %{
              state
              | attempt_ledger: ledger,
                attempt_ledger_status: {:blocked, reason},
                attempt_ledger_opts: ledger_opts
            }
        end

      {:error, reason} ->
        %{
          state
          | attempt_ledger_status: {:blocked, {:attempt_ledger_unavailable, reason}},
            attempt_ledger_opts: ledger_opts
        }
    end
  end

  defp reconcile_attempt_ledger(%State{} = state, %AttemptLedger{} = ledger) do
    case AttemptLedger.open_lineages(ledger) do
      {:ok, records} ->
        state = restore_durable_lineages(state, records)
        issue_ids = Enum.map(records, & &1.issue_id)

        if issue_ids == [] do
          {:ok, state}
        else
          reconcile_durable_issue_states(state, ledger, records, issue_ids)
        end

      {:error, reason} ->
        {:blocked, state, {:attempt_ledger_unavailable, reason}}
    end
  end

  defp restore_durable_lineages(%State{} = state, records) when is_list(records) do
    Enum.reduce(records, state, fn record, state_acc ->
      counters = Map.merge(AttemptPolicy.new(), record.safety_counters)

      state_acc = %{
        state_acc
        | attempt_counters: Map.put(state_acc.attempt_counters, record.issue_id, counters)
      }

      if record.status == :exhausted do
        %{state_acc | durable_exhausted: Map.put(state_acc.durable_exhausted, record.issue_id, record)}
      else
        state_acc
      end
    end)
  end

  defp reconcile_durable_issue_states(%State{} = state, ledger, records, issue_ids) do
    case Tracker.fetch_issues_by_ids(issue_ids) do
      {:ok, issues} when is_list(issues) ->
        case durable_issue_map(issues) do
          {:ok, issues_by_id} ->
            reconcile_fetched_durable_issue_states(state, ledger, records, issues_by_id)

          :error ->
            {:blocked, state, {:attempt_ledger_tracker_unavailable, :invalid_issue_collection}}
        end

      {:error, reason} ->
        {:blocked, state, {:attempt_ledger_tracker_unavailable, reason}}
    end
  end

  defp durable_issue_map(issues) do
    case Enum.reduce_while(issues, %{}, fn
           %Issue{id: issue_id} = issue, issues_by_id when is_binary(issue_id) ->
             {:cont, Map.put(issues_by_id, issue_id, issue)}

           _issue, _issues_by_id ->
             {:halt, :error}
         end) do
      :error -> :error
      issues_by_id -> {:ok, issues_by_id}
    end
  end

  defp reconcile_fetched_durable_issue_states(state, ledger, records, issues_by_id) do
    result =
      Enum.reduce(records, {state, [], []}, fn record, acc ->
        reconcile_durable_record(record, issues_by_id, ledger, acc)
      end)

    finish_durable_reconciliation(result)
  end

  defp reconcile_durable_record(record, issues_by_id, ledger, {state, missing, errors}) do
    case Map.get(issues_by_id, record.issue_id) do
      nil ->
        {state, [record.issue_id | missing], errors}

      %Issue{} = issue ->
        reconcile_visible_durable_record(issue, ledger, {state, missing, errors})
    end
  end

  defp reconcile_visible_durable_record(%Issue{} = issue, ledger, {state, missing, errors}) do
    if terminal_issue_state?(issue.state, terminal_state_set()) do
      case AttemptLedger.close_lineage(ledger, issue.id, reason: :terminal) do
        :ok -> {reset_durable_lineage(state, issue.id), missing, errors}
        {:error, reason} -> {state, missing, [{issue.id, reason} | errors]}
      end
    else
      {state, missing, errors}
    end
  end

  defp finish_durable_reconciliation({state, [], []}), do: {:ok, state}

  defp finish_durable_reconciliation({state, _missing, close_errors}) when close_errors != [] do
    {:blocked, state, {:attempt_ledger_close_failed, Enum.reverse(close_errors)}}
  end

  defp finish_durable_reconciliation({state, missing, []}) do
    {:blocked, state, {:attempt_ledger_issue_missing, Enum.sort(missing)}}
  end

  defp reset_durable_lineage(%State{} = state, issue_id) do
    %{
      state
      | attempt_counters: Map.delete(state.attempt_counters, issue_id),
        durable_exhausted: Map.delete(state.durable_exhausted, issue_id)
    }
  end

  defp autonomous_dispatch_allowed?(%State{attempt_ledger_status: {:blocked, _reason}}), do: false
  defp autonomous_dispatch_allowed?(%State{}), do: true

  defp ledger_block_reason(%State{attempt_ledger_status: {:blocked, reason}}), do: reason
  defp ledger_block_reason(_state), do: nil

  @impl true
  def handle_info({:tick, tick_token}, %{tick_token: tick_token} = state)
      when is_reference(tick_token) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info({:tick, _tick_token}, state), do: {:noreply, state}

  def handle_info(:tick, state) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info(:run_poll_cycle, state) do
    state = refresh_runtime_config(state)
    state = maybe_dispatch(state)
    state = schedule_tick(state, state.poll_interval_ms)
    state = %{state | poll_check_in_progress: false}

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{running: running} = state
      ) do
    case find_issue_id_for_ref(running, ref) do
      nil ->
        {:noreply, state}

      issue_id ->
        {running_entry, state} = pop_running_entry(state, issue_id)
        state = record_session_completion_totals(state, running_entry)
        session_id = running_entry_session_id(running_entry)

        state = handle_agent_down(reason, state, issue_id, running_entry, session_id)

        Logger.info("Agent task finished for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}")

        notify_dashboard()
        {:noreply, state}
    end
  end

  def handle_info({:worker_runtime_info, issue_id, runtime_info}, %{running: running} = state)
      when is_binary(issue_id) and is_map(runtime_info) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        updated_running_entry =
          running_entry
          |> maybe_put_runtime_value(:worker_host, runtime_info[:worker_host])
          |> maybe_put_runtime_value(:workspace_path, runtime_info[:workspace_path])

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  def handle_info(
        {:agent_route_changed, issue_id, %Route{} = previous_route, %Route{} = next_route},
        %{running: running} = state
      )
      when is_binary(issue_id) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        Logger.info(
          "Agent route changed for issue_id=#{issue_id}; ending worker attempt " <>
            "previous=#{previous_route.profile_name}/#{previous_route.responsibility} " <>
            "next=#{next_route.profile_name}/#{next_route.responsibility}"
        )

        updated_running_entry =
          Map.merge(running_entry, %{
            route_change_termination: true,
            route_change: route_change_metadata(previous_route, next_route)
          })

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  def handle_info(
        {:agent_dependency_blocked, issue_id, decision},
        %{running: running} = state
      )
      when is_binary(issue_id) and is_map(decision) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        error = dependency_blocker_error(decision)

        Logger.warning(
          "Agent dependency guard stopped issue_id=#{issue_id} " <>
            "issue_identifier=#{running_entry.identifier}: #{error}"
        )

        stop_running_task(
          Map.get(running_entry, :pid),
          Map.get(running_entry, :ref),
          state.task_supervisor
        )

        state = block_issue_from_entry(state, issue_id, running_entry, error, decision)
        notify_dashboard()
        {:noreply, state}
    end
  end

  def handle_info(
        {:codex_worker_update, issue_id, %{event: _, timestamp: _} = update},
        %{running: running} = state
      ) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        {updated_running_entry, token_delta} = integrate_codex_update(running_entry, update)

        state =
          state
          |> apply_codex_token_delta(token_delta)
          |> apply_codex_rate_limits(update)

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  def handle_info({:codex_worker_update, _issue_id, _update}, state), do: {:noreply, state}

  def handle_info({:retry_issue, issue_id, retry_token}, state) do
    result =
      case pop_retry_attempt_state(state, issue_id, retry_token) do
        {:ok, attempt, metadata, state} -> handle_retry_issue(state, issue_id, attempt, metadata)
        :missing -> {:noreply, state}
      end

    notify_dashboard()
    result
  end

  def handle_info({:retry_issue, _issue_id}, state), do: {:noreply, state}

  def handle_info(msg, state) do
    Logger.debug("Orchestrator ignored message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp handle_agent_down(:normal, state, issue_id, running_entry, session_id) do
    cond do
      input_required_blocker?(running_entry) ->
        block_input_required_agent_down(state, issue_id, running_entry, session_id, :normal)

      Map.get(running_entry, :route_change_termination, false) ->
        Logger.info("Agent task ended after route change for issue_id=#{issue_id} session_id=#{session_id}; scheduling fresh route dispatch")

        handle_normal_route_change(state, issue_id, running_entry)

      true ->
        Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; scheduling active-state continuation check")

        handle_normal_continuation(state, issue_id, running_entry)
    end
  end

  defp handle_agent_down(reason, state, issue_id, running_entry, session_id) do
    if input_required_blocker?(running_entry) do
      block_input_required_agent_down(state, issue_id, running_entry, session_id, reason)
    else
      retry_agent_down(state, issue_id, running_entry, session_id, reason)
    end
  end

  defp block_input_required_agent_down(state, issue_id, running_entry, session_id, reason) do
    error = blocker_error(running_entry, "agent exited: #{inspect(reason)}")

    Logger.warning("Agent task blocked for issue_id=#{issue_id} issue_identifier=#{running_entry.identifier} session_id=#{session_id}: #{error}")

    block_issue_from_entry(state, issue_id, running_entry, error)
  end

  defp retry_agent_down(state, issue_id, running_entry, session_id, reason) do
    termination_reason = worker_exit_termination_reason(reason)

    case record_attempt_event(state, issue_id, :ordinary_failure) do
      {:ok, state} ->
        Logger.warning("Agent task exited for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}; scheduling retry")

        next_attempt = next_retry_attempt_from_running(running_entry)

        schedule_issue_retry(
          state,
          issue_id,
          next_attempt,
          Map.merge(
            %{
              identifier: running_entry.identifier,
              issue_url: running_entry.issue.url,
              error: "agent exited: #{inspect(reason)}",
              termination_reason: termination_reason,
              worker_host: Map.get(running_entry, :worker_host),
              workspace_path: Map.get(running_entry, :workspace_path)
            },
            route_retry_metadata(running_entry)
          )
        )
        |> record_recent_attempt(issue_id, running_entry, termination_reason, "agent exited")

      {:stop, state, reason} ->
        Logger.error("Automatic retries exhausted for issue_id=#{issue_id} session_id=#{session_id}; requiring human attention")
        block_issue_from_entry(state, issue_id, running_entry, attempt_policy_error(reason))

      {:error, state, reason} ->
        Logger.error("Automatic retry blocked for issue_id=#{issue_id} session_id=#{session_id}: #{inspect(reason)}")
        block_issue_from_entry(state, issue_id, running_entry, attempt_ledger_error(reason))
    end
  end

  defp handle_normal_route_change(state, issue_id, running_entry) do
    route_change = Map.get(running_entry, :route_change)

    case record_route_change_events(state, issue_id, route_change) do
      {:ok, state} ->
        state
        |> record_recent_attempt(issue_id, running_entry, :route_changed)
        |> complete_issue(issue_id)
        |> schedule_issue_retry(
          issue_id,
          1,
          Map.merge(
            %{
              identifier: running_entry.identifier,
              issue_url: running_entry.issue.url,
              delay_type: :route_change,
              route_change: route_change,
              worker_host: Map.get(running_entry, :worker_host),
              workspace_path: Map.get(running_entry, :workspace_path)
            },
            route_retry_metadata(running_entry)
          )
        )

      {:stop, state, reason} ->
        block_issue_from_entry(state, issue_id, running_entry, attempt_policy_error(reason))

      {:error, state, reason} ->
        block_issue_from_entry(state, issue_id, running_entry, attempt_ledger_error(reason))
    end
  end

  defp handle_normal_continuation(state, issue_id, running_entry) do
    {:ok, state} = record_attempt_event(state, issue_id, :continuation)

    state
    |> record_recent_attempt(issue_id, running_entry, :normal_completion)
    |> complete_issue(issue_id)
    |> schedule_issue_retry(
      issue_id,
      1,
      Map.merge(
        %{
          identifier: running_entry.identifier,
          issue_url: running_entry.issue.url,
          delay_type: :continuation,
          worker_host: Map.get(running_entry, :worker_host),
          workspace_path: Map.get(running_entry, :workspace_path)
        },
        route_retry_metadata(running_entry)
      )
    )
  end

  defp maybe_dispatch(%State{} = state) do
    case state.attempt_ledger_status do
      {:blocked, reason} ->
        maybe_reconcile_blocked_ledger(state, reason)

      status when status in [:disabled, :ready] ->
        maybe_dispatch_ready(state)

      status ->
        Logger.debug("Skipping autonomous dispatch with invalid attempt ledger status: #{inspect(status)}")
        state
    end
  end

  defp maybe_reconcile_blocked_ledger(%State{} = state, reason) do
    with true <- retryable_ledger_reconciliation_reason?(reason),
         %AttemptLedger{} = ledger <- state.attempt_ledger do
      reconcile_blocked_ledger(state, ledger)
    else
      _ -> blocked_ledger_state(state, reason)
    end
  end

  defp reconcile_blocked_ledger(%State{} = state, %AttemptLedger{} = ledger) do
    case reconcile_attempt_ledger(state, ledger) do
      {:ok, state} ->
        maybe_dispatch_ready(%{state | attempt_ledger_status: :ready})

      {:blocked, state, reason} ->
        Logger.debug("Attempt ledger reconciliation remains blocked: #{inspect(reason)}")
        %{state | attempt_ledger_status: {:blocked, reason}}
    end
  end

  defp blocked_ledger_state(%State{} = state, reason) do
    Logger.debug("Skipping autonomous dispatch while attempt ledger is blocked: #{inspect(reason)}")
    state
  end

  defp retryable_ledger_reconciliation_reason?({:attempt_ledger_issue_missing, _}), do: true
  defp retryable_ledger_reconciliation_reason?({:attempt_ledger_tracker_unavailable, _}), do: true
  defp retryable_ledger_reconciliation_reason?({:attempt_ledger_close_failed, _}), do: true
  defp retryable_ledger_reconciliation_reason?(_reason), do: false

  defp maybe_dispatch_ready(%State{} = state) do
    state =
      state
      |> reconcile_running_issues()
      |> reconcile_blocked_issues()

    with :ok <- Config.validate!(),
         {:ok, issues} <- Tracker.fetch_issues_by_states(Config.settings!().tracker.active_states) do
      state = refresh_dependency_state_for_poll(state, issues)

      if available_slots(state) > 0 do
        choose_issues(issues, state)
      else
        state
      end
    else
      {:error, :missing_linear_api_token} ->
        Logger.error("Tracker API token missing in WORKFLOW.md")
        state

      {:error, :missing_linear_project_slug} ->
        Logger.error("Tracker project scope missing in WORKFLOW.md")
        state

      {:error, :missing_tracker_kind} ->
        Logger.error("Tracker kind missing in WORKFLOW.md")
        state

      {:error, {:unsupported_tracker_kind, kind}} ->
        Logger.error("Unsupported tracker kind in WORKFLOW.md: #{inspect(kind)}")
        state

      {:error, {:invalid_workflow_config, message}} ->
        Logger.error("Invalid WORKFLOW.md config: #{message}")
        state

      {:error, {:missing_workflow_file, path, reason}} ->
        Logger.error("Missing WORKFLOW.md at #{path}: #{inspect(reason)}")
        state

      {:error, :workflow_front_matter_not_a_map} ->
        Logger.error("Failed to parse WORKFLOW.md: workflow front matter must decode to a map")
        state

      {:error, {:workflow_parse_error, reason}} ->
        Logger.error("Failed to parse WORKFLOW.md: #{inspect(reason)}")
        state

      {:error, reason} ->
        Logger.error("Failed to fetch from issue tracker: #{inspect(reason)}")
        state
    end
  end

  defp refresh_dependency_state_for_poll(%State{} = state, active_issues) when is_list(active_issues) do
    case Tracker.fetch_dependency_graph() do
      {:ok, graph_issues} when is_list(graph_issues) ->
        state
        |> refresh_dependency_state(graph_issues, :complete)
        |> ensure_graph_contains_active_issues(active_issues)

      {:ok, _invalid_graph} ->
        Logger.warning("Dependency graph provider returned invalid data; implementation dispatch is disabled")
        refresh_dependency_state(state, active_issues, {:unavailable, :invalid_dependency_graph})

      {:error, reason} ->
        Logger.warning("Dependency graph refresh unavailable; implementation dispatch is disabled: #{inspect(reason)}")
        refresh_dependency_state(state, active_issues, {:unavailable, graph_failure_reason(reason)})
    end
  end

  defp refresh_dependency_state_for_poll(%State{} = state, _active_issues) do
    refresh_dependency_state(state, [], {:unavailable, :invalid_active_issue_collection})
  end

  defp reconcile_running_issues(%State{} = state) do
    state = reconcile_stalled_running_issues(state)
    running_ids = Map.keys(state.running)

    if running_ids == [] do
      state
    else
      case Tracker.fetch_issues_by_ids(running_ids) do
        {:ok, issues} ->
          state = refresh_dependency_state_for_running(state, issues)

          issues
          |> reconcile_running_issue_states(
            state,
            active_state_set(),
            terminal_state_set()
          )
          |> reconcile_missing_running_issue_ids(running_ids, issues)

        {:error, reason} ->
          Logger.debug("Failed to refresh running issue states: #{inspect(reason)}; keeping active workers")

          state
      end
    end
  end

  defp refresh_dependency_state_for_running(%State{} = state, running_issues)
       when is_list(running_issues) do
    case Tracker.fetch_dependency_graph() do
      {:ok, graph_issues} when is_list(graph_issues) ->
        state
        |> refresh_dependency_state(graph_issues, :complete)
        |> ensure_graph_contains_running_issues(running_issues)

      {:ok, _invalid_graph} ->
        Logger.warning("Running dependency graph provider returned invalid data; active implementation workers are unsafe")
        refresh_dependency_state(state, running_issues, {:unavailable, :invalid_dependency_graph})

      {:error, reason} ->
        Logger.warning("Running dependency graph refresh unavailable; active implementation workers are unsafe: #{inspect(reason)}")
        refresh_dependency_state(state, running_issues, {:unavailable, graph_failure_reason(reason)})
    end
  end

  defp refresh_dependency_state_for_running(%State{} = state, _running_issues) do
    refresh_dependency_state(state, [], {:unavailable, :invalid_running_issue_collection})
  end

  defp reconcile_blocked_issues(%State{} = state) do
    blocked_ids = Map.keys(state.blocked)

    if blocked_ids == [] do
      state
    else
      case Tracker.fetch_issues_by_ids(blocked_ids) do
        {:ok, issues} ->
          issues
          |> reconcile_blocked_issue_states(
            state,
            active_state_set(),
            terminal_state_set()
          )
          |> reconcile_missing_blocked_issue_ids(blocked_ids, issues)

        {:error, reason} ->
          Logger.debug("Failed to refresh blocked issue states: #{inspect(reason)}; keeping blocked issues")

          state
      end
    end
  end

  @doc false
  @spec reconcile_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  def reconcile_issue_states_for_test(issues, state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec reconcile_blocked_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_blocked_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    reconcile_blocked_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec handle_retry_issue_lookup_for_test(Issue.t(), term(), String.t(), non_neg_integer(), map()) ::
          term()
  def handle_retry_issue_lookup_for_test(%Issue{} = issue, %State{} = state, issue_id, attempt, metadata)
      when is_binary(issue_id) and is_integer(attempt) and attempt >= 0 and is_map(metadata) do
    {:noreply, updated_state} = handle_retry_issue_lookup(issue, state, issue_id, attempt, metadata)
    updated_state
  end

  @doc false
  @spec should_dispatch_issue_for_test(Issue.t(), term()) :: boolean()
  def should_dispatch_issue_for_test(%Issue{} = issue, %State{} = state) do
    should_dispatch_issue?(issue, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec revalidate_issue_for_dispatch_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:ok, Issue.t()} | {:skip, Issue.t() | :missing} | {:error, term()}
  def revalidate_issue_for_dispatch_for_test(%Issue{} = issue, issue_fetcher)
      when is_function(issue_fetcher, 1) do
    revalidate_issue_for_dispatch(issue, issue_fetcher, terminal_state_set())
  end

  @doc false
  @spec sort_issues_for_dispatch_for_test([Issue.t()]) :: [Issue.t()]
  def sort_issues_for_dispatch_for_test(issues) when is_list(issues) do
    sort_issues_for_dispatch(issues)
  end

  @doc false
  @spec select_worker_host_for_test(term(), String.t() | nil) :: String.t() | nil | :no_worker_capacity
  def select_worker_host_for_test(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host)
  end

  defp reconcile_running_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_running_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_running_issue_states(
      rest,
      reconcile_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, true, :terminal)

      !issue_routable?(issue) ->
        Logger.info("Issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; stopping active agent")

        terminate_running_issue(state, issue.id, false, :not_routable)

      active_issue_state?(issue.state, active_states) ->
        refresh_running_issue_state(state, issue)

      true ->
        Logger.info("Issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, false, :non_active)
    end
  end

  defp reconcile_issue_state(_issue, state, _active_states, _terminal_states), do: state

  defp reconcile_blocked_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_blocked_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_blocked_issue_states(
      rest,
      reconcile_blocked_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_blocked_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Blocked issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; releasing block")
        cleanup_issue_workspace(issue, Map.get(state.blocked, issue.id, %{}))

        state
        |> release_issue_claim(issue.id)
        |> reset_attempt_counters(issue.id)

      !issue_routable?(issue) ->
        Logger.info("Blocked issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; releasing block")
        release_issue_claim(state, issue.id)

      active_issue_state?(issue.state, active_states) ->
        refresh_blocked_issue_state(state, issue)

      true ->
        Logger.info("Blocked issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; releasing block")
        release_issue_claim(state, issue.id)
    end
  end

  defp reconcile_blocked_issue_state(_issue, state, _active_states, _terminal_states), do: state

  defp reconcile_missing_running_issue_ids(%State{} = state, requested_issue_ids, issues)
       when is_list(requested_issue_ids) and is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(requested_issue_ids, state, fn issue_id, state_acc ->
      if MapSet.member?(visible_issue_ids, issue_id) do
        state_acc
      else
        log_missing_running_issue(state_acc, issue_id)
        terminate_running_issue(state_acc, issue_id, false, :tracker_missing)
      end
    end)
  end

  defp reconcile_missing_running_issue_ids(state, _requested_issue_ids, _issues), do: state

  defp reconcile_missing_blocked_issue_ids(%State{} = state, requested_issue_ids, issues)
       when is_list(requested_issue_ids) and is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(requested_issue_ids, state, fn issue_id, state_acc ->
      if MapSet.member?(visible_issue_ids, issue_id) do
        state_acc
      else
        Logger.info("Blocked issue no longer visible during state refresh: issue_id=#{issue_id}; releasing block")
        release_issue_claim(state_acc, issue_id)
      end
    end)
  end

  defp reconcile_missing_blocked_issue_ids(state, _requested_issue_ids, _issues), do: state

  defp log_missing_running_issue(%State{} = state, issue_id) when is_binary(issue_id) do
    case Map.get(state.running, issue_id) do
      %{identifier: identifier} ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id} issue_identifier=#{identifier}; stopping active agent")

      _ ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id}; stopping active agent")
    end
  end

  defp log_missing_running_issue(_state, _issue_id), do: :ok

  defp refresh_running_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      %{issue: _, route: %Route{} = current_route} = running_entry ->
        refresh_routed_running_issue(state, issue, running_entry, current_route)

      %{issue: _} = running_entry ->
        %{state | running: Map.put(state.running, issue.id, %{running_entry | issue: issue})}

      _ ->
        state
    end
  end

  defp refresh_routed_running_issue(state, issue, running_entry, current_route) do
    case route_for_issue(issue) do
      {:ok, %Route{} = next_route} ->
        refresh_routed_running_issue(state, issue, running_entry, current_route, next_route)

      {:error, reason} ->
        Logger.info("Stopping active agent after route refresh failed for #{issue_context(issue)}: #{inspect(reason)}")
        terminate_running_issue(state, issue.id, false, :runtime_unavailable)
    end
  end

  defp refresh_routed_running_issue(state, issue, running_entry, current_route, next_route) do
    if Route.same?(current_route, next_route) do
      refresh_running_dependency_state(state, issue, running_entry, current_route)
    else
      Logger.info(
        "Stopping active agent after route refresh for #{issue_context(issue)} " <>
          "previous=#{current_route.profile_name}/#{current_route.responsibility} " <>
          "next=#{next_route.profile_name}/#{next_route.responsibility}"
      )

      stop_running_issue_for_route_change(state, issue, running_entry, current_route, next_route)
    end
  end

  defp refresh_running_dependency_state(%State{} = state, %Issue{} = issue, running_entry, route) do
    decision = dependency_decision_for_state(issue, route, state)

    if decision.allowed? == true do
      %{state | running: Map.put(state.running, issue.id, %{running_entry | issue: issue})}
    else
      Logger.warning(
        "Stopping active agent after dependency refresh for #{issue_context(issue)}: " <>
          dependency_blocker_error(decision)
      )

      updated_entry = %{running_entry | issue: issue}

      state
      |> record_session_completion_totals(running_entry)
      |> stop_and_block_issue(issue.id, updated_entry, dependency_blocker_error(decision), decision)
    end
  end

  defp stop_running_issue_for_route_change(
         %State{} = state,
         %Issue{} = issue,
         running_entry,
         %Route{} = previous_route,
         %Route{} = next_route
       ) do
    next_attempt = next_retry_attempt_from_running(running_entry)
    route_change = route_change_metadata(previous_route, next_route)

    state = record_session_completion_totals(state, running_entry)

    case record_route_change_events(state, issue.id, route_change) do
      {:ok, state} ->
        stop_running_task(Map.get(running_entry, :pid), Map.get(running_entry, :ref), state.task_supervisor)

        state =
          state
          |> record_recent_attempt(issue.id, %{running_entry | issue: issue}, :route_changed)
          |> then(&Map.update!(&1, :running, fn running -> Map.delete(running, issue.id) end))

        schedule_issue_retry(
          state,
          issue.id,
          next_attempt,
          Map.merge(
            %{
              identifier: issue.identifier,
              issue_url: issue.url,
              error: "route changed during poll refresh",
              delay_type: :route_change,
              route_change: route_change,
              worker_host: Map.get(running_entry, :worker_host),
              workspace_path: Map.get(running_entry, :workspace_path)
            },
            route_retry_metadata(running_entry)
          )
        )

      {:stop, state, reason} ->
        stop_and_block_issue(
          state,
          issue.id,
          %{running_entry | issue: issue},
          attempt_policy_error(reason)
        )
    end
  end

  defp refresh_blocked_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.blocked, issue.id) do
      %{issue: _} = blocked_entry ->
        refreshed_entry = %{blocked_entry | issue: issue}

        if dependency_blocked_entry?(blocked_entry) and dependency_block_resolved?(issue, state) do
          Logger.info("Dependency blocker resolved for blocked issue #{issue_context(issue)}; releasing claim for fresh dispatch")

          release_issue_claim(state, issue.id)
        else
          %{state | blocked: Map.put(state.blocked, issue.id, refreshed_entry)}
        end

      _ ->
        state
    end
  end

  defp dependency_blocked_entry?(blocked_entry) when is_map(blocked_entry) do
    is_map(Map.get(blocked_entry, :dependency))
  end

  defp dependency_block_resolved?(%Issue{} = issue, %State{} = state) do
    case route_for_issue(issue) do
      {:ok, %Route{responsibility: responsibility}} ->
        decision = dependency_decision(issue, responsibility)
        decision.allowed? == true and not dependency_cycle?(state, issue.id)

      {:error, _reason} ->
        false
    end
  end

  defp terminate_running_issue(%State{} = state, issue_id, cleanup_workspace, termination_reason) do
    case Map.get(state.running, issue_id) do
      nil ->
        state = release_issue_claim(state, issue_id)
        if cleanup_workspace, do: reset_attempt_counters(state, issue_id), else: state

      %{pid: pid, ref: ref, identifier: identifier} = running_entry ->
        state = record_session_completion_totals(state, running_entry)
        state = record_recent_attempt(state, issue_id, running_entry, termination_reason)

        stop_running_task(pid, ref, state.task_supervisor)

        if cleanup_workspace do
          cleanup_issue_workspace(Map.get(running_entry, :issue, identifier), running_entry)
        end

        state = %{
          state
          | running: Map.delete(state.running, issue_id),
            claimed: MapSet.delete(state.claimed, issue_id),
            blocked: Map.delete(state.blocked, issue_id),
            retry_attempts: Map.delete(state.retry_attempts, issue_id)
        }

        if cleanup_workspace, do: reset_attempt_counters(state, issue_id), else: state

      _ ->
        state = release_issue_claim(state, issue_id)
        if cleanup_workspace, do: reset_attempt_counters(state, issue_id), else: state
    end
  end

  defp reconcile_stalled_running_issues(%State{} = state) do
    timeout_ms = Config.settings!().codex.stall_timeout_ms

    cond do
      timeout_ms <= 0 ->
        state

      map_size(state.running) == 0 ->
        state

      true ->
        now = DateTime.utc_now()

        Enum.reduce(state.running, state, fn {issue_id, running_entry}, state_acc ->
          maybe_restart_stalled_issue(state_acc, issue_id, running_entry, now, timeout_ms)
        end)
    end
  end

  defp maybe_restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms) do
    if Map.has_key?(state.blocked, issue_id) do
      state
    else
      restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms)
    end
  end

  defp restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms) do
    elapsed_ms = stall_elapsed_ms(running_entry, now)

    cond do
      is_integer(elapsed_ms) and elapsed_ms > timeout_ms and input_required_blocker?(running_entry) ->
        identifier = Map.get(running_entry, :identifier, issue_id)
        session_id = running_entry_session_id(running_entry)
        error = blocker_error(running_entry, "stalled for #{elapsed_ms}ms after Codex requested operator input")

        Logger.warning("Issue blocked: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; #{error}")

        state
        |> record_session_completion_totals(running_entry)
        |> stop_and_block_issue(issue_id, running_entry, error)

      is_integer(elapsed_ms) and elapsed_ms > timeout_ms ->
        retry_stalled_issue(state, issue_id, running_entry, elapsed_ms)

      true ->
        state
    end
  end

  defp retry_stalled_issue(state, issue_id, running_entry, elapsed_ms) do
    identifier = Map.get(running_entry, :identifier, issue_id)
    session_id = running_entry_session_id(running_entry)

    Logger.warning("Issue stalled: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; restarting with backoff")

    next_attempt = next_retry_attempt_from_running(running_entry)

    retry_metadata =
      Map.merge(
        %{
          identifier: identifier,
          issue_url: running_entry.issue.url,
          error: "stalled for #{elapsed_ms}ms without codex activity",
          termination_reason: :runtime_stalled
        },
        route_retry_metadata(running_entry)
      )

    case record_attempt_event(state, issue_id, :ordinary_failure) do
      {:ok, state} ->
        state
        |> terminate_running_issue(issue_id, false, :runtime_stalled)
        |> schedule_issue_retry(issue_id, next_attempt, retry_metadata)

      {:stop, state, reason} ->
        state
        |> record_session_completion_totals(running_entry)
        |> stop_and_block_issue(issue_id, running_entry, attempt_policy_error(reason))

      {:error, state, reason} ->
        state
        |> record_session_completion_totals(running_entry)
        |> stop_and_block_issue(issue_id, running_entry, attempt_ledger_error(reason))
    end
  end

  defp stall_elapsed_ms(running_entry, now) do
    running_entry
    |> last_activity_timestamp()
    |> case do
      %DateTime{} = timestamp ->
        max(0, DateTime.diff(now, timestamp, :millisecond))

      _ ->
        nil
    end
  end

  defp last_activity_timestamp(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :last_codex_timestamp) || Map.get(running_entry, :started_at)
  end

  defp last_activity_timestamp(_running_entry), do: nil

  defp input_required_blocker?(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :last_codex_event) in [:turn_input_required, :approval_required] or
      not is_nil(input_required_completion_outcome(Map.get(running_entry, :completion))) or
      codex_message_method(Map.get(running_entry, :last_codex_message)) ==
        "mcpServer/elicitation/request"
  end

  defp input_required_blocker?(_running_entry), do: false

  defp input_required_completion_outcome(completion) when is_map(completion) do
    outcome = Map.get(completion, :outcome) || Map.get(completion, "outcome")
    normalize_input_required_outcome(outcome)
  end

  defp input_required_completion_outcome(_completion), do: nil

  defp normalize_input_required_outcome(outcome)
       when outcome in [:input_required, :needs_input, :approval_required],
       do: outcome

  defp normalize_input_required_outcome(outcome) when is_binary(outcome) do
    case outcome do
      "input_required" -> :input_required
      "needs_input" -> :needs_input
      "approval_required" -> :approval_required
      _ -> nil
    end
  end

  defp normalize_input_required_outcome(_outcome), do: nil

  defp blocker_error(running_entry, fallback) when is_map(running_entry) do
    codex_event_blocker_error(Map.get(running_entry, :last_codex_event)) ||
      completion_blocker_error(Map.get(running_entry, :completion)) ||
      codex_message_blocker_error(Map.get(running_entry, :last_codex_message)) ||
      fallback
  end

  defp blocker_error(_running_entry, fallback), do: fallback

  defp dependency_blocker_error(%{
         reason: reason,
         responsibility: responsibility,
         unresolved_blockers: blockers
       }) do
    "dependency guard blocked responsibility=#{inspect(responsibility)} reason=#{inspect(reason)} " <>
      "blockers=#{inspect(blocker_labels(blockers))}"
  end

  defp dependency_blocker_error(%{
         "reason" => reason,
         "responsibility" => responsibility,
         "unresolved_blockers" => blockers
       }) do
    "dependency guard blocked responsibility=#{inspect(responsibility)} reason=#{inspect(reason)} " <>
      "blockers=#{inspect(blocker_labels(blockers))}"
  end

  defp dependency_blocker_error(decision), do: "dependency guard blocked: #{inspect(decision)}"

  defp blocker_labels(blockers) when is_list(blockers) do
    Enum.map(blockers, fn blocker ->
      Map.get(blocker, :identifier) || Map.get(blocker, "identifier") || Map.get(blocker, :id) || Map.get(blocker, "id")
    end)
  end

  defp blocker_labels(_blockers), do: []

  defp codex_event_blocker_error(:turn_input_required), do: "codex turn requires operator input"
  defp codex_event_blocker_error(:approval_required), do: "codex turn requires approval"
  defp codex_event_blocker_error(_event), do: nil

  defp completion_blocker_error(completion) do
    case input_required_completion_outcome(completion) do
      outcome when outcome in [:input_required, :needs_input] -> "codex turn requires operator input"
      :approval_required -> "codex turn requires approval"
      nil -> nil
    end
  end

  defp codex_message_blocker_error(message) do
    if codex_message_method(message) == "mcpServer/elicitation/request" do
      "codex MCP elicitation requires operator input"
    end
  end

  defp codex_message_method(%{message: %{"method" => method}}) when is_binary(method), do: method
  defp codex_message_method(%{message: %{method: method}}) when is_binary(method), do: method
  defp codex_message_method(%{"method" => method}) when is_binary(method), do: method
  defp codex_message_method(%{method: method}) when is_binary(method), do: method
  defp codex_message_method(_message), do: nil

  defp terminate_task(pid, task_supervisor) when is_pid(pid) do
    case Task.Supervisor.terminate_child(task_supervisor, pid) do
      :ok ->
        :ok

      {:error, :not_found} ->
        Process.exit(pid, :shutdown)
    end
  end

  defp terminate_task(_pid, _task_supervisor), do: :ok

  defp stop_running_task(pid, ref, task_supervisor) do
    if is_pid(pid) do
      terminate_task(pid, task_supervisor)
    end

    if is_reference(ref) do
      Process.demonitor(ref, [:flush])
    end

    :ok
  end

  defp stop_and_block_issue(%State{} = state, issue_id, running_entry, error, dependency \\ nil) do
    stop_running_task(
      Map.get(running_entry, :pid),
      Map.get(running_entry, :ref),
      state.task_supervisor
    )

    block_issue_from_entry(state, issue_id, running_entry, error, dependency)
  end

  defp record_recent_attempt(state, issue_id, entry, reason, error \\ nil)

  defp record_recent_attempt(%State{} = state, issue_id, entry, reason, error)
       when is_binary(issue_id) and is_atom(reason) and is_map(entry) do
    issue = Map.get(entry, :issue)
    attempt = Map.get(entry, :retry_attempt, Map.get(entry, :attempt, 0))

    history_entry = %{
      issue_id: issue_id,
      identifier: Map.get(entry, :identifier) || issue_identifier(issue) || issue_id,
      issue_url: Map.get(entry, :issue_url) || issue_url(issue),
      termination_reason: reason,
      attempt: normalize_retry_attempt(attempt),
      profile_name: Map.get(entry, :profile_name),
      runtime_name: Map.get(entry, :runtime_name),
      responsibility: Map.get(entry, :responsibility),
      sandbox: sandbox_for_entry(entry),
      route_fingerprint: Map.get(entry, :route_fingerprint),
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: Map.get(entry, :session_id),
      attempt_counters: attempt_counters_for(state, issue_id),
      dependency_completeness: snapshot_dependency_completeness(state, issue_id),
      dependency: snapshot_dependency_metadata(Map.get(entry, :dependency)),
      error: observability_error(error || Map.get(entry, :error)),
      at: DateTime.utc_now()
    }

    %{state | recent_attempts: [history_entry | List.wrap(state.recent_attempts)] |> Enum.take(@recent_attempt_limit)}
  end

  defp record_recent_attempt(state, _issue_id, _entry, _reason, _error), do: state

  defp issue_identifier(%Issue{identifier: identifier}), do: identifier
  defp issue_identifier(_issue), do: nil

  defp issue_url(%Issue{url: url}), do: url
  defp issue_url(_issue), do: nil

  defp termination_reason_for_block(error, dependency) do
    if dependency_denied?(dependency), do: :dependency_blocked, else: error_termination_reason(error)
  end

  defp error_termination_reason(error) when is_binary(error) do
    Enum.find_value(@blocked_termination_rules, :blocked, fn {marker, reason} ->
      if String.contains?(error, marker), do: reason
    end)
  end

  defp error_termination_reason(_error), do: :blocked

  defp dependency_denied?(%{allowed?: false}), do: true
  defp dependency_denied?(%{"allowed?" => false}), do: true
  defp dependency_denied?(_dependency), do: false

  defp block_issue_from_entry(%State{} = state, issue_id, running_entry, error, dependency \\ nil) do
    blocked_entry = %{
      issue_id: issue_id,
      identifier: Map.get(running_entry, :identifier, issue_id),
      issue: Map.get(running_entry, :issue),
      profile_name: Map.get(running_entry, :profile_name),
      runtime_name: Map.get(running_entry, :runtime_name),
      responsibility: Map.get(running_entry, :responsibility),
      sandbox: sandbox_for_entry(running_entry),
      route_fingerprint: Map.get(running_entry, :route_fingerprint),
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path),
      retry_attempt: Map.get(running_entry, :retry_attempt, 0),
      session_id: running_entry_session_id(running_entry),
      error: error,
      termination_reason: termination_reason_for_block(error, dependency),
      blocked_at: DateTime.utc_now(),
      last_codex_message: Map.get(running_entry, :last_codex_message),
      last_codex_event: Map.get(running_entry, :last_codex_event),
      last_codex_timestamp: Map.get(running_entry, :last_codex_timestamp),
      dependency: dependency
    }

    state = %{
      state
      | running: Map.delete(state.running, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id),
        claimed: MapSet.put(state.claimed, issue_id),
        blocked: Map.put(state.blocked, issue_id, blocked_entry)
    }

    record_recent_attempt(
      state,
      issue_id,
      Map.put(blocked_entry, :dependency, dependency),
      blocked_entry.termination_reason,
      error
    )
  end

  defp refresh_dependency_state(%State{} = state, issues, completeness) when is_list(issues) do
    graph = Graph.build(issues, completeness: completeness)

    dependency_diagnostics =
      Enum.reduce(issues, %{}, fn
        %Issue{id: issue_id} = issue, diagnostics when is_binary(issue_id) ->
          Map.put(diagnostics, issue_id, dependency_diagnostic_for_issue(issue, graph))

        _, diagnostics ->
          diagnostics
      end)

    %{
      state
      | dependency_graph: graph,
        dependency_diagnostics: dependency_diagnostics
    }
  end

  defp dependency_diagnostic_for_issue(%Issue{id: issue_id} = issue, %Graph{} = graph) do
    case route_for_issue(issue) do
      {:ok, %Route{responsibility: responsibility}} ->
        issue
        |> dependency_decision(responsibility)
        |> maybe_mark_dependency_incomplete(graph, issue_id)
        |> maybe_mark_dependency_cycle(graph, issue_id)

      {:error, reason} ->
        route_diagnostic(issue, reason)
    end
  end

  defp dependency_decision(%Issue{} = issue, responsibility) do
    Guard.evaluate(issue, responsibility, dependency_policy_options())
  end

  defp dependency_decision_for_state(
         %Issue{id: issue_id} = issue,
         %Route{responsibility: responsibility},
         %State{} = state
       )
       when is_binary(issue_id) do
    issue
    |> Guard.evaluate(responsibility, dependency_policy_options())
    |> maybe_mark_dependency_incomplete(state.dependency_graph, issue_id)
    |> maybe_mark_dependency_cycle(state.dependency_graph, issue_id)
  end

  defp maybe_mark_dependency_cycle(decision, %Graph{} = graph, issue_id) do
    if Graph.cyclic?(graph, issue_id) do
      Map.merge(decision, %{
        allowed?: false,
        reason: :dependency_cycle,
        dependency_status: :invalidated,
        merge_permitted?: false,
        diagnostic: {:dependency_cycle, cycle_for_issue(graph, issue_id)}
      })
    else
      decision
    end
  end

  defp maybe_mark_dependency_incomplete(decision, %Graph{} = graph, issue_id) do
    case Graph.incompleteness_reason(graph, issue_id) do
      nil ->
        decision

      {:unavailable, :dependency_graph_unsupported} = reason ->
        if Config.settings!().agent.routing == "legacy" do
          Map.put(decision, :dependency_completeness, reason)
        else
          incomplete_dependency_decision(decision, reason)
        end

      reason ->
        if decision.allowed? == false do
          Map.put(decision, :dependency_completeness, reason)
        else
          incomplete_dependency_decision(decision, reason)
        end
    end
  end

  defp incomplete_dependency_decision(decision, reason) do
    if read_only_dependency_responsibility?(Map.get(decision, :responsibility)) do
      Map.merge(decision, %{
        dependency_status: :incomplete,
        dependency_completeness: reason,
        diagnostic: {:dependency_graph_incomplete, reason}
      })
    else
      Map.merge(decision, %{
        allowed?: false,
        dependency_status: :incomplete,
        reason: :dependency_data_incomplete,
        merge_permitted?: false,
        dependency_completeness: reason,
        diagnostic: {:dependency_graph_incomplete, reason}
      })
    end
  end

  defp read_only_dependency_responsibility?(responsibility) when is_binary(responsibility) do
    String.downcase(String.trim(responsibility)) in ["planning", "review"]
  end

  defp read_only_dependency_responsibility?(_responsibility), do: false

  defp choose_issues(issues, state) do
    active_states = active_state_set()
    terminal_states = terminal_state_set()

    issues
    |> sort_issues_for_dispatch()
    |> Enum.reduce(state, fn issue, state_acc ->
      if should_dispatch_issue?(issue, state_acc, active_states, terminal_states) do
        dispatch_issue(state_acc, issue)
      else
        state_acc
      end
    end)
  end

  defp sort_issues_for_dispatch(issues) when is_list(issues) do
    Enum.sort_by(issues, fn
      %Issue{} = issue ->
        {priority_rank(issue.priority), issue_created_at_sort_key(issue), issue.identifier || issue.id || ""}

      _ ->
        {priority_rank(nil), issue_created_at_sort_key(nil), ""}
    end)
  end

  defp priority_rank(priority) when is_integer(priority) and priority in 1..4, do: priority
  defp priority_rank(_priority), do: 5

  defp issue_created_at_sort_key(%Issue{created_at: %DateTime{} = created_at}) do
    DateTime.to_unix(created_at, :microsecond)
  end

  defp issue_created_at_sort_key(%Issue{}), do: 9_223_372_036_854_775_807
  defp issue_created_at_sort_key(_issue), do: 9_223_372_036_854_775_807

  defp should_dispatch_issue?(
         %Issue{} = issue,
         %State{} = state,
         active_states,
         terminal_states
       ) do
    candidate_issue?(issue, active_states, terminal_states) and
      issue_not_reserved?(state, issue.id) and
      route_dispatchable?(issue) and
      dependency_dispatchable?(issue, state) and
      dispatch_resources_available?(state, issue)
  end

  defp should_dispatch_issue?(_issue, _state, _active_states, _terminal_states), do: false

  defp issue_not_reserved?(%State{} = state, issue_id) do
    !MapSet.member?(state.claimed, issue_id) and
      !Map.has_key?(state.running, issue_id) and
      !Map.has_key?(state.blocked, issue_id) and
      !Map.has_key?(Map.get(state, :durable_exhausted, %{}), issue_id)
  end

  defp dispatch_resources_available?(%State{} = state, %Issue{} = issue) do
    available_slots(state) > 0 and
      state_slots_available?(issue, state.running) and
      worker_slots_available?(state)
  end

  defp state_slots_available?(%Issue{state: issue_state}, running) when is_map(running) do
    limit = Config.max_concurrent_agents_for_state(issue_state)
    used = running_issue_count_for_state(running, issue_state)
    limit > used
  end

  defp state_slots_available?(_issue, _running), do: false

  defp running_issue_count_for_state(running, issue_state) when is_map(running) do
    normalized_state = normalize_issue_state(issue_state)

    Enum.count(running, fn
      {_id, %{issue: %Issue{state: state_name}}} ->
        normalize_issue_state(state_name) == normalized_state

      _ ->
        false
    end)
  end

  defp candidate_issue?(
         %Issue{
           id: id,
           identifier: identifier,
           title: title,
           state: state_name
         } = issue,
         active_states,
         terminal_states
       )
       when is_binary(id) and is_binary(identifier) and is_binary(title) and is_binary(state_name) do
    Enum.all?([id, identifier, title, state_name], &present_string?/1) and
      issue_routable?(issue) and
      active_issue_state?(state_name, active_states) and
      !terminal_issue_state?(state_name, terminal_states)
  end

  defp candidate_issue?(_issue, _active_states, _terminal_states), do: false

  defp issue_routable?(%Issue{} = issue) do
    Issue.routable?(issue, Config.settings!().tracker.required_labels)
  end

  defp terminal_issue_state?(state_name, terminal_states) when is_binary(state_name) do
    MapSet.member?(terminal_states, normalize_issue_state(state_name))
  end

  defp terminal_issue_state?(_state_name, _terminal_states), do: false

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false

  defp active_issue_state?(state_name, active_states) when is_binary(state_name) do
    MapSet.member?(active_states, normalize_issue_state(state_name))
  end

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(String.trim(state_name))
  end

  defp terminal_state_set do
    Config.settings!().tracker.terminal_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp active_state_set do
    Config.settings!().tracker.active_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp dispatch_issue(%State{} = state, issue, attempt \\ nil, preferred_worker_host \\ nil) do
    case refresh_issue_for_dispatch(issue) do
      {:ok, %Issue{} = refreshed_issue} ->
        state = refresh_dependency_graph_for_dispatch(state, refreshed_issue)
        final_issue = Map.get(state.dependency_graph.nodes, refreshed_issue.id, refreshed_issue)
        dispatch_refreshed_issue(state, final_issue, attempt, preferred_worker_host)

      {:skip, _reason} ->
        state

      {:error, _reason} ->
        state
    end
  end

  defp dispatch_refreshed_issue(state, refreshed_issue, attempt, preferred_worker_host) do
    if candidate_issue?(refreshed_issue, active_state_set(), terminal_state_set()) and
         dispatch_slots_available?(refreshed_issue, state) do
      case route_for_issue(refreshed_issue) do
        {:ok, %Route{} = route} ->
          dispatch_if_dependency_allowed(state, refreshed_issue, route, attempt, preferred_worker_host)

        {:error, reason} ->
          Logger.warning("Skipping dispatch; issue route is unavailable for #{issue_context(refreshed_issue)}: #{inspect(reason)}")
          state
      end
    else
      Logger.info("Skipping final dispatch after candidate eligibility changed for #{issue_context(refreshed_issue)}")
      state
    end
  end

  defp dispatch_if_dependency_allowed(state, issue, route, attempt, preferred_worker_host) do
    state = put_dependency_decision(state, issue, route)

    if dependency_dispatchable?(issue, state) do
      do_dispatch_issue(state, issue, route, attempt, preferred_worker_host)
    else
      Logger.info("Skipping dispatch after dependency recheck for #{issue_context(issue)}")
      state
    end
  end

  defp refresh_issue_for_dispatch(issue) do
    case revalidate_issue_for_dispatch(issue, &Tracker.fetch_issues_by_ids/1, terminal_state_set()) do
      {:ok, %Issue{} = refreshed_issue} ->
        {:ok, refreshed_issue}

      {:skip, :missing} ->
        Logger.info("Skipping dispatch; issue no longer active or visible: #{issue_context(issue)}")
        {:skip, :missing}

      {:skip, %Issue{} = refreshed_issue} ->
        Logger.info("Skipping stale dispatch after issue refresh: #{issue_context(refreshed_issue)} state=#{inspect(refreshed_issue.state)} blocked_by=#{length(refreshed_issue.blocked_by)}")

        {:skip, refreshed_issue}

      {:error, reason} ->
        Logger.warning("Skipping dispatch; issue refresh failed for #{issue_context(issue)}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp refresh_dependency_graph_for_dispatch(%State{} = state, fallback_issue) do
    case Tracker.fetch_dependency_graph() do
      {:ok, graph_issues} when is_list(graph_issues) ->
        state
        |> refresh_dependency_state(graph_issues, :complete)
        |> ensure_graph_contains_issue(fallback_issue)

      {:ok, _invalid_graph} ->
        Logger.warning("Final dependency graph refresh returned invalid data; implementation dispatch is disabled")
        refresh_dependency_state(state, [fallback_issue], {:unavailable, :invalid_dependency_graph})

      {:error, reason} ->
        Logger.warning("Final dependency graph refresh unavailable; implementation dispatch is disabled: #{inspect(reason)}")
        refresh_dependency_state(state, [fallback_issue], {:unavailable, graph_failure_reason(reason)})
    end
  end

  defp graph_failure_reason(:dependency_graph_unsupported), do: :dependency_graph_unsupported
  defp graph_failure_reason(_reason), do: :dependency_graph_unavailable

  defp ensure_graph_contains_active_issues(%State{} = state, active_issues) when is_list(active_issues) do
    ensure_graph_contains_issues(state, active_issues)
  end

  defp ensure_graph_contains_running_issues(%State{} = state, running_issues)
       when is_list(running_issues) do
    ensure_graph_contains_issues(state, running_issues)
  end

  defp ensure_graph_contains_issues(%State{} = state, issues) when is_list(issues) do
    missing_issue? =
      Enum.any?(issues, fn
        %Issue{id: issue_id} when is_binary(issue_id) ->
          not Map.has_key?(state.dependency_graph.nodes, issue_id)

        _issue ->
          false
      end)

    if missing_issue?, do: mark_graph_incomplete(state, :missing_graph_node), else: state
  end

  defp ensure_graph_contains_issue(%State{} = state, %Issue{id: issue_id}) when is_binary(issue_id) do
    if Map.has_key?(state.dependency_graph.nodes, issue_id) do
      state
    else
      mark_graph_incomplete(state, :missing_graph_node)
    end
  end

  defp ensure_graph_contains_issue(state, _issue), do: mark_graph_incomplete(state, :invalid_dispatch_issue)

  defp mark_graph_incomplete(%State{dependency_graph: %Graph{} = graph} = state, reason) do
    %{state | dependency_graph: %{graph | completeness: {:incomplete, reason}}}
  end

  defp do_dispatch_issue(%State{} = state, issue, route, attempt, preferred_worker_host) do
    recipient = self()

    case select_worker_host(state, preferred_worker_host) do
      :no_worker_capacity ->
        Logger.debug("No SSH worker slots available for #{issue_context(issue)} preferred_worker_host=#{inspect(preferred_worker_host)}")
        state

      worker_host ->
        spawn_issue_on_worker_host(state, issue, route, attempt, recipient, worker_host)
    end
  end

  defp spawn_issue_on_worker_host(%State{} = state, issue, route, attempt, recipient, worker_host) do
    case Task.Supervisor.start_child(state.task_supervisor, fn ->
           state.agent_runner.run(issue, recipient,
             attempt: attempt,
             worker_host: worker_host,
             route: route,
             dependency_decision: Map.get(state.dependency_diagnostics, issue.id)
           )
         end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        Logger.info("Dispatching issue to agent: #{issue_context(issue)} pid=#{inspect(pid)} attempt=#{inspect(attempt)} worker_host=#{worker_host || "local"}")

        running =
          Map.put(state.running, issue.id, %{
            pid: pid,
            ref: ref,
            identifier: issue.identifier,
            issue: issue,
            route: route,
            profile_name: route.profile_name,
            runtime_name: route.runtime_name,
            responsibility: route.responsibility,
            sandbox: route_sandbox(route),
            route_fingerprint: route.fingerprint,
            route_change_termination: false,
            route_change: nil,
            worker_host: worker_host,
            workspace_path: nil,
            session_id: nil,
            last_codex_message: nil,
            last_codex_timestamp: nil,
            last_codex_event: nil,
            codex_app_server_pid: nil,
            codex_input_tokens: 0,
            codex_output_tokens: 0,
            codex_total_tokens: 0,
            codex_last_reported_input_tokens: 0,
            codex_last_reported_output_tokens: 0,
            codex_last_reported_total_tokens: 0,
            turn_count: 0,
            retry_attempt: normalize_retry_attempt(attempt),
            started_at: DateTime.utc_now()
          })

        %{
          state
          | running: running,
            claimed: MapSet.put(state.claimed, issue.id),
            retry_attempts: Map.delete(state.retry_attempts, issue.id)
        }

      {:error, reason} ->
        Logger.error("Unable to spawn agent for #{issue_context(issue)}: #{inspect(reason)}")
        next_attempt = if is_integer(attempt), do: attempt + 1, else: nil

        retry_metadata = %{
          identifier: issue.identifier,
          issue_url: issue.url,
          error: "failed to spawn agent: #{inspect(reason)}",
          worker_host: worker_host,
          profile_name: route.profile_name,
          runtime_name: route.runtime_name,
          responsibility: route.responsibility,
          sandbox: route_sandbox(route),
          route_fingerprint: route.fingerprint
        }

        case record_attempt_event(state, issue.id, :ordinary_failure) do
          {:ok, state} ->
            state
            |> record_recent_attempt(issue.id, Map.put(retry_metadata, :issue, issue), :runtime_failure, retry_metadata.error)
            |> schedule_issue_retry(issue.id, next_attempt, retry_metadata)

          {:stop, state, reason} ->
            block_issue_after_attempt_limit(state, issue, attempt, retry_metadata, reason)

          {:error, state, reason} ->
            block_issue_from_entry(
              state,
              issue.id,
              Map.put(retry_metadata, :retry_attempt, attempt),
              attempt_ledger_error(reason)
            )
        end
    end
  end

  defp revalidate_issue_for_dispatch(%Issue{id: issue_id}, issue_fetcher, terminal_states)
       when is_binary(issue_id) and is_function(issue_fetcher, 1) do
    case issue_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if retry_candidate_issue?(refreshed_issue, terminal_states) do
          {:ok, refreshed_issue}
        else
          {:skip, refreshed_issue}
        end

      {:ok, []} ->
        {:skip, :missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp revalidate_issue_for_dispatch(issue, _issue_fetcher, _terminal_states), do: {:ok, issue}

  @doc false
  @spec record_attempt_event_for_test(State.t(), String.t(), atom()) :: term()
  def record_attempt_event_for_test(%State{} = state, issue_id, event) do
    record_attempt_event(state, issue_id, event)
  end

  defp record_attempt_event(%State{} = state, issue_id, event)
       when is_binary(issue_id) and is_atom(event) do
    counters =
      state.attempt_counters
      |> Map.get(issue_id, AttemptPolicy.new())
      |> then(&Map.merge(AttemptPolicy.new(), &1))

    case AttemptPolicy.record(counters, event) do
      {:ok, counters} ->
        persist_attempt_event(state, issue_id, event, counters, :open, nil)

      {:stop, counters, reason} ->
        persist_attempt_event(state, issue_id, event, counters, :exhausted, reason)
    end
  end

  defp persist_attempt_event(%State{} = state, issue_id, event, counters, status, stop_reason) do
    if event in @durable_attempt_events do
      persist_durable_attempt_event(state, issue_id, counters, status, stop_reason)
    else
      apply_attempt_event_result(state, issue_id, counters, status, stop_reason)
    end
  end

  defp persist_durable_attempt_event(%State{} = state, issue_id, counters, status, stop_reason) do
    case state.attempt_ledger_status do
      :disabled ->
        apply_attempt_event_result(state, issue_id, counters, status, stop_reason)

      :ready ->
        persist_ready_attempt_event(state, issue_id, counters, status, stop_reason)

      {:blocked, reason} ->
        {:error, state, {:attempt_ledger_unavailable, reason}}

      _ ->
        reason = :invalid_ledger_status
        {:error, block_ledger(state, reason), {:attempt_ledger_unavailable, reason}}
    end
  end

  defp persist_ready_attempt_event(%State{attempt_ledger: %AttemptLedger{} = ledger} = state, issue_id, counters, status, stop_reason) do
    case AttemptLedger.persist_safety(ledger, issue_id, counters,
           status: status,
           stop_reason: stop_reason,
           route_fingerprint: route_fingerprint_for_issue(state, issue_id)
         ) do
      {:ok, _record} ->
        apply_attempt_event_result(state, issue_id, counters, status, stop_reason)

      {:error, reason} ->
        {:error, block_ledger(state, reason), {:attempt_ledger_unavailable, reason}}
    end
  end

  defp persist_ready_attempt_event(%State{} = state, _issue_id, _counters, _status, _stop_reason) do
    reason = :missing_ledger_handle

    {:error, block_ledger(state, reason), {:attempt_ledger_unavailable, reason}}
  end

  defp apply_attempt_event_result(%State{} = state, issue_id, counters, :open, _stop_reason) do
    {:ok,
     %{
       state
       | attempt_counters: Map.put(state.attempt_counters, issue_id, counters),
         durable_exhausted: Map.delete(Map.get(state, :durable_exhausted, %{}), issue_id)
     }}
  end

  defp apply_attempt_event_result(%State{} = state, issue_id, counters, :exhausted, stop_reason) do
    state = %{state | attempt_counters: Map.put(state.attempt_counters, issue_id, counters)}

    {:stop,
     %{
       state
       | durable_exhausted:
           Map.put(Map.get(state, :durable_exhausted, %{}), issue_id, %{
             issue_id: issue_id,
             status: :exhausted,
             safety_counters: counters,
             stop_reason: stop_reason
           })
     }, stop_reason}
  end

  defp block_ledger(%State{} = state, reason) do
    %{state | attempt_ledger_status: {:blocked, {:attempt_ledger_unavailable, reason}}}
  end

  defp route_fingerprint_for_issue(%State{} = state, issue_id) do
    running = Map.get(state.running, issue_id)
    retry = Map.get(state.retry_attempts, issue_id)
    blocked = Map.get(state.blocked, issue_id)

    Map.get(running || retry || blocked || %{}, :route_fingerprint)
  end

  defp attempt_ledger_error({:attempt_ledger_unavailable, reason}) do
    "attempt ledger unavailable; automatic work is blocked: #{inspect(reason)}"
  end

  defp record_route_change_events(state, issue_id, route_change) do
    case record_attempt_event(state, issue_id, :route_change) do
      {:ok, state} -> record_review_cycle_event(state, issue_id, route_change)
      {:stop, _state, _reason} = result -> result
      {:error, _state, _reason} = result -> result
    end
  end

  defp record_review_cycle_event(state, _issue_id, route_change)
       when not is_map(route_change),
       do: {:ok, state}

  defp record_review_cycle_event(state, issue_id, route_change) do
    if reviewer_to_correction?(route_change) do
      record_attempt_event(state, issue_id, :review_cycle)
    else
      {:ok, state}
    end
  end

  defp reviewer_to_correction?(%{previous: previous, next: next})
       when is_map(previous) and is_map(next) do
    Map.get(previous, :responsibility) == "review" and
      Map.get(next, :responsibility) == "correction"
  end

  defp reviewer_to_correction?(%{"previous" => previous, "next" => next})
       when is_map(previous) and is_map(next) do
    Map.get(previous, "responsibility") == "review" and
      Map.get(next, "responsibility") == "correction"
  end

  defp reviewer_to_correction?(_route_change), do: false

  defp attempt_policy_error(:ordinary_retry_limit),
    do: "automatic ordinary retry limit reached after three retries; human attention required"

  defp attempt_policy_error(:review_cycle_limit),
    do: "automatic review cycle limit reached after three cycles; human attention required"

  defp attempt_policy_error(:ci_retry_disabled),
    do: "automatic CI retry is disabled; human or provider attention required"

  defp worker_exit_termination_reason(:shutdown), do: :shutdown
  defp worker_exit_termination_reason({:shutdown, _detail}), do: :shutdown
  defp worker_exit_termination_reason(_reason), do: :runtime_failure

  defp block_issue_after_attempt_limit(%State{} = state, %Issue{} = issue, attempt, metadata, reason)
       when is_map(metadata) do
    running_entry = %{
      pid: nil,
      ref: nil,
      identifier: metadata[:identifier] || issue.identifier,
      issue: issue,
      profile_name: metadata[:profile_name],
      runtime_name: metadata[:runtime_name],
      responsibility: metadata[:responsibility],
      route_fingerprint: metadata[:route_fingerprint],
      worker_host: metadata[:worker_host],
      workspace_path: metadata[:workspace_path],
      retry_attempt: normalize_retry_attempt(attempt),
      session_id: metadata[:session_id],
      last_codex_message: nil,
      last_codex_event: nil,
      last_codex_timestamp: nil
    }

    block_issue_from_entry(state, issue.id, running_entry, attempt_policy_error(reason))
  end

  defp complete_issue(%State{} = state, issue_id) do
    %{
      state
      | completed: MapSet.put(state.completed, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp schedule_issue_retry(%State{} = state, issue_id, attempt, metadata)
       when is_binary(issue_id) and is_map(metadata) do
    previous_retry = Map.get(state.retry_attempts, issue_id, %{attempt: 0})
    next_attempt = if is_integer(attempt), do: attempt, else: previous_retry.attempt + 1
    delay_ms = retry_delay(next_attempt, metadata)
    old_timer = Map.get(previous_retry, :timer_ref)
    retry_token = make_ref()
    due_at_ms = System.monotonic_time(:millisecond) + delay_ms
    identifier = pick_retry_identifier(issue_id, previous_retry, metadata)
    issue_url = pick_retry_issue_url(previous_retry, metadata)
    error = pick_retry_error(previous_retry, metadata)
    worker_host = pick_retry_worker_host(previous_retry, metadata)
    workspace_path = pick_retry_workspace_path(previous_retry, metadata)
    session_id = pick_retry_metadata(previous_retry, metadata, :session_id)
    delay_type = pick_retry_metadata(previous_retry, metadata, :delay_type)
    profile_name = pick_retry_metadata(previous_retry, metadata, :profile_name)
    runtime_name = pick_retry_metadata(previous_retry, metadata, :runtime_name)
    responsibility = pick_retry_metadata(previous_retry, metadata, :responsibility)
    sandbox = pick_retry_metadata(previous_retry, metadata, :sandbox)
    route_fingerprint = pick_retry_metadata(previous_retry, metadata, :route_fingerprint)
    route_change = pick_retry_metadata(previous_retry, metadata, :route_change)

    if is_reference(old_timer) do
      Process.cancel_timer(old_timer)
    end

    timer_ref = Process.send_after(self(), {:retry_issue, issue_id, retry_token}, delay_ms)

    error_suffix = if is_binary(error), do: " error=#{error}", else: ""

    Logger.warning("Retrying issue_id=#{issue_id} issue_identifier=#{identifier} in #{delay_ms}ms (attempt #{next_attempt})#{error_suffix}")

    %{
      state
      | retry_attempts:
          Map.put(state.retry_attempts, issue_id, %{
            attempt: next_attempt,
            timer_ref: timer_ref,
            retry_token: retry_token,
            due_at_ms: due_at_ms,
            identifier: identifier,
            issue_url: issue_url,
            error: error,
            delay_type: delay_type,
            termination_reason: pick_retry_metadata(previous_retry, metadata, :termination_reason),
            worker_host: worker_host,
            workspace_path: workspace_path,
            session_id: session_id,
            profile_name: profile_name,
            runtime_name: runtime_name,
            responsibility: responsibility,
            sandbox: sandbox,
            route_fingerprint: route_fingerprint,
            route_change: route_change
          }),
        claimed: MapSet.put(state.claimed, issue_id)
    }
  end

  defp pop_retry_attempt_state(%State{} = state, issue_id, retry_token) when is_reference(retry_token) do
    case Map.get(state.retry_attempts, issue_id) do
      %{attempt: attempt, retry_token: ^retry_token} = retry_entry ->
        metadata = %{
          identifier: Map.get(retry_entry, :identifier),
          issue_url: Map.get(retry_entry, :issue_url),
          error: Map.get(retry_entry, :error),
          delay_type: Map.get(retry_entry, :delay_type),
          termination_reason: Map.get(retry_entry, :termination_reason),
          worker_host: Map.get(retry_entry, :worker_host),
          workspace_path: Map.get(retry_entry, :workspace_path),
          session_id: Map.get(retry_entry, :session_id),
          profile_name: Map.get(retry_entry, :profile_name),
          runtime_name: Map.get(retry_entry, :runtime_name),
          responsibility: Map.get(retry_entry, :responsibility),
          sandbox: Map.get(retry_entry, :sandbox),
          route_fingerprint: Map.get(retry_entry, :route_fingerprint),
          route_change: Map.get(retry_entry, :route_change)
        }

        {:ok, attempt, metadata, %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}}

      _ ->
        :missing
    end
  end

  defp handle_retry_issue(%State{} = state, issue_id, attempt, metadata) do
    case Tracker.fetch_issues_by_ids([issue_id]) do
      {:ok, issues} ->
        issues
        |> find_issue_by_id(issue_id)
        |> handle_retry_issue_lookup(state, issue_id, attempt, metadata)

      {:error, reason} ->
        Logger.warning("Retry poll failed for issue_id=#{issue_id} issue_identifier=#{metadata[:identifier] || issue_id}: #{inspect(reason)}")

        retry_issue = retry_issue_from_metadata(issue_id, metadata)

        retry_after_failure(
          state,
          retry_issue,
          attempt,
          metadata,
          "retry poll failed: #{inspect(reason)}"
        )
    end
  end

  defp handle_retry_issue_lookup(%Issue{} = issue, state, issue_id, attempt, metadata) do
    terminal_states = terminal_state_set()

    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue state is terminal: issue_id=#{issue_id} issue_identifier=#{issue.identifier} state=#{issue.state}; removing associated workspace")

        cleanup_issue_workspace(issue, metadata)

        state =
          state
          |> record_recent_attempt(
            issue_id,
            Map.merge(metadata, %{issue: issue, identifier: issue.identifier, attempt: attempt}),
            :terminal
          )
          |> release_issue_claim(issue_id)
          |> reset_attempt_counters(issue_id)

        {:noreply, state}

      retry_candidate_issue?(issue, terminal_states) ->
        handle_active_retry(state, issue, attempt, metadata)

      true ->
        Logger.debug("Issue left active states, removing claim issue_id=#{issue_id} issue_identifier=#{issue.identifier}")

        {:noreply, release_issue_claim(state, issue_id)}
    end
  end

  defp handle_retry_issue_lookup(nil, state, issue_id, _attempt, _metadata) do
    Logger.debug("Issue no longer visible, removing claim issue_id=#{issue_id}")
    {:noreply, release_issue_claim(state, issue_id)}
  end

  defp cleanup_issue_workspace(identifier, worker_host \\ nil)

  defp cleanup_issue_workspace(issue_or_identifier, metadata) when is_map(metadata) do
    case Map.get(metadata, :workspace_path) do
      workspace_path when is_binary(workspace_path) and workspace_path != "" ->
        Workspace.remove_recorded(workspace_path, Map.get(metadata, :worker_host))

      _ ->
        cleanup_issue_workspace(issue_or_identifier, Map.get(metadata, :worker_host))
    end
  end

  defp cleanup_issue_workspace(%Issue{} = issue, worker_host) do
    Workspace.remove_issue_workspaces(issue, worker_host)
  end

  defp cleanup_issue_workspace(identifier, worker_host) when is_binary(identifier) do
    Workspace.remove_issue_workspaces(identifier, worker_host)
  end

  defp cleanup_issue_workspace(_issue_or_identifier, _worker_host), do: :ok

  defp run_terminal_workspace_cleanup do
    case Tracker.fetch_issues_by_states(Config.settings!().tracker.terminal_states) do
      {:ok, issues} ->
        issues
        |> Enum.each(fn
          %Issue{} = issue ->
            cleanup_issue_workspace(issue)

          _ ->
            :ok
        end)

      {:error, reason} ->
        Logger.warning("Skipping startup terminal workspace cleanup; failed to fetch terminal issues: #{inspect(reason)}")
    end
  end

  defp notify_dashboard do
    StatusDashboard.notify_update()
  end

  defp handle_active_retry(state, issue, attempt, metadata) do
    if retry_available_for_dispatch?(issue, state, metadata) do
      dispatch_active_retry(state, issue, attempt, metadata)
    else
      schedule_retry_without_slots(state, issue, attempt, metadata)
    end
  end

  defp retry_available_for_dispatch?(issue, state, metadata) do
    retry_candidate_issue?(issue, terminal_state_set()) and
      dispatch_slots_available?(issue, state) and
      worker_slots_available?(state, metadata[:worker_host])
  end

  defp schedule_retry_without_slots(state, issue, attempt, metadata) do
    Logger.debug("No available slots for retrying #{issue_context(issue)}; retrying again")

    {:ok, state} = record_attempt_event(state, issue.id, :capacity_wait)
    attempt = if is_integer(attempt) and attempt > 0, do: attempt, else: 1

    history_entry =
      metadata
      |> Map.merge(%{issue: issue, identifier: issue.identifier, attempt: attempt})

    state = record_recent_attempt(state, issue.id, history_entry, :capacity_wait, "no available orchestrator slots")

    {:noreply,
     schedule_issue_retry(
       state,
       issue.id,
       attempt,
       Map.merge(metadata, %{
         identifier: issue.identifier,
         delay_type: :capacity_wait,
         error: "no available orchestrator slots"
       })
     )}
  end

  defp dispatch_active_retry(state, issue, attempt, metadata) do
    case refresh_issue_for_dispatch(issue) do
      {:ok, %Issue{} = refreshed_issue} ->
        dispatch_refreshed_retry(state, issue, refreshed_issue, attempt, metadata)

      {:skip, :missing} ->
        {:noreply, release_issue_claim(state, issue.id)}

      {:skip, %Issue{} = refreshed_issue} ->
        handle_retry_issue_lookup(refreshed_issue, state, issue.id, attempt, metadata)

      {:error, reason} ->
        retry_after_refresh_error(state, issue, attempt, metadata, reason)
    end
  end

  defp dispatch_refreshed_retry(state, issue, refreshed_issue, attempt, metadata) do
    state = refresh_dependency_graph_for_dispatch(state, refreshed_issue)
    refreshed_issue = Map.get(state.dependency_graph.nodes, refreshed_issue.id, refreshed_issue)

    cond do
      not retry_candidate_issue?(refreshed_issue, terminal_state_set()) ->
        handle_retry_issue_lookup(refreshed_issue, state, issue.id, attempt, metadata)

      not retry_available_for_dispatch?(refreshed_issue, state, metadata) ->
        schedule_retry_without_slots(state, refreshed_issue, attempt, metadata)

      true ->
        dispatch_final_retry(state, issue, refreshed_issue, attempt, metadata)
    end
  end

  defp dispatch_final_retry(state, issue, refreshed_issue, attempt, metadata) do
    case route_for_issue(refreshed_issue) do
      {:ok, %Route{} = route} ->
        dispatch_routable_retry(state, issue, refreshed_issue, route, attempt, metadata)

      {:error, reason} ->
        retry_after_route_error(state, issue, attempt, metadata, reason)
    end
  end

  defp dispatch_routable_retry(state, issue, refreshed_issue, route, attempt, metadata) do
    state = put_dependency_decision(state, refreshed_issue, route)
    previous = get_in(metadata, [:route_change, :next]) || metadata

    case record_review_cycle_event(state, issue.id, %{previous: previous, next: route_metadata(route)}) do
      {:ok, state} ->
        if dependency_dispatchable?(refreshed_issue, state) do
          {:noreply, do_dispatch_issue(state, refreshed_issue, route, attempt, metadata[:worker_host])}
        else
          {:noreply, release_issue_claim(state, issue.id)}
        end

      {:stop, state, reason} ->
        {:noreply, block_issue_after_attempt_limit(state, refreshed_issue, attempt, metadata, reason)}

      {:error, state, reason} ->
        {:noreply, block_issue_from_entry(state, refreshed_issue.id, metadata, attempt_ledger_error(reason))}
    end
  end

  defp retry_after_route_error(state, issue, attempt, metadata, reason) do
    retry_after_failure(
      state,
      issue,
      attempt,
      metadata,
      "retry route resolution failed: #{inspect(reason)}"
    )
  end

  defp retry_after_refresh_error(state, issue, attempt, metadata, reason) do
    retry_after_failure(
      state,
      issue,
      attempt,
      Map.put(metadata, :identifier, issue.identifier),
      "retry dispatch refresh failed: #{inspect(reason)}"
    )
  end

  defp retry_after_failure(%State{} = state, %Issue{} = issue, attempt, metadata, error)
       when is_integer(attempt) and is_map(metadata) and is_binary(error) do
    metadata = Map.put(metadata, :error, error)

    case record_attempt_event(state, issue.id, :ordinary_failure) do
      {:ok, state} ->
        termination_reason = if runtime_unavailable_error?(error), do: :runtime_unavailable, else: :runtime_failure

        state =
          record_recent_attempt(
            state,
            issue.id,
            Map.merge(metadata, %{issue: issue, identifier: issue.identifier, attempt: attempt + 1}),
            termination_reason,
            error
          )

        {:noreply, schedule_issue_retry(state, issue.id, attempt + 1, metadata)}

      {:stop, state, reason} ->
        {:noreply, block_issue_after_attempt_limit(state, issue, attempt, metadata, reason)}

      {:error, state, reason} ->
        {:noreply, block_issue_from_entry(state, issue.id, metadata, attempt_ledger_error(reason))}
    end
  end

  defp retry_issue_from_metadata(issue_id, metadata) when is_binary(issue_id) and is_map(metadata) do
    %Issue{
      id: issue_id,
      identifier: metadata[:identifier] || issue_id,
      state: "In Progress",
      url: metadata[:issue_url]
    }
  end

  defp release_issue_claim(%State{} = state, issue_id) do
    %{
      state
      | claimed: MapSet.delete(state.claimed, issue_id),
        blocked: Map.delete(state.blocked, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp reset_attempt_counters(%State{} = state, issue_id) when is_binary(issue_id) do
    case state.attempt_ledger_status do
      :disabled ->
        reset_durable_lineage(state, issue_id)

      :ready ->
        reset_ready_attempt_counters(state, issue_id)

      {:blocked, _reason} ->
        state

      _ ->
        block_ledger(state, :invalid_ledger_status)
    end
  end

  defp reset_ready_attempt_counters(%State{attempt_ledger: %AttemptLedger{} = ledger} = state, issue_id) do
    case AttemptLedger.close_lineage(ledger, issue_id, reason: :terminal) do
      :ok -> reset_durable_lineage(state, issue_id)
      {:error, reason} -> block_ledger(state, reason)
    end
  end

  defp reset_ready_attempt_counters(%State{} = state, _issue_id),
    do: block_ledger(state, :missing_ledger_handle)

  defp retry_delay(attempt, metadata) when is_integer(attempt) and attempt > 0 and is_map(metadata) do
    if metadata[:delay_type] in [:continuation, :route_change, :capacity_wait] do
      @continuation_retry_delay_ms
    else
      failure_retry_delay(attempt)
    end
  end

  defp failure_retry_delay(attempt) do
    max_delay_power = min(attempt - 1, 10)
    min(@failure_retry_base_ms * (1 <<< max_delay_power), Config.settings!().agent.max_retry_backoff_ms)
  end

  defp normalize_retry_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  defp normalize_retry_attempt(_attempt), do: 0

  defp next_retry_attempt_from_running(running_entry) do
    case Map.get(running_entry, :retry_attempt) do
      attempt when is_integer(attempt) and attempt > 0 -> attempt + 1
      _ -> nil
    end
  end

  defp pick_retry_identifier(issue_id, previous_retry, metadata) do
    metadata[:identifier] || Map.get(previous_retry, :identifier) || issue_id
  end

  defp pick_retry_issue_url(previous_retry, metadata) do
    metadata[:issue_url] || Map.get(previous_retry, :issue_url)
  end

  defp pick_retry_error(previous_retry, metadata) do
    metadata[:error] || Map.get(previous_retry, :error)
  end

  defp pick_retry_worker_host(previous_retry, metadata) do
    metadata[:worker_host] || Map.get(previous_retry, :worker_host)
  end

  defp pick_retry_workspace_path(previous_retry, metadata) do
    metadata[:workspace_path] || Map.get(previous_retry, :workspace_path)
  end

  defp pick_retry_metadata(previous_retry, metadata, key) do
    metadata[key] || Map.get(previous_retry, key)
  end

  defp route_retry_metadata(running_entry) when is_map(running_entry) do
    %{
      profile_name: Map.get(running_entry, :profile_name),
      runtime_name: Map.get(running_entry, :runtime_name),
      responsibility: Map.get(running_entry, :responsibility),
      sandbox: sandbox_for_entry(running_entry),
      route_fingerprint: Map.get(running_entry, :route_fingerprint),
      session_id: Map.get(running_entry, :session_id)
    }
  end

  defp maybe_put_runtime_value(running_entry, _key, nil), do: running_entry

  defp maybe_put_runtime_value(running_entry, key, value) when is_map(running_entry) do
    Map.put(running_entry, key, value)
  end

  defp select_worker_host(%State{} = state, preferred_worker_host) do
    case Config.settings!().worker.ssh_hosts do
      [] ->
        nil

      hosts ->
        available_hosts = Enum.filter(hosts, &worker_host_slots_available?(state, &1))

        cond do
          available_hosts == [] ->
            :no_worker_capacity

          preferred_worker_host_available?(preferred_worker_host, available_hosts) ->
            preferred_worker_host

          true ->
            least_loaded_worker_host(state, available_hosts)
        end
    end
  end

  defp preferred_worker_host_available?(preferred_worker_host, hosts)
       when is_binary(preferred_worker_host) and is_list(hosts) do
    preferred_worker_host != "" and preferred_worker_host in hosts
  end

  defp preferred_worker_host_available?(_preferred_worker_host, _hosts), do: false

  defp least_loaded_worker_host(%State{} = state, hosts) when is_list(hosts) do
    hosts
    |> Enum.with_index()
    |> Enum.min_by(fn {host, index} ->
      {running_worker_host_count(state.running, host), index}
    end)
    |> elem(0)
  end

  defp running_worker_host_count(running, worker_host) when is_map(running) and is_binary(worker_host) do
    Enum.count(running, fn
      {_issue_id, %{worker_host: ^worker_host}} -> true
      _ -> false
    end)
  end

  defp worker_slots_available?(%State{} = state) do
    select_worker_host(state, nil) != :no_worker_capacity
  end

  defp worker_slots_available?(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host) != :no_worker_capacity
  end

  defp worker_host_slots_available?(%State{} = state, worker_host) when is_binary(worker_host) do
    case Config.settings!().worker.max_concurrent_agents_per_host do
      limit when is_integer(limit) and limit > 0 ->
        running_worker_host_count(state.running, worker_host) < limit

      _ ->
        true
    end
  end

  defp find_issue_by_id(issues, issue_id) when is_binary(issue_id) do
    Enum.find(issues, fn
      %Issue{id: ^issue_id} ->
        true

      _ ->
        false
    end)
  end

  defp find_issue_id_for_ref(running, ref) do
    running
    |> Enum.find_value(fn {issue_id, %{ref: running_ref}} ->
      if running_ref == ref, do: issue_id
    end)
  end

  defp running_entry_session_id(%{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp running_entry_session_id(_running_entry), do: "n/a"

  defp route_for_issue(%Issue{} = issue) do
    settings = Config.settings!()

    if settings.agent.routing == "legacy" do
      if active_issue_state?(issue.state, active_state_set()) do
        {:ok, Route.legacy(issue)}
      else
        {:error, {:not_dispatchable_state, normalize_issue_state(issue.state)}}
      end
    else
      case Router.resolve(issue, settings.agent.profiles, settings.agent.routes) do
        {:ok, %Route{runtime_name: "codex"} = route} ->
          {:ok, route}

        {:ok, %Route{runtime_name: runtime_name}} ->
          {:error, {:runtime_not_available, runtime_name}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp route_dispatchable?(%Issue{} = issue) do
    match?({:ok, %Route{}}, route_for_issue(issue))
  end

  defp route_change_metadata(%Route{} = previous_route, %Route{} = next_route) do
    %{
      previous: route_metadata(previous_route),
      next: route_metadata(next_route)
    }
  end

  defp route_metadata(%Route{} = route) do
    %{
      profile_name: route.profile_name,
      runtime_name: route.runtime_name,
      responsibility: route.responsibility,
      sandbox: route_sandbox(route),
      fingerprint: route.fingerprint
    }
  end

  defp dependency_dispatchable?(%Issue{id: issue_id} = issue, %State{} = state)
       when is_binary(issue_id) do
    decision =
      case Map.get(state.dependency_diagnostics, issue_id) do
        %{allowed?: _} = cached_decision ->
          cached_decision

        _ ->
          case route_for_issue(issue) do
            {:ok, %Route{responsibility: responsibility}} ->
              issue
              |> Guard.evaluate(responsibility, dependency_policy_options())
              |> maybe_mark_dependency_incomplete(state.dependency_graph, issue_id)
              |> maybe_mark_dependency_cycle(state.dependency_graph, issue_id)

            {:error, reason} ->
              route_diagnostic(issue, reason)
          end
      end

    decision.allowed? == true and not dependency_cycle?(state, issue_id)
  end

  defp dependency_dispatchable?(_issue, _state), do: false

  defp put_dependency_decision(
         %State{} = state,
         %Issue{id: issue_id} = issue,
         %Route{responsibility: responsibility}
       )
       when is_binary(issue_id) do
    decision =
      Guard.evaluate(
        issue,
        responsibility,
        dependency_policy_options()
      )

    decision =
      decision
      |> maybe_mark_dependency_incomplete(state.dependency_graph, issue_id)
      |> maybe_mark_dependency_cycle(state.dependency_graph, issue_id)

    %{state | dependency_diagnostics: Map.put(state.dependency_diagnostics, issue_id, decision)}
  end

  defp put_dependency_decision(state, _issue, _route), do: state

  defp dependency_cycle?(%State{dependency_graph: %Graph{} = graph}, issue_id) do
    Graph.cyclic?(graph, issue_id)
  end

  defp dependency_cycle?(_state, _issue_id), do: false

  defp cycle_for_issue(%Graph{} = graph, issue_id) do
    Enum.find(Graph.cycles(graph), &Enum.member?(&1, issue_id)) || []
  end

  defp dependency_policy_options do
    settings = Config.settings!()

    [
      active_states: settings.tracker.active_states || [],
      terminal_states: settings.tracker.terminal_states || []
    ]
  end

  defp route_diagnostic(%Issue{} = issue, reason) do
    %{
      allowed?: false,
      dependency_status: :invalidated,
      dependent_state: normalize_issue_state(issue.state),
      responsibility: nil,
      reason: :route_unavailable,
      merge_permitted?: false,
      blockers: issue.blocked_by,
      unresolved_blockers: [],
      invalidated_blockers: [],
      diagnostic: reason,
      issue_id: issue.id,
      identifier: issue.identifier
    }
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp available_slots(%State{} = state) do
    max(
      (state.max_concurrent_agents || Config.settings!().agent.max_concurrent_agents) -
        map_size(state.running),
      0
    )
  end

  @spec request_refresh() :: map() | :unavailable
  def request_refresh do
    request_refresh(__MODULE__)
  end

  @spec request_refresh(GenServer.server()) :: map() | :unavailable
  def request_refresh(server) do
    if Process.whereis(server) do
      GenServer.call(server, :request_refresh)
    else
      :unavailable
    end
  end

  @spec snapshot() :: map() | :timeout | :unavailable
  def snapshot, do: snapshot(__MODULE__, 15_000)

  @spec snapshot(GenServer.server(), timeout()) :: map() | :timeout | :unavailable
  def snapshot(server, timeout) do
    if Process.whereis(server) do
      try do
        GenServer.call(server, :snapshot, timeout)
      catch
        :exit, {:timeout, _} -> :timeout
        :exit, _ -> :unavailable
      end
    else
      :unavailable
    end
  end

  @doc false
  @spec observability_error(term()) :: String.t() | nil
  def observability_error(value), do: snapshot_safe_error(value)

  @doc false
  @spec observability_codex_message(term()) :: term()
  def observability_codex_message(value), do: snapshot_safe_codex_message(value)

  @doc false
  @spec observability_event(term()) :: term()
  def observability_event(value), do: snapshot_safe_event(value)

  @doc false
  @spec observability_dependency(term()) :: map() | nil
  def observability_dependency(value), do: snapshot_dependency_metadata(value)

  @doc false
  @spec observability_rate_limits(term()) :: map() | nil
  def observability_rate_limits(value), do: snapshot_safe_rate_limits(value)

  @doc false
  @spec observability_route_change(term()) :: map() | nil
  def observability_route_change(value), do: snapshot_safe_route_change(value)

  @doc false
  @spec observability_graph(term()) :: map()
  def observability_graph(value), do: snapshot_dependency_graph_value(value)

  @doc false
  @spec observability_completeness(term()) :: term()
  def observability_completeness(value), do: safe_dependency_completeness(value)

  @doc false
  @spec observability_termination_reason(term()) :: atom() | nil
  def observability_termination_reason(reason) when reason in @observability_termination_reasons,
    do: reason

  def observability_termination_reason(nil), do: nil
  def observability_termination_reason(_reason), do: :unknown

  @impl true
  def handle_call(:snapshot, _from, state) do
    state = refresh_runtime_config(state)
    now = DateTime.utc_now()
    now_ms = System.monotonic_time(:millisecond)

    running =
      state.running
      |> Enum.map(fn {issue_id, metadata} ->
        %{
          issue_id: issue_id,
          identifier: safe_identifier(Map.get(metadata, :identifier)),
          issue_url: safe_identifier(issue_url(Map.get(metadata, :issue))),
          state: safe_identifier(Map.get(Map.get(metadata, :issue), :state)),
          dependency: snapshot_dependency_for_issue(state, issue_id),
          dependency_completeness: snapshot_dependency_completeness(state, issue_id),
          profile_name: safe_identifier(Map.get(metadata, :profile_name)),
          runtime_name: safe_identifier(Map.get(metadata, :runtime_name)),
          responsibility: safe_identifier(Map.get(metadata, :responsibility)),
          sandbox: safe_identifier(sandbox_for_entry(metadata)),
          route_fingerprint: safe_identifier(Map.get(metadata, :route_fingerprint)),
          route_change_termination: Map.get(metadata, :route_change_termination, false),
          route_change: observability_route_change(Map.get(metadata, :route_change)),
          worker_host: safe_identifier(Map.get(metadata, :worker_host)),
          workspace_path: safe_identifier(Map.get(metadata, :workspace_path)),
          session_id: safe_identifier(Map.get(metadata, :session_id)),
          codex_app_server_pid: safe_identifier(Map.get(metadata, :codex_app_server_pid)),
          codex_input_tokens: Map.get(metadata, :codex_input_tokens, 0),
          codex_output_tokens: Map.get(metadata, :codex_output_tokens, 0),
          codex_total_tokens: Map.get(metadata, :codex_total_tokens, 0),
          turn_count: Map.get(metadata, :turn_count, 0),
          started_at: Map.get(metadata, :started_at),
          last_codex_timestamp: Map.get(metadata, :last_codex_timestamp),
          last_codex_message: observability_codex_message(Map.get(metadata, :last_codex_message)),
          last_codex_event: observability_event(Map.get(metadata, :last_codex_event)),
          attempt_counters: attempt_counters_for(state, issue_id),
          termination_reason: observability_termination_reason(Map.get(metadata, :termination_reason)),
          runtime_seconds: running_seconds(Map.get(metadata, :started_at), now)
        }
      end)

    retrying =
      state.retry_attempts
      |> Enum.map(fn {issue_id, %{attempt: attempt, due_at_ms: due_at_ms} = retry} ->
        %{
          issue_id: issue_id,
          attempt: attempt,
          due_in_ms: max(0, due_at_ms - now_ms),
          identifier: safe_identifier(Map.get(retry, :identifier)),
          issue_url: safe_identifier(Map.get(retry, :issue_url)),
          error: observability_error(Map.get(retry, :error)),
          worker_host: safe_identifier(Map.get(retry, :worker_host)),
          workspace_path: safe_identifier(Map.get(retry, :workspace_path)),
          session_id: safe_identifier(Map.get(retry, :session_id)),
          profile_name: safe_identifier(Map.get(retry, :profile_name)),
          runtime_name: safe_identifier(Map.get(retry, :runtime_name)),
          responsibility: safe_identifier(Map.get(retry, :responsibility)),
          sandbox: safe_identifier(Map.get(retry, :sandbox)),
          route_fingerprint: safe_identifier(Map.get(retry, :route_fingerprint)),
          route_change: observability_route_change(Map.get(retry, :route_change)),
          attempt_counters: attempt_counters_for(state, issue_id),
          dependency_completeness: snapshot_dependency_completeness(state, issue_id),
          delay_type: Map.get(retry, :delay_type),
          termination_reason: retry_termination_reason(retry)
        }
      end)

    blocked =
      state.blocked
      |> Enum.map(fn {issue_id, metadata} ->
        %{
          issue_id: issue_id,
          identifier: safe_identifier(Map.get(metadata, :identifier)),
          issue_url: safe_identifier(blocked_issue_url(metadata)),
          state: safe_identifier(blocked_issue_state(metadata)),
          profile_name: safe_identifier(Map.get(metadata, :profile_name)),
          runtime_name: safe_identifier(Map.get(metadata, :runtime_name)),
          responsibility: safe_identifier(Map.get(metadata, :responsibility)),
          sandbox: safe_identifier(sandbox_for_entry(metadata)),
          route_fingerprint: safe_identifier(Map.get(metadata, :route_fingerprint)),
          worker_host: safe_identifier(Map.get(metadata, :worker_host)),
          workspace_path: safe_identifier(Map.get(metadata, :workspace_path)),
          attempt: Map.get(metadata, :retry_attempt, 0),
          session_id: safe_identifier(Map.get(metadata, :session_id)),
          error: observability_error(Map.get(metadata, :error)),
          attempt_counters: attempt_counters_for(state, issue_id),
          dependency_completeness: snapshot_dependency_completeness(state, issue_id),
          termination_reason: observability_termination_reason(Map.get(metadata, :termination_reason)),
          dependency: snapshot_dependency_metadata(Map.get(metadata, :dependency)),
          blocked_at: Map.get(metadata, :blocked_at),
          last_codex_timestamp: Map.get(metadata, :last_codex_timestamp),
          last_codex_message: observability_codex_message(Map.get(metadata, :last_codex_message)),
          last_codex_event: observability_event(Map.get(metadata, :last_codex_event))
        }
      end)

    {:reply,
     %{
       running: running,
       retrying: retrying,
       blocked: blocked,
       recent_attempts: snapshot_recent_attempts(state),
       dependency_diagnostics: snapshot_dependency_diagnostics(state),
       dependency_graph: snapshot_dependency_graph(state),
       codex_totals: state.codex_totals,
       rate_limits: observability_rate_limits(Map.get(state, :codex_rate_limits)),
       polling: %{
         checking?: state.poll_check_in_progress == true,
         next_poll_in_ms: next_poll_in_ms(state.next_poll_due_at_ms, now_ms),
         poll_interval_ms: state.poll_interval_ms
       }
     }, state}
  end

  def handle_call(:request_refresh, _from, state) do
    now_ms = System.monotonic_time(:millisecond)
    already_due? = is_integer(state.next_poll_due_at_ms) and state.next_poll_due_at_ms <= now_ms
    coalesced = state.poll_check_in_progress == true or already_due?
    state = if coalesced, do: state, else: schedule_tick(state, 0)

    {:reply,
     %{
       queued: true,
       coalesced: coalesced,
       requested_at: DateTime.utc_now(),
       operations: ["poll", "reconcile"]
     }, state}
  end

  defp blocked_issue_state(%{issue: %Issue{state: state}}), do: state
  defp blocked_issue_state(_metadata), do: nil

  defp blocked_issue_url(%{issue: %Issue{url: url}}), do: url
  defp blocked_issue_url(_metadata), do: nil

  defp attempt_counters_for(%State{} = state, issue_id) when is_binary(issue_id) do
    state.attempt_counters
    |> Map.get(issue_id, AttemptPolicy.new())
    |> then(&Map.merge(AttemptPolicy.new(), &1))
    |> safe_attempt_counters()
  end

  defp attempt_counters_for(_state, _issue_id), do: AttemptPolicy.new()

  defp snapshot_dependency_completeness(%State{dependency_graph: %Graph{} = graph} = state, issue_id)
       when is_binary(issue_id) do
    decision = Map.get(state.dependency_diagnostics, issue_id)

    (Map.get(decision || %{}, :dependency_completeness) ||
       Graph.incompleteness_reason(graph, issue_id) || graph.completeness)
    |> safe_dependency_completeness()
  end

  defp snapshot_dependency_completeness(%State{dependency_graph: graph}, _issue_id),
    do: safe_dependency_completeness(graph)

  defp snapshot_dependency_completeness(_state, _issue_id), do: {:unavailable, :unknown}

  defp sandbox_for_entry(entry) when is_map(entry) do
    Map.get(entry, :sandbox) || route_sandbox(Map.get(entry, :route))
  end

  defp route_sandbox(%Route{profile: profile}) when is_map(profile), do: Map.get(profile, :sandbox)
  defp route_sandbox(_route), do: nil

  defp retry_termination_reason(retry) when is_map(retry) do
    retry_termination_reason(
      observability_termination_reason(Map.get(retry, :termination_reason)),
      retry
    )
  end

  defp retry_termination_reason(nil, retry), do: retry_default_termination_reason(retry)
  defp retry_termination_reason(reason, _retry), do: reason

  defp retry_default_termination_reason(%{delay_type: :capacity_wait}), do: :capacity_wait
  defp retry_default_termination_reason(%{delay_type: :route_change}), do: :route_changed
  defp retry_default_termination_reason(%{delay_type: :continuation}), do: :normal_completion

  defp retry_default_termination_reason(retry) do
    if runtime_unavailable_error?(Map.get(retry, :error)),
      do: :runtime_unavailable,
      else: :runtime_failure
  end

  defp snapshot_recent_attempts(%State{recent_attempts: attempts}) when is_list(attempts) do
    attempts
    |> Enum.take(@recent_attempt_limit)
    |> Enum.map(&snapshot_recent_attempt/1)
  end

  defp snapshot_recent_attempts(_state), do: []

  defp snapshot_recent_attempt(attempt) when is_map(attempt) do
    %{
      issue_id: Map.get(attempt, :issue_id),
      identifier: safe_identifier(Map.get(attempt, :identifier)),
      issue_url: safe_identifier(Map.get(attempt, :issue_url)),
      termination_reason: observability_termination_reason(Map.get(attempt, :termination_reason)),
      attempt: Map.get(attempt, :attempt, 0),
      profile_name: safe_identifier(Map.get(attempt, :profile_name)),
      runtime_name: safe_identifier(Map.get(attempt, :runtime_name)),
      responsibility: safe_identifier(Map.get(attempt, :responsibility)),
      sandbox: safe_identifier(Map.get(attempt, :sandbox)),
      route_fingerprint: safe_identifier(Map.get(attempt, :route_fingerprint)),
      worker_host: safe_identifier(Map.get(attempt, :worker_host)),
      workspace_path: safe_identifier(Map.get(attempt, :workspace_path)),
      session_id: safe_identifier(Map.get(attempt, :session_id)),
      attempt_counters: safe_attempt_counters(Map.get(attempt, :attempt_counters)),
      dependency_completeness: safe_dependency_completeness(Map.get(attempt, :dependency_completeness)),
      dependency: snapshot_dependency_metadata(Map.get(attempt, :dependency)),
      error: observability_error(Map.get(attempt, :error)),
      at: Map.get(attempt, :at)
    }
  end

  defp snapshot_recent_attempt(_attempt), do: %{termination_reason: :invalid_attempt}

  defp safe_attempt_counters(counters) when is_map(counters) do
    AttemptPolicy.new()
    |> Map.merge(Map.take(counters, Map.keys(AttemptPolicy.new())))
    |> Enum.map(fn {key, value} -> {key, if(is_integer(value) and value >= 0, do: value, else: 0)} end)
    |> Map.new()
  end

  defp safe_attempt_counters(_counters), do: AttemptPolicy.new()

  defp snapshot_dependency_for_issue(%State{} = state, issue_id) do
    state.dependency_diagnostics
    |> Map.get(issue_id)
    |> snapshot_dependency_metadata()
  end

  defp snapshot_dependency_diagnostics(%State{dependency_diagnostics: diagnostics})
       when is_map(diagnostics) do
    diagnostics
    |> Enum.map(fn {issue_id, decision} ->
      snapshot_dependency_metadata(Map.put(decision, :issue_id, issue_id))
    end)
    |> Enum.sort_by(& &1.issue_id)
  end

  defp snapshot_dependency_diagnostics(_state), do: []

  defp snapshot_dependency_graph(%State{dependency_graph: %Graph{} = graph}) do
    snapshot_dependency_graph_value(graph)
  end

  defp snapshot_dependency_graph(_state), do: snapshot_dependency_graph_value(nil)

  defp snapshot_dependency_graph_value(%Graph{} = graph) do
    %{
      completeness: safe_dependency_completeness(graph.completeness),
      cycles: safe_cycle_list(Graph.cycles(graph)),
      diagnostics: Enum.map(graph.diagnostics, &snapshot_graph_diagnostic/1)
    }
  end

  defp snapshot_dependency_graph_value(%{} = graph) do
    %{
      completeness: safe_dependency_completeness(Map.get(graph, :completeness)),
      cycles: safe_cycle_list(Map.get(graph, :cycles, [])),
      diagnostics: safe_graph_diagnostics(Map.get(graph, :diagnostics, []))
    }
  end

  defp snapshot_dependency_graph_value(_graph), do: %{completeness: {:unavailable, :unknown}, cycles: [], diagnostics: []}

  defp safe_cycle_list(cycles) when is_list(cycles) do
    cycles
    |> Enum.filter(&is_list/1)
    |> Enum.take(@recent_attempt_limit)
    |> Enum.map(fn cycle -> Enum.take(cycle, @recent_attempt_limit) |> Enum.map(&safe_identifier/1) end)
  end

  defp safe_cycle_list(_cycles), do: []

  defp safe_graph_diagnostics(diagnostics) when is_list(diagnostics),
    do: Enum.take(diagnostics, @recent_attempt_limit) |> Enum.map(&snapshot_graph_diagnostic/1)

  defp safe_graph_diagnostics(_diagnostics), do: []

  defp safe_dependency_completeness(nil), do: nil
  defp safe_dependency_completeness(:complete), do: :complete

  defp safe_dependency_completeness({kind, reason}) when kind in [:incomplete, :unavailable] do
    {kind, safe_reason(reason)}
  end

  defp safe_dependency_completeness(_completeness), do: {:incomplete, :redacted}

  defp safe_boolean(value) when is_boolean(value), do: value
  defp safe_boolean(_value), do: nil

  defp snapshot_dependency_metadata(nil), do: nil

  defp snapshot_dependency_metadata(decision) when is_map(decision) do
    %{
      issue_id: safe_identifier(Map.get(decision, :issue_id)),
      identifier: safe_identifier(Map.get(decision, :identifier)),
      dependent_state: safe_identifier(Map.get(decision, :dependent_state)),
      responsibility: safe_identifier(Map.get(decision, :responsibility)),
      dependency_status: safe_identifier(Map.get(decision, :dependency_status)),
      reason: safe_reason(Map.get(decision, :reason)),
      allowed?: safe_boolean(Map.get(decision, :allowed?)),
      merge_permitted?: safe_boolean(Map.get(decision, :merge_permitted?)),
      dependency_completeness: safe_dependency_completeness(Map.get(decision, :dependency_completeness)),
      blockers: safe_blocker_list(Map.get(decision, :blockers, [])),
      unresolved_blockers: safe_blocker_list(Map.get(decision, :unresolved_blockers, [])),
      invalidated_blockers: safe_blocker_list(Map.get(decision, :invalidated_blockers, [])),
      diagnostic: safe_dependency_diagnostic(Map.get(decision, :diagnostic))
    }
  end

  defp snapshot_dependency_metadata(_decision), do: nil

  defp safe_blocker_list(blockers) when is_list(blockers), do: Enum.map(blockers, &safe_blocker/1)
  defp safe_blocker_list(_blockers), do: []

  defp safe_blocker(blocker) when is_map(blocker) do
    %{
      id: safe_identifier(Map.get(blocker, :id) || Map.get(blocker, "id")),
      identifier: safe_identifier(Map.get(blocker, :identifier) || Map.get(blocker, "identifier")),
      state: safe_identifier(Map.get(blocker, :state) || Map.get(blocker, "state"))
    }
  end

  defp safe_blocker(_blocker), do: %{id: nil, identifier: nil, state: nil}

  defp safe_dependency_diagnostic(nil), do: nil
  defp safe_dependency_diagnostic({:dependency_cycle, cycle}) when is_list(cycle), do: %{kind: :dependency_cycle, members: safe_cycle_ids(cycle)}
  defp safe_dependency_diagnostic({:unknown_blocker_state, state}) when is_binary(state), do: %{kind: :unknown_blocker_state, state: safe_identifier(state)}
  defp safe_dependency_diagnostic({:malformed_blocker, blocker}), do: %{kind: :malformed_blocker, blocker: safe_blocker(blocker)}
  defp safe_dependency_diagnostic(reason) when is_atom(reason), do: reason
  defp safe_dependency_diagnostic(_reason), do: :redacted

  defp snapshot_graph_diagnostic(%{kind: kind, dependent_id: dependent_id, blocker_id: blocker_id, blocker: blocker}) do
    %{
      kind: safe_identifier(kind),
      dependent_id: safe_identifier(dependent_id),
      blocker_id: safe_identifier(blocker_id),
      blocker: safe_blocker(blocker)
    }
  end

  defp snapshot_graph_diagnostic(_diagnostic), do: %{kind: :invalid_diagnostic}

  defp safe_cycle_ids(ids) when is_list(ids) do
    ids
    |> Enum.take(@recent_attempt_limit)
    |> Enum.map(&safe_identifier/1)
  end

  defp safe_cycle_ids(_ids), do: []

  defp safe_identifier(nil), do: nil

  defp safe_identifier(value) when is_atom(value), do: value

  defp safe_identifier(value) when is_binary(value) do
    value = normalize_observability_text(value)

    if unsafe_observability_text?(value) do
      "[redacted]"
    else
      String.slice(value, 0, @observability_text_limit)
    end
  end

  defp safe_identifier(_value), do: "[redacted]"

  defp snapshot_safe_error(nil), do: nil

  defp snapshot_safe_error(value) when is_binary(value) do
    value = normalize_observability_text(value)

    cond do
      value == "" -> nil
      unsafe_observability_text?(value) -> "runtime error details redacted"
      true -> String.slice(value, 0, @observability_text_limit)
    end
  end

  defp snapshot_safe_error(_value), do: "runtime error details redacted"

  defp snapshot_safe_codex_message(nil), do: nil

  defp snapshot_safe_codex_message(%{event: event, message: message, timestamp: timestamp}) do
    %{event: snapshot_safe_event(event), message: safe_codex_value(message), timestamp: timestamp}
  end

  defp snapshot_safe_codex_message(%{} = message), do: safe_codex_value(message)

  defp snapshot_safe_codex_message(value) when is_binary(value) do
    if unsafe_observability_text?(value), do: "codex event details redacted", else: safe_codex_string(value)
  end

  defp snapshot_safe_codex_message(_value), do: "codex event details redacted"

  defp snapshot_safe_event(nil), do: nil
  defp snapshot_safe_event(value) when is_atom(value), do: value

  defp snapshot_safe_event(value) when is_binary(value) do
    value = normalize_observability_text(value)

    if unsafe_observability_text?(value) do
      "[redacted]"
    else
      String.slice(value, 0, @observability_text_limit)
    end
  end

  defp snapshot_safe_event(_value), do: :unknown

  defp safe_codex_value(%DateTime{} = value), do: value

  defp safe_codex_value(value) when is_map(value) do
    {safe_value, redacted?} =
      value
      |> Enum.take(@recent_attempt_limit)
      |> Enum.reduce({%{}, false}, fn {key, nested}, {result, redacted?} ->
        if unsafe_observability_key?(key) do
          {result, true}
        else
          {Map.put(result, key, safe_codex_value_for_key(key, nested)), redacted?}
        end
      end)

    if redacted?, do: Map.put(safe_value, redacted_key(value), true), else: safe_value
  end

  defp safe_codex_value(value) when is_list(value) do
    value
    |> Enum.take(@recent_attempt_limit)
    |> Enum.map(&safe_codex_value/1)
  end

  defp safe_codex_value(value) when is_binary(value), do: safe_codex_string(value)
  defp safe_codex_value(value) when is_number(value) or is_boolean(value) or is_atom(value), do: value
  defp safe_codex_value(_value), do: "[redacted]"

  defp safe_codex_value_for_key(key, value) do
    if key_name(key) in ["method", "event", "type", "status", "tool"] and is_binary(value) do
      safe_codex_string(value)
    else
      safe_codex_value(value)
    end
  end

  defp safe_codex_string(value) when is_binary(value) do
    value = normalize_observability_text(value)
    if unsafe_observability_text?(value), do: "[redacted]", else: String.slice(value, 0, @observability_text_limit)
  end

  defp redacted_key(value) when is_map(value) do
    if Enum.any?(Map.keys(value), &is_binary/1), do: "redacted", else: :redacted
  end

  defp snapshot_safe_rate_limits(nil), do: nil

  defp snapshot_safe_rate_limits(%{} = rate_limits) do
    snapshot_safe_rate_limit_map(rate_limits, @observability_rate_limit_keys)
  end

  defp snapshot_safe_rate_limits(_rate_limits), do: nil

  defp snapshot_safe_rate_limit_map(value, allowed_keys) when is_map(value) do
    value
    |> Enum.take(@recent_attempt_limit)
    |> Enum.reduce(%{}, &put_safe_rate_limit_field(&1, &2, allowed_keys))
  end

  defp put_safe_rate_limit_field({key, nested}, result, allowed_keys) do
    normalized_key = key_name(key)

    if normalized_key in allowed_keys do
      put_safe_rate_limit_value(result, key, normalized_key, nested)
    else
      result
    end
  end

  defp put_safe_rate_limit_value(result, output_key, normalized_key, nested) do
    case snapshot_safe_rate_limit_value(normalized_key, nested) do
      {:ok, safe_value} -> Map.put(result, output_key, safe_value)
      :drop -> result
    end
  end

  defp snapshot_safe_rate_limit_value(key, value)
       when key in ["primary", "secondary"] and is_map(value) do
    {:ok, snapshot_safe_rate_limit_map(value, @observability_rate_bucket_keys)}
  end

  defp snapshot_safe_rate_limit_value("credits", value) when is_map(value) do
    {:ok, snapshot_safe_rate_limit_map(value, @observability_rate_credit_keys)}
  end

  defp snapshot_safe_rate_limit_value(key, value) when key in ["primary", "secondary", "credits"],
    do: safe_rate_limit_scalar(value)

  defp snapshot_safe_rate_limit_value(key, value) when key in @observability_rate_bucket_keys,
    do: safe_rate_limit_scalar(value)

  defp snapshot_safe_rate_limit_value(key, value) when key in @observability_rate_credit_keys,
    do: safe_rate_limit_scalar(value)

  defp snapshot_safe_rate_limit_value(key, value) when key in ["limit_id", "limit_name"],
    do: safe_rate_limit_scalar(value)

  defp snapshot_safe_rate_limit_value(_key, _value), do: :drop

  defp safe_rate_limit_scalar(nil), do: {:ok, nil}
  defp safe_rate_limit_scalar(value) when is_number(value) or is_boolean(value), do: {:ok, value}

  defp safe_rate_limit_scalar(%DateTime{} = value),
    do: {:ok, DateTime.to_iso8601(DateTime.truncate(value, :second))}

  defp safe_rate_limit_scalar(value) when is_binary(value) do
    value = normalize_observability_text(value)

    if unsafe_observability_text?(value) do
      {:ok, "[redacted]"}
    else
      {:ok, String.slice(value, 0, @observability_text_limit)}
    end
  end

  defp safe_rate_limit_scalar(_value), do: :drop

  defp snapshot_safe_route_change(nil), do: nil

  defp snapshot_safe_route_change(%{} = route_change) do
    result =
      Enum.reduce([:previous, :next], %{}, fn key, result ->
        put_safe_route_change(result, route_change, key)
      end)

    result
    |> case do
      result when map_size(result) == 0 -> nil
      result -> result
    end
  end

  defp snapshot_safe_route_change(_route_change), do: nil

  defp put_safe_route_change(result, route_change, key) do
    case observability_map_value(route_change, key) do
      metadata when is_map(metadata) -> Map.put(result, key, snapshot_safe_route_metadata(metadata))
      _ -> result
    end
  end

  defp snapshot_safe_route_metadata(metadata) when is_map(metadata) do
    [:profile_name, :runtime_name, :responsibility, :sandbox, :fingerprint]
    |> Enum.reduce(%{}, fn key, result ->
      case observability_map_value(metadata, key) do
        nil -> result
        value -> Map.put(result, key, safe_identifier(value))
      end
    end)
  end

  defp observability_map_value(value, key) when is_map(value) and is_atom(key) do
    case Map.fetch(value, key) do
      {:ok, nested} -> nested
      :error -> Map.get(value, Atom.to_string(key))
    end
  end

  defp observability_map_value(_value, _key), do: nil

  defp key_name(key) when is_atom(key), do: Atom.to_string(key)
  defp key_name(key) when is_binary(key), do: String.downcase(key)
  defp key_name(key), do: to_string(key) |> String.downcase()

  defp unsafe_observability_key?(key) do
    key = key_name(key)

    Enum.any?(
      [
        "api_key",
        "apikey",
        "authorization",
        "bearer",
        "client_secret",
        "cookie",
        "command",
        "parsedcmd",
        "environment",
        "env",
        "graphql",
        "headers",
        "password",
        "prompt",
        "question",
        "query",
        "raw",
        "refresh_token",
        "secret",
        "token",
        "variables"
      ],
      &String.contains?(key, &1)
    )
  end

  defp unsafe_observability_text?(value) when is_binary(value) do
    downcased = String.downcase(value)

    Enum.any?(
      [
        "api_key",
        "api-key",
        "authorization",
        "bearer ",
        "client_secret",
        "command=",
        "parsedcmd",
        "environment",
        "graphql",
        "mutation ",
        "password",
        "query ",
        "raw_",
        "refresh_token",
        "secret",
        "secret=",
        "private_key",
        "token=",
        "token:",
        "access_token",
        "cookie"
      ],
      &String.contains?(downcased, &1)
    ) or
      Regex.match?(~r/(^|\s)(curl|wget|git|mix|npm|yarn|pnpm|bash|sh|rm|mv|cp|mkdir|find|sed|awk|docker|kubectl|terraform|node|python|python3|ruby|go|cargo|make|pytest|java|gradle)\s+/, downcased)
  end

  defp normalize_observability_text(value) when is_binary(value) do
    value
    |> String.replace(~r/[\r\n\t]+/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp safe_reason(nil), do: nil
  defp safe_reason(reason) when is_atom(reason), do: reason
  defp safe_reason({kind, _detail}) when is_atom(kind), do: kind
  defp safe_reason(_reason), do: :redacted

  defp runtime_unavailable_error?(error) when is_binary(error) do
    downcased = String.downcase(error)

    Enum.any?(
      [
        "retry poll failed",
        "retry route resolution failed",
        "retry dispatch refresh failed",
        "runtime unavailable",
        "runtime not available",
        "provider"
      ],
      &String.contains?(downcased, &1)
    )
  end

  defp runtime_unavailable_error?(_error), do: false

  defp integrate_codex_update(running_entry, %{event: event, timestamp: timestamp} = update) do
    token_delta = extract_token_delta(running_entry, update)
    codex_input_tokens = Map.get(running_entry, :codex_input_tokens, 0)
    codex_output_tokens = Map.get(running_entry, :codex_output_tokens, 0)
    codex_total_tokens = Map.get(running_entry, :codex_total_tokens, 0)
    codex_app_server_pid = Map.get(running_entry, :codex_app_server_pid)
    last_reported_input = Map.get(running_entry, :codex_last_reported_input_tokens, 0)
    last_reported_output = Map.get(running_entry, :codex_last_reported_output_tokens, 0)
    last_reported_total = Map.get(running_entry, :codex_last_reported_total_tokens, 0)
    turn_count = Map.get(running_entry, :turn_count, 0)

    {
      Map.merge(running_entry, %{
        last_codex_timestamp: timestamp,
        last_codex_message: summarize_codex_update(update),
        session_id: session_id_for_update(running_entry.session_id, update),
        last_codex_event: event,
        codex_app_server_pid: codex_app_server_pid_for_update(codex_app_server_pid, update),
        codex_input_tokens: codex_input_tokens + token_delta.input_tokens,
        codex_output_tokens: codex_output_tokens + token_delta.output_tokens,
        codex_total_tokens: codex_total_tokens + token_delta.total_tokens,
        codex_last_reported_input_tokens: max(last_reported_input, token_delta.input_reported),
        codex_last_reported_output_tokens: max(last_reported_output, token_delta.output_reported),
        codex_last_reported_total_tokens: max(last_reported_total, token_delta.total_reported),
        turn_count: turn_count_for_update(turn_count, running_entry.session_id, update)
      }),
      token_delta
    }
  end

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_binary(pid),
       do: pid

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_integer(pid),
       do: Integer.to_string(pid)

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid}) when is_list(pid),
    do: to_string(pid)

  defp codex_app_server_pid_for_update(existing, _update), do: existing

  defp session_id_for_update(_existing, %{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp session_id_for_update(existing, _update), do: existing

  defp turn_count_for_update(existing_count, existing_session_id, %{
         event: :session_started,
         session_id: session_id
       })
       when is_integer(existing_count) and is_binary(session_id) do
    if session_id == existing_session_id do
      existing_count
    else
      existing_count + 1
    end
  end

  defp turn_count_for_update(existing_count, _existing_session_id, _update)
       when is_integer(existing_count),
       do: existing_count

  defp turn_count_for_update(_existing_count, _existing_session_id, _update), do: 0

  defp summarize_codex_update(update) do
    %{
      event: update[:event],
      message: update[:payload] || update[:raw],
      timestamp: update[:timestamp]
    }
  end

  defp schedule_tick(%State{} = state, delay_ms) when is_integer(delay_ms) and delay_ms >= 0 do
    if is_reference(state.tick_timer_ref) do
      Process.cancel_timer(state.tick_timer_ref)
    end

    tick_token = make_ref()
    timer_ref = Process.send_after(self(), {:tick, tick_token}, delay_ms)

    %{
      state
      | tick_timer_ref: timer_ref,
        tick_token: tick_token,
        next_poll_due_at_ms: System.monotonic_time(:millisecond) + delay_ms
    }
  end

  defp schedule_poll_cycle_start do
    :timer.send_after(@poll_transition_render_delay_ms, self(), :run_poll_cycle)
    :ok
  end

  defp next_poll_in_ms(nil, _now_ms), do: nil

  defp next_poll_in_ms(next_poll_due_at_ms, now_ms) when is_integer(next_poll_due_at_ms) do
    max(0, next_poll_due_at_ms - now_ms)
  end

  defp pop_running_entry(state, issue_id) do
    {Map.get(state.running, issue_id), %{state | running: Map.delete(state.running, issue_id)}}
  end

  defp record_session_completion_totals(state, running_entry) when is_map(running_entry) do
    runtime_seconds = running_seconds(running_entry.started_at, DateTime.utc_now())

    codex_totals =
      apply_token_delta(
        state.codex_totals,
        %{
          input_tokens: 0,
          output_tokens: 0,
          total_tokens: 0,
          seconds_running: runtime_seconds
        }
      )

    %{state | codex_totals: codex_totals}
  end

  defp record_session_completion_totals(state, _running_entry), do: state

  defp refresh_runtime_config(%State{} = state) do
    config = Config.settings!()

    state = %{
      state
      | poll_interval_ms: config.polling.interval_ms,
        max_concurrent_agents: config.agent.max_concurrent_agents
    }

    synchronize_attempt_ledger_config(state, config)
  end

  defp synchronize_attempt_ledger_config(%State{} = state, %{agent: %{routing: "legacy"}}) do
    case state.attempt_ledger do
      nil ->
        %{state | attempt_ledger_status: :disabled, attempt_ledger_opts: []}

      %AttemptLedger{} = ledger ->
        case AttemptLedger.close(ledger) do
          :ok -> %{state | attempt_ledger: nil, attempt_ledger_status: :disabled, attempt_ledger_opts: []}
          {:error, reason} -> block_ledger(state, {:ledger_close_failed, reason})
        end
    end
  end

  defp synchronize_attempt_ledger_config(%State{} = state, config) do
    project_id = config.symphony.project_id
    tracker_identity = Tracker.identity(config.tracker)

    case state.attempt_ledger_status do
      :disabled ->
        initialize_attempt_ledger(
          state,
          config,
          attempt_ledger_opts: state.attempt_ledger_opts
        )

      :ready ->
        case state.attempt_ledger do
          %AttemptLedger{project_id: ^project_id, tracker_identity: ^tracker_identity} ->
            state

          %AttemptLedger{project_id: stored_project_id}
          when stored_project_id != project_id ->
            block_ledger(
              state,
              {:ledger_project_namespace_mismatch, stored_project_id, project_id}
            )

          %AttemptLedger{tracker_identity: stored_identity} ->
            block_ledger(
              state,
              {:ledger_tracker_identity_mismatch, stored_identity, tracker_identity}
            )

          _ ->
            block_ledger(state, :missing_ledger_handle)
        end

      {:blocked, _reason} ->
        state

      _ ->
        block_ledger(state, :invalid_ledger_status)
    end
  end

  defp retry_candidate_issue?(%Issue{} = issue, terminal_states) do
    candidate_issue?(issue, active_state_set(), terminal_states)
  end

  defp dispatch_slots_available?(%Issue{} = issue, %State{} = state) do
    available_slots(state) > 0 and state_slots_available?(issue, state.running)
  end

  defp apply_codex_token_delta(
         %{codex_totals: codex_totals} = state,
         %{input_tokens: input, output_tokens: output, total_tokens: total} = token_delta
       )
       when is_integer(input) and is_integer(output) and is_integer(total) do
    %{state | codex_totals: apply_token_delta(codex_totals, token_delta)}
  end

  defp apply_codex_token_delta(state, _token_delta), do: state

  defp apply_codex_rate_limits(%State{} = state, update) when is_map(update) do
    case extract_rate_limits(update) do
      %{} = rate_limits ->
        %{state | codex_rate_limits: rate_limits}

      _ ->
        state
    end
  end

  defp apply_codex_rate_limits(state, _update), do: state

  defp apply_token_delta(codex_totals, token_delta) do
    input_tokens = Map.get(codex_totals, :input_tokens, 0) + token_delta.input_tokens
    output_tokens = Map.get(codex_totals, :output_tokens, 0) + token_delta.output_tokens
    total_tokens = Map.get(codex_totals, :total_tokens, 0) + token_delta.total_tokens

    seconds_running =
      Map.get(codex_totals, :seconds_running, 0) + Map.get(token_delta, :seconds_running, 0)

    %{
      input_tokens: max(0, input_tokens),
      output_tokens: max(0, output_tokens),
      total_tokens: max(0, total_tokens),
      seconds_running: max(0, seconds_running)
    }
  end

  defp extract_token_delta(running_entry, %{event: _, timestamp: _} = update) do
    running_entry = running_entry || %{}
    usage = extract_token_usage(update)

    {
      compute_token_delta(
        running_entry,
        :input,
        usage,
        :codex_last_reported_input_tokens
      ),
      compute_token_delta(
        running_entry,
        :output,
        usage,
        :codex_last_reported_output_tokens
      ),
      compute_token_delta(
        running_entry,
        :total,
        usage,
        :codex_last_reported_total_tokens
      )
    }
    |> Tuple.to_list()
    |> then(fn [input, output, total] ->
      %{
        input_tokens: input.delta,
        output_tokens: output.delta,
        total_tokens: total.delta,
        input_reported: input.reported,
        output_reported: output.reported,
        total_reported: total.reported
      }
    end)
  end

  defp compute_token_delta(running_entry, token_key, usage, reported_key) do
    next_total = get_token_usage(usage, token_key)
    prev_reported = Map.get(running_entry, reported_key, 0)

    delta =
      if is_integer(next_total) and next_total >= prev_reported do
        next_total - prev_reported
      else
        0
      end

    %{
      delta: max(delta, 0),
      reported: if(is_integer(next_total), do: next_total, else: prev_reported)
    }
  end

  defp extract_token_usage(update) do
    payloads = [
      update[:usage],
      Map.get(update, "usage"),
      Map.get(update, :usage),
      update[:payload],
      Map.get(update, "payload"),
      update
    ]

    Enum.find_value(payloads, &absolute_token_usage_from_payload/1) ||
      Enum.find_value(payloads, &turn_completed_usage_from_payload/1) ||
      %{}
  end

  defp extract_rate_limits(update) do
    rate_limits_from_payload(update[:rate_limits]) ||
      rate_limits_from_payload(Map.get(update, "rate_limits")) ||
      rate_limits_from_payload(Map.get(update, :rate_limits)) ||
      rate_limits_from_payload(update[:payload]) ||
      rate_limits_from_payload(Map.get(update, "payload")) ||
      rate_limits_from_payload(update)
  end

  defp absolute_token_usage_from_payload(payload) when is_map(payload) do
    absolute_paths = [
      ["params", "msg", "payload", "info", "total_token_usage"],
      [:params, :msg, :payload, :info, :total_token_usage],
      ["params", "msg", "info", "total_token_usage"],
      [:params, :msg, :info, :total_token_usage],
      ["params", "tokenUsage", "total"],
      [:params, :tokenUsage, :total],
      ["tokenUsage", "total"],
      [:tokenUsage, :total]
    ]

    explicit_map_at_paths(payload, absolute_paths)
  end

  defp absolute_token_usage_from_payload(_payload), do: nil

  defp turn_completed_usage_from_payload(payload) when is_map(payload) do
    method = Map.get(payload, "method") || Map.get(payload, :method)

    if method in ["turn/completed", :turn_completed] do
      direct =
        Map.get(payload, "usage") ||
          Map.get(payload, :usage) ||
          map_at_path(payload, ["params", "usage"]) ||
          map_at_path(payload, [:params, :usage])

      if is_map(direct) and integer_token_map?(direct), do: direct
    end
  end

  defp turn_completed_usage_from_payload(_payload), do: nil

  defp rate_limits_from_payload(payload) when is_map(payload) do
    direct = Map.get(payload, "rate_limits") || Map.get(payload, :rate_limits)

    cond do
      rate_limits_map?(direct) ->
        direct

      rate_limits_map?(payload) ->
        payload

      true ->
        rate_limit_payloads(payload)
    end
  end

  defp rate_limits_from_payload(payload) when is_list(payload) do
    rate_limit_payloads(payload)
  end

  defp rate_limits_from_payload(_payload), do: nil

  defp rate_limit_payloads(payload) when is_map(payload) do
    Map.values(payload)
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limit_payloads(payload) when is_list(payload) do
    payload
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limits_map?(payload) when is_map(payload) do
    limit_id =
      Map.get(payload, "limit_id") ||
        Map.get(payload, :limit_id) ||
        Map.get(payload, "limit_name") ||
        Map.get(payload, :limit_name)

    has_buckets =
      Enum.any?(
        ["primary", :primary, "secondary", :secondary, "credits", :credits],
        &Map.has_key?(payload, &1)
      )

    !is_nil(limit_id) and has_buckets
  end

  defp rate_limits_map?(_payload), do: false

  defp explicit_map_at_paths(payload, paths) when is_map(payload) and is_list(paths) do
    Enum.find_value(paths, fn path ->
      value = map_at_path(payload, path)

      if is_map(value) and integer_token_map?(value), do: value
    end)
  end

  defp explicit_map_at_paths(_payload, _paths), do: nil

  defp map_at_path(payload, path) when is_map(payload) and is_list(path) do
    Enum.reduce_while(path, payload, fn key, acc ->
      if is_map(acc) and Map.has_key?(acc, key) do
        {:cont, Map.get(acc, key)}
      else
        {:halt, nil}
      end
    end)
  end

  defp map_at_path(_payload, _path), do: nil

  defp integer_token_map?(payload) do
    token_fields = [
      :input_tokens,
      :output_tokens,
      :total_tokens,
      :prompt_tokens,
      :completion_tokens,
      :inputTokens,
      :outputTokens,
      :totalTokens,
      :promptTokens,
      :completionTokens,
      "input_tokens",
      "output_tokens",
      "total_tokens",
      "prompt_tokens",
      "completion_tokens",
      "inputTokens",
      "outputTokens",
      "totalTokens",
      "promptTokens",
      "completionTokens"
    ]

    token_fields
    |> Enum.any?(fn field ->
      value = payload_get(payload, field)
      !is_nil(integer_like(value))
    end)
  end

  defp get_token_usage(usage, :input),
    do:
      payload_get(usage, [
        "input_tokens",
        "prompt_tokens",
        :input_tokens,
        :prompt_tokens,
        :input,
        "promptTokens",
        :promptTokens,
        "inputTokens",
        :inputTokens
      ])

  defp get_token_usage(usage, :output),
    do:
      payload_get(usage, [
        "output_tokens",
        "completion_tokens",
        :output_tokens,
        :completion_tokens,
        :output,
        :completion,
        "outputTokens",
        :outputTokens,
        "completionTokens",
        :completionTokens
      ])

  defp get_token_usage(usage, :total),
    do:
      payload_get(usage, [
        "total_tokens",
        "total",
        :total_tokens,
        :total,
        "totalTokens",
        :totalTokens
      ])

  defp payload_get(payload, fields) when is_list(fields) do
    Enum.find_value(fields, fn field -> map_integer_value(payload, field) end)
  end

  defp payload_get(payload, field), do: map_integer_value(payload, field)

  defp map_integer_value(payload, field) do
    if is_map(payload) do
      value = Map.get(payload, field)
      integer_like(value)
    else
      nil
    end
  end

  defp running_seconds(%DateTime{} = started_at, %DateTime{} = now) do
    max(0, DateTime.diff(now, started_at, :second))
  end

  defp running_seconds(_started_at, _now), do: 0

  defp integer_like(value) when is_integer(value) and value >= 0, do: value

  defp integer_like(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {num, _} when num >= 0 -> num
      _ -> nil
    end
  end

  defp integer_like(_value), do: nil
end
