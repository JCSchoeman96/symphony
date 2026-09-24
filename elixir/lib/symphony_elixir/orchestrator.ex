defmodule SymphonyElixir.Orchestrator do
  @dialyzer {:nowarn_function, validate_transition_work_item_context: 1}
  @moduledoc """
  Polls the configured issue tracker and dispatches repository copies to Codex-backed workers.
  """

  use GenServer
  require Logger
  import Bitwise, only: [<<<: 2]

  alias SymphonyElixir.{AgentRunner, Config, PathSafety, StatusDashboard, Tracker, TransitionCoordinator, Workspace}
  alias SymphonyElixir.Workspace.OwnershipLedger

  alias SymphonyElixir.AgentRuntime.{
    AttemptLedger,
    AttemptPolicy,
    Route,
    Router,
    RuntimeAttempt
  }

  alias SymphonyElixir.AgentRuntime.RuntimeAttempt.Identity, as: RuntimeAttemptIdentity
  alias SymphonyElixir.Dependency.{Graph, Guard, Policy}
  alias SymphonyElixir.Plane.ProjectContract
  alias SymphonyElixir.Tracker.Issue

  alias SymphonyElixir.WorkControl.{
    AuthorityDisposition,
    GuardClass,
    LifecycleAssessment,
    ProjectContractEvidence,
    ProviderObservation,
    ProviderProjectContract,
    RecoveryLedger,
    SuspensionContext,
    SuspensionRecovery,
    WorkflowLifecycle,
    WorkItem
  }

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
  @semantic_tool_dependency_blocker_limit 128
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
    :observed,
    :provider_configuration_changed,
    :provider_configuration_drift
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

    # The GenServer owns this shared orchestration aggregate; splitting these fields would duplicate state ownership.
    # credo:disable-for-next-line Credo.Check.Warning.StructFieldAmount
    defstruct [
      :poll_interval_ms,
      :max_concurrent_agents,
      :next_poll_due_at_ms,
      :poll_check_in_progress,
      :tick_timer_ref,
      :tick_token,
      :transition_coordinator,
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
      attempt_lineages: %{},
      attempt_ledger: nil,
      attempt_ledger_status: :disabled,
      attempt_ledger_opts: [],
      attempt_ledger_pending_closes: MapSet.new(),
      durable_in_flight: MapSet.new(),
      durable_blocked: %{},
      durable_exhausted: %{},
      recent_attempts: [],
      startup_reconciliation: :ready,
      recovery_ledger: nil,
      recovery_ledger_status: :disabled,
      recovery_ledger_opts: [],
      recovery_checkpoints: %{},
      workspace_ownership_ledger: nil,
      workspace_ownership_ledger_status: :blocked,
      workspace_ownership_ledger_opts: [],
      startup_cleanup_ran?: false,
      transition_reconciliation_candidates: [],
      work_control: %{},
      project_contract_evidence: nil,
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
          transition_coordinator: Keyword.get(opts, :transition_coordinator, TransitionCoordinator),
          work_control: initial_work_control(Keyword.get(opts, :work_control, %{})),
          project_contract_evidence: ProjectContractEvidence.new(config.provider_project_contract),
          startup_reconciliation: startup_reconciliation_initial_state(config.agent.routing),
          codex_totals: @empty_codex_totals,
          codex_rate_limits: nil
        }

        state = initialize_attempt_ledger(state, config, opts)
        state = initialize_recovery_ledger(state, config, opts)
        state = initialize_workspace_ownership_ledger(state, config, opts)

        state =
          if Keyword.get(opts, :start_quiesced, false) do
            state
          else
            schedule_tick(state, 0)
          end

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  defp startup_reconciliation_initial_state(_routing), do: :pending

  @impl true
  def terminate(_reason, %State{} = state) do
    close_attempt_ledger(state.attempt_ledger)
    close_recovery_ledger(state.recovery_ledger)
    close_workspace_ownership_ledger(state.workspace_ownership_ledger)
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
        case AttemptLedger.open_lineages(ledger) do
          {:ok, records} ->
            restored = restore_durable_lineages(state, records)

            %{
              restored
              | attempt_ledger: ledger,
                attempt_ledger_status: :ready,
                attempt_ledger_opts: ledger_opts
            }

          {:error, reason} ->
            %{
              state
              | attempt_ledger: ledger,
                attempt_ledger_status: {:blocked, {:attempt_ledger_unavailable, reason}},
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

  defp initialize_recovery_ledger(%State{} = state, %{agent: %{routing: "legacy"}}, _opts) do
    %{state | recovery_ledger_status: :disabled, recovery_ledger_opts: []}
  end

  defp initialize_recovery_ledger(%State{} = state, config, opts) do
    project_id = config.symphony.project_id
    tracker_identity = Tracker.identity(config.tracker)
    ledger_opts = recovery_ledger_options(opts)

    case RecoveryLedger.open(project_id, tracker_identity, ledger_opts) do
      {:ok, ledger} ->
        case RecoveryLedger.list(ledger) do
          {:ok, checkpoints} ->
            %{
              state
              | recovery_ledger: ledger,
                recovery_ledger_status: :ready,
                recovery_ledger_opts: ledger_opts,
                recovery_checkpoints: Map.new(checkpoints, &{&1.work_item_id, &1})
            }

          {:error, reason} ->
            _ = RecoveryLedger.close(ledger)

            %{
              state
              | recovery_ledger_status: {:blocked, {:recovery_ledger_unavailable, reason}},
                recovery_ledger_opts: ledger_opts
            }
        end

      {:error, reason} ->
        %{
          state
          | recovery_ledger_status: {:blocked, {:recovery_ledger_unavailable, reason}},
            recovery_ledger_opts: ledger_opts
        }
    end
  end

  defp initialize_workspace_ownership_ledger(%State{} = state, config, opts) do
    project_id = workspace_ownership_project_id(config)
    tracker_identity = Tracker.identity(config.tracker)

    ledger_opts =
      opts
      |> workspace_ownership_ledger_options()
      |> Keyword.put(:workspace_root, Config.local_workspace_root())

    case open_workspace_ownership_ledger(opts, project_id, tracker_identity, ledger_opts) do
      {:ok, %OwnershipLedger{} = ledger} ->
        validate_workspace_ownership_ledger(state, ledger, ledger_opts)

      {:error, reason} ->
        block_workspace_ownership_ledger(state, ledger_opts, reason)
    end
  end

  defp synchronize_workspace_ownership_ledger_config(%State{} = state, config) do
    project_id = workspace_ownership_project_id(config)
    tracker_identity = Tracker.identity(config.tracker)
    current_root = Config.local_workspace_root()
    previous_opts = state.workspace_ownership_ledger_opts
    previous_root = Keyword.get(previous_opts, :workspace_root)

    cond do
      is_binary(previous_root) and previous_root != current_root ->
        block_workspace_ownership_root_change(state, previous_root, current_root)

      workspace_ownership_ledger_binding_matches?(
        state.workspace_ownership_ledger,
        project_id,
        tracker_identity,
        previous_opts
      ) ->
        %{state | workspace_ownership_ledger_opts: previous_opts}

      true ->
        reopen_workspace_ownership_ledger(state, project_id, tracker_identity, current_root)
    end
  end

  defp workspace_ownership_ledger_binding_matches?(
         %OwnershipLedger{} = ledger,
         project_id,
         tracker_identity,
         ledger_opts
       ) do
    ledger.project_id == project_id and
      ledger.tracker_identity == tracker_identity and
      ledger.path == OwnershipLedger.path_for(project_id, ledger_opts) and
      ledger.host_identity_path == OwnershipLedger.host_identity_path(ledger_opts)
  end

  defp workspace_ownership_ledger_binding_matches?(_ledger, _project_id, _tracker_identity, _ledger_opts),
    do: false

  defp block_workspace_ownership_root_change(%State{} = state, previous_root, current_root) do
    close_result = close_workspace_ownership_ledger(state.workspace_ownership_ledger)

    reason =
      case close_result do
        :ok -> {:workspace_root_changed, previous_root, current_root}
        {:error, close_reason} -> {:workspace_root_changed, previous_root, current_root, close_reason}
      end

    Logger.error("Workspace ownership ledger blocked after workspace root change: #{inspect(reason)}")

    %{
      state
      | workspace_ownership_ledger: nil,
        workspace_ownership_ledger_status: {:blocked, {:workspace_ownership_ledger_unavailable, reason}},
        startup_reconciliation: :pending
    }
  end

  defp reopen_workspace_ownership_ledger(%State{} = state, project_id, tracker_identity, current_root) do
    ledger_opts = Keyword.put(state.workspace_ownership_ledger_opts, :workspace_root, current_root)
    close_result = close_workspace_ownership_ledger(state.workspace_ownership_ledger)

    case close_result do
      :ok ->
        case OwnershipLedger.open(project_id, tracker_identity, ledger_opts) do
          {:ok, %OwnershipLedger{} = ledger} ->
            state
            |> validate_workspace_ownership_ledger(ledger, ledger_opts)
            |> Map.put(:startup_reconciliation, :pending)

          {:error, reason} ->
            state
            |> block_workspace_ownership_ledger(ledger_opts, reason)
            |> Map.put(:startup_reconciliation, :pending)
        end

      {:error, reason} ->
        state
        |> block_workspace_ownership_ledger(ledger_opts, {:workspace_ownership_ledger_close_failed, reason})
        |> Map.put(:startup_reconciliation, :pending)
    end
  end

  defp open_workspace_ownership_ledger(opts, project_id, tracker_identity, ledger_opts) do
    case Keyword.get(opts, :workspace_ownership_ledger) do
      %OwnershipLedger{} = ledger ->
        {:ok, ledger}

      nil when is_binary(project_id) and project_id != "" ->
        OwnershipLedger.open(project_id, tracker_identity, ledger_opts)

      nil ->
        {:error, :missing_symphony_project_id}

      _invalid ->
        {:error, :invalid_workspace_ownership_ledger}
    end
  end

  defp validate_workspace_ownership_ledger(%State{} = state, %OwnershipLedger{} = ledger, ledger_opts) do
    case OwnershipLedger.list(ledger) do
      {:ok, _records} ->
        %{
          state
          | workspace_ownership_ledger: ledger,
            workspace_ownership_ledger_status: :ready,
            workspace_ownership_ledger_opts: ledger_opts
        }

      {:error, reason} ->
        Logger.error("Workspace ownership ledger validation failed: #{inspect(reason)}")
        _ = OwnershipLedger.close(ledger)
        blocked_workspace_ownership_ledger_state(state, ledger_opts, reason)
    end
  end

  defp block_workspace_ownership_ledger(%State{} = state, ledger_opts, reason) do
    Logger.error("Workspace ownership ledger is unavailable: #{inspect(reason)}")
    blocked_workspace_ownership_ledger_state(state, ledger_opts, reason)
  end

  defp blocked_workspace_ownership_ledger_state(%State{} = state, ledger_opts, reason) do
    %{
      state
      | workspace_ownership_ledger: nil,
        workspace_ownership_ledger_status: {:blocked, {:workspace_ownership_ledger_unavailable, reason}},
        workspace_ownership_ledger_opts: ledger_opts
    }
  end

  defp workspace_ownership_project_id(%{agent: %{routing: "legacy"}, symphony: %{project_id: project_id}})
       when is_binary(project_id) and project_id != "",
       do: project_id

  defp workspace_ownership_project_id(%{agent: %{routing: "legacy"}}), do: "legacy-default"

  defp workspace_ownership_project_id(%{symphony: %{project_id: project_id}}), do: project_id

  defp workspace_ownership_ledger_options(opts) do
    ledger_opts = Keyword.get(opts, :workspace_ownership_ledger_opts, [])

    if Keyword.has_key?(ledger_opts, :path) or Keyword.has_key?(ledger_opts, :root) do
      ledger_opts
    else
      case Application.get_env(:symphony_elixir, :attempt_ledger_root) do
        root when is_binary(root) -> Keyword.put(ledger_opts, :root, Path.join(root, "workspace-ownership"))
        _unset -> ledger_opts
      end
    end
  end

  defp recovery_ledger_options(opts) do
    ledger_opts = Keyword.get(opts, :recovery_ledger_opts, [])

    if Keyword.has_key?(ledger_opts, :path) or Keyword.has_key?(ledger_opts, :root) do
      ledger_opts
    else
      case Application.get_env(:symphony_elixir, :attempt_ledger_root) do
        root when is_binary(root) -> Keyword.put(ledger_opts, :root, Path.join(root, "work-control-recovery"))
        _unset -> ledger_opts
      end
    end
  end

  defp close_attempt_ledger(nil), do: :ok

  defp close_attempt_ledger(%AttemptLedger{} = ledger) do
    case AttemptLedger.close(ledger) do
      :ok -> :ok
      {:error, reason} -> Logger.error("Failed to close attempt ledger: #{inspect(reason)}")
    end
  end

  defp close_recovery_ledger(nil), do: :ok

  defp close_recovery_ledger(%RecoveryLedger{} = ledger) do
    case RecoveryLedger.close(ledger) do
      :ok -> :ok
      {:error, reason} -> Logger.error("Failed to close work-control recovery ledger: #{inspect(reason)}")
    end
  end

  defp close_workspace_ownership_ledger(nil), do: :ok

  defp close_workspace_ownership_ledger(%OwnershipLedger{} = ledger) do
    case OwnershipLedger.close(ledger) do
      :ok ->
        :ok

      {:error, reason} = error ->
        Logger.error("Failed to close workspace ownership ledger: #{inspect(reason)}")
        error
    end
  end

  defp reconcile_attempt_ledger(%State{} = state, %AttemptLedger{} = ledger) do
    case reconcile_pending_lineage_closes(state, ledger) do
      {:blocked, state, reason} ->
        {:blocked, state, reason}

      {:ok, state} ->
        reconcile_open_lineages(state, ledger)
    end
  end

  defp reconcile_open_lineages(%State{} = state, %AttemptLedger{} = ledger) do
    case AttemptLedger.open_lineages(ledger) do
      {:ok, records} ->
        state = restore_durable_lineages(state, records)

        case reconcile_pending_lineage_closes(state, ledger) do
          {:blocked, state, reason} ->
            {:blocked, state, reason}

          {:ok, state} ->
            reread_open_lineages(state, ledger)
        end

      {:error, reason} ->
        {:blocked, state, {:attempt_ledger_unavailable, reason}}
    end
  end

  defp reread_open_lineages(%State{} = state, %AttemptLedger{} = ledger) do
    case AttemptLedger.open_lineages(ledger) do
      {:ok, records} ->
        reconcile_open_lineage_records(state, ledger, records)

      {:error, reason} ->
        {:blocked, state, {:attempt_ledger_unavailable, reason}}
    end
  end

  defp reconcile_open_lineage_records(%State{} = state, _ledger, []),
    do: {:ok, restore_durable_lineages(state, [])}

  defp reconcile_open_lineage_records(%State{} = state, %AttemptLedger{} = ledger, records) do
    state = restore_durable_lineages(state, records)
    reconcile_durable_issue_states(state, ledger, records, Enum.map(records, & &1.issue_id))
  end

  defp reconcile_pending_lineage_closes(%State{attempt_ledger_pending_closes: pending} = state, ledger)
       when is_struct(pending, MapSet) do
    Enum.reduce_while(MapSet.to_list(pending), {:ok, state}, fn issue_id, accumulator ->
      reconcile_pending_lineage(accumulator, ledger, issue_id)
    end)
  end

  defp reconcile_pending_lineage_closes(%State{} = state, _ledger), do: {:ok, state}

  defp reconcile_pending_lineage({:ok, %State{} = state}, ledger, issue_id) do
    case AttemptLedger.current(ledger, issue_id) do
      {:ok, %{status: :closed}} ->
        confirm_pending_lineage_close(state, ledger, issue_id)

      {:ok, %{status: :exhausted} = record} ->
        {:cont, {:ok, preserve_exhausted_lineage(state, issue_id, record)}}

      {:ok, %{status: :open}} ->
        retry_pending_lineage_close(state, ledger, issue_id)

      :not_found ->
        {:halt, {:blocked, state, pending_close_reason(issue_id, :missing_after_close_failure)}}

      {:error, reason} ->
        {:halt, {:blocked, state, pending_close_reason(issue_id, reason)}}
    end
  end

  defp confirm_pending_lineage_close(%State{} = state, ledger, issue_id) do
    case AttemptLedger.confirm_lineage_close(ledger, issue_id) do
      :ok -> {:cont, {:ok, reset_durable_lineage(state, issue_id)}}
      {:error, reason} -> {:halt, {:blocked, state, pending_close_reason(issue_id, reason)}}
    end
  end

  defp retry_pending_lineage_close(%State{} = state, ledger, issue_id) do
    case AttemptLedger.close_lineage(ledger, issue_id, reason: :terminal) do
      :ok -> {:cont, {:ok, reset_durable_lineage(state, issue_id)}}
      {:error, reason} -> {:halt, {:blocked, state, pending_close_reason(issue_id, reason)}}
    end
  end

  defp pending_close_reason(issue_id, reason),
    do: {:attempt_ledger_close_failed, [{issue_id, reason}]}

  defp restore_durable_lineages(%State{} = state, records) when is_list(records) do
    Enum.reduce(records, state, fn record, state_acc ->
      counters = Map.merge(AttemptPolicy.new(), record.safety_counters)

      state_acc = %{
        state_acc
        | attempt_counters: Map.put(state_acc.attempt_counters, record.issue_id, counters),
          attempt_lineages: Map.put(state_acc.attempt_lineages, record.issue_id, record.lineage_id)
      }

      state_acc =
        if Map.get(record, :close_pending, false) do
          mark_pending_lineage_close(state_acc, record.issue_id)
        else
          %{state_acc | attempt_ledger_pending_closes: MapSet.delete(state_acc.attempt_ledger_pending_closes, record.issue_id)}
        end

      state_acc =
        if record.status == :exhausted do
          %{state_acc | durable_exhausted: Map.put(state_acc.durable_exhausted, record.issue_id, record)}
        else
          %{state_acc | durable_exhausted: Map.delete(state_acc.durable_exhausted, record.issue_id)}
        end

      if Map.get(record, :in_flight, false) do
        %{state_acc | durable_in_flight: MapSet.put(state_acc.durable_in_flight, record.issue_id)}
      else
        %{state_acc | durable_in_flight: MapSet.delete(state_acc.durable_in_flight, record.issue_id)}
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
        {
          mark_durable_blocked(state, record.issue_id, {:attempt_ledger_issue_missing, record.issue_id}),
          [record.issue_id | missing],
          errors
        }

      %Issue{} = issue ->
        reconcile_visible_durable_record(issue, record, ledger, {state, missing, errors})
    end
  end

  defp reconcile_visible_durable_record(%Issue{} = issue, record, ledger, {state, missing, errors}) do
    cond do
      record.status == :exhausted ->
        {clear_missing_attempt_ledger_block(state, issue.id), missing, errors}

      terminal_issue_state?(issue.state, terminal_state_set()) ->
        close_visible_terminal_lineage(issue, ledger, {state, missing, errors})

      true ->
        {state, missing, errors} = reconcile_visible_in_flight(issue, record, {state, missing, errors})
        {clear_missing_attempt_ledger_block(state, issue.id), missing, errors}
    end
  end

  defp close_visible_terminal_lineage(issue, ledger, {state, missing, errors}) do
    case AttemptLedger.close_lineage(ledger, issue.id, reason: :terminal) do
      :ok ->
        {reset_durable_lineage(state, issue.id), missing, errors}

      {:error, reason} ->
        state = mark_pending_lineage_close(state, issue.id)
        {state, missing, [{issue.id, reason} | errors]}
    end
  end

  defp reconcile_visible_in_flight(issue, record, {state, missing, errors}) do
    state =
      if Map.get(record, :in_flight, false) do
        mark_durable_in_flight(state, issue.id, true)
      else
        clear_durable_in_flight(state, issue.id)
      end

    {state, missing, errors}
  end

  defp finish_durable_reconciliation({state, [], []}), do: {:ok, state}

  defp finish_durable_reconciliation({state, _missing, close_errors}) when close_errors != [] do
    {:blocked, state, {:attempt_ledger_close_failed, Enum.reverse(close_errors)}}
  end

  defp finish_durable_reconciliation({state, _missing, []}), do: {:ok, state}

  defp reset_durable_lineage(%State{} = state, issue_id) do
    %{
      state
      | attempt_counters: Map.delete(state.attempt_counters, issue_id),
        attempt_lineages: Map.delete(state.attempt_lineages, issue_id),
        durable_exhausted: Map.delete(state.durable_exhausted, issue_id),
        attempt_ledger_pending_closes: MapSet.delete(state.attempt_ledger_pending_closes, issue_id),
        durable_in_flight: MapSet.delete(state.durable_in_flight, issue_id),
        durable_blocked: Map.delete(state.durable_blocked, issue_id)
    }
  end

  defp initial_work_control(work_control) when is_map(work_control) do
    Enum.reduce(work_control, %{}, fn
      {issue_id, %WorkItem{} = work_item}, acc when is_binary(issue_id) ->
        Map.put(acc, issue_id, work_item)

      {_issue_id, _work_item}, acc ->
        acc
    end)
  end

  defp initial_work_control(_work_control), do: %{}

  defp mark_durable_blocked(%State{} = state, issue_id, reason) do
    %{state | durable_blocked: Map.put(state.durable_blocked, issue_id, reason)}
  end

  defp clear_missing_attempt_ledger_block(%State{} = state, issue_id) do
    case Map.get(state.durable_blocked, issue_id) do
      {:attempt_ledger_issue_missing, ^issue_id} ->
        %{state | durable_blocked: Map.delete(state.durable_blocked, issue_id)}

      _reason ->
        state
    end
  end

  defp reconcile_visible_missing_attempt_lineages(%State{} = state, issues) when is_list(issues) do
    if Enum.any?(issues, fn
         %Issue{id: issue_id} when is_binary(issue_id) ->
           Map.get(state.durable_blocked, issue_id) == {:attempt_ledger_issue_missing, issue_id}

         _issue ->
           false
       end) do
      reconcile_visible_missing_attempt_lineages(state)
    else
      state
    end
  end

  defp reconcile_visible_missing_attempt_lineages(
         %State{
           attempt_ledger_status: :ready,
           attempt_ledger: %AttemptLedger{} = ledger
         } = state
       ) do
    case reconcile_attempt_ledger(state, ledger) do
      {:ok, reconciled_state} ->
        reconciled_state

      {:blocked, blocked_state, reason} ->
        %{blocked_state | attempt_ledger_status: {:blocked, reason}}
    end
  end

  defp reconcile_visible_missing_attempt_lineages(%State{} = state), do: state

  defp mark_pending_lineage_close(%State{} = state, issue_id) do
    %{
      state
      | attempt_ledger_pending_closes: MapSet.put(state.attempt_ledger_pending_closes, issue_id)
    }
  end

  defp mark_durable_in_flight(%State{} = state, issue_id, true) do
    %{state | durable_in_flight: MapSet.put(state.durable_in_flight, issue_id)}
  end

  defp clear_durable_in_flight(%State{} = state, issue_id) do
    %{state | durable_in_flight: MapSet.delete(state.durable_in_flight, issue_id)}
  end

  defp autonomous_dispatch_allowed?(%State{attempt_ledger_status: attempt_status} = state)
       when attempt_status in [:disabled, :ready] do
    state.startup_reconciliation == :ready and
      state.recovery_ledger_status in [:disabled, :ready] and
      state.workspace_ownership_ledger_status == :ready and
      match?(%OwnershipLedger{}, state.workspace_ownership_ledger) and
      not ProjectContractEvidence.reconciliation_required?(state.project_contract_evidence)
  end

  defp autonomous_dispatch_allowed?(%State{}), do: false

  defp ledger_block_reason(%State{attempt_ledger_status: {:blocked, reason}}), do: reason
  defp ledger_block_reason(_state), do: nil

  defp reconcile_project_contract_state(
         %State{
           project_contract_evidence: %ProjectContractEvidence{
             contract: %ProviderProjectContract{} = contract
           }
         } = state,
         snapshot
       )
       when is_map(snapshot) do
    validation = ProjectContract.validate(contract, snapshot)
    {apply_project_contract_validation(state, validation), validation}
  end

  defp reconcile_project_contract_state(%State{} = state, _snapshot),
    do: {state, {:error, :provider_project_contract_not_configured}}

  defp apply_project_contract_validation(
         %State{} = state,
         %ProviderProjectContract.ValidationResult{} = validation
       ) do
    evidence = ProjectContractEvidence.apply_validation(state.project_contract_evidence, validation)
    state = %{state | project_contract_evidence: evidence}

    if ProjectContractEvidence.reconciliation_required?(evidence) do
      reason = evidence.reason || :provider_configuration_drift

      state
      |> Map.put(:startup_reconciliation, :pending)
      |> suspend_work_control_for_project_contract(reason)
      |> suspend_running_for_project_contract(reason)
    else
      state
    end
  end

  defp suspend_work_control_for_project_contract(%State{} = state, reason) do
    work_control =
      Enum.reduce(state.work_control, %{}, fn
        {issue_id, %WorkItem{} = work_item}, work_control_acc ->
          suspended_work_item =
            case WorkItem.suspend(work_item, reason) do
              {:ok, suspended} -> suspended
              {:error, _reason} -> work_item
            end

          Map.put(work_control_acc, issue_id, suspended_work_item)

        {issue_id, work_item}, work_control_acc ->
          Map.put(work_control_acc, issue_id, work_item)
      end)

    %{state | work_control: work_control}
  end

  defp suspend_running_for_project_contract(%State{} = state, reason) do
    state =
      Enum.reduce(Map.keys(state.running), state, fn issue_id, state_acc ->
        terminate_running_issue(state_acc, issue_id, false, reason)
      end)

    cancel_project_contract_retries(state)
  end

  defp cancel_project_contract_retries(%State{} = state) do
    Enum.each(state.retry_attempts, fn {_issue_id, retry} ->
      case Map.get(retry, :timer_ref) do
        timer_ref when is_reference(timer_ref) -> Process.cancel_timer(timer_ref)
        _ -> :ok
      end
    end)

    retry_issue_ids = Map.keys(state.retry_attempts)

    %{
      state
      | retry_attempts: %{},
        claimed: Enum.reduce(retry_issue_ids, state.claimed, &MapSet.delete(&2, &1))
    }
  end

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

  def handle_info(
        {:runtime_attempt_session_started, issue_id, %RuntimeAttemptIdentity{} = identity},
        %{running: running} = state
      )
      when is_binary(issue_id) do
    case validate_current_runtime_event(state, issue_id, identity, require_running: false) do
      {:ok, validated_issue_id, running_entry} ->
        apply_runtime_attempt_session_started(state, running, validated_issue_id, running_entry)

      :stale ->
        {:noreply, state}
    end
  end

  def handle_info(
        {:worker_runtime_info, issue_id, %RuntimeAttemptIdentity{} = identity, runtime_info},
        %{running: running} = state
      )
      when is_binary(issue_id) and is_map(runtime_info) do
    case validate_current_runtime_event(state, issue_id, identity, require_running: false) do
      {:ok, validated_issue_id, running_entry} ->
        updated_running_entry =
          running_entry
          |> maybe_put_runtime_value(:worker_host, runtime_info[:worker_host])
          |> maybe_put_runtime_value(:workspace_path, runtime_info[:workspace_path])

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, validated_issue_id, updated_running_entry)}}

      :stale ->
        {:noreply, state}
    end
  end

  def handle_info({:worker_runtime_info, issue_id, runtime_info}, %{running: running} = state)
      when is_binary(issue_id) and is_map(runtime_info) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      %{runtime_attempt: %RuntimeAttempt{}} ->
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
        {
          :agent_route_changed,
          issue_id,
          %RuntimeAttemptIdentity{} = identity,
          %Route{} = previous_route,
          %Route{} = next_route
        },
        state
      )
      when is_binary(issue_id) do
    case validate_current_runtime_event(state, issue_id, identity, require_running: true) do
      {:ok, validated_issue_id, running_entry} ->
        apply_agent_route_changed(state, validated_issue_id, running_entry, previous_route, next_route)

      :stale ->
        {:noreply, state}
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

      %{runtime_attempt: %RuntimeAttempt{}} ->
        {:noreply, state}

      running_entry ->
        apply_agent_route_changed(state, issue_id, running_entry, previous_route, next_route)
    end
  end

  def handle_info(
        {:agent_lifecycle_suspended, issue_id, %RuntimeAttemptIdentity{} = identity, assessment},
        state
      )
      when is_binary(issue_id) do
    case validate_current_runtime_event(state, issue_id, identity, require_running: true) do
      {:ok, validated_issue_id, running_entry} ->
        apply_agent_lifecycle_suspended(state, validated_issue_id, running_entry, assessment)

      :stale ->
        {:noreply, state}
    end
  end

  def handle_info(
        {:agent_lifecycle_suspended, issue_id, assessment},
        %{running: running} = state
      )
      when is_binary(issue_id) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      %{runtime_attempt: %RuntimeAttempt{}} ->
        {:noreply, state}

      running_entry ->
        apply_agent_lifecycle_suspended(state, issue_id, running_entry, assessment)
    end
  end

  def handle_info(
        {:agent_dependency_blocked, issue_id, %RuntimeAttemptIdentity{} = identity, decision},
        state
      )
      when is_binary(issue_id) and is_map(decision) do
    case validate_current_runtime_event(state, issue_id, identity, require_running: true) do
      {:ok, validated_issue_id, running_entry} ->
        apply_agent_dependency_blocked(state, validated_issue_id, running_entry, decision)

      :stale ->
        {:noreply, state}
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

      %{runtime_attempt: %RuntimeAttempt{}} ->
        {:noreply, state}

      running_entry ->
        apply_agent_dependency_blocked(state, issue_id, running_entry, decision)
    end
  end

  def handle_info(
        {:codex_worker_update, issue_id, %RuntimeAttemptIdentity{} = identity, %{event: _, timestamp: _} = update},
        %{running: running} = state
      ) do
    case validate_current_runtime_event(state, issue_id, identity, require_running: true) do
      {:ok, validated_issue_id, running_entry} ->
        {updated_running_entry, token_delta} = integrate_codex_update(running_entry, update)

        state =
          state
          |> apply_codex_token_delta(token_delta)
          |> apply_codex_rate_limits(update)

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, validated_issue_id, updated_running_entry)}}

      :stale ->
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

      %{runtime_attempt: %RuntimeAttempt{}} ->
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
      if autonomous_dispatch_allowed?(state) do
        case pop_retry_attempt_state(state, issue_id, retry_token) do
          {:ok, attempt, metadata, state} -> handle_retry_issue(state, issue_id, attempt, metadata)
          :missing -> {:noreply, state}
        end
      else
        Logger.debug("Skipping retry while autonomous dispatch is fenced: issue_id=#{issue_id}")
        {:noreply, state}
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
      not is_nil(Map.get(running_entry, :lifecycle_suspension)) ->
        error =
          "agent suspended after lifecycle observation: #{inspect(running_entry.lifecycle_suspension)}"

        block_issue_from_entry(state, issue_id, running_entry, error)

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

        case transition_running_entry_attempt(running_entry, :retry_queued) do
          {:ok, running_entry} ->
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

          {:error, :invalid_runtime_attempt_transition} ->
            state
        end

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
        case transition_running_entry_attempt(running_entry, :retry_queued) do
          {:ok, running_entry} ->
            schedule_agent_route_change_retry(state, issue_id, running_entry, route_change)

          {:error, :invalid_runtime_attempt_transition} ->
            state
        end

      {:stop, state, reason} ->
        block_issue_from_entry(state, issue_id, running_entry, attempt_policy_error(reason))

      {:error, state, reason} ->
        block_issue_from_entry(state, issue_id, running_entry, attempt_ledger_error(reason))
    end
  end

  defp handle_normal_continuation(state, issue_id, running_entry) do
    with {:ok, running_entry} <- transition_running_entry_attempt(running_entry, :completed),
         {:ok, state} <- clear_attempt_in_flight(state, issue_id) do
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
    else
      {:error, :invalid_runtime_attempt_transition} ->
        state

      {:error, state, reason} ->
        block_issue_from_entry(state, issue_id, running_entry, attempt_ledger_error(reason))
    end
  end

  defp maybe_dispatch(%State{} = state) do
    if state.startup_reconciliation == :ready do
      case state.attempt_ledger_status do
        {:blocked, reason} ->
          maybe_reconcile_blocked_ledger(state, reason)

        status when status in [:disabled, :ready] ->
          maybe_dispatch_ready(state)

        status ->
          Logger.debug("Skipping autonomous dispatch with invalid attempt ledger status: #{inspect(status)}")
          state
      end
    else
      state = reconcile_startup(state)

      if autonomous_dispatch_allowed?(state) do
        dispatch_ready_if_allowed(state)
      else
        Logger.debug("Skipping autonomous dispatch while startup reconciliation is #{inspect(state.startup_reconciliation)}")

        state
      end
    end
  end

  defp reconcile_startup(%State{} = state) do
    state = %{state | startup_reconciliation: :reconciling}

    case do_reconcile_startup(state) do
      {:ok, %State{} = ready_state} ->
        finish_startup_reconciliation(ready_state)

      {:blocked, %State{} = blocked_state, reason} ->
        Logger.warning("Startup reconciliation is blocked: #{inspect(reason)}")
        %{blocked_state | startup_reconciliation: {:blocked, reason}}
    end
  end

  defp finish_startup_reconciliation(%State{} = state) do
    state
    |> Map.put(:startup_reconciliation, :ready)
    |> reconcile_pending_workspace_releases()
    |> maybe_run_startup_workspace_cleanup()
    |> reschedule_pending_retries()
  end

  defp maybe_run_startup_workspace_cleanup(%State{} = state) do
    if state.startup_reconciliation != :ready or state.startup_cleanup_ran? do
      state
    else
      complete_startup_workspace_cleanup(state)
    end
  end

  defp complete_startup_workspace_cleanup(%State{} = state) do
    case run_terminal_workspace_cleanup(state) do
      :ok ->
        %{state | startup_cleanup_ran?: true}

      {:error, reason} ->
        Logger.error("Startup terminal workspace cleanup remains pending: #{inspect(reason)}")
        %{state | startup_reconciliation: :pending, startup_cleanup_ran?: false}
    end
  end

  defp do_reconcile_startup(%State{} = state) do
    with {:ok, state} <- refresh_startup_ledgers(state),
         {:ok, candidates} <- fetch_startup_transition_candidates(state),
         {:ok, state} <- validate_startup_project_contract(state),
         {:ok, graph} <- acquire_startup_dependency_graph(),
         state <- refresh_dependency_graph_epoch(%{state | transition_reconciliation_candidates: candidates}, graph),
         {:ok, state} <- startup_work_items_reconciled(state, graph),
         {:ok, state} <- reconcile_attempt_ledger_from_snapshot(state, graph.nodes |> Map.values()),
         {:ok, state} <- reconcile_startup_transition_candidates(state, candidates, graph),
         {:ok, state} <- clear_reconciled_stale_in_flight(state),
         {:ok, state} <- startup_durable_stores_ready(state) do
      {:ok, state}
    else
      {:blocked, %State{} = blocked_state, reason} -> {:blocked, blocked_state, reason}
      {:error, reason} -> {:blocked, state, reason}
    end
  end

  defp refresh_startup_ledgers(%State{} = state) do
    config = Config.settings!()

    state =
      if config.agent.routing == "legacy" or match?(%AttemptLedger{}, state.attempt_ledger) do
        state
      else
        initialize_attempt_ledger(state, config, attempt_ledger_opts: state.attempt_ledger_opts)
      end

    state =
      if config.agent.routing == "legacy" or match?(%RecoveryLedger{}, state.recovery_ledger) do
        state
      else
        initialize_recovery_ledger(state, config, recovery_ledger_opts: state.recovery_ledger_opts)
      end

    with {:ok, state} <- reload_attempt_ledger_records(state, config) do
      reload_recovery_ledger_records(state, config)
    end
  end

  defp reload_attempt_ledger_records(%State{attempt_ledger_status: :disabled} = state, %{agent: %{routing: "legacy"}}),
    do: {:ok, state}

  defp reload_attempt_ledger_records(%State{attempt_ledger: %AttemptLedger{} = ledger} = state, config) do
    case attempt_ledger_identity_mismatch(ledger, config) do
      nil ->
        reload_matching_attempt_ledger(state, ledger)

      mismatch ->
        blocked_reason = {:attempt_ledger_unavailable, mismatch}
        blocked_state = %{state | attempt_ledger_status: {:blocked, blocked_reason}}
        {:blocked, blocked_state, blocked_reason}
    end
  end

  defp reload_attempt_ledger_records(%State{} = state, _config) do
    reason = ledger_block_reason(state) || :missing_ledger_handle
    {:blocked, state, reason}
  end

  defp reload_matching_attempt_ledger(%State{} = state, %AttemptLedger{} = ledger) do
    case resync_attempt_ledger_if_needed(state, ledger) do
      {:ok, state} -> reload_attempt_ledger_lineages(state, ledger)
      {:error, state, reason} -> {:blocked, state, reason}
    end
  end

  defp reload_attempt_ledger_lineages(%State{} = state, %AttemptLedger{} = ledger) do
    case AttemptLedger.open_lineages(ledger) do
      {:ok, records} ->
        restored = restore_durable_lineages(state, records)
        {:ok, %{restored | attempt_ledger_status: :ready}}

      {:error, reason} ->
        blocked_reason = {:attempt_ledger_unavailable, reason}
        blocked_state = %{state | attempt_ledger_status: {:blocked, blocked_reason}}
        {:blocked, blocked_state, blocked_reason}
    end
  end

  defp attempt_ledger_identity_mismatch(%AttemptLedger{} = ledger, config) do
    project_id = config.symphony.project_id
    tracker_identity = Tracker.identity(config.tracker)

    cond do
      ledger.project_id != project_id ->
        {:ledger_project_namespace_mismatch, ledger.project_id, project_id}

      ledger.tracker_identity != tracker_identity ->
        {:ledger_tracker_identity_mismatch, ledger.tracker_identity, tracker_identity}

      true ->
        nil
    end
  end

  defp resync_attempt_ledger_if_needed(
         %State{
           attempt_ledger_status: {:blocked, {:attempt_ledger_unavailable, {:ledger_sync_failed, _reason}}}
         } = state,
         %AttemptLedger{} = ledger
       ) do
    case AttemptLedger.sync(ledger) do
      :ok ->
        {:ok, state}

      {:error, reason} ->
        blocked_reason = {:attempt_ledger_unavailable, reason}
        {:error, %{state | attempt_ledger_status: {:blocked, blocked_reason}}, blocked_reason}
    end
  end

  defp resync_attempt_ledger_if_needed(%State{} = state, %AttemptLedger{}), do: {:ok, state}

  defp reload_recovery_ledger_records(%State{recovery_ledger_status: :disabled} = state, %{agent: %{routing: "legacy"}}),
    do: {:ok, state}

  defp reload_recovery_ledger_records(%State{recovery_ledger: %RecoveryLedger{} = ledger} = state, _config) do
    case resync_recovery_ledger_if_needed(state, ledger) do
      {:ok, state} ->
        case RecoveryLedger.list(ledger) do
          {:ok, checkpoints} ->
            {:ok, %{state | recovery_ledger_status: :ready, recovery_checkpoints: Map.new(checkpoints, &{&1.work_item_id, &1})}}

          {:error, reason} ->
            next_state = %{state | recovery_ledger_status: {:blocked, {:recovery_ledger_unavailable, reason}}}
            {:blocked, next_state, {:recovery_ledger_unavailable, reason}}
        end

      {:error, state, reason} ->
        {:blocked, state, reason}
    end
  end

  defp reload_recovery_ledger_records(%State{} = state, _config) do
    reason = {:recovery_ledger_unavailable, state.recovery_ledger_status}
    {:blocked, state, reason}
  end

  defp resync_recovery_ledger_if_needed(%State{recovery_ledger_status: :ready} = state, %RecoveryLedger{}),
    do: {:ok, state}

  defp resync_recovery_ledger_if_needed(%State{} = state, %RecoveryLedger{} = ledger) do
    case RecoveryLedger.sync(ledger) do
      :ok ->
        {:ok, state}

      {:error, reason} ->
        next_state = fence_recovery_ledger(state, reason)
        {:error, next_state, {:recovery_ledger_unavailable, reason}}
    end
  end

  defp fetch_startup_transition_candidates(%State{} = state) do
    tracker_kind = Config.settings!().tracker.kind

    case TransitionCoordinator.sync_reconciliation_ledger(state.transition_coordinator) do
      :ok ->
        case TransitionCoordinator.list_reconciliation_candidates(state.transition_coordinator) do
          {:ok, candidates} when is_list(candidates) -> {:ok, candidates}
          {:error, reason} -> {:blocked, state, {:transition_coordinator_unavailable, reason}}
          _invalid -> {:blocked, state, :invalid_transition_reconciliation_candidates}
        end

      {:error, :transitions_disabled} when tracker_kind != "plane" ->
        {:ok, []}

      {:error, reason} ->
        {:blocked, state, {:transition_coordinator_unavailable, reason}}
    end
  end

  defp validate_startup_project_contract(%State{} = state) do
    config = Config.settings!()

    case state.project_contract_evidence do
      %ProjectContractEvidence{contract: %ProviderProjectContract{}} ->
        result = apply_provider_project_snapshot(state, Tracker.fetch_project_snapshot())

        if match?(%ProjectContractEvidence{validation: %{status: :valid}}, result.project_contract_evidence) do
          {:ok, result}
        else
          {:blocked, result, result.project_contract_evidence.reason || :provider_contract_not_validated}
        end

      _missing_contract when config.tracker.kind == "plane" ->
        {:blocked, state, :provider_project_contract_not_configured}

      _no_contract ->
        {:ok, state}
    end
  end

  defp acquire_startup_dependency_graph do
    case Tracker.fetch_dependency_graph() do
      {:ok, %Graph{} = graph} ->
        if Graph.complete?(graph), do: {:ok, graph}, else: {:error, {:dependency_graph_incomplete, graph.completeness}}

      {:ok, issues} when is_list(issues) ->
        graph =
          Graph.build(issues,
            source: Config.settings!().tracker.kind,
            scope: Tracker.identity(Config.settings!().tracker).provider_scope,
            completeness: :complete
          )

        if Graph.complete?(graph), do: {:ok, graph}, else: {:error, {:dependency_graph_incomplete, graph.completeness}}

      {:error, reason} ->
        {:error, {:dependency_graph_unavailable, reason}}

      _invalid ->
        {:error, :invalid_dependency_graph}
    end
  end

  defp startup_work_items_reconciled(%State{} = state, %Graph{} = graph) do
    if Config.settings!().agent.routing == "legacy" do
      {:ok, state}
    else
      missing_ids =
        graph.nodes
        |> Map.keys()
        |> Enum.reject(&match?(%WorkItem{}, Map.get(state.work_control, &1)))

      state =
        Enum.reduce(missing_ids, state, fn issue_id, state_acc ->
          mark_durable_blocked(state_acc, issue_id, :work_control_reconciliation_incomplete)
        end)

      {:ok, state}
    end
  end

  defp reconcile_attempt_ledger_from_snapshot(%State{attempt_ledger_status: :disabled} = state, _issues),
    do: {:ok, state}

  defp reconcile_attempt_ledger_from_snapshot(
         %State{attempt_ledger_status: :ready, attempt_ledger: %AttemptLedger{} = ledger} = state,
         issues
       )
       when is_list(issues) do
    with {:ok, state} <- reconcile_pending_lineage_closes(state, ledger),
         {:ok, records} <- AttemptLedger.open_lineages(ledger),
         state <- restore_durable_lineages(state, records),
         {:ok, issues_by_id} <- durable_issue_map_result(issues) do
      case reconcile_fetched_durable_issue_states(state, ledger, records, issues_by_id) do
        {:ok, reconciled_state} ->
          {:ok, reconciled_state}

        {:blocked, blocked_state, reason} ->
          {:blocked, %{blocked_state | attempt_ledger_status: {:blocked, reason}}, reason}
      end
    else
      {:blocked, %State{} = blocked_state, reason} ->
        {:blocked, %{blocked_state | attempt_ledger_status: {:blocked, reason}}, reason}

      {:error, reason} ->
        blocked_reason = {:attempt_ledger_unavailable, reason}
        {:blocked, %{state | attempt_ledger_status: {:blocked, blocked_reason}}, blocked_reason}
    end
  end

  defp reconcile_attempt_ledger_from_snapshot(%State{} = state, _issues) do
    {:blocked, state, ledger_block_reason(state) || :missing_attempt_ledger}
  end

  defp durable_issue_map_result(issues) do
    case durable_issue_map(issues) do
      {:ok, issues_by_id} -> {:ok, issues_by_id}
      :error -> {:error, :invalid_issue_collection}
    end
  end

  defp reconcile_startup_transition_candidates(%State{} = state, candidates, %Graph{} = graph)
       when is_list(candidates) do
    case reconcile_transition_candidate_list(state, candidates, graph.nodes) do
      {:blocked, blocked_state, reason} ->
        {:blocked, blocked_state, reason}

      {:ok, state, unresolved} ->
        sync_and_store_transition_candidates(state, unresolved)
    end
  end

  defp reconcile_transition_candidate_list(state, candidates, graph_issues) do
    Enum.reduce_while(candidates, {:ok, state, []}, fn candidate, accumulator ->
      reduce_transition_candidate(candidate, accumulator, graph_issues)
    end)
  end

  defp reduce_transition_candidate(candidate, {:ok, state, unresolved}, graph_issues) do
    case reconcile_startup_transition_candidate(state, candidate, graph_issues) do
      {:reconciled, next_state} ->
        {:cont, {:ok, next_state, unresolved}}

      {:unresolved, next_state} ->
        {:cont, {:ok, next_state, [candidate | unresolved]}}

      {:blocked, blocked_state, reason} ->
        {:halt, {:blocked, blocked_state, reason}}
    end
  end

  defp sync_and_store_transition_candidates(state, unresolved) do
    case TransitionCoordinator.sync_reconciliation_ledger(state.transition_coordinator) do
      :ok -> store_synced_transition_candidates(state, unresolved)
      {:error, :transitions_disabled} -> transitions_disabled_reconciliation(state)
      {:error, reason} -> {:blocked, state, {:transition_coordinator_unavailable, reason}}
    end
  end

  defp store_synced_transition_candidates(state, unresolved) do
    case TransitionCoordinator.list_reconciliation_candidates(state.transition_coordinator) do
      {:ok, remaining} when is_list(remaining) ->
        candidates = merge_transition_candidates(remaining, unresolved)
        {:ok, %{state | transition_reconciliation_candidates: candidates}}

      {:error, reason} ->
        {:blocked, state, {:transition_coordinator_unavailable, reason}}

      _invalid ->
        {:blocked, state, :invalid_transition_reconciliation_candidates}
    end
  end

  defp transitions_disabled_reconciliation(state) do
    if Config.settings!().tracker.kind != "plane" do
      {:ok, %{state | transition_reconciliation_candidates: []}}
    else
      {:blocked, state, :transitions_disabled}
    end
  end

  defp reconcile_startup_transition_candidate(%State{} = state, candidate, graph_issues) when is_map(candidate) do
    work_item_id = Map.get(candidate, :work_item_id)
    work_item = Map.get(state.work_control, work_item_id)
    issue = Map.get(graph_issues, work_item_id)
    dependency = Map.get(state.dependency_diagnostics, work_item_id)

    with %WorkItem{} <- work_item,
         %Issue{} <- issue,
         :ok <- startup_transition_item_safe(state, work_item, dependency),
         {:ok, state, work_item} <- ensure_startup_transition_suspension(state, work_item),
         {:ok, evidence_identity} <- startup_transition_evidence_identity(work_item),
         outcome when not is_nil(outcome) <- startup_transition_outcome(candidate, work_item),
         {:ok, state, work_item, recovery_resolved?} <-
           prepare_startup_transition_recovery(state, issue, candidate, outcome, work_item) do
      case TransitionCoordinator.reconcile_candidate(state.transition_coordinator, candidate, %{
             outcome: outcome,
             evidence_identity: evidence_identity,
             reconciled_at: DateTime.utc_now()
           }) do
        {:ok, _marker} ->
          {:reconciled, finish_startup_transition_recovery(state, work_item, recovery_resolved?)}

        {:error, {:ledger_sync_failed, reason}} ->
          {:blocked, state, {:transition_reconciliation_marker_sync_failed, work_item_id, reason}}

        {:error, _reason} ->
          {:unresolved, mark_transition_reconciliation_blocked(state, work_item_id)}
      end
    else
      {:error, blocked_state, {:ledger_sync_failed, reason}} ->
        {:blocked, blocked_state, {:recovery_ledger_sync_failed, work_item_id, reason}}

      {:error, blocked_state, {:transition_coordinator_unavailable, reason}} ->
        {:blocked, blocked_state, {:transition_coordinator_unavailable, reason}}

      {:error, blocked_state, _reason} ->
        {:unresolved, mark_transition_reconciliation_blocked(blocked_state, work_item_id)}

      _unresolved ->
        {:unresolved, mark_transition_reconciliation_blocked(state, work_item_id)}
    end
  end

  defp reconcile_startup_transition_candidate(%State{} = state, _candidate, _graph_issues), do: {:unresolved, state}

  defp mark_transition_reconciliation_blocked(%State{} = state, work_item_id) when is_binary(work_item_id),
    do: mark_durable_blocked(state, work_item_id, :transition_reconciliation_unresolved)

  defp mark_transition_reconciliation_blocked(%State{} = state, _work_item_id), do: state

  defp merge_transition_candidates(remaining, unresolved) do
    Enum.uniq_by(remaining ++ Enum.reverse(unresolved), fn candidate ->
      Map.get(candidate, :attempt_id) || Map.get(candidate, :work_item_id)
    end)
  end

  defp startup_transition_item_safe(%State{} = state, %WorkItem{} = work_item, dependency) do
    resumable_h040_context? = resumable_h040_checkpoint_context?(state, work_item.id)

    cond do
      Map.has_key?(state.durable_exhausted, work_item.id) ->
        {:error, :retry_lineage_exhausted}

      (WorkItem.suspended?(work_item) and not resumable_h040_context?) or
          not LifecycleAssessment.validated?(work_item.lifecycle_assessment) ->
        {:error, :work_item_suspended}

      not match?(%{allowed?: true}, dependency) ->
        {:error, :dependency_not_reconciled}

      not WorkflowLifecycle.canonical?(work_item.validated_lifecycle_state) ->
        {:error, :lifecycle_not_reconciled}

      true ->
        :ok
    end
  end

  defp resumable_h040_checkpoint_context?(state, work_item_id) do
    checkpoint_context = state.recovery_checkpoints |> Map.get(work_item_id) |> checkpoint_suspension_context()

    match?(%SuspensionContext{status: status} when status in [:open, :resolving], checkpoint_context) and
      SuspensionRecovery.classify_reason(checkpoint_context.reason) == :h040_reconciliation
  end

  defp ensure_startup_transition_suspension(%State{} = state, %WorkItem{} = work_item) do
    checkpoint = Map.get(state.recovery_checkpoints, work_item.id)

    case checkpoint_suspension_context(checkpoint) do
      %SuspensionContext{status: status} = context when status in [:open, :resolving] ->
        if SuspensionRecovery.classify_reason(context.reason) == :h040_reconciliation do
          work_item =
            %{work_item | suspension_context: context}
            |> force_transition_suspension(context)

          {:ok, %{state | work_control: Map.put(state.work_control, work_item.id, work_item)}, work_item}
        else
          {:error, state, :another_suspension_context_is_active}
        end

      nil ->
        persist_startup_transition_suspension(state, checkpoint, work_item)

      _other_context ->
        {:error, state, :another_suspension_context_is_active}
    end
  end

  defp persist_startup_transition_suspension(
         %State{recovery_ledger_status: :ready} = state,
         %{last_validated_lifecycle_state: last_state} = checkpoint,
         %WorkItem{provider_observation: %ProviderObservation{} = observation} = work_item
       ) do
    with true <- WorkflowLifecycle.canonical?(last_state),
         {:ok, context} <-
           SuspensionContext.new(%{
             work_item_id: work_item.id,
             last_validated_lifecycle_state: last_state,
             provider_observation: observation,
             reason: :transition_indeterminate,
             lineage_generation: Map.get(state.attempt_lineages, work_item.id),
             created_at: observation.observed_at,
             recovery_policy: :fresh_reconciliation,
             required_evidence: [],
             resume_target: last_state,
             status: :open
           }),
         next_checkpoint <-
           checkpoint_record(
             state,
             work_item.id,
             last_state,
             checkpoint.durable_guard_evidence,
             context,
             checkpoint.last_terminal_suspension_context
           ),
         {:ok, state, _persisted_checkpoint} <- persist_recovery_checkpoint(state, next_checkpoint) do
      work_item = work_item |> force_transition_suspension(context)

      {:ok, %{state | work_control: Map.put(state.work_control, work_item.id, work_item)}, work_item}
    else
      false -> {:error, state, :missing_trusted_lifecycle_checkpoint}
      {:error, blocked_state, reason} -> {:error, blocked_state, reason}
      {:error, reason} -> {:error, state, reason}
    end
  end

  defp persist_startup_transition_suspension(%State{} = state, _checkpoint, _work_item),
    do: {:error, state, :missing_recovery_ledger_or_checkpoint}

  defp force_transition_suspension(%WorkItem{} = work_item, %SuspensionContext{} = context) do
    disposition =
      AuthorityDisposition.new(%{
        status: :suspended,
        lifecycle_state: context.last_validated_lifecycle_state,
        reason: context.reason,
        resume_target: context.last_validated_lifecycle_state
      })

    %{work_item | authority_disposition: disposition, suspension_context: context}
  end

  defp prepare_startup_transition_recovery(state, issue, candidate, outcome, %WorkItem{} = work_item) do
    context = work_item.suspension_context

    with %SuspensionContext{} <- context,
         {:ok, last_candidate_for_item?} <- last_unresolved_transition_candidate_for_item(state, candidate),
         resolving <- begin_suspension_resolution(context),
         %{
           last_validated_lifecycle_state: last_state,
           durable_guard_evidence: evidence,
           last_terminal_suspension_context: terminal_context
         } <-
           Map.get(state.recovery_checkpoints, work_item.id),
         resolving_checkpoint <-
           checkpoint_record(
             state,
             work_item.id,
             last_state,
             evidence,
             resolving,
             terminal_context
           ),
         {:ok, state, _stored_checkpoint} <- persist_recovery_checkpoint(state, resolving_checkpoint),
         resolving_work_item <- %{work_item | suspension_context: resolving},
         state <- %{state | work_control: Map.put(state.work_control, work_item.id, resolving_work_item)},
         facts <-
           state
           |> suspension_recovery_facts(issue, resolving, resolving_work_item)
           |> Map.put(:transition_candidate_reconciled?, last_candidate_for_item? and not is_nil(outcome)),
         decision <- SuspensionRecovery.evaluate(resolving, facts),
         {:ok, state, resolved?, next_work_item} <-
           resolve_startup_transition_checkpoint(state, resolving_work_item, resolving, facts, decision) do
      {:ok, state, next_work_item, resolved?}
    else
      {:error, blocked_state, reason} -> {:error, blocked_state, reason}
      {:error, reason} -> {:error, state, reason}
      _missing_or_invalid -> {:ok, state, work_item, false}
    end
  end

  defp resolve_startup_transition_checkpoint(state, work_item, context, facts, decision) do
    if decision.status == :resolved and decision.resume_target == work_item.validated_lifecycle_state and
         LifecycleAssessment.validated?(work_item.lifecycle_assessment) do
      supplied_evidence = work_item.lifecycle_assessment.satisfied_guards

      with {:ok, resolved_context} <-
             SuspensionContext.resolve(context, %{
               fresh_reconciliation: true,
               resume_target: Map.get(facts, :resume_target),
               required_evidence: supplied_evidence
             }),
           checkpoint <-
             checkpoint_record(
               state,
               work_item.id,
               work_item.validated_lifecycle_state,
               durable_mechanical_evidence(supplied_evidence),
               nil,
               resolved_context
             ),
           {:ok, state, _stored_checkpoint} <- persist_recovery_checkpoint(state, checkpoint) do
        {:ok, state, true, work_item}
      else
        {:error, blocked_state, reason} -> {:error, blocked_state, reason}
        {:error, reason} -> {:error, state, reason}
      end
    else
      {:ok, state, false, work_item}
    end
  end

  defp last_unresolved_transition_candidate_for_item(state, candidate) do
    candidate_id = Map.get(candidate, :attempt_id) || Map.get(candidate, :work_item_id)
    work_item_id = Map.get(candidate, :work_item_id)

    case TransitionCoordinator.list_reconciliation_candidates(state.transition_coordinator) do
      {:ok, candidates} when is_list(candidates) ->
        {:ok, last_candidate_for_work_item?(candidates, candidate_id, work_item_id)}

      {:error, reason} ->
        {:error, {:transition_coordinator_unavailable, reason}}

      _invalid ->
        {:error, {:transition_coordinator_unavailable, :invalid_transition_reconciliation_candidates}}
    end
  end

  defp last_candidate_for_work_item?(candidates, candidate_id, work_item_id) do
    current_present? =
      Enum.any?(candidates, fn entry ->
        transition_candidate_id(entry) == candidate_id and Map.get(entry, :work_item_id) == work_item_id
      end)

    other_unresolved? =
      Enum.any?(candidates, fn entry ->
        Map.get(entry, :work_item_id) == work_item_id and transition_candidate_id(entry) != candidate_id
      end)

    current_present? and not other_unresolved?
  end

  defp transition_candidate_id(candidate),
    do: Map.get(candidate, :attempt_id) || Map.get(candidate, :work_item_id)

  defp finish_startup_transition_recovery(state, work_item, true) do
    disposition = AuthorityDisposition.derive(work_item.lifecycle_assessment)
    work_item = %{work_item | authority_disposition: disposition, suspension_context: nil}

    %{
      state
      | work_control: Map.put(state.work_control, work_item.id, work_item),
        durable_blocked: Map.delete(state.durable_blocked, work_item.id)
    }
  end

  defp finish_startup_transition_recovery(state, _work_item, false), do: state

  defp startup_transition_evidence_identity(%WorkItem{provider_observation: %ProviderObservation{snapshot_identity: identity}})
       when not is_nil(identity) and
              (is_binary(identity) or is_atom(identity) or is_integer(identity) or is_map(identity)) do
    if is_binary(identity) and String.trim(identity) == "" do
      {:error, :missing_provider_observation_identity}
    else
      {:ok, identity}
    end
  end

  defp startup_transition_evidence_identity(_work_item), do: {:error, :missing_provider_observation_identity}

  defp startup_transition_outcome(candidate, %WorkItem{validated_lifecycle_state: current_state}) do
    requested_to = Map.get(candidate, :requested_to) || Map.get(candidate, :target_state)
    requested_from = Map.get(candidate, :requested_from) || Map.get(candidate, :source_state)
    status = Map.get(candidate, :status) || Map.get(candidate, :state)

    cond do
      current_state == requested_to -> :verified
      status == :prepared and current_state == requested_from -> :provider_failed
      current_state not in [requested_from, requested_to] -> :conflict
      true -> nil
    end
  end

  defp clear_reconciled_stale_in_flight(%State{} = state) do
    Enum.reduce_while(MapSet.to_list(state.durable_in_flight), {:ok, state}, fn issue_id, {:ok, state_acc} ->
      case clear_reconciled_stale_in_flight_for_issue(state_acc, issue_id) do
        {:ok, next_state} -> {:cont, {:ok, next_state}}
        {:blocked, blocked_state, reason} -> {:halt, {:blocked, blocked_state, reason}}
      end
    end)
  end

  defp clear_reconciled_stale_in_flight_for_issue(%State{} = state, issue_id) do
    case stale_in_flight_block_reason(state, issue_id) do
      nil ->
        clear_reconciled_in_flight_record(state, issue_id)

      :running ->
        {:ok, state}

      :stale_in_flight_attempt_ledger_unavailable ->
        {:blocked, state, {:stale_in_flight_attempt_ledger_unavailable, issue_id}}

      reason ->
        {:ok, mark_durable_blocked(state, issue_id, reason)}
    end
  end

  defp stale_in_flight_block_reason(state, issue_id) do
    work_item = Map.get(state.work_control, issue_id)
    dependency = Map.get(state.dependency_diagnostics, issue_id)
    checkpoint = Map.get(state.recovery_checkpoints, issue_id)

    checks = [
      {Map.has_key?(state.running, issue_id), :running},
      {Map.has_key?(state.durable_exhausted, issue_id), :stale_in_flight_lineage_exhausted},
      {transition_candidate_pending?(state, issue_id), :stale_in_flight_transition_unresolved},
      {match?(%SuspensionContext{}, checkpoint_suspension_context(checkpoint)), :stale_in_flight_suspension_unresolved},
      {not eligible_work_item?(work_item), :stale_in_flight_work_item_unavailable},
      {not validated_work_item?(work_item), :stale_in_flight_lifecycle_unvalidated},
      {not match?(%{allowed?: true}, dependency), :stale_in_flight_dependency_unavailable},
      {not match?(%AttemptLedger{}, state.attempt_ledger), :stale_in_flight_attempt_ledger_unavailable}
    ]

    case Enum.find(checks, &elem(&1, 0)) do
      {_blocked?, reason} -> reason
      nil -> nil
    end
  end

  defp transition_candidate_pending?(state, issue_id) do
    Enum.any?(state.transition_reconciliation_candidates, &(Map.get(&1, :work_item_id) == issue_id))
  end

  defp eligible_work_item?(%WorkItem{authority_disposition: %AuthorityDisposition{status: :eligible}}), do: true
  defp eligible_work_item?(_work_item), do: false

  defp validated_work_item?(%WorkItem{lifecycle_assessment: %LifecycleAssessment{status: :validated}}), do: true
  defp validated_work_item?(_work_item), do: false

  defp clear_reconciled_in_flight_record(state, issue_id) do
    case AttemptLedger.clear_in_flight(state.attempt_ledger, issue_id) do
      :ok ->
        {:ok,
         state
         |> clear_durable_in_flight(issue_id)
         |> then(&%{&1 | durable_blocked: Map.delete(&1.durable_blocked, issue_id)})}

      {:error, reason} ->
        blocked_state = block_ledger(state, reason)
        {:blocked, blocked_state, {:attempt_ledger_clear_in_flight_failed, issue_id, reason}}
    end
  end

  defp startup_durable_stores_ready(%State{} = state) do
    routed? = Config.settings!().agent.routing == "routed"

    with :ok <- attempt_store_ready(state, routed?),
         :ok <- recovery_store_ready(state, routed?),
         :ok <- workspace_ownership_store_ready(state) do
      {:ok, state}
    else
      {:error, reason} ->
        {:blocked, state, reason}
    end
  end

  defp attempt_store_ready(state, routed?) do
    cond do
      routed? and state.attempt_ledger_status != :ready ->
        {:error, ledger_block_reason(state) || :attempt_ledger_unavailable}

      state.attempt_ledger_status in [:disabled, :ready] ->
        :ok

      true ->
        {:error, ledger_block_reason(state) || :attempt_ledger_unavailable}
    end
  end

  defp recovery_store_ready(state, routed?) do
    cond do
      routed? and state.recovery_ledger_status != :ready ->
        {:error, {:recovery_ledger_unavailable, state.recovery_ledger_status}}

      state.recovery_ledger_status in [:disabled, :ready] ->
        :ok

      true ->
        {:error, {:recovery_ledger_unavailable, state.recovery_ledger_status}}
    end
  end

  defp workspace_ownership_store_ready(%State{} = state) do
    if workspace_dispatchable?(state) do
      :ok
    else
      {:error, workspace_ownership_ledger_block_reason(state)}
    end
  end

  defp workspace_ownership_ledger_block_reason(%State{workspace_ownership_ledger_status: {:blocked, reason}}),
    do: {:workspace_ownership_ledger_unavailable, reason}

  defp workspace_ownership_ledger_block_reason(%State{}),
    do: {:workspace_ownership_ledger_unavailable, :missing_ledger_handle}

  defp maybe_reconcile_blocked_ledger(%State{} = state, reason) do
    with true <- retryable_ledger_reconciliation_reason?(reason),
         %AttemptLedger{} = ledger <- state.attempt_ledger do
      reconcile_blocked_ledger(state, ledger)
    else
      _ -> blocked_ledger_state(state, reason)
    end
  end

  defp reconcile_blocked_ledger(%State{} = state, %AttemptLedger{} = ledger) do
    case resync_sync_failed_ledger(state, ledger) do
      {:ok, state} ->
        case reconcile_attempt_ledger(state, ledger) do
          {:ok, state} ->
            state = %{state | attempt_ledger_status: :ready}
            state = reschedule_pending_retries(state)
            maybe_dispatch_ready(state)

          {:blocked, state, reason} ->
            Logger.debug("Attempt ledger reconciliation remains blocked: #{inspect(reason)}")
            %{state | attempt_ledger_status: {:blocked, reason}}
        end

      {:blocked, state} ->
        state
    end
  end

  defp resync_sync_failed_ledger(
         %State{
           attempt_ledger_status: {:blocked, {:attempt_ledger_unavailable, {:ledger_sync_failed, _reason}}}
         } = state,
         %AttemptLedger{} = ledger
       ) do
    case AttemptLedger.sync(ledger) do
      :ok ->
        {:ok, state}

      {:error, reason} ->
        Logger.debug("Attempt ledger durable resync remains blocked: #{inspect(reason)}")
        {:blocked, state}
    end
  end

  defp resync_sync_failed_ledger(%State{} = state, %AttemptLedger{}), do: {:ok, state}

  defp blocked_ledger_state(%State{} = state, reason) do
    Logger.debug("Skipping autonomous dispatch while attempt ledger is blocked: #{inspect(reason)}")
    state
  end

  defp retryable_ledger_reconciliation_reason?({:attempt_ledger_issue_missing, _}), do: true
  defp retryable_ledger_reconciliation_reason?({:attempt_ledger_tracker_unavailable, _}), do: true
  defp retryable_ledger_reconciliation_reason?({:attempt_ledger_close_failed, _}), do: true
  defp retryable_ledger_reconciliation_reason?({:attempt_ledger_unavailable, {:attempt_ledger_close_failed, _}}), do: true
  defp retryable_ledger_reconciliation_reason?({:attempt_ledger_unavailable, {:ledger_write_failed, _}}), do: true
  defp retryable_ledger_reconciliation_reason?({:attempt_ledger_unavailable, {:ledger_sync_failed, _}}), do: true
  defp retryable_ledger_reconciliation_reason?(_reason), do: false

  defp maybe_dispatch_ready(%State{} = state) do
    state =
      state
      |> reconcile_provider_project_contract_from_provider()
      |> refresh_dependency_state_for_reconciliation()
      |> reconcile_running_issues()
      |> reconcile_blocked_issues()
      |> reconcile_pending_workspace_releases()

    dispatch_ready_if_allowed(state)
  end

  defp reconcile_provider_project_contract_from_provider(
         %State{
           project_contract_evidence: %ProjectContractEvidence{
             contract: %ProviderProjectContract{}
           }
         } = state
       ) do
    apply_provider_project_snapshot(state, Tracker.fetch_project_snapshot())
  end

  defp reconcile_provider_project_contract_from_provider(%State{} = state), do: state

  @doc false
  @spec reconcile_provider_project_snapshot_for_test(State.t(), term()) :: State.t()
  def reconcile_provider_project_snapshot_for_test(%State{} = state, result),
    do: apply_provider_project_snapshot(state, result)

  defp apply_provider_project_snapshot(%State{} = state, {:ok, snapshot}) when is_map(snapshot) do
    {state, _validation} = reconcile_project_contract_state(state, snapshot)
    state
  end

  defp apply_provider_project_snapshot(%State{} = state, {:error, reason}) do
    Logger.debug("Provider project snapshot unavailable; autonomous dispatch remains fenced: #{safe_reason(reason)}")
    mark_provider_project_snapshot_incomplete(state)
  end

  defp apply_provider_project_snapshot(%State{} = state, _invalid) do
    Logger.debug("Provider project snapshot malformed; autonomous dispatch remains fenced")
    mark_provider_project_snapshot_incomplete(state)
  end

  defp mark_provider_project_snapshot_incomplete(%State{} = state) do
    {state, _validation} = reconcile_project_contract_state(state, %{completeness: :incomplete})
    state
  end

  defp dispatch_ready_if_allowed(%State{} = state) do
    if autonomous_dispatch_allowed?(state) do
      fetch_and_dispatch_ready(state)
    else
      Logger.debug("Skipping autonomous dispatch after reconciliation fenced the ledger")
      state
    end
  end

  defp fetch_and_dispatch_ready(%State{} = state) do
    with :ok <- Config.validate!(),
         {:ok, issues} <- Tracker.fetch_issues_by_states(Config.settings!().tracker.active_states) do
      state =
        state
        |> ensure_graph_contains_active_issues(issues)
        |> reconcile_visible_missing_attempt_lineages(issues)

      if autonomous_dispatch_allowed?(state), do: dispatch_ready_issues(state, issues), else: state
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

  defp refresh_dependency_state_for_reconciliation(%State{} = state) do
    refresh_dependency_state_for_poll(state, [])
  end

  defp dispatch_ready_issues(%State{} = state, issues) do
    if available_slots(state) > 0 do
      choose_issues(issues, state)
    else
      state
    end
  end

  defp refresh_dependency_state_for_poll(%State{} = state, active_issues) when is_list(active_issues) do
    case Tracker.fetch_dependency_graph() do
      {:ok, %Graph{} = graph} ->
        state
        |> refresh_dependency_graph_epoch(graph)
        |> ensure_graph_contains_active_issues(active_issues)

      {:ok, graph_issues} when is_list(graph_issues) ->
        state
        |> refresh_dependency_state(graph_issues, :complete)
        |> ensure_graph_contains_active_issues(active_issues)

      {:ok, _invalid_graph} ->
        Logger.warning("Dependency graph provider returned invalid data; implementation dispatch is disabled")

        state
        |> refresh_dependency_state(active_issues, {:unavailable, :invalid_dependency_graph})
        |> refresh_work_control(active_issues)

      {:error, reason} ->
        Logger.warning("Dependency graph refresh unavailable; implementation dispatch is disabled: #{inspect(reason)}")

        state
        |> refresh_dependency_state(active_issues, {:unavailable, graph_failure_reason(reason)})
        |> refresh_work_control(active_issues)
    end
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
    state
    |> refresh_work_control(overlay_state_dependency_facts(state, running_issues))
    |> ensure_graph_contains_running_issues(running_issues)
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
  @spec reconcile_stalled_running_issues_for_test(State.t()) :: State.t()
  def reconcile_stalled_running_issues_for_test(%State{} = state), do: reconcile_stalled_running_issues(state)

  @doc false
  @spec terminate_running_issue_for_test(State.t(), String.t(), boolean(), atom()) :: State.t()
  def terminate_running_issue_for_test(%State{} = state, issue_id, cleanup_workspace, termination_reason)
      when is_binary(issue_id) and is_boolean(cleanup_workspace) and is_atom(termination_reason) do
    terminate_running_issue(state, issue_id, cleanup_workspace, termination_reason)
  end

  @doc false
  @spec stop_running_issue_for_route_change_for_test(
          State.t(),
          Issue.t(),
          map(),
          Route.t(),
          Route.t()
        ) :: State.t()
  def stop_running_issue_for_route_change_for_test(
        %State{} = state,
        %Issue{} = issue,
        running_entry,
        %Route{} = previous_route,
        %Route{} = next_route
      )
      when is_map(running_entry) do
    stop_running_issue_for_route_change(state, issue, running_entry, previous_route, next_route)
  end

  @doc false
  @spec transition_running_entry_attempt_for_test(map(), atom()) ::
          {:ok, map()} | {:error, :invalid_runtime_attempt_transition}
  def transition_running_entry_attempt_for_test(running_entry, to_state)
      when is_map(running_entry) and is_atom(to_state) do
    transition_running_entry_attempt(running_entry, to_state)
  end

  @doc false
  @spec tracker_terminal_teardown_reason_for_test(Issue.t(), State.t()) :: atom()
  def tracker_terminal_teardown_reason_for_test(%Issue{} = issue, %State{} = state) do
    tracker_terminal_teardown_reason(issue, state)
  end

  @doc false
  @spec handle_normal_route_change_for_test(State.t(), String.t(), map()) :: State.t()
  def handle_normal_route_change_for_test(%State{} = state, issue_id, running_entry)
      when is_binary(issue_id) and is_map(running_entry) do
    handle_normal_route_change(state, issue_id, running_entry)
  end

  @doc false
  @spec schedule_agent_route_change_retry_for_test(State.t(), String.t(), map(), term()) :: State.t()
  def schedule_agent_route_change_retry_for_test(%State{} = state, issue_id, running_entry, route_change)
      when is_binary(issue_id) and is_map(running_entry) do
    schedule_agent_route_change_retry(state, issue_id, running_entry, route_change)
  end

  @doc false
  @spec schedule_poll_route_change_retry_for_test(State.t(), Issue.t(), map(), non_neg_integer(), term()) ::
          State.t()
  def schedule_poll_route_change_retry_for_test(
        %State{} = state,
        %Issue{} = issue,
        running_entry,
        next_attempt,
        route_change
      )
      when is_map(running_entry) and is_integer(next_attempt) and next_attempt >= 0 do
    schedule_poll_route_change_retry(state, issue, running_entry, next_attempt, route_change)
  end

  @doc false
  @spec reconcile_blocked_ledger_for_test(State.t()) :: State.t()
  def reconcile_blocked_ledger_for_test(%State{} = state) do
    reconcile_blocked_ledger_without_dispatch(state)
  end

  @doc false
  @spec reconcile_startup_transition_candidate_for_test(State.t(), map(), map()) :: term()
  def reconcile_startup_transition_candidate_for_test(%State{} = state, candidate, issues) when is_map(issues) do
    reconcile_startup_transition_candidate(state, candidate, issues)
  end

  @doc false
  @spec reconcile_startup_transition_candidates_for_test(State.t(), [map()], Graph.t()) :: term()
  def reconcile_startup_transition_candidates_for_test(%State{} = state, candidates, %Graph{} = graph)
      when is_list(candidates) do
    reconcile_startup_transition_candidates(state, candidates, graph)
  end

  @doc false
  @spec clear_stale_in_flight_for_test(State.t(), String.t()) :: term()
  def clear_stale_in_flight_for_test(%State{} = state, issue_id) when is_binary(issue_id) do
    clear_reconciled_stale_in_flight_for_issue(state, issue_id)
  end

  defp reconcile_blocked_ledger_without_dispatch(%State{attempt_ledger: %AttemptLedger{} = ledger} = state) do
    case resync_sync_failed_ledger(state, ledger) do
      {:ok, state} -> finalize_reconciled_ledger_status(state, ledger)
      {:blocked, state} -> state
    end
  end

  defp reconcile_blocked_ledger_without_dispatch(%State{} = state), do: state

  defp finalize_reconciled_ledger_status(%State{} = state, %AttemptLedger{} = ledger) do
    case reconcile_attempt_ledger(state, ledger) do
      {:ok, state} -> %{state | attempt_ledger_status: :ready}
      {:blocked, state, reason} -> %{state | attempt_ledger_status: {:blocked, reason}}
    end
  end

  @doc false
  @spec handle_normal_continuation_for_test(State.t(), String.t(), map()) :: State.t()
  def handle_normal_continuation_for_test(%State{} = state, issue_id, running_entry)
      when is_binary(issue_id) and is_map(running_entry) do
    handle_normal_continuation(state, issue_id, running_entry)
  end

  @doc false
  @spec refresh_work_control_for_test(State.t(), [Issue.t()]) :: State.t()
  def refresh_work_control_for_test(%State{} = state, issues) when is_list(issues) do
    refresh_work_control(state, issues)
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
    issue = overlay_current_dependency_facts(state, issue)
    state = refresh_work_control(state, [issue])

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

        state = refresh_running_issue_entry(state, issue)
        terminate_running_issue(state, issue.id, true, tracker_terminal_teardown_reason(issue, state))

      routed_lifecycle_suspended?(issue, state) ->
        Logger.info("Stopping active agent after unsafe lifecycle observation for #{issue_context(issue)}")
        terminate_running_issue(state, issue.id, false, :observed)

      !issue_in_routing_scope?(issue) ->
        Logger.info("Issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; stopping active agent")

        terminate_running_issue(state, issue.id, false, :not_routable)

      routed_issue_continuable?(issue, state) ->
        refresh_running_issue_state(state, issue)

      Config.settings!().agent.routing == "routed" ->
        Logger.info("Stopping active agent after canonical route became unavailable for #{issue_context(issue)}")
        terminate_running_issue(state, issue.id, false, :observed)

      active_issue_state?(issue.state, active_states) ->
        refresh_running_issue_state(state, issue)

      true ->
        Logger.info("Issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, false, :non_active)
    end
  end

  defp reconcile_issue_state(_issue, state, _active_states, _terminal_states), do: state

  defp refresh_running_issue_entry(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      running_entry when is_map(running_entry) ->
        %{state | running: Map.put(state.running, issue.id, Map.put(running_entry, :issue, issue))}

      _missing_entry ->
        state
    end
  end

  defp reconcile_blocked_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_blocked_issue_states([issue | rest], state, active_states, terminal_states) do
    issue = overlay_current_dependency_facts(state, issue)
    state = refresh_work_control(state, [issue])

    reconcile_blocked_issue_states(
      rest,
      reconcile_blocked_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_blocked_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
    if terminal_issue_state?(issue.state, terminal_states) do
      reconcile_terminal_blocked_issue_state(issue, state)
    else
      reconcile_nonterminal_blocked_issue_state(issue, state, active_states)
    end
  end

  defp reconcile_blocked_issue_state(_issue, state, _active_states, _terminal_states), do: state

  defp reconcile_terminal_blocked_issue_state(issue, state) do
    Logger.info("Blocked issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; releasing block")

    blocked_entry = Map.get(state.blocked, issue.id, %{})

    case cleanup_issue_workspace(state, issue, Map.get(blocked_entry, :worker_host)) do
      :ok ->
        state
        |> release_issue_claim(issue.id)
        |> reset_attempt_counters(issue.id)

      {:error, reason} ->
        Logger.error("Blocked terminal workspace cleanup remains pending for #{issue_context(issue)}: #{inspect(reason)}")
        state
    end
  end

  defp reconcile_nonterminal_blocked_issue_state(issue, state, active_states) do
    cond do
      routed_lifecycle_suspended?(issue, state) ->
        Logger.info("Retaining blocked issue after unsafe lifecycle observation for #{issue_context(issue)}")
        retain_blocked_issue(state, issue)

      !issue_in_routing_scope?(issue) ->
        Logger.info("Blocked issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; releasing block")
        release_issue_claim(state, issue.id)

      routed_issue_continuable?(issue, state) ->
        refresh_blocked_issue_state(state, issue)

      Config.settings!().agent.routing == "routed" ->
        Logger.info("Retaining blocked issue after canonical route became unavailable for #{issue_context(issue)}")
        retain_blocked_issue(state, issue)

      active_issue_state?(issue.state, active_states) ->
        refresh_blocked_issue_state(state, issue)

      true ->
        Logger.info("Blocked issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; releasing block")
        release_issue_claim(state, issue.id)
    end
  end

  defp routed_lifecycle_suspended?(%Issue{id: issue_id}, %State{} = state)
       when is_binary(issue_id) do
    if Config.settings!().agent.routing == "routed" do
      case Map.get(state.work_control, issue_id) do
        %WorkItem{lifecycle_assessment: assessment, authority_disposition: disposition} ->
          not LifecycleAssessment.validated?(assessment) or
            AuthorityDisposition.suspended?(disposition)

        _missing_work_item ->
          true
      end
    else
      false
    end
  end

  defp routed_lifecycle_suspended?(_issue, _state), do: false

  defp routed_issue_continuable?(%Issue{} = issue, %State{} = state) do
    Config.settings!().agent.routing == "routed" and
      routed_issue_in_scope?(issue) and
      not routed_lifecycle_suspended?(issue, state) and
      match?({:ok, %Route{}}, route_for_issue(issue, state))
  end

  defp routed_issue_continuable?(_issue, _state), do: false

  defp retain_blocked_issue(%State{} = state, %Issue{id: issue_id} = issue)
       when is_binary(issue_id) do
    case Map.get(state.blocked, issue_id) do
      %{issue: _} = blocked_entry -> %{state | blocked: Map.put(state.blocked, issue_id, %{blocked_entry | issue: issue})}
      _missing -> state
    end
  end

  defp retain_blocked_issue(state, _issue), do: state

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

        state_acc
        |> terminate_running_issue(issue_id, false, :tracker_missing)
        |> forget_work_item(issue_id)
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

        state_acc
        |> release_issue_claim(issue_id)
        |> forget_work_item(issue_id)
      end
    end)
  end

  defp reconcile_missing_blocked_issue_ids(state, _requested_issue_ids, _issues), do: state

  defp forget_work_item(%State{} = state, issue_id) when is_binary(issue_id) do
    %{state | work_control: Map.delete(state.work_control, issue_id)}
  end

  defp forget_work_item(state, _issue_id), do: state

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
    case route_for_issue(issue, state) do
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

    case decision.allowed? do
      true ->
        %{state | running: Map.put(state.running, issue.id, %{running_entry | issue: issue})}

      _ ->
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

    case record_route_change_events(state, issue.id, route_change, in_flight: true) do
      {:ok, state} ->
        apply_poll_route_change_terminal_retry(state, issue, running_entry, next_attempt, route_change)

      {:stop, state, reason} ->
        stop_and_block_issue(
          state,
          issue.id,
          %{running_entry | issue: issue},
          attempt_policy_error(reason)
        )

      {:error, state, reason} ->
        stop_and_block_issue(
          state,
          issue.id,
          %{running_entry | issue: issue},
          attempt_ledger_error(reason)
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
    case route_for_issue(issue, state) do
      {:ok, %Route{responsibility: responsibility}} ->
        decision = dependency_decision(issue, responsibility, state)
        decision.allowed? == true and not dependency_cycle?(state, issue.id)

      {:error, _reason} ->
        false
    end
  end

  defp terminate_running_issue(%State{} = state, issue_id, cleanup_workspace, termination_reason) do
    case finalize_running_attempt_removal(state, issue_id, cleanup_workspace, termination_reason) do
      {:ok, state} -> state
      {:error, state} -> state
    end
  end

  defp finalize_running_attempt_removal(%State{} = state, issue_id, cleanup_workspace, termination_reason) do
    case Map.get(state.running, issue_id) do
      nil ->
        {:ok, release_running_maps_without_entry(state, issue_id, cleanup_workspace)}

      %{pid: pid, ref: ref, identifier: identifier} = running_entry ->
        finalize_existing_running_removal(
          state,
          issue_id,
          running_entry,
          pid,
          ref,
          identifier,
          cleanup_workspace,
          termination_reason
        )

      _ ->
        {:ok, release_running_maps_without_entry(state, issue_id, cleanup_workspace)}
    end
  end

  defp finalize_existing_running_removal(
         state,
         issue_id,
         running_entry,
         pid,
         ref,
         identifier,
         cleanup_workspace,
         termination_reason
       ) do
    terminal_state = runtime_attempt_terminal_for_teardown(termination_reason)

    case transition_running_entry_attempt(running_entry, terminal_state) do
      {:ok, running_entry} ->
        state =
          complete_terminalized_running_removal(
            state,
            issue_id,
            running_entry,
            pid,
            ref,
            identifier,
            cleanup_workspace,
            termination_reason
          )

        {:ok, state}

      {:error, :invalid_runtime_attempt_transition} ->
        {:error, state}
    end
  end

  defp release_running_maps_without_entry(state, issue_id, cleanup_workspace) do
    state = release_issue_claim(state, issue_id)
    if cleanup_workspace, do: reset_attempt_counters(state, issue_id), else: state
  end

  defp complete_terminalized_running_removal(
         state,
         issue_id,
         running_entry,
         pid,
         ref,
         _identifier,
         cleanup_workspace,
         termination_reason
       ) do
    state = record_session_completion_totals(state, running_entry)
    state = record_recent_attempt(state, issue_id, running_entry, termination_reason)
    stop_running_task(pid, ref, state.task_supervisor)

    if cleanup_workspace and terminal_cleanup_termination?(termination_reason),
      do: cleanup_terminalized_running_workspace(state, running_entry, issue_id)

    state = pop_running_issue_maps(state, issue_id)

    if cleanup_workspace, do: reset_attempt_counters(state, issue_id), else: state
  end

  defp cleanup_terminalized_running_workspace(state, running_entry, issue_id) do
    case Map.get(running_entry, :issue) do
      %Issue{} = issue ->
        cleanup_terminal_workspace(state, issue, Map.get(running_entry, :worker_host))

      _missing_issue ->
        Logger.error("Skipping terminal workspace cleanup for issue_id=#{issue_id}: current issue identity is unavailable")
    end
  end

  defp cleanup_terminal_workspace(state, issue, worker_host) do
    case cleanup_issue_workspace(state, issue, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Terminal workspace cleanup remains pending for #{issue_context(issue)}: #{inspect(reason)}")
    end
  end

  defp pop_running_issue_maps(%State{} = state, issue_id) do
    %{
      state
      | running: Map.delete(state.running, issue_id),
        claimed: MapSet.delete(state.claimed, issue_id),
        blocked: Map.delete(state.blocked, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp tracker_terminal_teardown_reason(%Issue{} = issue, %State{} = state) do
    if successful_runtime_completion_observation?(issue, state) do
      :terminal_completed
    else
      :terminal_cancelled
    end
  end

  defp terminal_cleanup_termination?(termination_reason),
    do: termination_reason in [:terminal_completed, :terminal_cancelled]

  defp successful_runtime_completion_observation?(%Issue{} = issue, %State{} = state) do
    case Map.get(state.work_control, issue.id) do
      %WorkItem{lifecycle_assessment: %LifecycleAssessment{} = assessment} ->
        LifecycleAssessment.completion_validated?(assessment)

      _ ->
        false
    end
  end

  defp runtime_attempt_terminal_for_teardown(termination_reason) do
    case termination_reason do
      :terminal_completed -> :completed
      :terminal_cancelled -> :cancelled
      :runtime_unavailable -> :failed
      :runtime_stalled -> :retry_queued
      _ -> :cancelled
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

    case record_attempt_event(state, issue_id, :ordinary_failure, in_flight: true) do
      {:ok, state} ->
        schedule_stall_retry_after_terminal_removal(
          state,
          issue_id,
          running_entry,
          next_attempt,
          retry_metadata
        )

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
    case transition_running_entry_attempt(running_entry, :blocked) do
      {:ok, running_entry} ->
        stop_running_task(
          Map.get(running_entry, :pid),
          Map.get(running_entry, :ref),
          state.task_supervisor
        )

        do_block_issue_from_entry(state, issue_id, running_entry, error, dependency)

      {:error, :invalid_runtime_attempt_transition} ->
        state
    end
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
    case transition_running_entry_attempt(running_entry, :blocked) do
      {:ok, running_entry} ->
        do_block_issue_from_entry(state, issue_id, running_entry, error, dependency)

      {:error, :invalid_runtime_attempt_transition} ->
        block_issue_from_terminal_attempt(state, issue_id, running_entry, error, dependency)
    end
  end

  defp block_issue_from_terminal_attempt(%State{} = state, issue_id, running_entry, error, dependency) do
    case Map.get(running_entry, :runtime_attempt) do
      %RuntimeAttempt{state: attempt_state}
      when attempt_state in [:completed, :retry_queued, :blocked, :failed, :cancelled] ->
        do_block_issue_from_entry(state, issue_id, running_entry, error, dependency)

      _ ->
        state
    end
  end

  defp do_block_issue_from_entry(%State{} = state, issue_id, running_entry, error, dependency) do
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

    refresh_dependency_graph_epoch(state, graph)
  end

  defp refresh_dependency_graph_epoch(%State{} = state, %Graph{} = graph) do
    issues = graph.nodes |> Map.values() |> overlay_epoch_dependency_facts(graph)
    state = refresh_work_control(%{state | dependency_graph: graph}, issues)

    dependency_diagnostics =
      Enum.reduce(Map.values(graph.nodes), %{}, fn
        %Issue{id: issue_id} = issue, diagnostics when is_binary(issue_id) ->
          Map.put(diagnostics, issue_id, dependency_diagnostic_for_issue(issue, graph, state))

        _, diagnostics ->
          diagnostics
      end)

    %{
      state
      | dependency_graph: graph,
        dependency_diagnostics: dependency_diagnostics
    }
  end

  defp overlay_epoch_dependency_facts(issues, %Graph{} = graph) when is_list(issues) do
    Enum.map(issues, &overlay_epoch_dependency_facts(graph, &1))
  end

  defp overlay_epoch_dependency_facts(%Graph{} = graph, %Issue{id: issue_id} = issue)
       when is_binary(issue_id) do
    case Map.get(graph.nodes, issue_id) do
      %Issue{} = epoch_issue ->
        %{issue | blocked_by: epoch_issue.blocked_by, dependency_completeness: epoch_issue.dependency_completeness}

      _missing ->
        %{issue | blocked_by: [], dependency_completeness: {:unavailable, :missing_graph_node}}
    end
  end

  defp overlay_epoch_dependency_facts(_graph, issue), do: issue

  defp overlay_state_dependency_facts(%State{dependency_graph: %Graph{} = graph}, issues)
       when is_list(issues) do
    if Config.settings!().agent.routing == "legacy",
      do: issues,
      else: overlay_epoch_dependency_facts(issues, graph)
  end

  defp overlay_state_dependency_facts(_state, issues), do: issues

  defp overlay_current_dependency_facts(%State{} = state, %Issue{} = issue) do
    case overlay_state_dependency_facts(state, [issue]) do
      [%Issue{} = overlaid] -> overlaid
      _invalid -> issue
    end
  end

  defp overlay_current_dependency_facts(_state, issue), do: issue

  defp refresh_work_control(%State{} = state, issues) when is_list(issues) do
    case Config.settings!().agent.routing do
      "routed" -> refresh_routed_work_control(state, issues)
      _legacy -> state
    end
  end

  defp refresh_work_control(%State{} = state, _issues), do: state

  defp refresh_routed_work_control(%State{} = state, issues) do
    Enum.reduce(issues, state, &refresh_routed_work_item/2)
  end

  defp refresh_routed_work_item(%Issue{id: issue_id} = issue, %State{} = state)
       when is_binary(issue_id) do
    if state.recovery_ledger_status == :disabled do
      refresh_routed_work_item_without_recovery_ledger(issue, state)
    else
      refresh_routed_work_item_with_recovery_ledger(issue, state)
    end
  end

  defp refresh_routed_work_item(_issue, %State{} = state), do: state

  defp refresh_routed_work_item_with_recovery_ledger(%Issue{id: issue_id} = issue, %State{} = state) do
    previous = Map.get(state.work_control, issue_id)
    checkpoint = recovery_checkpoint_for_refresh(state, issue_id, previous)
    contract = Config.settings!().provider_project_contract
    active_context = checkpoint_suspension_context(checkpoint)
    prior_state = checkpoint && checkpoint.last_validated_lifecycle_state

    prior_disposition =
      cond do
        match?(%SuspensionContext{status: :escalated}, active_context) ->
          %AuthorityDisposition{status: :escalated, lifecycle_state: prior_state, reason: active_context.reason}

        match?(%SuspensionContext{status: status} when status in [:open, :resolving], active_context) ->
          %AuthorityDisposition{status: :suspended, lifecycle_state: prior_state, reason: active_context.reason}

        state.startup_reconciliation == :ready ->
          prior_authority_disposition(previous)

        true ->
          nil
      end

    opts = %{
      provider: Config.settings!().tracker.kind,
      observed_at: DateTime.utc_now(),
      prior_validated_lifecycle_state: prior_state,
      prior_authority_disposition: prior_disposition,
      evidence: recovery_evidence(issue, checkpoint, contract),
      provider_project_contract: contract
    }

    case WorkItem.from_issue(issue, opts) do
      {:ok, work_item} ->
        persist_refreshed_work_item(state, issue, checkpoint, work_item)

      {:error, reason} ->
        Logger.warning("Unable to derive routed WorkItem for #{issue_context(issue)}: #{inspect(reason)}")

        state
        |> mark_durable_blocked(issue_id, {:work_item_derivation_failed, reason})
        |> then(&%{&1 | work_control: Map.delete(&1.work_control, issue_id)})
    end
  end

  defp refresh_routed_work_item_without_recovery_ledger(%Issue{id: issue_id} = issue, %State{} = state) do
    previous = Map.get(state.work_control, issue_id)
    contract = Config.settings!().provider_project_contract

    opts = %{
      provider: Config.settings!().tracker.kind,
      observed_at: DateTime.utc_now(),
      prior_validated_lifecycle_state: ephemeral_prior_validated_state(previous),
      prior_authority_disposition: ephemeral_prior_authority_disposition(previous),
      evidence: ephemeral_evidence_for_observation(issue, previous, contract),
      provider_project_contract: contract
    }

    case WorkItem.from_issue(issue, opts) do
      {:ok, work_item} ->
        work_item =
          work_item
          |> attach_ephemeral_suspension_context(previous, opts)
          |> apply_project_contract_guard(state)
          |> suspend_ephemeral_exhausted_lineage(state)

        %{state | work_control: Map.put(state.work_control, issue_id, work_item)}

      {:error, reason} ->
        Logger.warning("Unable to derive routed WorkItem for #{issue_context(issue)}: #{inspect(reason)}")
        %{state | work_control: Map.delete(state.work_control, issue_id)}
    end
  end

  defp ephemeral_prior_validated_state(%WorkItem{
         authority_disposition: %AuthorityDisposition{status: :suspended, lifecycle_state: :canceled}
       }),
       do: :canceled

  defp ephemeral_prior_validated_state(%WorkItem{
         suspension_context: %SuspensionContext{last_validated_lifecycle_state: state},
         validated_lifecycle_state: fallback_state
       }) do
    case WorkflowLifecycle.parse(state) do
      {:ok, canonical_state} -> canonical_state
      {:error, _reason} -> fallback_state
    end
  end

  defp ephemeral_prior_validated_state(%WorkItem{validated_lifecycle_state: state}), do: state
  defp ephemeral_prior_validated_state(_previous), do: nil

  defp ephemeral_prior_authority_disposition(%WorkItem{authority_disposition: %AuthorityDisposition{status: :suspended}}),
    do: nil

  defp ephemeral_prior_authority_disposition(previous), do: prior_authority_disposition(previous)

  defp ephemeral_evidence_for_observation(%Issue{} = issue, %WorkItem{} = previous, %ProviderProjectContract{} = contract) do
    with true <- stable_provider_state_identity?(issue, previous.provider_observation),
         {:ok, mapped_state} <-
           ProviderProjectContract.resolve_provider_state(
             contract,
             issue.provider_state_id,
             issue.provider_state_group
           ),
         true <- mapped_state == previous.validated_lifecycle_state do
      previous.lifecycle_assessment.satisfied_guards
    else
      _changed_or_invalid -> []
    end
  end

  defp ephemeral_evidence_for_observation(%Issue{state: state}, %WorkItem{} = previous, _contract) do
    case WorkflowLifecycle.parse(state) do
      {:ok, canonical_state} when canonical_state == previous.validated_lifecycle_state ->
        previous.lifecycle_assessment.satisfied_guards

      _changed_or_invalid ->
        []
    end
  end

  defp ephemeral_evidence_for_observation(_issue, _previous, _contract), do: []

  defp stable_provider_state_identity?(%Issue{} = issue, %ProviderObservation{} = prior_observation) do
    present_string?(prior_observation.provider_state_id) and
      present_string?(issue.provider_state_id) and
      issue.provider_state_id == prior_observation.provider_state_id and
      provider_state_groups_equivalent?(issue.provider_state_group, prior_observation.provider_state_group)
  end

  defp stable_provider_state_identity?(_issue, _prior_observation), do: false

  defp provider_state_groups_equivalent?(left, right) do
    normalize_provider_state_group(left) == normalize_provider_state_group(right)
  end

  defp normalize_provider_state_group(group) when group in [:backlog, :unstarted, :started, :completed, :cancelled], do: group

  defp normalize_provider_state_group(group) when is_binary(group) do
    case String.downcase(String.trim(group)) do
      "backlog" -> :backlog
      "unstarted" -> :unstarted
      "started" -> :started
      "completed" -> :completed
      "cancelled" -> :cancelled
      "canceled" -> :cancelled
      _unknown -> nil
    end
  end

  defp normalize_provider_state_group(_group), do: nil

  defp attach_ephemeral_suspension_context(%WorkItem{} = work_item, %WorkItem{} = previous, opts) do
    prior_state = Map.get(opts, :prior_validated_lifecycle_state)

    if work_item.lifecycle_assessment.status in [:authority_reducing, :validation_required, :invalid] and
         WorkflowLifecycle.canonical?(prior_state) do
      observation = work_item.provider_observation

      case SuspensionContext.new(%{
             work_item_id: work_item.id,
             last_validated_lifecycle_state: prior_state,
             provider_observation: observation,
             reason: work_item.lifecycle_assessment.reason || :unsafe_lifecycle_observation,
             lineage_generation: ephemeral_lineage_generation(previous),
             created_at: observation.observed_at,
             recovery_policy: :fresh_reconciliation,
             required_evidence: work_item.lifecycle_assessment.missing_guards,
             resume_target: prior_state
           }) do
        {:ok, context} -> %{work_item | suspension_context: context}
        {:error, _reason} -> work_item
      end
    else
      %{work_item | suspension_context: nil}
    end
  end

  defp attach_ephemeral_suspension_context(%WorkItem{} = work_item, _previous, _opts), do: work_item

  defp ephemeral_lineage_generation(%WorkItem{suspension_context: %SuspensionContext{lineage_generation: generation}}),
    do: generation

  defp ephemeral_lineage_generation(_previous), do: nil

  defp suspend_ephemeral_exhausted_lineage(%WorkItem{} = work_item, %State{} = state) do
    if Map.has_key?(state.durable_exhausted, work_item.id) do
      case WorkItem.suspend(work_item, :retry_exhausted) do
        {:ok, suspended} -> suspended
        {:error, _reason} -> work_item
      end
    else
      work_item
    end
  end

  defp recovery_checkpoint_for_refresh(state, issue_id, _previous),
    do: Map.get(state.recovery_checkpoints, issue_id)

  defp persist_refreshed_work_item(state, issue, original_checkpoint, work_item) do
    work_item =
      work_item
      |> apply_project_contract_guard(state)
      |> attach_checkpoint_suspension(original_checkpoint, state)

    {state, work_item} = maybe_reconcile_suspension(state, issue, original_checkpoint, work_item)
    {state, work_item} = maybe_suspend_exhausted_lineage(state, issue, original_checkpoint, work_item)
    checkpoint = Map.get(state.recovery_checkpoints, issue.id, original_checkpoint)

    case persist_refreshed_work_item_checkpoint(state, checkpoint, work_item) do
      {:ok, next_state, next_checkpoint} ->
        %{
          next_state
          | work_control: Map.put(next_state.work_control, issue.id, work_item),
            recovery_checkpoints: put_checkpoint(next_state.recovery_checkpoints, issue.id, next_checkpoint)
        }

      {:error, blocked_state, reason} ->
        Logger.error("Unable to persist work-control recovery checkpoint for #{issue_context(issue)}: #{inspect(reason)}")
        blocked_state
    end
  end

  defp prior_authority_disposition(%WorkItem{authority_disposition: disposition}), do: disposition
  defp prior_authority_disposition(_previous), do: nil

  defp checkpoint_suspension_context(%{active_suspension_context: %SuspensionContext{} = context}), do: context

  defp checkpoint_suspension_context(%{last_terminal_suspension_context: %SuspensionContext{status: :escalated} = context}),
    do: context

  defp checkpoint_suspension_context(_checkpoint), do: nil

  defp recovery_evidence(_issue, nil, _contract), do: []

  defp recovery_evidence(%Issue{} = issue, checkpoint, contract) do
    with {:ok, observation} <- ProviderObservation.from_issue(issue, %{provider: Config.settings!().tracker.kind}),
         {:ok, mapped_state} <- map_observation_state(observation, contract),
         true <- mapped_state == checkpoint.last_validated_lifecycle_state do
      checkpoint.durable_guard_evidence
    else
      _changed_or_invalid -> []
    end
  end

  defp map_observation_state(observation, %ProviderProjectContract{} = contract),
    do: ProviderObservation.map_state(observation, contract)

  defp map_observation_state(observation, _contract), do: ProviderObservation.map_state(observation)

  defp attach_checkpoint_suspension(%WorkItem{} = work_item, checkpoint, %State{} = state) do
    existing = checkpoint_suspension_context(checkpoint)

    cond do
      match?(%SuspensionContext{}, existing) ->
        %{work_item | suspension_context: existing}

      Map.has_key?(state.durable_exhausted, work_item.id) ->
        suspend_work_item_with_checkpoint_context(work_item, checkpoint, state, :retry_exhausted)

      match?(%AuthorityDisposition{status: :suspended}, work_item.authority_disposition) ->
        reason = work_item.authority_disposition.reason || work_item.lifecycle_assessment.reason || :unsafe_lifecycle_observation
        suspend_work_item_with_checkpoint_context(work_item, checkpoint, state, reason)

      true ->
        %{work_item | suspension_context: nil}
    end
  end

  defp suspend_work_item_with_checkpoint_context(%WorkItem{} = work_item, checkpoint, state, reason) do
    with %{last_validated_lifecycle_state: last_state} when is_atom(last_state) <- checkpoint,
         {:ok, suspended} <- WorkItem.suspend(work_item, reason),
         {:ok, context} <- checkpoint_suspension_context(work_item, last_state, state, reason) do
      %{suspended | suspension_context: context}
    else
      _invalid_or_missing ->
        work_item
    end
  end

  defp checkpoint_suspension_context(%WorkItem{} = work_item, last_state, state, reason) do
    observation = work_item.provider_observation

    SuspensionContext.new(%{
      work_item_id: work_item.id,
      last_validated_lifecycle_state: last_state,
      provider_observation: observation,
      reason: reason,
      lineage_generation: Map.get(state.attempt_lineages, work_item.id),
      created_at: observation.observed_at,
      recovery_policy: :fresh_reconciliation,
      required_evidence: work_item.lifecycle_assessment.missing_guards,
      resume_target: last_state
    })
  end

  defp maybe_suspend_exhausted_lineage(%State{} = state, issue, checkpoint, %WorkItem{} = work_item) do
    if Map.has_key?(state.durable_exhausted, issue.id) and is_nil(work_item.suspension_context) do
      {state, suspend_work_item_with_checkpoint_context(work_item, checkpoint, state, :retry_exhausted)}
    else
      {state, work_item}
    end
  end

  defp maybe_reconcile_suspension(%State{} = state, %Issue{} = issue, checkpoint, %WorkItem{} = work_item) do
    case work_item.suspension_context do
      %SuspensionContext{status: status} = context when status in [:open, :resolving] and not is_nil(checkpoint) ->
        resolve_durable_suspension(state, issue, checkpoint, context, work_item)

      _no_recovery_context ->
        {state, work_item}
    end
  end

  defp resolve_durable_suspension(state, issue, checkpoint, context, work_item) do
    resolving = begin_suspension_resolution(context)

    first_checkpoint =
      checkpoint_record(
        state,
        issue.id,
        checkpoint.last_validated_lifecycle_state,
        checkpoint.durable_guard_evidence,
        resolving,
        checkpoint.last_terminal_suspension_context
      )

    with {:ok, state, stored_checkpoint} <- persist_recovery_checkpoint(state, first_checkpoint),
         resolving <- resolving_context_with_fresh_target(resolving, work_item),
         next_checkpoint <-
           checkpoint_record(
             state,
             issue.id,
             stored_checkpoint.last_validated_lifecycle_state,
             stored_checkpoint.durable_guard_evidence,
             resolving,
             stored_checkpoint.last_terminal_suspension_context
           ),
         {:ok, state, next_checkpoint} <- persist_recovery_checkpoint(state, next_checkpoint) do
      reconcile_suspension_recovery(state, issue, context, next_checkpoint, resolving, work_item)
    else
      {:error, blocked_state, _reason} ->
        {blocked_state, %{work_item | suspension_context: resolving}}
    end
  end

  defp begin_suspension_resolution(%SuspensionContext{status: :open} = context) do
    case SuspensionContext.begin_resolution(context) do
      {:ok, resolving} -> resolving
      {:error, _reason} -> context
    end
  end

  defp begin_suspension_resolution(%SuspensionContext{} = context), do: context

  defp reconcile_suspension_recovery(state, issue, original_context, checkpoint, resolving, work_item) do
    facts = suspension_recovery_facts(state, issue, original_context, work_item)
    decision = SuspensionRecovery.evaluate(resolving, facts)

    if decision.status == :resolved and
         decision.resume_target == work_item.validated_lifecycle_state and
         LifecycleAssessment.validated?(work_item.lifecycle_assessment) do
      resolve_suspension_checkpoint(state, checkpoint, resolving, work_item, facts)
    else
      {state, %{work_item | suspension_context: resolving}}
    end
  end

  defp resolving_context_with_fresh_target(%SuspensionContext{status: :resolving} = context, %WorkItem{} = work_item) do
    if LifecycleAssessment.validated?(work_item.lifecycle_assessment) and
         WorkflowLifecycle.canonical?(work_item.validated_lifecycle_state) do
      %{context | resume_target: work_item.validated_lifecycle_state}
    else
      context
    end
  end

  defp resolve_suspension_checkpoint(state, _checkpoint, context, work_item, facts) do
    supplied_evidence = work_item.lifecycle_assessment.satisfied_guards

    with {:ok, resolved} <-
           SuspensionContext.resolve(context, %{
             fresh_reconciliation: true,
             resume_target: Map.get(facts, :resume_target),
             required_evidence: supplied_evidence
           }),
         resolved_checkpoint <-
           checkpoint_record(
             state,
             work_item.id,
             work_item.validated_lifecycle_state,
             durable_mechanical_evidence(supplied_evidence),
             nil,
             resolved
           ),
         {:ok, state, resolved_checkpoint} <- persist_recovery_checkpoint(state, resolved_checkpoint) do
      disposition = AuthorityDisposition.derive(work_item.lifecycle_assessment)

      {%{state | recovery_checkpoints: put_checkpoint(state.recovery_checkpoints, work_item.id, resolved_checkpoint)}, %{work_item | authority_disposition: disposition, suspension_context: nil}}
    else
      {:error, blocked_state, _reason} -> {blocked_state, %{work_item | suspension_context: context}}
      {:error, _reason} -> {state, %{work_item | suspension_context: context}}
    end
  end

  defp suspension_recovery_facts(state, issue, context, work_item) do
    dependency = dependency_diagnostic_for_issue(issue, state.dependency_graph, state)
    graph_complete? = match?(%Graph{completeness: :complete}, state.dependency_graph)
    contract_valid? = project_contract_valid?(state.project_contract_evidence)
    observation = work_item.provider_observation
    stable_identity? = stable_provider_identity?(observation)

    facts = %{
      fresh_reconciliation: true,
      resume_target: work_item.validated_lifecycle_state,
      trusted_resume_target?: LifecycleAssessment.validated?(work_item.lifecycle_assessment),
      lifecycle_assessment_validated?: LifecycleAssessment.validated?(work_item.lifecycle_assessment),
      dependency_graph_complete?: graph_complete?,
      dependency_satisfied?: Map.get(dependency, :allowed?, false),
      dependency_cycle?: Map.get(dependency, :reason) == :dependency_cycle,
      contract_revalidated?: contract_valid?,
      stable_provider_ids?: stable_identity?,
      authoritative_observation?: graph_complete? and match?(%ProviderObservation{}, observation),
      evidence_identity_stable?: stable_identity?,
      provider_observation_complete?: graph_complete?,
      provider_observation: observation,
      evidence_identity: observation && observation.snapshot_identity,
      resubmit?: false,
      candidate_evidence_revalidated?: false,
      candidate_identity_stable?: false,
      runtime_available?: false,
      old_runtime_discarded?: map_size(state.running) == 0
    }

    case SuspensionRecovery.classify_reason(context.reason) do
      :retry_exhaustion -> Map.put(facts, :h030_rearm, h030_rearm_proof(state, issue.id, context.lineage_generation))
      :h040_reconciliation -> Map.put(facts, :transition_reconciliation_durable?, transition_reconciliation_durable?(state, issue.id))
      _other -> facts
    end
  end

  defp project_contract_valid?(%ProjectContractEvidence{validation: %{status: :valid}}), do: true
  defp project_contract_valid?(%ProjectContractEvidence{contract: nil}), do: Config.settings!().tracker.kind != "plane"
  defp project_contract_valid?(_evidence), do: false

  defp stable_provider_identity?(%ProviderObservation{} = observation) do
    present_string?(observation.provider_state_id) and present_string?(observation.project_id) and
      (observation.provider not in [:plane, "plane"] or present_string?(observation.workspace_id))
  end

  defp stable_provider_identity?(_observation), do: false

  defp h030_rearm_proof(%State{attempt_ledger: %AttemptLedger{} = ledger} = state, issue_id, old_lineage) do
    current_lineage = Map.get(state.attempt_lineages, issue_id)

    with true <- is_binary(old_lineage) and is_binary(current_lineage) and old_lineage != current_lineage,
         {:ok, history} <- AttemptLedger.history(ledger),
         old when is_map(old) <- Enum.find(history, &(Map.get(&1, :issue_id) == issue_id and Map.get(&1, :lineage_id) == old_lineage)),
         true <- Map.get(old, :status) == :closed and Map.get(old, :closed_reason) == :rearmed,
         rearm_reason when is_binary(rearm_reason) <- Map.get(old, :rearm_reason),
         true <- String.trim(rearm_reason) != "",
         rearmed_by when is_binary(rearmed_by) <- Map.get(old, :rearmed_by),
         true <- String.trim(rearmed_by) != "",
         rearmed_at when is_integer(rearmed_at) and rearmed_at >= 0 <- Map.get(old, :rearmed_at) do
      %{
        explicitly_rearmed?: true,
        old_lineage: old_lineage,
        replacement_lineage: current_lineage,
        rearm_reason: rearm_reason,
        rearmed_by: rearmed_by,
        rearmed_at: rearmed_at,
        old_history_retained?: true
      }
    else
      _missing_proof -> nil
    end
  end

  defp h030_rearm_proof(_state, _issue_id, _old_lineage), do: nil

  defp transition_reconciliation_durable?(%State{} = state, work_item_id) when is_binary(work_item_id) do
    case TransitionCoordinator.reconciliation_marker_for_work_item(state.transition_coordinator, work_item_id) do
      {:ok, %{work_item_id: ^work_item_id}} -> true
      _unreconciled -> false
    end
  end

  defp transition_reconciliation_durable?(_state, _work_item_id), do: false

  defp persist_refreshed_work_item_checkpoint(%State{recovery_ledger_status: :disabled} = state, _previous, work_item),
    do: {:ok, state, checkpoint_from_work_item(state, nil, work_item)}

  defp persist_refreshed_work_item_checkpoint(%State{} = state, previous, %WorkItem{} = work_item) do
    checkpoint = refreshed_checkpoint(state, previous, work_item)

    cond do
      is_nil(checkpoint) ->
        {:ok, state, nil}

      checkpoint_equivalent?(checkpoint, previous) ->
        {:ok, state, previous}

      state.recovery_ledger_status != :ready or not match?(%RecoveryLedger{}, state.recovery_ledger) ->
        {:error, fence_recovery_ledger(state, :missing_recovery_ledger), :missing_recovery_ledger}

      true ->
        persist_recovery_checkpoint(state, checkpoint)
    end
  end

  defp refreshed_checkpoint(%State{} = state, previous, %WorkItem{} = work_item) do
    case work_item.suspension_context do
      %SuspensionContext{status: :escalated} = context ->
        checkpoint_record(state, work_item.id, previous_lifecycle_state(previous), previous_evidence(previous), nil, context)

      %SuspensionContext{status: status} = context when status in [:open, :resolving] ->
        checkpoint_record(
          state,
          work_item.id,
          previous_lifecycle_state(previous),
          previous_evidence(previous),
          context,
          previous_terminal_context(previous)
        )

      _no_active_context ->
        validated_or_previous_checkpoint(state, previous, work_item)
    end
  end

  defp validated_or_previous_checkpoint(state, previous, work_item) do
    if LifecycleAssessment.validated?(work_item.lifecycle_assessment) and
         WorkflowLifecycle.canonical?(work_item.validated_lifecycle_state) do
      checkpoint_record(
        state,
        work_item.id,
        work_item.validated_lifecycle_state,
        durable_mechanical_evidence(work_item.lifecycle_assessment.satisfied_guards),
        nil,
        previous_terminal_context(previous)
      )
    else
      previous_lifecycle_checkpoint(state, previous, work_item)
    end
  end

  defp previous_lifecycle_checkpoint(state, previous, work_item) do
    lifecycle_state = previous_lifecycle_state(previous)

    if WorkflowLifecycle.canonical?(lifecycle_state) do
      checkpoint_record(
        state,
        work_item.id,
        lifecycle_state,
        previous_evidence(previous),
        nil,
        previous_terminal_context(previous)
      )
    else
      nil
    end
  end

  defp previous_lifecycle_state(%{last_validated_lifecycle_state: state}), do: state
  defp previous_lifecycle_state(_previous), do: nil

  defp previous_evidence(%{durable_guard_evidence: evidence}), do: evidence
  defp previous_evidence(_previous), do: []

  defp previous_terminal_context(%{last_terminal_suspension_context: context}), do: context
  defp previous_terminal_context(_previous), do: nil

  defp checkpoint_from_work_item(state, previous, %WorkItem{} = work_item),
    do: refreshed_checkpoint(state, previous, work_item)

  defp checkpoint_record(_state, _work_item_id, nil, _evidence, _active, _terminal), do: nil

  defp checkpoint_record(_state, work_item_id, lifecycle_state, evidence, active_context, terminal_context) do
    %{
      schema_version: RecoveryLedger.schema_version(),
      project_namespace: Config.settings!().symphony.project_id,
      work_item_id: work_item_id,
      last_validated_lifecycle_state: lifecycle_state,
      durable_guard_evidence: evidence,
      active_suspension_context: active_context,
      last_terminal_suspension_context: terminal_context,
      updated_at: DateTime.utc_now()
    }
  end

  defp durable_mechanical_evidence(evidence) when is_list(evidence) do
    evidence
    |> Enum.filter(fn
      %{class: :mechanical_guard} = item -> GuardClass.valid_evidence?(item)
      _other -> false
    end)
    |> Enum.map(&Map.take(&1, [:class, :name, :outcome]))
  end

  defp durable_mechanical_evidence(_evidence), do: []

  defp persist_recovery_checkpoint(%State{recovery_ledger: %RecoveryLedger{} = ledger} = state, checkpoint) do
    existing = Map.get(state.recovery_checkpoints, checkpoint.work_item_id)

    if checkpoint_equivalent?(checkpoint, existing) do
      {:ok, state, existing}
    else
      case RecoveryLedger.put_sync(ledger, checkpoint) do
        :ok ->
          {:ok,
           %{
             state
             | recovery_ledger_status: :ready,
               recovery_checkpoints: put_checkpoint(state.recovery_checkpoints, checkpoint.work_item_id, checkpoint)
           }, checkpoint}

        {:error, reason} ->
          {:error, fence_recovery_ledger(state, reason), reason}
      end
    end
  end

  defp persist_recovery_checkpoint(%State{} = state, _checkpoint),
    do: {:error, fence_recovery_ledger(state, :missing_recovery_ledger), :missing_recovery_ledger}

  defp put_checkpoint(checkpoints, work_item_id, nil), do: Map.delete(checkpoints, work_item_id)
  defp put_checkpoint(checkpoints, work_item_id, checkpoint), do: Map.put(checkpoints, work_item_id, checkpoint)

  defp checkpoint_equivalent?(_checkpoint, nil), do: false

  defp checkpoint_equivalent?(checkpoint, previous) do
    Map.drop(checkpoint, [:updated_at]) == Map.drop(previous, [:updated_at])
  end

  defp persist_authoritative_work_item(%State{} = state, work_item_id, %WorkItem{id: work_item_id} = work_item) do
    cond do
      not LifecycleAssessment.validated?(work_item.lifecycle_assessment) or
          not WorkflowLifecycle.canonical?(work_item.validated_lifecycle_state) ->
        {:error, state, :unvalidated_work_item_lifecycle}

      state.recovery_ledger_status == :disabled ->
        {:ok, state}

      state.recovery_ledger_status != :ready or not match?(%RecoveryLedger{}, state.recovery_ledger) ->
        {:error, fence_recovery_ledger(state, :missing_recovery_ledger), :missing_recovery_ledger}

      true ->
        persist_validated_work_item(state, work_item_id, work_item)
    end
  end

  defp persist_authoritative_work_item(%State{} = state, _work_item_id, _work_item),
    do: {:error, state, :work_item_id_mismatch}

  defp persist_validated_work_item(state, work_item_id, work_item) do
    previous = Map.get(state.recovery_checkpoints, work_item_id)

    if active_checkpoint_suspension?(previous) or active_work_item_suspension?(work_item) do
      {:error, state, :active_suspension_context}
    else
      checkpoint =
        checkpoint_record(
          state,
          work_item_id,
          work_item.validated_lifecycle_state,
          durable_mechanical_evidence(work_item.lifecycle_assessment.satisfied_guards),
          nil,
          previous && previous.last_terminal_suspension_context
        )

      case persist_recovery_checkpoint(state, checkpoint) do
        {:ok, next_state, _checkpoint} -> {:ok, next_state}
        {:error, blocked_state, reason} -> {:error, blocked_state, reason}
      end
    end
  end

  defp active_checkpoint_suspension?(%{active_suspension_context: %SuspensionContext{status: status}})
       when status in [:open, :resolving],
       do: true

  defp active_checkpoint_suspension?(_checkpoint), do: false

  defp active_work_item_suspension?(%WorkItem{suspension_context: %SuspensionContext{status: status}})
       when status in [:open, :resolving, :escalated],
       do: true

  defp active_work_item_suspension?(_work_item), do: false

  defp persist_suspended_work_item(%State{} = state, work_item_id, %WorkItem{} = work_item) do
    checkpoint = Map.get(state.recovery_checkpoints, work_item_id)

    cond do
      state.recovery_ledger_status == :disabled ->
        {:ok, state, work_item}

      is_nil(checkpoint) ->
        {:ok, state, work_item}

      state.recovery_ledger_status != :ready or not match?(%RecoveryLedger{}, state.recovery_ledger) ->
        {:error, fence_recovery_ledger(state, :missing_recovery_ledger), :missing_recovery_ledger}

      true ->
        persist_open_suspension(state, checkpoint, work_item_id, work_item)
    end
  end

  defp persist_open_suspension(state, checkpoint, work_item_id, work_item) do
    context = work_item.suspension_context

    cond do
      not match?(%SuspensionContext{status: :open}, context) ->
        fail_suspended_work_item(state, :missing_active_suspension_context)

      context.work_item_id != work_item_id or
          context.last_validated_lifecycle_state != checkpoint.last_validated_lifecycle_state ->
        fail_suspended_work_item(state, :suspension_checkpoint_mismatch)

      true ->
        checkpoint =
          checkpoint_record(
            state,
            work_item_id,
            checkpoint.last_validated_lifecycle_state,
            checkpoint.durable_guard_evidence,
            context,
            checkpoint.last_terminal_suspension_context
          )

        case persist_recovery_checkpoint(state, checkpoint) do
          {:ok, next_state, _checkpoint} -> {:ok, next_state, work_item}
          {:error, blocked_state, reason} -> {:error, blocked_state, reason}
        end
    end
  end

  defp fail_suspended_work_item(state, reason) do
    {:error, fence_recovery_ledger(state, reason), reason}
  end

  defp fence_recovery_ledger(%State{} = state, reason) do
    blocked_reason = {:recovery_ledger_unavailable, reason}

    %{
      state
      | recovery_ledger_status: {:blocked, blocked_reason},
        startup_reconciliation: {:blocked, blocked_reason}
    }
  end

  defp apply_project_contract_guard(%WorkItem{} = work_item, %State{} = state) do
    evidence = state.project_contract_evidence

    if ProjectContractEvidence.reconciliation_required?(evidence) do
      reason = evidence.reason || :provider_configuration_drift

      case WorkItem.suspend(work_item, reason) do
        {:ok, suspended} -> suspended
        {:error, _reason} -> work_item
      end
    else
      work_item
    end
  end

  defp dependency_diagnostic_for_issue(%Issue{id: issue_id} = issue, %Graph{} = graph, %State{} = state) do
    case route_for_issue(issue, state) do
      {:ok, %Route{responsibility: responsibility}} ->
        issue
        |> dependency_decision(responsibility, state)
        |> maybe_mark_dependency_incomplete(graph, issue_id)
        |> maybe_mark_dependency_cycle(graph, issue_id)

      {:error, reason} ->
        route_diagnostic(issue, reason)
    end
  end

  defp dependency_decision(%Issue{} = issue, responsibility, %State{} = state) do
    Guard.evaluate(issue, responsibility, dependency_policy_options(state))
  end

  defp dependency_decision_for_state(
         %Issue{id: issue_id} = issue,
         %Route{responsibility: responsibility},
         %State{} = state
       )
       when is_binary(issue_id) do
    issue
    |> Guard.evaluate(responsibility, dependency_policy_options(state))
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
    dispatch_candidate_issue?(issue, state, active_states, terminal_states) and
      issue_not_reserved?(state, issue.id) and
      route_dispatchable?(issue, state) and
      dependency_dispatchable?(issue, state) and
      dispatch_resources_available?(state, issue)
  end

  defp should_dispatch_issue?(_issue, _state, _active_states, _terminal_states), do: false

  defp issue_not_reserved?(%State{} = state, issue_id) do
    !MapSet.member?(state.claimed, issue_id) and
      !Map.has_key?(state.running, issue_id) and
      !Map.has_key?(state.blocked, issue_id) and
      !MapSet.member?(state.attempt_ledger_pending_closes, issue_id) and
      !MapSet.member?(state.durable_in_flight, issue_id) and
      !Map.has_key?(state.durable_blocked, issue_id) and
      !Enum.any?(state.transition_reconciliation_candidates, &(Map.get(&1, :work_item_id) == issue_id)) and
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

  defp dispatch_candidate_issue?(%Issue{} = issue, %State{} = state, _active_states, _terminal_states) do
    if Config.settings!().agent.routing == "routed" do
      routed_candidate_issue?(issue, state)
    else
      candidate_issue?(issue, active_state_set(), terminal_state_set())
    end
  end

  defp dispatch_candidate_issue?(_issue, _state, _active_states, _terminal_states), do: false

  defp routed_candidate_issue?(%Issue{} = issue, %State{} = state) do
    candidate_shape?(issue) and
      routed_issue_in_scope?(issue) and
      match?({:ok, %Route{}}, route_for_issue(issue, state))
  end

  defp candidate_shape?(%Issue{id: id, identifier: identifier, title: title, state: state_name}) do
    Enum.all?([id, identifier, title, state_name], &present_string?/1)
  end

  defp candidate_shape?(_issue), do: false

  defp issue_routable?(%Issue{} = issue) do
    Issue.routable?(issue, Config.settings!().tracker.required_labels)
  end

  defp issue_in_routing_scope?(%Issue{} = issue) do
    if Config.settings!().agent.routing == "routed" do
      routed_issue_in_scope?(issue)
    else
      issue_routable?(issue)
    end
  end

  defp routed_issue_in_scope?(%Issue{} = issue) do
    required_labels = Config.settings!().tracker.required_labels
    labels = Issue.label_names(issue)

    Enum.all?(required_labels, fn required_label ->
      Enum.any?(labels, fn label -> normalize_label(label) == normalize_label(required_label) end)
    end)
  end

  defp normalize_label(label) when is_binary(label) do
    label
    |> String.trim()
    |> String.downcase()
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
        case overlay_candidate_dependency_facts(state, refreshed_issue) do
          {:ok, state, final_issue} ->
            dispatch_refreshed_issue(state, final_issue, attempt, preferred_worker_host)

          {:error, reason} ->
            Logger.info("Skipping dispatch; dependency epoch is unavailable for #{issue_context(refreshed_issue)}: #{inspect(reason)}")
            state
        end

      {:skip, _reason} ->
        state

      {:error, _reason} ->
        state
    end
  end

  defp dispatch_refreshed_issue(state, refreshed_issue, attempt, preferred_worker_host) do
    if dispatch_candidate_issue?(refreshed_issue, state, active_state_set(), terminal_state_set()) and
         dispatch_slots_available?(refreshed_issue, state) do
      case route_for_issue(refreshed_issue, state) do
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

  defp overlay_candidate_dependency_facts(%State{dependency_graph: %Graph{} = graph} = state, %Issue{id: issue_id} = issue)
       when is_binary(issue_id) do
    if Config.settings!().agent.routing == "legacy" do
      {:ok, state, issue}
    else
      overlay_routed_candidate_dependency_facts(graph, state, issue, issue_id)
    end
  end

  defp overlay_candidate_dependency_facts(_state, _issue), do: {:error, :graph_unavailable}

  defp overlay_routed_candidate_dependency_facts(graph, state, issue, issue_id) do
    cond do
      not Graph.complete?(graph) ->
        {:error, :graph_incomplete}

      not Map.has_key?(graph.nodes, issue_id) ->
        {:error, :missing_graph_node}

      true ->
        final_issue = overlay_epoch_dependency_facts(graph, issue)
        {:ok, refresh_work_control(state, [final_issue]), final_issue}
    end
  end

  defp graph_failure_reason(:dependency_graph_unsupported), do: :dependency_graph_unsupported
  defp graph_failure_reason(_reason), do: :dependency_graph_unavailable

  defp ensure_graph_contains_active_issues(%State{} = state, active_issues) when is_list(active_issues) do
    if Config.settings!().agent.routing == "legacy",
      do: state,
      else: ensure_graph_contains_issues(state, active_issues)
  end

  defp ensure_graph_contains_running_issues(%State{} = state, running_issues)
       when is_list(running_issues) do
    if Config.settings!().agent.routing == "legacy",
      do: state,
      else: ensure_graph_contains_issues(state, running_issues)
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

  defp mark_graph_incomplete(%State{dependency_graph: %Graph{} = graph} = state, reason) do
    %{state | dependency_graph: %{graph | completeness: {:incomplete, reason}}}
  end

  defp do_dispatch_issue(%State{} = state, issue, route, attempt, preferred_worker_host) do
    if workspace_dispatchable?(state) do
      recipient = self()

      case select_worker_host(state, preferred_worker_host) do
        :no_worker_capacity ->
          Logger.debug("No SSH worker slots available for #{issue_context(issue)} preferred_worker_host=#{inspect(preferred_worker_host)}")
          state

        worker_host ->
          spawn_issue_on_worker_host(state, issue, route, attempt, recipient, worker_host)
      end
    else
      Logger.error("Skipping workspace-backed dispatch because workspace ownership ledger is unavailable for #{issue_context(issue)}")
      state
    end
  end

  defp workspace_dispatchable?(%State{} = state) do
    state.workspace_ownership_ledger_status == :ready and
      match?(%OwnershipLedger{}, state.workspace_ownership_ledger)
  end

  defp spawn_issue_on_worker_host(%State{} = state, issue, route, attempt, recipient, worker_host) do
    case begin_durable_attempt(state, issue, route) do
      {:ok, state, ledger_record} ->
        runtime_attempt = allocate_runtime_attempt(state, issue, route, ledger_record)

        spawn_prepared_issue_on_worker_host(
          state,
          issue,
          route,
          attempt,
          recipient,
          worker_host,
          runtime_attempt
        )

      {:error, state, reason} ->
        Logger.error("Unable to reserve durable attempt for #{issue_context(issue)}: #{inspect(reason)}")

        block_issue_from_entry(
          state,
          issue.id,
          dispatch_entry(issue, route, attempt, worker_host),
          attempt_ledger_error({:attempt_ledger_unavailable, reason})
        )
    end
  end

  defp begin_durable_attempt(%State{attempt_ledger_status: :disabled} = state, _issue, _route),
    do: {:ok, state, nil}

  defp begin_durable_attempt(
         %State{attempt_ledger_status: :ready, attempt_ledger: %AttemptLedger{} = ledger} = state,
         issue,
         route
       ) do
    case AttemptLedger.begin_attempt(ledger, issue.id, route_fingerprint: route.fingerprint) do
      {:ok, record} ->
        {:ok, mark_durable_in_flight(state, issue.id, true), record}

      {:error, :attempt_in_flight} ->
        {:error, state, :attempt_in_flight}

      {:error, :lineage_exhausted} ->
        {:error, state, :lineage_exhausted}

      {:error, reason} ->
        state = block_ledger(state, reason)
        {:error, persist_attempt_failure_fence(state, issue, route), reason}
    end
  end

  defp begin_durable_attempt(%State{attempt_ledger_status: {:blocked, reason}} = state, _issue, _route),
    do: {:error, state, reason}

  defp begin_durable_attempt(%State{} = state, _issue, _route) do
    reason = :invalid_ledger_status
    {:error, block_ledger(state, reason), reason}
  end

  defp allocate_runtime_attempt(%State{attempt_ledger_status: :ready}, issue, route, record)
       when is_map(record) do
    identity = RuntimeAttemptIdentity.allocate(issue.id, route, record.lineage_id)
    RuntimeAttempt.new(identity, :starting)
  end

  defp allocate_runtime_attempt(_state, _issue, _route, _record), do: nil

  defp persist_attempt_failure_fence(%State{attempt_ledger: %AttemptLedger{} = ledger} = state, issue, route) do
    case AttemptLedger.fence_attempt(ledger, issue.id, route_fingerprint: route.fingerprint) do
      {:ok, _record} -> mark_durable_in_flight(state, issue.id, true)
      {:error, reason} -> block_ledger(state, {:attempt_reservation_fence_failed, reason})
    end
  end

  defp persist_attempt_failure_fence(%State{} = state, _issue, _route),
    do: block_ledger(state, :missing_ledger_handle)

  defp dispatch_entry(issue, route, attempt, worker_host) do
    %{
      identifier: issue.identifier,
      issue: issue,
      profile_name: route.profile_name,
      runtime_name: route.runtime_name,
      responsibility: route.responsibility,
      sandbox: route_sandbox(route),
      route_fingerprint: route.fingerprint,
      worker_host: worker_host,
      retry_attempt: attempt
    }
  end

  defp spawn_prepared_issue_on_worker_host(
         %State{} = state,
         issue,
         route,
         attempt,
         recipient,
         worker_host,
         runtime_attempt
       ) do
    work_item = active_work_item_for_attempt(state, issue.id)
    runtime_attempt_identity = runtime_attempt_identity_from(runtime_attempt)

    case Task.Supervisor.start_child(state.task_supervisor, fn ->
           state.agent_runner.run(issue, recipient,
             attempt: attempt,
             worker_host: worker_host,
             route: route,
             work_item: work_item,
             work_control: state.work_control,
             dependency_decision: Map.get(state.dependency_diagnostics, issue.id),
             ownership_ledger: state.workspace_ownership_ledger,
             runtime_attempt_identity: runtime_attempt_identity
           )
         end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        state = put_active_work_item(state, issue.id, work_item)

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
            lifecycle_suspension: nil,
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
            runtime_attempt: runtime_attempt,
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

  defp runtime_attempt_identity_from(%RuntimeAttempt{identity: identity}), do: identity
  defp runtime_attempt_identity_from(_runtime_attempt), do: nil

  defp apply_runtime_attempt_session_started(state, running, validated_issue_id, running_entry) do
    with %RuntimeAttempt{state: :starting} = attempt <- Map.get(running_entry, :runtime_attempt),
         {:ok, running_attempt} <- RuntimeAttempt.mark_running(attempt) do
      updated_running_entry = Map.put(running_entry, :runtime_attempt, running_attempt)

      notify_dashboard()
      {:noreply, %{state | running: Map.put(running, validated_issue_id, updated_running_entry)}}
    else
      _ -> {:noreply, state}
    end
  end

  defp schedule_agent_route_change_retry(state, issue_id, running_entry, route_change) do
    case clear_attempt_in_flight(state, issue_id) do
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

      {:error, state, reason} ->
        block_issue_from_entry(state, issue_id, running_entry, attempt_ledger_error(reason))
    end
  end

  defp apply_poll_route_change_terminal_retry(state, issue, running_entry, next_attempt, route_change) do
    case transition_running_entry_attempt(running_entry, :retry_queued) do
      {:ok, running_entry} ->
        stop_running_task(Map.get(running_entry, :pid), Map.get(running_entry, :ref), state.task_supervisor)

        state = Map.update!(state, :running, &Map.delete(&1, issue.id))
        schedule_poll_route_change_retry(state, issue, running_entry, next_attempt, route_change)

      {:error, :invalid_runtime_attempt_transition} ->
        state
    end
  end

  defp schedule_poll_route_change_retry(state, issue, running_entry, next_attempt, route_change) do
    case clear_attempt_in_flight(state, issue.id) do
      {:ok, state} ->
        state
        |> record_recent_attempt(issue.id, %{running_entry | issue: issue}, :route_changed)
        |> schedule_issue_retry(
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

      {:error, state, reason} ->
        block_issue_from_entry(state, issue.id, %{running_entry | issue: issue}, attempt_ledger_error(reason))
    end
  end

  defp schedule_stall_retry_after_terminal_removal(
         state,
         issue_id,
         running_entry,
         next_attempt,
         retry_metadata
       ) do
    case finalize_running_attempt_removal(state, issue_id, false, :runtime_stalled) do
      {:ok, state} ->
        case clear_attempt_in_flight(state, issue_id) do
          {:ok, state} ->
            schedule_issue_retry(state, issue_id, next_attempt, retry_metadata)

          {:error, state, reason} ->
            block_issue_from_entry(state, issue_id, running_entry, attempt_ledger_error(reason))
        end

      {:error, state} ->
        state
    end
  end

  defp transition_running_entry_attempt(running_entry, to_state)
       when is_map(running_entry) and is_atom(to_state) do
    case Map.get(running_entry, :runtime_attempt) do
      %RuntimeAttempt{} = attempt ->
        case RuntimeAttempt.transition(attempt, to_state) do
          {:ok, updated} -> {:ok, Map.put(running_entry, :runtime_attempt, updated)}
          {:error, :invalid_transition} -> {:error, :invalid_runtime_attempt_transition}
        end

      _ ->
        {:ok, running_entry}
    end
  end

  defp active_work_item_for_attempt(%State{} = state, issue_id) when is_binary(issue_id) do
    case Map.get(state.work_control, issue_id) do
      %WorkItem{authority_disposition: disposition} = work_item ->
        case AuthorityDisposition.transition(disposition, :active, %{attempt_started: true}) do
          {:ok, active_disposition} -> %{work_item | authority_disposition: active_disposition}
          {:error, :attempt_not_started} -> work_item
          {:error, :invalid_disposition_transition} -> work_item
          {:error, _reason} -> work_item
        end

      _missing_work_item ->
        nil
    end
  end

  defp active_work_item_for_attempt(_state, _issue_id), do: nil

  defp put_active_work_item(%State{} = state, issue_id, %WorkItem{} = work_item)
       when is_binary(issue_id) do
    %{state | work_control: Map.put(state.work_control, issue_id, work_item)}
  end

  defp put_active_work_item(state, _issue_id, _work_item), do: state

  defp revalidate_issue_for_dispatch(%Issue{id: issue_id}, issue_fetcher, terminal_states)
       when is_binary(issue_id) and is_function(issue_fetcher, 1) do
    case issue_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        revalidate_refreshed_issue(refreshed_issue, terminal_states)

      {:ok, []} ->
        {:skip, :missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp revalidate_issue_for_dispatch(issue, _issue_fetcher, _terminal_states), do: {:ok, issue}

  defp revalidate_refreshed_issue(%Issue{} = issue, terminal_states) do
    if Config.settings!().agent.routing == "routed" do
      revalidate_routed_issue(issue, terminal_states)
    else
      revalidate_legacy_issue(issue, terminal_states)
    end
  end

  defp revalidate_routed_issue(%Issue{} = issue, terminal_states) do
    if terminal_issue_state?(issue.state, terminal_states) do
      {:skip, issue}
    else
      {:ok, issue}
    end
  end

  defp revalidate_legacy_issue(%Issue{} = issue, terminal_states) do
    if retry_candidate_issue?(issue, terminal_states) do
      {:ok, issue}
    else
      {:skip, issue}
    end
  end

  @doc false
  @spec record_attempt_event_for_test(State.t(), String.t(), atom()) :: term()
  def record_attempt_event_for_test(%State{} = state, issue_id, event) do
    record_attempt_event(state, issue_id, event)
  end

  defp record_attempt_event(%State{} = state, issue_id, event),
    do: record_attempt_event(state, issue_id, event, [])

  defp record_attempt_event(%State{} = state, issue_id, event, opts)
       when is_binary(issue_id) and is_atom(event) do
    counters =
      state.attempt_counters
      |> Map.get(issue_id, AttemptPolicy.new())
      |> then(&Map.merge(AttemptPolicy.new(), &1))

    case AttemptPolicy.record(counters, event) do
      {:ok, counters} ->
        persist_attempt_event(state, issue_id, event, counters, :open, nil, opts)

      {:stop, counters, reason} ->
        persist_attempt_event(state, issue_id, event, counters, :exhausted, reason, opts)
    end
  end

  defp persist_attempt_event(%State{} = state, issue_id, event, counters, status, stop_reason, opts) do
    if event in @durable_attempt_events do
      persist_durable_attempt_event(state, issue_id, counters, status, stop_reason, opts)
    else
      apply_attempt_event_result(state, issue_id, counters, status, stop_reason, opts)
    end
  end

  defp persist_durable_attempt_event(%State{} = state, issue_id, counters, status, stop_reason, opts) do
    case state.attempt_ledger_status do
      :disabled ->
        apply_attempt_event_result(state, issue_id, counters, status, stop_reason, opts)

      :ready ->
        persist_ready_attempt_event(state, issue_id, counters, status, stop_reason, opts)

      {:blocked, reason} ->
        {:error, state, {:attempt_ledger_unavailable, reason}}

      _ ->
        reason = :invalid_ledger_status
        {:error, block_ledger(state, reason), {:attempt_ledger_unavailable, reason}}
    end
  end

  defp persist_ready_attempt_event(
         %State{attempt_ledger: %AttemptLedger{} = ledger} = state,
         issue_id,
         counters,
         status,
         stop_reason,
         opts
       ) do
    persist_opts =
      Keyword.put(opts, :in_flight, Keyword.get(opts, :in_flight, false) and status != :exhausted)

    case AttemptLedger.persist_safety(ledger, issue_id, counters,
           status: status,
           stop_reason: stop_reason,
           in_flight: Keyword.get(persist_opts, :in_flight),
           route_fingerprint: route_fingerprint_for_issue(state, issue_id)
         ) do
      {:ok, _record} ->
        apply_attempt_event_result(state, issue_id, counters, status, stop_reason, persist_opts)

      {:error, reason} ->
        {:error, block_ledger(state, reason), {:attempt_ledger_unavailable, reason}}
    end
  end

  defp persist_ready_attempt_event(%State{} = state, _issue_id, _counters, _status, _stop_reason, _opts) do
    reason = :missing_ledger_handle

    {:error, block_ledger(state, reason), {:attempt_ledger_unavailable, reason}}
  end

  defp clear_attempt_in_flight(%State{attempt_ledger_status: :disabled} = state, issue_id) do
    {:ok, clear_durable_in_flight(state, issue_id)}
  end

  defp clear_attempt_in_flight(
         %State{attempt_ledger_status: :ready, attempt_ledger: %AttemptLedger{} = ledger} = state,
         issue_id
       ) do
    case AttemptLedger.clear_in_flight(ledger, issue_id) do
      :ok -> {:ok, clear_durable_in_flight(state, issue_id)}
      {:error, reason} -> {:error, block_ledger(state, reason), {:attempt_ledger_unavailable, reason}}
    end
  end

  defp clear_attempt_in_flight(%State{attempt_ledger_status: {:blocked, reason}} = state, _issue_id),
    do: {:error, state, {:attempt_ledger_unavailable, reason}}

  defp clear_attempt_in_flight(%State{} = state, _issue_id) do
    reason = :invalid_ledger_status
    {:error, block_ledger(state, reason), {:attempt_ledger_unavailable, reason}}
  end

  defp apply_attempt_event_result(%State{} = state, issue_id, counters, :open, _stop_reason, opts) do
    state = maybe_clear_durable_in_flight(state, issue_id, opts)

    {:ok,
     %{
       state
       | attempt_counters: Map.put(state.attempt_counters, issue_id, counters),
         durable_exhausted: Map.delete(Map.get(state, :durable_exhausted, %{}), issue_id)
     }}
  end

  defp apply_attempt_event_result(%State{} = state, issue_id, counters, :exhausted, stop_reason, opts) do
    state =
      state
      |> maybe_clear_durable_in_flight(issue_id, opts)
      |> then(&%{&1 | attempt_counters: Map.put(&1.attempt_counters, issue_id, counters)})

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

  defp maybe_clear_durable_in_flight(%State{} = state, issue_id, opts) do
    if Keyword.get(opts, :in_flight, false) do
      state
    else
      clear_durable_in_flight(state, issue_id)
    end
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

  defp record_route_change_events(state, issue_id, route_change),
    do: record_route_change_events(state, issue_id, route_change, [])

  defp record_route_change_events(state, issue_id, route_change, opts) do
    case record_attempt_event(state, issue_id, :route_change, opts) do
      {:ok, state} -> record_review_cycle_event(state, issue_id, route_change, opts)
      {:stop, _state, _reason} = result -> result
      {:error, _state, _reason} = result -> result
    end
  end

  defp record_review_cycle_event(state, issue_id, route_change),
    do: record_review_cycle_event(state, issue_id, route_change, [])

  defp record_review_cycle_event(state, _issue_id, route_change, _opts)
       when not is_map(route_change),
       do: {:ok, state}

  defp record_review_cycle_event(state, issue_id, route_change, opts) do
    if reviewer_to_correction?(route_change) do
      record_attempt_event(state, issue_id, :review_cycle, opts)
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

  defp reschedule_pending_retries(%State{} = state) do
    retry_attempts =
      Enum.into(state.retry_attempts, %{}, fn {issue_id, retry} ->
        if is_reference(Map.get(retry, :timer_ref)) do
          Process.cancel_timer(retry.timer_ref)
        end

        retry_token = make_ref()
        timer_ref = Process.send_after(self(), {:retry_issue, issue_id, retry_token}, 0)

        {issue_id,
         retry
         |> Map.put(:retry_token, retry_token)
         |> Map.put(:timer_ref, timer_ref)
         |> Map.put(:due_at_ms, System.monotonic_time(:millisecond))}
      end)

    %{state | retry_attempts: retry_attempts}
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
        Logger.info("Issue state is terminal: issue_id=#{issue_id} issue_identifier=#{issue.identifier} state=#{issue.state}; preserving workspace during retry teardown")

        state =
          state
          |> refresh_work_control([issue])
          |> record_recent_attempt(
            issue_id,
            Map.merge(metadata, %{issue: issue, identifier: issue.identifier, attempt: attempt}),
            :terminal
          )
          |> release_issue_claim(issue_id)
          |> reset_attempt_counters(issue_id)

        {:noreply, state}

      Config.settings!().agent.routing == "routed" ->
        handle_routed_retry_issue_lookup(issue, state, issue_id, attempt, metadata)

      retry_candidate_issue?(issue, terminal_states) ->
        handle_active_retry(state, issue, attempt, metadata)

      true ->
        Logger.debug("Issue left active states, removing claim issue_id=#{issue_id} issue_identifier=#{issue.identifier}")

        {:noreply, release_issue_claim(state, issue_id)}
    end
  end

  defp handle_retry_issue_lookup(nil, state, issue_id, _attempt, _metadata) do
    Logger.debug("Issue no longer visible, removing claim issue_id=#{issue_id}")

    {:noreply,
     state
     |> release_issue_claim(issue_id)
     |> forget_work_item(issue_id)}
  end

  defp handle_routed_retry_issue_lookup(%Issue{} = issue, state, issue_id, attempt, metadata) do
    trusted_work_item = Map.get(state.work_control, issue_id)
    state = refresh_work_control(state, [issue])

    cond do
      not routed_issue_in_scope?(issue) ->
        Logger.debug("Issue is no longer routed, removing claim issue_id=#{issue_id}")
        {:noreply, release_issue_claim(state, issue_id)}

      not trusted_retry_work_item?(trusted_work_item) ->
        dispatch_active_retry(state, issue, attempt, metadata)

      true ->
        handle_trusted_routed_retry(state, issue, attempt, metadata)
    end
  end

  defp handle_trusted_routed_retry(state, issue, attempt, metadata) do
    case route_for_issue(issue, state) do
      {:ok, %Route{}} -> handle_active_retry(state, issue, attempt, metadata)
      {:error, reason} -> retry_after_route_error(state, issue, attempt, metadata, reason)
    end
  end

  defp cleanup_issue_workspace(%State{} = state, %Issue{} = issue, worker_host) do
    cond do
      not terminal_cleanup_authorized?(state, issue) ->
        Logger.info("Preserving workspace for #{issue_context(issue)} because terminal cleanup is not authorized")
        :ok

      not workspace_dispatchable?(state) ->
        Logger.error("Skipping terminal workspace cleanup for #{issue_context(issue)} because workspace ownership ledger is unavailable")
        {:error, :workspace_ownership_ledger_unavailable}

      true ->
        case Workspace.remove_issue_workspaces(
               issue,
               worker_host,
               state.workspace_ownership_ledger,
               cleanup_authorized: true
             ) do
          :ok ->
            :ok

          {:error, :workspace_ownership_not_found} ->
            Logger.info("Preserving unowned workspace for #{issue_context(issue)} because no trusted ownership record exists")

            :ok

          {:error, reason} ->
            Logger.error("Terminal workspace cleanup failed for #{issue_context(issue)}: #{inspect(reason)}")
            {:error, reason}
        end
    end
  end

  defp terminal_cleanup_authorized?(%State{} = state, %Issue{} = issue) do
    state.startup_reconciliation == :ready and
      terminal_policy_current?(state, issue) and
      not transition_candidate_pending?(state, issue.id) and
      not terminal_workspace_suspension?(state, issue.id)
  end

  defp terminal_policy_current?(%State{} = state, %Issue{} = issue) do
    if Config.settings!().agent.routing == "routed" do
      case Map.get(state.work_control, issue.id) do
        %WorkItem{
          lifecycle_assessment: %LifecycleAssessment{} = assessment,
          validated_lifecycle_state: lifecycle_state
        } ->
          terminal_issue_state?(issue.state, terminal_state_set()) and
            WorkflowLifecycle.terminal?(lifecycle_state) and
            lifecycle_state == terminal_lifecycle_state(assessment) and
            (LifecycleAssessment.validated?(assessment) or
               LifecycleAssessment.authority_reducing?(assessment))

        _missing_or_invalid_work_item ->
          false
      end
    else
      terminal_issue_state?(issue.state, terminal_state_set())
    end
  end

  defp terminal_lifecycle_state(%LifecycleAssessment{validated_state: state}), do: state

  defp terminal_workspace_suspension?(%State{} = state, issue_id) when is_binary(issue_id) do
    work_item = Map.get(state.work_control, issue_id)
    checkpoint = Map.get(state.recovery_checkpoints, issue_id)

    active_context? = fn
      %SuspensionContext{status: status} when status in [:open, :resolving, :escalated] -> true
      _context -> false
    end

    checkpoint_contexts =
      [
        Map.get(checkpoint || %{}, :active_suspension_context),
        Map.get(checkpoint || %{}, :last_terminal_suspension_context)
      ]

    active_context?.(Map.get(work_item || %{}, :suspension_context)) or
      Enum.any?(checkpoint_contexts, active_context?) or
      terminal_authority_suspension?(work_item)
  end

  defp terminal_workspace_suspension?(_state, _issue_id), do: false

  defp terminal_authority_suspension?(%WorkItem{
         authority_disposition: %AuthorityDisposition{status: :escalated}
       }),
       do: true

  defp terminal_authority_suspension?(%WorkItem{
         authority_disposition: %AuthorityDisposition{status: :suspended, lifecycle_state: :canceled},
         suspension_context: nil
       }),
       do: false

  defp terminal_authority_suspension?(%WorkItem{
         authority_disposition: %AuthorityDisposition{status: status}
       })
       when status in [:suspended, :escalated],
       do: true

  defp terminal_authority_suspension?(_work_item), do: false

  defp run_terminal_workspace_cleanup(%State{} = state, issues) when is_list(issues) do
    errors =
      Enum.reduce(issues, [], fn
        %Issue{} = issue, errors ->
          case cleanup_issue_workspace(state, issue, nil) do
            {:error, reason} -> [{issue.id, reason} | errors]
            _ok -> errors
          end

        _invalid_issue, errors ->
          errors
      end)

    case errors do
      [] -> :ok
      errors -> {:error, Enum.reverse(errors)}
    end
  end

  defp run_terminal_workspace_cleanup(%State{} = state) do
    case Tracker.fetch_issues_by_states(Config.settings!().tracker.terminal_states) do
      {:ok, issues} ->
        run_terminal_workspace_cleanup(state, issues)

      {:error, reason} ->
        Logger.warning("Skipping startup terminal workspace cleanup; failed to fetch terminal issues: #{inspect(reason)}")
        {:error, {:terminal_issue_fetch_failed, reason}}
    end
  end

  defp reconcile_pending_workspace_releases(%State{} = state) do
    if workspace_dispatchable?(state) do
      case OwnershipLedger.list(state.workspace_ownership_ledger) do
        {:ok, records} ->
          reconcile_pending_workspace_records(state, records)

        {:error, reason} ->
          Logger.error("Unable to validate pending workspace releases: #{inspect(reason)}")

          %{
            state
            | workspace_ownership_ledger_status: {:blocked, {:workspace_ownership_ledger_unavailable, reason}},
              startup_reconciliation: {:blocked, {:workspace_pending_reconciliation_unavailable, reason}}
          }
      end
    else
      state
    end
  end

  defp reconcile_pending_workspace_records(%State{} = state, records) when is_list(records) do
    pending_records = Enum.filter(records, &(Map.get(&1, :state) == :release_pending))

    reconcile_pending_workspace_record_list(state, pending_records)
  end

  defp reconcile_pending_workspace_record_list(%State{} = state, []), do: state

  defp reconcile_pending_workspace_record_list(%State{} = state, records) do
    issue_ids = Enum.map(records, &Map.get(&1, :work_item_id)) |> Enum.filter(&is_binary/1)

    case Tracker.fetch_issues_by_ids(issue_ids) do
      {:ok, issues} ->
        reconcile_pending_workspace_records_with_issues(state, records, issues)

      {:error, reason} ->
        Logger.error("Unable to fetch tracker state for pending workspace releases: #{inspect(reason)}")
        %{state | startup_reconciliation: {:blocked, {:workspace_pending_reconciliation_unavailable, reason}}}
    end
  end

  defp reconcile_pending_workspace_records_with_issues(%State{} = state, records, issues) do
    issues_by_id = Map.new(issues, fn issue -> {issue.id, issue} end)

    Enum.reduce(records, state, fn record, state_acc ->
      reconcile_pending_workspace_record_for_issue(state_acc, record, issues_by_id)
    end)
  end

  defp reconcile_pending_workspace_record_for_issue(%State{} = state, record, issues_by_id) do
    case Map.get(issues_by_id, Map.get(record, :work_item_id)) do
      %Issue{} = issue ->
        reconcile_pending_workspace_record(state, record, issue)

      _missing_issue ->
        Logger.warning(
          "Keeping pending workspace release because tracker identity is unavailable: " <>
            "work_item_id=#{inspect(Map.get(record, :work_item_id))}"
        )

        state
    end
  end

  defp reconcile_pending_workspace_record(%State{} = state, record, %Issue{} = issue) do
    cond do
      Map.get(record, :release_origin) == :failed_provisioning ->
        reconcile_failed_provisioning_workspace_record(state, record, issue)

      terminal_cleanup_authorized?(state, issue) ->
        reconcile_authorized_pending_workspace_record(state, record, issue)

      pending_workspace_release_preserved?(state, issue) ->
        preserve_pending_workspace_record(state, issue)

      pending_workspace_identity_matches?(state, record, issue) ->
        cancel_stale_pending_workspace_record(state, record, issue)

      true ->
        preserve_ambiguous_pending_workspace_record(state, issue)
    end
  end

  defp reconcile_failed_provisioning_workspace_record(
         %State{workspace_ownership_ledger: %OwnershipLedger{} = ledger} = state,
         record,
         %Issue{} = issue
       ) do
    authorization = %{
      workspace_ownership_id: Map.get(record, :workspace_ownership_id),
      canonical_workspace_path: Map.get(record, :canonical_workspace_path),
      worker_host: Map.get(record, :worker_host)
    }

    case Workspace.remove_recorded(
           record.canonical_workspace_path,
           record.worker_host,
           ledger,
           cleanup_authorized: true,
           cleanup_authorization: authorization
         ) do
      {:ok, _removed} ->
        state

      {:error, reason, _output} ->
        Logger.error("Failed provisioning workspace cleanup remains pending for #{issue_context(issue)}: #{inspect(reason)}")
        %{state | startup_reconciliation: :pending, startup_cleanup_ran?: false}
    end
  end

  defp reconcile_failed_provisioning_workspace_record(%State{} = state, _record, _issue), do: state

  defp reconcile_authorized_pending_workspace_record(%State{} = state, record, %Issue{} = issue) do
    case cleanup_issue_workspace(state, issue, Map.get(record, :worker_host)) do
      :ok ->
        state

      {:error, reason} ->
        Logger.error("Pending terminal workspace cleanup remains unresolved for #{issue_context(issue)}: #{inspect(reason)}")
        %{state | startup_reconciliation: :pending, startup_cleanup_ran?: false}
    end
  end

  defp pending_workspace_release_preserved?(%State{} = state, %Issue{} = issue) do
    terminal_issue_state?(issue.state, terminal_state_set()) or
      terminal_workspace_suspension?(state, issue.id) or
      transition_candidate_pending?(state, issue.id)
  end

  defp preserve_pending_workspace_record(%State{} = state, %Issue{} = issue) do
    Logger.info("Keeping pending workspace release for #{issue_context(issue)} until preservation checks clear")
    state
  end

  defp cancel_stale_pending_workspace_record(%State{} = state, record, %Issue{} = issue) do
    case cancel_pending_workspace_release(state, record) do
      :ok ->
        Logger.info("Cancelled stale pending workspace release for #{issue_context(issue)}")
        state

      {:error, reason} ->
        Logger.error("Unable to cancel pending workspace release for #{issue_context(issue)}: #{inspect(reason)}")
        state
    end
  end

  defp preserve_ambiguous_pending_workspace_record(%State{} = state, %Issue{} = issue) do
    Logger.warning("Keeping ambiguous pending workspace release for #{issue_context(issue)}")
    state
  end

  defp pending_workspace_identity_matches?(
         %State{workspace_ownership_ledger: %OwnershipLedger{} = ledger},
         record,
         %Issue{id: issue_id, identifier: identifier}
       )
       when is_binary(issue_id) and is_binary(identifier) do
    Map.get(record, :work_item_id) == issue_id and
      Map.get(record, :issue_identifier) == identifier and
      Map.get(record, :workspace_key) == Workspace.workspace_key(identifier) and
      pending_workspace_record_provable?(record, ledger)
  end

  defp pending_workspace_identity_matches?(_state, _record, _issue), do: false

  defp pending_workspace_record_provable?(%{location: :remote}, _ledger), do: true

  defp pending_workspace_record_provable?(record, ledger),
    do: pending_workspace_record_current?(record, ledger)

  defp cancel_pending_workspace_release(
         %State{workspace_ownership_ledger: %OwnershipLedger{} = ledger},
         %{location: :remote} = record
       ) do
    Workspace.cancel_pending_release_if_current(record, ledger)
  end

  defp cancel_pending_workspace_release(
         %State{workspace_ownership_ledger: %OwnershipLedger{} = ledger},
         record
       ) do
    case pending_workspace_record_current?(record, ledger) do
      true ->
        case OwnershipLedger.transition_sync(
               ledger,
               Map.get(record, :workspace_ownership_id),
               :owned
             ) do
          {:ok, _owned} -> :ok
          {:error, reason} -> {:error, reason}
        end

      false ->
        {:error, :workspace_identity_unavailable}
    end
  end

  defp cancel_pending_workspace_release(_state, _record),
    do: {:error, :workspace_ownership_ledger_unavailable}

  defp pending_workspace_record_current?(
         %{
           state: :release_pending,
           location: :local,
           worker_host: nil,
           trusted_host_identity: trusted_host_identity,
           configured_root: configured_root,
           configured_root_identity: configured_root_identity,
           canonical_root: canonical_root,
           canonical_workspace_path: canonical_workspace_path,
           top_level_filesystem_identity: workspace_identity
         },
         %OwnershipLedger{host_identity: host_identity}
       ) do
    with true <- trusted_host_identity == host_identity,
         true <- Path.expand(Config.local_workspace_root()) == configured_root,
         {:ok, current_root} <- PathSafety.canonicalize(Config.local_workspace_root()),
         true <- current_root == canonical_root,
         {:ok, ^configured_root_identity} <- OwnershipLedger.root_identity(canonical_root),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(canonical_workspace_path),
         {:ok, ^workspace_identity} <- OwnershipLedger.filesystem_identity(canonical_workspace_path) do
      true
    else
      _ -> false
    end
  end

  defp pending_workspace_record_current?(_record, _ledger), do: false

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
    retry_candidate_for_state?(issue, state, terminal_state_set()) and
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
    case overlay_candidate_dependency_facts(state, refreshed_issue) do
      {:ok, state, refreshed_issue} ->
        cond do
          not retry_candidate_for_state?(refreshed_issue, state, terminal_state_set()) ->
            handle_non_candidate_retry(state, issue, refreshed_issue, attempt, metadata)

          not retry_available_for_dispatch?(refreshed_issue, state, metadata) ->
            schedule_retry_without_slots(state, refreshed_issue, attempt, metadata)

          true ->
            dispatch_final_retry(state, issue, refreshed_issue, attempt, metadata)
        end

      {:error, reason} ->
        Logger.info("Deferring retry; dependency epoch is unavailable for #{issue_context(refreshed_issue)}: #{inspect(reason)}")
        {:noreply, release_issue_claim(state, issue.id)}
    end
  end

  defp handle_non_candidate_retry(state, issue, refreshed_issue, attempt, metadata) do
    if Config.settings!().agent.routing == "routed" and routed_issue_in_scope?(refreshed_issue) do
      handle_routed_non_candidate_retry(state, issue, refreshed_issue, attempt, metadata)
    else
      handle_retry_issue_lookup(refreshed_issue, state, issue.id, attempt, metadata)
    end
  end

  defp handle_routed_non_candidate_retry(state, issue, refreshed_issue, attempt, metadata) do
    case route_for_issue(refreshed_issue, state) do
      {:error, reason} -> retry_after_route_error(state, refreshed_issue, attempt, metadata, reason)
      {:ok, %Route{}} -> handle_retry_issue_lookup(refreshed_issue, state, issue.id, attempt, metadata)
    end
  end

  defp dispatch_final_retry(state, issue, refreshed_issue, attempt, metadata) do
    case route_for_issue(refreshed_issue, state) do
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
    if Config.settings!().agent.routing == "routed" and routed_lifecycle_error?(reason) do
      error = "routed lifecycle authority suspended: #{inspect(reason)}"

      blocked_entry =
        Map.merge(metadata, %{
          issue: issue,
          identifier: issue.identifier,
          issue_url: issue.url,
          retry_attempt: attempt
        })

      {:noreply, block_issue_from_entry(state, issue.id, blocked_entry, error)}
    else
      retry_after_failure(
        state,
        issue,
        attempt,
        metadata,
        "retry route resolution failed: #{inspect(reason)}"
      )
    end
  end

  defp routed_lifecycle_error?(:canonical_work_item_required), do: true
  defp routed_lifecycle_error?(:lifecycle_validation_required), do: true
  defp routed_lifecycle_error?(:authority_unavailable), do: true
  defp routed_lifecycle_error?(:invalid_work_item), do: true
  defp routed_lifecycle_error?(:missing_validated_lifecycle_state), do: true
  defp routed_lifecycle_error?({:authority_reducing, _reason}), do: true
  defp routed_lifecycle_error?({:invalid_lifecycle, _reason}), do: true
  defp routed_lifecycle_error?({:not_dispatchable_state, _state}), do: true
  defp routed_lifecycle_error?(_reason), do: false

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
    case AttemptLedger.current(ledger, issue_id) do
      {:ok, %{status: :exhausted} = record} ->
        preserve_exhausted_lineage(state, issue_id, record)

      {:error, reason} ->
        block_ledger(state, reason)

      _open_or_closed ->
        case AttemptLedger.close_lineage(ledger, issue_id, reason: :terminal) do
          :ok ->
            reset_durable_lineage(state, issue_id)

          {:error, reason} ->
            state
            |> mark_pending_lineage_close(issue_id)
            |> block_ledger(reason)
        end
    end
  end

  defp reset_ready_attempt_counters(%State{} = state, _issue_id),
    do: block_ledger(state, :missing_ledger_handle)

  defp preserve_exhausted_lineage(%State{} = state, issue_id, record) do
    counters = Map.merge(AttemptPolicy.new(), Map.get(record, :safety_counters, %{}))

    %{
      state
      | attempt_counters: Map.put(state.attempt_counters, issue_id, counters),
        attempt_lineages: Map.put(state.attempt_lineages, issue_id, record.lineage_id),
        durable_exhausted: Map.put(state.durable_exhausted, issue_id, record),
        attempt_ledger_pending_closes: MapSet.delete(state.attempt_ledger_pending_closes, issue_id),
        durable_in_flight: MapSet.delete(state.durable_in_flight, issue_id)
    }
  end

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

  defp validate_current_runtime_event(
         %State{running: running},
         issue_id,
         %RuntimeAttemptIdentity{} = identity,
         opts
       )
       when is_binary(issue_id) and is_list(opts) do
    require_running = Keyword.get(opts, :require_running, false)

    with true <- issue_id == identity.work_item_id,
         {:ok, entry} <- current_running_entry(running, issue_id),
         %RuntimeAttempt{identity: current, state: attempt_state} <- Map.get(entry, :runtime_attempt),
         true <- RuntimeAttemptIdentity.same?(identity, current),
         true <- not require_running or attempt_state == :running do
      {:ok, issue_id, entry}
    else
      _failure -> :stale
    end
  end

  defp current_running_entry(running, work_item_id) when is_map(running) and is_binary(work_item_id) do
    case Map.get(running, work_item_id) do
      entry when is_map(entry) -> {:ok, entry}
      _missing -> :stale
    end
  end

  defp current_runtime_attempt_identity(%State{running: running}, work_item_id) do
    case Map.get(running, work_item_id) do
      %{runtime_attempt: %RuntimeAttempt{identity: identity}} -> identity
      _ -> nil
    end
  end

  defp transition_context_runtime_attempt_id(running) do
    case Map.get(running, :runtime_attempt) do
      %RuntimeAttempt{identity: %{runtime_attempt_id: id}} -> id
      _ -> nil
    end
  end

  defp transition_context_lineage_generation(running) do
    case Map.get(running, :runtime_attempt) do
      %RuntimeAttempt{identity: %{lineage_generation: generation}} -> generation
      _ -> nil
    end
  end

  defp transition_context_lineage_id(running) do
    transition_context_lineage_generation(running)
  end

  defp validate_expected_runtime_identity(context, opts) when is_map(context) do
    case Keyword.get(opts, :expected_runtime_identity) do
      nil ->
        :ok

      %RuntimeAttemptIdentity{} = expected ->
        if runtime_identity_matches_context?(expected, context), do: :ok, else: {:error, :stale_runtime_attempt}

      expected when is_map(expected) ->
        if runtime_identity_map_matches_context?(expected, context),
          do: :ok,
          else: {:error, :stale_runtime_attempt}

      _invalid ->
        {:error, :stale_runtime_attempt}
    end
  end

  defp runtime_identity_matches_context?(%RuntimeAttemptIdentity{} = identity, context) do
    runtime_identity_map_matches_context?(
      %{
        runtime_attempt_id: identity.runtime_attempt_id,
        lineage_generation: identity.lineage_generation,
        work_item_id: identity.work_item_id,
        responsibility: identity.responsibility,
        runtime_profile: identity.runtime_profile
      },
      context
    )
  end

  defp runtime_identity_map_matches_context?(expected, context) do
    context_identity = %{
      runtime_attempt_id: Map.get(context, :runtime_attempt_id),
      lineage_generation: Map.get(context, :lineage_generation),
      work_item_id: get_in(context, [:work_item, Access.key(:id)]),
      responsibility: Map.get(context, :responsibility),
      runtime_profile: Map.get(context, :runtime_profile)
    }

    Enum.all?(Map.keys(expected), fn key ->
      normalize_identity_field(key, Map.get(expected, key)) ==
        normalize_identity_field(key, Map.get(context_identity, key))
    end)
  end

  defp normalize_identity_field(:responsibility, value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_identity_field(:responsibility, value) when is_binary(value), do: String.trim(value)
  defp normalize_identity_field(_key, value), do: value

  defp apply_agent_route_changed(state, issue_id, running_entry, previous_route, next_route) do
    %{running: running} = state

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

  defp apply_agent_lifecycle_suspended(state, issue_id, running_entry, assessment) do
    %{running: running} = state

    Logger.warning(
      "Agent lifecycle continuation suspended for issue_id=#{issue_id}: " <>
        inspect(assessment)
    )

    updated_running_entry = Map.put(running_entry, :lifecycle_suspension, assessment)
    notify_dashboard()
    {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
  end

  defp apply_agent_dependency_blocked(state, issue_id, running_entry, decision) do
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

  defp route_for_issue(%Issue{} = issue, state) do
    settings = Config.settings!()

    if settings.agent.routing == "legacy" do
      if active_issue_state?(issue.state, active_state_set()) do
        {:ok, Route.legacy(issue)}
      else
        {:error, {:not_dispatchable_state, normalize_issue_state(issue.state)}}
      end
    else
      routed_route_for_issue(issue, state, settings)
    end
  end

  defp routed_route_for_issue(%Issue{} = issue, state, settings) do
    work_item = if is_struct(state, State), do: Map.get(state.work_control, issue.id), else: nil

    case work_item do
      %WorkItem{} = work_item ->
        resolve_routed_route(work_item, settings)

      _missing_work_item ->
        {:error, :canonical_work_item_required}
    end
  end

  defp resolve_routed_route(%WorkItem{} = work_item, settings) do
    case Router.resolve(work_item, settings.agent.profiles, settings.agent.routes) do
      {:ok, %Route{runtime_name: "codex"} = route} ->
        {:ok, route}

      {:ok, %Route{runtime_name: runtime_name}} ->
        {:error, {:runtime_not_available, runtime_name}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp route_dispatchable?(%Issue{} = issue, %State{} = state) do
    match?({:ok, %Route{}}, route_for_issue(issue, state))
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
          case route_for_issue(issue, state) do
            {:ok, %Route{responsibility: responsibility}} ->
              issue
              |> Guard.evaluate(responsibility, dependency_policy_options(state))
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
        dependency_policy_options(state)
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

  defp dependency_policy_options(%State{} = state) do
    settings = Config.settings!()

    [
      active_states: settings.tracker.active_states || [],
      terminal_states: settings.tracker.terminal_states || [],
      work_control: state.work_control
    ]
  end

  defp transition_context_for_state(%State{} = state, work_item_id, opts) do
    case Map.get(state.work_control, work_item_id) do
      %WorkItem{} = work_item ->
        with :ok <- transition_context_available?(state, work_item_id, work_item),
             {:ok, context} <- build_transition_context(state, work_item_id, work_item),
             {:ok, context} <- validate_transition_context_token(context, opts),
             :ok <- validate_expected_runtime_identity(context, opts) do
          {:ok, context}
        end

      _missing ->
        {:error, :work_item_not_found}
    end
  end

  defp semantic_tool_context_for_state(%State{} = state, work_item_id) do
    case Map.get(state.work_control, work_item_id) do
      %WorkItem{} = work_item ->
        {:ok, build_semantic_tool_context(state, work_item_id, work_item)}

      _missing ->
        {:error, :work_item_not_found}
    end
  end

  defp build_semantic_tool_context(%State{} = state, work_item_id, %WorkItem{} = work_item) do
    contract = semantic_tool_project_contract(state.project_contract_evidence)

    %{
      work_item: work_item,
      dependency_decision: Map.get(state.dependency_diagnostics || %{}, work_item_id),
      dependency_blocker_classifications: semantic_tool_dependency_blocker_classifications(state, work_item_id),
      dependency_epoch_evidence: semantic_tool_dependency_epoch_evidence(state),
      provider_project_contract: contract,
      provider_contract_fingerprint: provider_contract_fingerprint(contract),
      project_contract_evidence: semantic_tool_project_contract_evidence(state.project_contract_evidence),
      runtime_attempt_identity: current_runtime_attempt_identity(state, work_item_id)
    }
  end

  defp semantic_tool_dependency_blocker_classifications(%State{} = state, work_item_id) do
    decision =
      if is_map(state.dependency_diagnostics) do
        Map.get(state.dependency_diagnostics, work_item_id)
      end

    blockers =
      if is_map(decision) do
        Map.get(decision, :blockers) || Map.get(decision, "blockers")
      end

    with {:ok, blockers} <- semantic_tool_dependency_blocker_prefix(blockers),
         true <- is_map(state.work_control) do
      Enum.reduce(blockers, %{}, fn blocker, classifications ->
        semantic_tool_dependency_blocker_classification(
          blocker,
          state.work_control,
          classifications
        )
      end)
    else
      _reason -> %{}
    end
  end

  defp semantic_tool_dependency_blocker_prefix(nil), do: {:ok, []}

  defp semantic_tool_dependency_blocker_prefix(blockers) when is_list(blockers) do
    semantic_tool_dependency_blocker_prefix(
      blockers,
      @semantic_tool_dependency_blocker_limit,
      []
    )
  end

  defp semantic_tool_dependency_blocker_prefix(_blockers), do: {:error, :invalid_blockers}

  defp semantic_tool_dependency_blocker_prefix([], _remaining, acc),
    do: {:ok, Enum.reverse(acc)}

  defp semantic_tool_dependency_blocker_prefix([_head | _tail], 0, acc),
    do: {:ok, Enum.reverse(acc)}

  defp semantic_tool_dependency_blocker_prefix([head | tail], remaining, acc)
       when remaining > 0 do
    semantic_tool_dependency_blocker_prefix(tail, remaining - 1, [head | acc])
  end

  defp semantic_tool_dependency_blocker_prefix(_improper_tail, _remaining, _acc),
    do: {:error, :invalid_blockers}

  defp semantic_tool_dependency_blocker_classification(
         %WorkItem{} = blocker,
         _work_control,
         classifications
       ) do
    case Policy.classify_blocker(blocker) do
      {:ok, %{status: status}} ->
        Map.put(classifications, blocker.id, semantic_tool_dependency_classification(status))

      {:error, _reason} ->
        classifications
    end
  end

  defp semantic_tool_dependency_blocker_classification(
         %{} = blocker,
         work_control,
         classifications
       ) do
    with id when is_binary(id) <- semantic_tool_dependency_blocker_id(blocker),
         %WorkItem{} = work_item <- Map.get(work_control, id),
         {:ok, %{status: status}} <-
           Policy.classify_blocker(blocker, work_control: %{id => work_item}) do
      Map.put(classifications, id, semantic_tool_dependency_classification(status))
    else
      _reason ->
        classifications
    end
  end

  defp semantic_tool_dependency_blocker_classification(
         _blocker,
         _work_control,
         classifications
       ),
       do: classifications

  defp semantic_tool_dependency_blocker_id(blocker) when is_map(blocker) do
    Map.get(blocker, :id) || Map.get(blocker, "id")
  end

  defp semantic_tool_dependency_classification(:satisfied), do: :satisfied
  defp semantic_tool_dependency_classification(:invalidated), do: :invalidated
  defp semantic_tool_dependency_classification(:unresolved), do: :unavailable

  defp semantic_tool_dependency_epoch_evidence(%State{dependency_graph: %Graph{} = graph}) do
    %{
      epoch: graph.epoch,
      completeness: graph.completeness,
      complete?: Graph.complete?(graph)
    }
  end

  defp semantic_tool_dependency_epoch_evidence(%State{}) do
    %{epoch: nil, completeness: {:unavailable, :unknown}, complete?: false}
  end

  defp semantic_tool_project_contract(%ProjectContractEvidence{contract: contract}), do: contract
  defp semantic_tool_project_contract(_evidence), do: nil

  defp semantic_tool_project_contract_evidence(%ProjectContractEvidence{} = evidence),
    do: ProjectContractEvidence.observability(evidence)

  defp semantic_tool_project_contract_evidence(_evidence),
    do: ProjectContractEvidence.observability(nil)

  defp transition_context_available?(%State{} = state, work_item_id, %WorkItem{} = work_item) do
    with :ok <- startup_item_authority_available(state, work_item_id),
         :ok <- validate_transition_work_item(work_item),
         :ok <- validate_transition_dependency_context(state, work_item_id),
         :ok <- validate_transition_work_item_context(work_item) do
      validate_transition_contract_context(state.project_contract_evidence)
    end
  end

  defp startup_item_authority_available(%State{startup_reconciliation: :ready} = state, work_item_id) do
    if Enum.any?(state.transition_reconciliation_candidates, &(Map.get(&1, :work_item_id) == work_item_id)) do
      {:error, :transition_reconciliation_pending}
    else
      :ok
    end
  end

  defp startup_item_authority_available(%State{}, _work_item_id),
    do: {:error, :startup_reconciliation_pending}

  defp validate_transition_work_item(%WorkItem{} = work_item) do
    if WorkItem.suspended?(work_item), do: {:error, :work_item_suspended}, else: :ok
  end

  defp validate_transition_dependency_context(%State{} = state, work_item_id) do
    cond do
      not is_map(state.dependency_diagnostics) or
          not is_map(Map.get(state.dependency_diagnostics, work_item_id)) ->
        {:error, :dependency_context_unavailable}

      not match?(%Graph{}, state.dependency_graph) or not Graph.complete?(state.dependency_graph) ->
        {:error, :dependency_context_unavailable}

      true ->
        :ok
    end
  end

  defp validate_transition_work_item_context(%WorkItem{} = work_item) do
    if match?(%ProviderObservation{}, work_item.provider_observation) and
         match?(%LifecycleAssessment{}, work_item.lifecycle_assessment) and
         WorkflowLifecycle.canonical?(work_item.validated_lifecycle_state) do
      :ok
    else
      {:error, :work_item_context_unavailable}
    end
  end

  defp validate_transition_contract_context(contract_evidence) do
    if ProjectContractEvidence.reconciliation_required?(contract_evidence) do
      {:error, contract_evidence.reason || :provider_contract_reconciliation_required}
    else
      :ok
    end
  end

  defp build_transition_context(%State{} = state, work_item_id, %WorkItem{} = work_item) do
    contract_evidence = state.project_contract_evidence
    dependency_decision = Map.fetch!(state.dependency_diagnostics, work_item_id)
    contract = contract_evidence && contract_evidence.contract
    running = Map.get(state.running, work_item_id, %{})
    observation = work_item.provider_observation
    assessment = work_item.lifecycle_assessment

    {:ok,
     %{
       work_item: work_item,
       current_state: work_item.validated_lifecycle_state,
       dependency_decision: dependency_decision,
       dependency_epoch_evidence: %{
         epoch: state.dependency_graph.epoch,
         completeness: state.dependency_graph.completeness,
         complete?: Graph.complete?(state.dependency_graph)
       },
       guard_evidence: assessment.satisfied_guards,
       provider_observation: observation,
       provider_project_contract: contract,
       provider_contract_fingerprint: provider_contract_fingerprint(contract),
       runtime_attempt_id: transition_context_runtime_attempt_id(running),
       lineage_id: transition_context_lineage_id(running),
       lineage_generation: transition_context_lineage_generation(running),
       runtime_profile: Map.get(running, :profile_name),
       responsibility: WorkflowLifecycle.responsibility(work_item.validated_lifecycle_state),
       repository_context: %{
         workspace_path: Map.get(running, :workspace_path),
         worker_host: Map.get(running, :worker_host)
       },
       context_token: transition_context_token(work_item, state, dependency_decision, contract)
     }}
  end

  defp validate_transition_context_token(context, opts) do
    case Keyword.get(opts, :expected_context_token) do
      nil -> {:ok, context}
      expected when expected == context.context_token -> {:ok, context}
      _stale -> {:error, :context_token_mismatch}
    end
  end

  defp provider_contract_fingerprint(%ProviderProjectContract{} = contract),
    do: ProviderProjectContract.fingerprint(contract)

  defp provider_contract_fingerprint(_contract), do: nil

  defp transition_context_token(work_item, %State{} = state, dependency_decision, contract) do
    token_input = %{
      work_item_id: work_item.id,
      validated_state: work_item.validated_lifecycle_state,
      provider_observation: work_item.provider_observation,
      lifecycle_status: work_item.lifecycle_assessment.status,
      dependency_epoch: state.dependency_graph.epoch,
      dependency_decision: dependency_decision,
      contract_fingerprint:
        if(
          match?(%ProviderProjectContract{}, contract),
          do: ProviderProjectContract.fingerprint(contract),
          else: nil
        )
    }

    digest = :crypto.hash(:sha256, :erlang.term_to_binary(token_input))
    "sha256:" <> Base.encode16(digest, case: :lower)
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

  @doc """
  Returns the trusted, read-only host context for one routed work item.

  The result contains only local canonical evidence and the current provider
  contract. It is a handoff boundary for `TransitionCoordinator`; it is not a
  provider mutation API.
  """
  @spec transition_context(GenServer.server(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()} | :unavailable
  def transition_context(server \\ __MODULE__, work_item_id, opts \\ [])
      when is_binary(work_item_id) and is_list(opts) do
    if server_available?(server) do
      GenServer.call(server, {:transition_context, work_item_id, opts})
    else
      :unavailable
    end
  end

  @doc """
  Returns current host-owned canonical context for one work item.

  This read path preserves local lifecycle, dependency, and project-contract
  evidence even when the item is suspended or the evidence is incomplete. It
  does not refresh provider state or validate transition authority.
  """
  @spec semantic_tool_context(GenServer.server(), String.t()) ::
          {:ok, map()} | {:error, :work_item_not_found} | :unavailable
  def semantic_tool_context(server \\ __MODULE__, work_item_id) when is_binary(work_item_id) do
    if server_available?(server) do
      GenServer.call(server, {:semantic_tool_context, work_item_id})
    else
      :unavailable
    end
  end

  @doc """
  Applies a verified canonical projection to the orchestrator-owned work
  control map. Only a trusted host caller should use this function.
  """
  @spec apply_transition_result(GenServer.server(), String.t(), WorkItem.t(), keyword()) ::
          :ok | {:error, term()} | :unavailable
  def apply_transition_result(server \\ __MODULE__, work_item_id, %WorkItem{} = work_item, opts \\ [])
      when is_binary(work_item_id) and is_list(opts) do
    if server_available?(server) do
      GenServer.call(server, {:apply_transition_result, work_item_id, work_item, opts})
    else
      :unavailable
    end
  end

  @doc "Suspends one canonical work item after an unsafe transition outcome."
  @spec suspend_work_item(GenServer.server(), String.t(), atom()) ::
          {:ok, WorkItem.t()} | {:error, term()} | :unavailable
  def suspend_work_item(server \\ __MODULE__, work_item_id, reason)
      when is_binary(work_item_id) and is_atom(reason) do
    if server_available?(server) do
      GenServer.call(server, {:suspend_work_item, work_item_id, reason})
    else
      :unavailable
    end
  end

  @doc """
  Reconciles the configured provider project contract against a fresh provider
  snapshot. The provider snapshot is supplied by a trusted adapter boundary;
  this operation performs no provider mutation. The P-030 provider adapter is
  responsible for invoking this handoff after its authoritative read.
  """
  @spec reconcile_project_contract(GenServer.server(), map()) ::
          {:ok, ProviderProjectContract.ValidationResult.t()} | {:error, term()}
  def reconcile_project_contract(server \\ __MODULE__, snapshot) when is_map(snapshot) do
    GenServer.call(server, {:reconcile_project_contract, snapshot})
  end

  @doc false
  @spec reconcile_project_contract_for_test(State.t(), map()) :: State.t()
  def reconcile_project_contract_for_test(%State{} = state, snapshot) when is_map(snapshot) do
    {state, _result} = reconcile_project_contract_state(state, snapshot)
    state
  end

  @doc false
  @spec reconfigure_project_contract_for_test(
          State.t(),
          nil | ProviderProjectContract.t()
        ) :: State.t()
  def reconfigure_project_contract_for_test(%State{} = state, contract) do
    synchronize_project_contract_config(state, contract)
  end

  @doc false
  @spec autonomous_dispatch_allowed_for_test?(State.t()) :: boolean()
  def autonomous_dispatch_allowed_for_test?(%State{} = state), do: autonomous_dispatch_allowed?(state)

  @doc false
  @spec h030_rearm_proof_for_test(State.t(), String.t(), String.t() | nil) :: map() | nil
  def h030_rearm_proof_for_test(%State{} = state, issue_id, old_lineage),
    do: h030_rearm_proof(state, issue_id, old_lineage)

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
       project_contract: ProjectContractEvidence.observability(state.project_contract_evidence),
       codex_totals: state.codex_totals,
       rate_limits: observability_rate_limits(Map.get(state, :codex_rate_limits)),
       polling: %{
         checking?: state.poll_check_in_progress == true,
         next_poll_in_ms: next_poll_in_ms(state.next_poll_due_at_ms, now_ms),
         poll_interval_ms: state.poll_interval_ms
       }
     }, state}
  end

  def handle_call({:reconcile_project_contract, snapshot}, _from, %State{} = state)
      when is_map(snapshot) do
    {state, result} = reconcile_project_contract_state(state, snapshot)

    case result do
      %ProviderProjectContract.ValidationResult{} = validation ->
        {:reply, {:ok, validation}, state}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
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

  def handle_call({:transition_context, work_item_id, opts}, _from, %State{} = state)
      when is_binary(work_item_id) and is_list(opts) do
    case transition_context_for_state(state, work_item_id, opts) do
      {:ok, context} -> {:reply, {:ok, context}, state}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call({:semantic_tool_context, work_item_id}, _from, %State{} = state)
      when is_binary(work_item_id) do
    if state.startup_reconciliation == :ready do
      case semantic_tool_context_for_state(state, work_item_id) do
        {:ok, context} -> {:reply, {:ok, context}, state}
        {:error, _reason} = error -> {:reply, error, state}
      end
    else
      {:reply, {:error, :startup_reconciliation_pending}, state}
    end
  end

  def handle_call(
        {:apply_transition_result, work_item_id, %WorkItem{} = work_item, opts},
        _from,
        %State{} = state
      )
      when is_binary(work_item_id) and is_list(opts) do
    cond do
      work_item.id != work_item_id ->
        {:reply, {:error, :work_item_id_mismatch}, state}

      state.startup_reconciliation != :ready ->
        {:reply, {:error, :startup_reconciliation_pending}, state}

      Enum.any?(state.transition_reconciliation_candidates, &(Map.get(&1, :work_item_id) == work_item_id)) ->
        {:reply, {:error, :transition_reconciliation_pending}, state}

      transition_context_token_matches?(state, work_item_id, Keyword.get(opts, :expected_context_token)) ->
        case persist_authoritative_work_item(state, work_item_id, work_item) do
          {:ok, next_state} ->
            {:reply, :ok, %{next_state | work_control: Map.put(next_state.work_control, work_item_id, work_item)}}

          {:error, next_state, reason} ->
            {:reply, {:error, {:recovery_ledger_unavailable, reason}}, next_state}
        end

      true ->
        {:reply, {:error, :context_token_mismatch}, state}
    end
  end

  def handle_call({:suspend_work_item, work_item_id, reason}, _from, %State{} = state)
      when is_binary(work_item_id) and is_atom(reason) do
    case Map.get(state.work_control, work_item_id) do
      %WorkItem{} = work_item ->
        case WorkItem.suspend(work_item, reason) do
          {:ok, suspended} ->
            handle_suspension_persistence(state, work_item_id, reason, suspended)

          {:error, _reason} = error ->
            {:reply, error, state}
        end

      _missing ->
        {:reply, {:error, :work_item_not_found}, state}
    end
  end

  defp handle_suspension_persistence(state, work_item_id, reason, suspended) do
    suspended =
      suspend_work_item_with_checkpoint_context(
        suspended,
        Map.get(state.recovery_checkpoints, work_item_id),
        state,
        reason
      )

    case persist_suspended_work_item(state, work_item_id, suspended) do
      {:ok, next_state, suspended} ->
        next_state = %{next_state | work_control: Map.put(next_state.work_control, work_item_id, suspended)}
        {:reply, {:ok, suspended}, next_state}

      {:error, next_state, persistence_reason} ->
        {:reply, {:error, {:recovery_ledger_unavailable, persistence_reason}}, next_state}
    end
  end

  defp transition_context_token_matches?(_state, _work_item_id, nil), do: true

  defp transition_context_token_matches?(%State{} = state, work_item_id, expected) do
    case Map.get(state.work_control, work_item_id) do
      %WorkItem{} = current ->
        decision = Map.get(state.dependency_diagnostics, work_item_id, %{})
        contract = state.project_contract_evidence && state.project_contract_evidence.contract
        transition_context_token(current, state, decision, contract) == expected

      _missing ->
        false
    end
  end

  defp server_available?(server) when is_pid(server), do: Process.alive?(server)
  defp server_available?(server) when is_atom(server), do: not is_nil(Process.whereis(server))
  defp server_available?(server), do: not is_nil(GenServer.whereis(server))

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

    state
    |> synchronize_project_contract_config(config.provider_project_contract)
    |> synchronize_attempt_ledger_config(config)
    |> synchronize_workspace_ownership_ledger_config(config)
  end

  defp synchronize_project_contract_config(%State{} = state, contract) do
    previous_evidence = state.project_contract_evidence
    evidence = ProjectContractEvidence.reconfigure(previous_evidence, contract)
    state = %{state | project_contract_evidence: evidence}

    if project_contract_changed?(previous_evidence, contract) do
      reason = evidence.reason || :provider_configuration_changed

      state
      |> Map.put(:startup_reconciliation, :pending)
      |> suspend_work_control_for_project_contract(reason)
      |> suspend_running_for_project_contract(reason)
    else
      state
    end
  end

  defp project_contract_changed?(nil, nil), do: false
  defp project_contract_changed?(nil, %ProviderProjectContract{}), do: true
  defp project_contract_changed?(%ProjectContractEvidence{contract: nil}, nil), do: false
  defp project_contract_changed?(%ProjectContractEvidence{contract: nil}, %ProviderProjectContract{}), do: true

  defp project_contract_changed?(
         %ProjectContractEvidence{contract: %ProviderProjectContract{}},
         nil
       ),
       do: true

  defp project_contract_changed?(
         %ProjectContractEvidence{contract: %ProviderProjectContract{} = previous},
         %ProviderProjectContract{} = next
       ) do
    ProviderProjectContract.fingerprint(previous) != ProviderProjectContract.fingerprint(next)
  end

  defp project_contract_changed?(_previous, next), do: not is_nil(next)

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
        synchronize_attempt_ledger_identity(state, project_id, tracker_identity, :ready)

      {:blocked, reason} ->
        synchronize_attempt_ledger_identity(state, project_id, tracker_identity, {:blocked, reason})

      _ ->
        block_ledger(state, :invalid_ledger_status)
    end
  end

  defp synchronize_attempt_ledger_identity(
         %State{} = state,
         project_id,
         tracker_identity,
         fallback_status
       ) do
    case state.attempt_ledger do
      %AttemptLedger{project_id: ^project_id, tracker_identity: ^tracker_identity} ->
        %{state | attempt_ledger_status: fallback_status}

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

      nil ->
        synchronize_missing_attempt_ledger(state, fallback_status)

      _ ->
        block_ledger(state, :missing_ledger_handle)
    end
  end

  defp synchronize_missing_attempt_ledger(%State{} = state, :ready),
    do: block_ledger(state, :missing_ledger_handle)

  defp synchronize_missing_attempt_ledger(%State{} = state, {:blocked, reason}),
    do: %{state | attempt_ledger_status: {:blocked, reason}}

  defp retry_candidate_issue?(%Issue{} = issue, terminal_states) do
    candidate_issue?(issue, active_state_set(), terminal_states)
  end

  defp retry_candidate_for_state?(%Issue{} = issue, %State{} = state, terminal_states) do
    if Config.settings!().agent.routing == "routed" do
      routed_candidate_issue?(issue, state)
    else
      retry_candidate_issue?(issue, terminal_states)
    end
  end

  defp retry_candidate_for_state?(_issue, _state, _terminal_states), do: false

  defp trusted_retry_work_item?(%WorkItem{lifecycle_assessment: assessment}),
    do: LifecycleAssessment.validated?(assessment)

  defp trusted_retry_work_item?(_work_item), do: false

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
