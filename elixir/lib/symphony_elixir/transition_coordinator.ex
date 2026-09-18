defmodule SymphonyElixir.TransitionCoordinator do
  @moduledoc """
  Host-only owner for one controlled work-item transition at a time.

  The coordinator is deliberately a small sequencing boundary. It does not
  decide lifecycle policy or turn provider observations into authority. It
  serializes requests, writes the durable no-resubmit fence before calling a
  provider, and sends every possibly-submitted request through one fresh
  verification callback.
  """

  use GenServer

  alias SymphonyElixir.{Config, Orchestrator}
  alias SymphonyElixir.Plane.ProjectContract, as: PlaneProjectContract
  alias SymphonyElixir.Tracker
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.Tracker.TransitionPolicy

  alias SymphonyElixir.WorkControl.{
    GuardClass,
    LifecycleAssessment,
    ProviderObservation,
    ProviderProjectContract,
    SemanticTransitionIntent,
    TransitionAttempt,
    TransitionAttemptLedger,
    WorkflowLifecycle,
    WorkItem
  }

  @claims_table :symphony_transition_coordinator_claims

  defmodule State do
    @moduledoc false

    defstruct [
      :ledger,
      :load_context,
      :refresh_contract,
      :submit,
      :verify,
      :apply_verified,
      :suspend,
      :clock,
      :orchestrator,
      require_durable?: true,
      active_work_items: MapSet.new(),
      fenced_work_items: MapSet.new()
    ]

    @type t :: %__MODULE__{
            ledger: TransitionAttemptLedger.t() | nil,
            load_context: (SemanticTransitionIntent.t() -> term()),
            refresh_contract: (map() -> term()),
            submit: (TransitionAttempt.t(), map() -> term()),
            verify: (TransitionAttempt.t(), map() -> term()),
            apply_verified: (TransitionAttempt.t(), term() -> term()),
            suspend: (String.t(), atom(), TransitionAttempt.t() -> term()) | nil,
            clock: (-> DateTime.t()),
            orchestrator: GenServer.server(),
            require_durable?: boolean(),
            active_work_items: MapSet.t(),
            fenced_work_items: MapSet.t()
          }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    start_opts = if is_nil(name), do: [], else: [name: name]
    GenServer.start_link(__MODULE__, opts, start_opts)
  end

  @spec request_transition(GenServer.server(), SemanticTransitionIntent.t() | map()) ::
          {:ok, TransitionAttempt.t()} | {:error, term()}
  def request_transition(server \\ __MODULE__, intent) do
    case request_claim_key(server, intent) do
      {:ok, claim_key} ->
        table = claims_table()

        if :ets.insert_new(table, {claim_key, self()}) do
          try do
            call_transition(server, intent)
          after
            :ets.delete(table, claim_key)
          end
        else
          {:error, :transition_in_progress}
        end

      :skip ->
        call_transition(server, intent)
    end
  end

  defp call_transition(server, intent) do
    GenServer.call(server, {:request_transition, intent}, :infinity)
  catch
    :exit, _reason -> {:error, :coordinator_unavailable}
  end

  @spec init(keyword()) :: {:ok, State.t()} | {:stop, term()}
  @impl true
  def init(opts) do
    orchestrator = Keyword.get(opts, :orchestrator, Orchestrator)

    default_suspend = fn work_item_id, reason, _attempt ->
      Orchestrator.suspend_work_item(orchestrator, work_item_id, reason)
    end

    with {:ok, ledger} <- open_ledger(opts),
         {:ok, refresh_contract} <- callback(opts, :refresh_contract, &default_refresh_contract/1),
         {:ok, load_context} <-
           callback(opts, :load_context, fn intent ->
             default_load_context(orchestrator, intent, refresh_contract)
           end),
         {:ok, submit} <- callback(opts, :submit, &default_submit/2),
         {:ok, verify} <-
           callback(opts, :verify, fn attempt, context ->
             default_verify(attempt, context, refresh_contract)
           end),
         default_apply = fn attempt, context -> default_apply_verified(orchestrator, attempt, context) end,
         {:ok, apply_verified} <- callback(opts, :apply_verified, default_apply),
         {:ok, suspend} <- callback(opts, :suspend, default_suspend) do
      {:ok,
       %State{
         ledger: ledger,
         load_context: load_context,
         refresh_contract: refresh_contract,
         submit: submit,
         verify: verify,
         apply_verified: apply_verified,
         suspend: suspend,
         clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
         orchestrator: orchestrator,
         require_durable?: Keyword.get(opts, :require_durable?, true),
         fenced_work_items: load_fenced_work_items(ledger)
       }}
    end
  end

  @impl true
  def terminate(_reason, %State{ledger: nil}), do: :ok
  def terminate(_reason, %State{ledger: ledger}), do: TransitionAttemptLedger.close(ledger)

  @impl true
  def handle_call({:request_transition, raw_intent}, _from, %State{} = state) do
    case normalize_intent(raw_intent) do
      {:ok, intent} -> execute_if_claimed(state, intent)
      {:error, reason} -> {:reply, {:error, {:rejected, reason}}, state}
    end
  end

  defp execute_if_claimed(%State{} = state, %SemanticTransitionIntent{} = intent) do
    work_item_id = intent.work_item_id

    cond do
      MapSet.member?(state.active_work_items, work_item_id) ->
        {:reply, {:error, :transition_in_progress}, state}

      MapSet.member?(state.fenced_work_items, work_item_id) ->
        {:reply, {:error, :transition_fenced}, state}

      true ->
        state = %{state | active_work_items: MapSet.put(state.active_work_items, work_item_id)}
        {reply, state} = execute(state, intent)
        {:reply, reply, %{state | active_work_items: MapSet.delete(state.active_work_items, work_item_id)}}
    end
  end

  defp request_claim_key(server, intent) when is_map(intent) do
    case Map.get(intent, :work_item_id) do
      work_item_id when is_binary(work_item_id) and byte_size(work_item_id) > 0 ->
        {:ok, {server, String.trim(work_item_id)}}

      _missing ->
        :skip
    end
  end

  defp request_claim_key(_server, _intent), do: :skip

  defp claims_table do
    case :ets.whereis(@claims_table) do
      :undefined ->
        try do
          :ets.new(@claims_table, [:named_table, :public, :set, read_concurrency: true])
        rescue
          ArgumentError -> @claims_table
        end

      _table ->
        @claims_table
    end
  end

  defp execute(%State{} = state, %SemanticTransitionIntent{} = intent) do
    with {:ok, attempt} <- new_attempt(intent, state.clock),
         {:ok, attempt} <- authorize_attempt(attempt, intent),
         {:ok, context} <- load_context(state, intent),
         :ok <- authorize_fresh_context(intent, context),
         :ok <- guard_context(intent, context),
         {:ok, context} <- bind_target(context, intent),
         {:ok, attempt} <- transition_attempt(attempt, :fresh_context_loaded, [context]),
         {:ok, attempt} <- transition_attempt(attempt, :prepare, [context]),
         {:ok, attempt} <- persist_attempt(state, attempt),
         {:ok, attempt} <- transition_attempt(attempt, :mark_mutation_submitted, []),
         {:ok, attempt} <- persist_attempt(state, attempt),
         {submit_result, attempt} <- submit_once(state, attempt, context),
         {reply, state} <- reconcile_submission(state, attempt, context, submit_result) do
      {reply, state}
    else
      {:error, {:pre_submit, reason}, attempt} ->
        finish_pre_submit(state, attempt, reason)

      {:error, {:pre_submit, reason, attempt}} ->
        finish_pre_submit(state, attempt, reason)

      {:error, reason} ->
        finish_without_submission(state, intent, reason)
    end
  end

  defp new_attempt(%SemanticTransitionIntent{} = intent, clock) do
    attrs =
      intent
      |> Map.from_struct()
      |> Map.put(:state, :requested)
      |> Map.put(:provider, :plane)
      |> Map.put(:requested_at, clock.())
      |> Map.put(:transition_identity, transition_identity(intent))

    case TransitionAttempt.new(attrs) do
      {:ok, attempt} -> {:ok, attempt}
      %TransitionAttempt{} = attempt -> {:ok, attempt}
      {:error, reason} -> {:error, {:pre_submit, reason}, attrs}
      other -> {:error, {:pre_submit, {:invalid_attempt, other}}, attrs}
    end
  end

  defp authorize_attempt(%TransitionAttempt{} = attempt, %SemanticTransitionIntent{} = intent) do
    case transition_attempt(attempt, :authorize_intent, [intent]) do
      {:ok, authorized} ->
        policy_context = %{
          current_state: intent.requested_from,
          target_state: intent.requested_to,
          responsibility: intent.responsibility
        }

        case TransitionPolicy.authorize_intent(policy_context) do
          :ok -> {:ok, authorized}
          {:error, reason} -> {:error, {:pre_submit, {:policy_rejected, reason}, authorized}}
        end

      {:error, _reason} = error ->
        {:error, {:pre_submit, elem(error, 1)}, attempt}
    end
  end

  defp load_context(%State{load_context: load_context}, intent) do
    case invoke(load_context, [intent]) do
      {:ok, context} when is_map(context) -> {:ok, Map.put(context, :intent, intent)}
      {:error, reason} -> {:error, {:pre_submit, {:context_unavailable, reason}}}
      other -> {:error, {:pre_submit, {:context_unavailable, other}}}
    end
  end

  defp authorize_fresh_context(intent, context) do
    current_state = Map.get(context, :current_state, intent.requested_from)

    with :ok <- validate_fresh_current_state(current_state, intent.requested_from),
         policy_context <- fresh_policy_context(context, intent, current_state),
         :ok <- authorize_fresh_policy(policy_context) do
      authorize_fresh_dependencies(policy_context, context)
    end
  end

  defp validate_fresh_current_state(current_state, expected_state) do
    cond do
      not is_atom(current_state) or not WorkflowLifecycle.canonical?(current_state) ->
        {:error, {:pre_submit, :non_canonical_current_state}}

      current_state != expected_state ->
        {:error, {:pre_submit, :source_state_changed}}

      true ->
        :ok
    end
  end

  defp fresh_policy_context(context, intent, current_state) do
    context
    |> Map.put(:current_state, current_state)
    |> Map.put(:target_state, intent.requested_to)
    |> Map.put(:responsibility, intent.responsibility)
  end

  defp authorize_fresh_policy(policy_context) do
    case TransitionPolicy.authorize_intent(policy_context) do
      :ok -> :ok
      {:error, reason} -> {:error, {:pre_submit, {:policy_rejected, reason}}}
    end
  end

  defp authorize_fresh_dependencies(policy_context, context) do
    case Map.get(context, :dependency_decision) do
      decision when is_map(decision) ->
        case TransitionPolicy.authorize(Map.put(policy_context, :dependency_decision, decision)) do
          :ok -> :ok
          {:error, reason} -> {:error, {:pre_submit, {:policy_rejected, reason}}}
        end

      _missing ->
        {:error, {:pre_submit, :dependency_context_unavailable}}
    end
  end

  defp guard_context(%SemanticTransitionIntent{} = intent, context) do
    requirements = WorkflowLifecycle.guard_requirements(intent.requested_from, intent.requested_to) || []
    evidence = Map.get(context, :guard_evidence, intent.guard_evidence)

    if GuardClass.all_satisfied?(requirements, evidence, %{
         subject: {:work_item, intent.work_item_id},
         responsibility: intent.responsibility
       }) do
      :ok
    else
      {:error, {:pre_submit, :required_guard_missing}}
    end
  end

  defp bind_target(context, %SemanticTransitionIntent{} = intent) do
    case Map.get(context, :provider_project_contract) || Map.get(context, :contract) do
      %ProviderProjectContract{} = contract ->
        with :ok <- validate_bound_contract(context, contract),
             {:ok, mapping} <- ProviderProjectContract.provider_mapping_for(contract, intent.requested_to) do
          {:ok,
           context
           |> Map.put(:provider_project_contract, contract)
           |> Map.put(:workspace_id, contract.workspace_id)
           |> Map.put(:project_id, contract.project_id)
           |> Map.put(:provider_contract_fingerprint, ProviderProjectContract.fingerprint(contract))
           |> Map.put(:target_provider_state_id, mapping.state_id)
           |> Map.put(:target_provider_state_group, mapping.group)}
        else
          {:error, reason} ->
            {:error, {:pre_submit, {:target_mapping_unavailable, reason}}}
        end

      nil ->
        {:error, {:pre_submit, :provider_project_contract_required}}

      _invalid ->
        {:error, {:pre_submit, :invalid_provider_project_contract}}
    end
  end

  defp validate_bound_contract(context, %ProviderProjectContract{} = contract) do
    expected_fingerprint = ProviderProjectContract.fingerprint(contract)
    observed_fingerprint = Map.get(context, :provider_contract_fingerprint)
    observation = Map.get(context, :provider_observation)
    epoch_evidence = Map.get(context, :dependency_epoch_evidence)

    cond do
      is_binary(observed_fingerprint) and observed_fingerprint != expected_fingerprint ->
        {:error, :provider_contract_drift}

      match?(%ProviderObservation{}, observation) and
          (observation.workspace_id != contract.workspace_id or observation.project_id != contract.project_id) ->
        {:error, :wrong_project}

      not is_map(epoch_evidence) ->
        {:error, :dependency_context_unavailable}

      Map.get(epoch_evidence, :complete?, Map.get(epoch_evidence, "complete?")) != true ->
        {:error, :dependency_context_unavailable}

      true ->
        :ok
    end
  end

  defp submit_once(%State{submit: submit}, attempt, context) do
    result = invoke(submit, [attempt, context])
    {result, attempt}
  end

  defp reconcile_submission(%State{} = state, attempt, context, result) do
    ack_status = provider_ack_status(result)
    reconcile_submission_with_ack(state, attempt, context, result, ack_status)
  end

  defp reconcile_submission_with_ack(%State{} = state, attempt, _context, {:error, :econnrefused}, ack_status) do
    terminal_result(state, %{attempt | provider_ack_status: ack_status}, :provider_failed, :connection_refused)
  end

  defp reconcile_submission_with_ack(%State{} = state, attempt, context, _result, ack_status) do
    verify_submission(state, attempt, context, ack_status)
  end

  defp verify_submission(%State{} = state, attempt, context, ack_status) do
    with {:ok, attempt} <- transition_attempt(attempt, :begin_verification, [%{provider_ack_status: ack_status}]),
         :ok <- persist(state, attempt),
         result <- invoke(state.verify, [attempt, context]) do
      case classify_verification(result) do
        {:verified, reason} ->
          _ = invoke(state.apply_verified, [attempt, reason])
          terminal_result(state, attempt, :verified, reason)

        {:conflict, reason} ->
          terminal_result(state, attempt, :conflict, reason)

        {:provider_failed, reason} ->
          terminal_result(state, attempt, :provider_failed, reason)

        {:indeterminate, reason} ->
          terminal_result(state, attempt, :indeterminate, reason)
      end
    else
      {:error, reason} -> terminal_result(state, attempt, :indeterminate, {:verification_failed, reason})
    end
  end

  defp provider_ack_status(:ok), do: :accepted

  defp provider_ack_status({:ok, %{status: status}}) when is_integer(status) and status in 200..299,
    do: {:http, status}

  defp provider_ack_status({:error, :econnrefused}), do: :not_submitted
  defp provider_ack_status({:error, _reason}), do: :ambiguous
  defp provider_ack_status(_result), do: :ambiguous

  defp classify_verification(:verified), do: {:verified, :target_confirmed}
  defp classify_verification({:verified, %{} = context}), do: {:verified, context}
  defp classify_verification({:verified, reason}), do: {:verified, reason}
  defp classify_verification({:ok, :verified}), do: {:verified, :target_confirmed}
  defp classify_verification({:ok, %{status: :verified} = context}), do: {:verified, context}
  defp classify_verification({:conflict, %{} = context}), do: {:indeterminate, context}
  defp classify_verification({:conflict, reason}), do: {:indeterminate, {:unproven_conflict, reason}}
  defp classify_verification({:conflict, reason, :non_commit}), do: {:conflict, reason}
  defp classify_verification({:provider_failed, %{} = context}), do: {:indeterminate, context}
  defp classify_verification({:provider_failed, reason}), do: {:indeterminate, {:unproven_failure, reason}}
  defp classify_verification({:indeterminate, %{} = context}), do: {:indeterminate, context}
  defp classify_verification({:provider_failed, reason, :non_commit}), do: {:provider_failed, reason}
  defp classify_verification({:error, reason}), do: {:indeterminate, reason}
  defp classify_verification(other), do: {:indeterminate, {:invalid_verification, other}}

  defp terminal_result(%State{} = state, attempt, state_name, reason) do
    terminal_args =
      case {state_name, reason} do
        {:verified, %{} = context} -> [Map.put(context, :status, :verified)]
        {:verified, reason} -> [%{status: :verified, reason: reason}]
        {_state, %{} = context} -> [Map.put_new(context, :reason, Map.get(context, :reason, reason))]
        {_state, reason} -> [reason]
      end

    with {:ok, terminal} <- transition_attempt(attempt, terminal_function(state_name), terminal_args),
         :ok <- persist(state, terminal) do
      state =
        if safety_fence?(state_name, reason) do
          fenced = MapSet.put(state.fenced_work_items, terminal.work_item_id)
          _ = invoke_suspend(state.suspend, [terminal.work_item_id, state_name, terminal])
          %{state | fenced_work_items: fenced}
        else
          state
        end

      {{:ok, terminal}, state}
    else
      {:error, error} ->
        state =
          if TransitionAttempt.submission_fenced?(attempt) do
            fence_work_item(state, attempt, :durability_failed)
          else
            state
          end

        {{:error, error}, state}
    end
  end

  defp fence_work_item(%State{} = state, %TransitionAttempt{} = attempt, reason) do
    fenced = MapSet.put(state.fenced_work_items, attempt.work_item_id)
    _ = invoke_suspend(state.suspend, [attempt.work_item_id, reason, attempt])
    %{state | fenced_work_items: fenced}
  end

  defp terminal_function(:verified), do: :verify
  defp terminal_function(:rejected), do: :reject
  defp terminal_function(:conflict), do: :conflict
  defp terminal_function(:provider_failed), do: :provider_failed
  defp terminal_function(:indeterminate), do: :indeterminate

  defp safety_fence?(state_name, _reason) when state_name in [:conflict, :indeterminate], do: true
  defp safety_fence?(:provider_failed, {:durability_failed, _reason}), do: true
  defp safety_fence?(_state_name, _reason), do: false

  defp finish_rejected(%State{} = state, %TransitionAttempt{} = attempt, reason) do
    case terminal_result(state, attempt, :rejected, reason) do
      {{:ok, _} = reply, state} -> {reply, state}
      {reply, state} -> {reply, state}
    end
  end

  defp finish_rejected(%State{} = state, _attempt, reason),
    do: {{:error, {:rejected, reason}}, state}

  defp finish_pre_submit(%State{} = state, %TransitionAttempt{} = attempt, reason) do
    case pre_submit_outcome(reason) do
      :conflict -> terminal_result(state, attempt, :conflict, reason)
      :provider_failed -> terminal_result(state, attempt, :provider_failed, reason)
      :rejected -> finish_rejected(state, attempt, reason)
    end
  end

  defp finish_pre_submit(%State{} = state, _attempt, reason),
    do: {{:error, {:rejected, reason}}, state}

  defp pre_submit_outcome(:source_state_changed), do: :conflict
  defp pre_submit_outcome({:context_unavailable, :source_state_changed}), do: :conflict
  defp pre_submit_outcome({:context_unavailable, :provider_contract_drift}), do: :rejected

  defp pre_submit_outcome({:context_unavailable, reason})
       when reason in [:work_item_suspended, :dependency_context_unavailable],
       do: :rejected

  defp pre_submit_outcome({:context_unavailable, _reason}), do: :provider_failed
  defp pre_submit_outcome({:fresh_context_unavailable, _reason}), do: :provider_failed
  defp pre_submit_outcome({:durability_failed, _reason}), do: :provider_failed
  defp pre_submit_outcome(:provider_project_contract_required), do: :provider_failed
  defp pre_submit_outcome(_reason), do: :rejected

  defp finish_without_submission(%State{} = state, %SemanticTransitionIntent{} = intent, reason) do
    case new_attempt(intent, state.clock) do
      {:ok, attempt} -> finish_pre_submit(state, attempt, reason)
      {:error, _error, _attrs} -> {{:error, {:rejected, reason}}, state}
    end
  end

  defp persist(%State{ledger: nil, require_durable?: false}, _attempt), do: :ok

  defp persist(%State{ledger: nil, require_durable?: true}, _attempt),
    do: {:error, {:durability_failed, :ledger_unavailable}}

  defp persist(%State{ledger: ledger}, %TransitionAttempt{} = attempt) do
    case TransitionAttemptLedger.put_sync(ledger, attempt) do
      :ok -> :ok
      {:error, reason} -> {:error, {:durability_failed, reason}}
    end
  end

  defp persist_attempt(%State{} = state, %TransitionAttempt{} = attempt) do
    case persist(state, attempt) do
      :ok -> {:ok, attempt}
      {:error, reason} -> {:error, {:pre_submit, reason, attempt}}
    end
  end

  defp transition_attempt(%TransitionAttempt{} = attempt, function, args) do
    arity = length(args) + 1

    if function_exported?(TransitionAttempt, function, arity) do
      case apply(TransitionAttempt, function, [attempt | args]) do
        {:ok, %TransitionAttempt{} = next} -> {:ok, next}
        %TransitionAttempt{} = next -> {:ok, next}
        {:error, reason} -> {:error, reason}
        other -> {:error, {:invalid_transition_result, other}}
      end
    else
      {:error, {:unsupported_transition, function}}
    end
  end

  defp normalize_intent(%SemanticTransitionIntent{} = intent) do
    case SemanticTransitionIntent.validate(intent) do
      :ok -> {:ok, intent}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_intent(attrs) when is_map(attrs), do: SemanticTransitionIntent.new(attrs)
  defp normalize_intent(_attrs), do: {:error, :invalid_intent}

  defp transition_identity(intent) do
    case WorkflowLifecycle.transition(intent.requested_from, intent.requested_to) do
      {:ok, metadata} -> Map.take(metadata, [:source, :target, :owner, :responsibility])
      {:error, _reason} -> %{source: intent.requested_from, target: intent.requested_to}
    end
  end

  defp open_ledger(opts) do
    case Keyword.fetch(opts, :ledger) do
      {:ok, ledger} ->
        {:ok, ledger}

      :error ->
        {project_id, tracker_identity} = configured_ledger_identity(opts)

        with project_id when is_binary(project_id) <- project_id,
             tracker_identity when is_map(tracker_identity) <- tracker_identity,
             {:ok, ledger} <- TransitionAttemptLedger.open(project_id, tracker_identity, Keyword.get(opts, :ledger_opts, [])) do
          {:ok, ledger}
        else
          _ -> {:ok, nil}
        end
    end
  end

  defp configured_ledger_identity(opts) do
    explicit = {Keyword.get(opts, :project_id), Keyword.get(opts, :tracker_identity)}

    case explicit do
      {project_id, identity} when is_binary(project_id) and is_map(identity) ->
        explicit

      _ ->
        case safe_settings() do
          %{symphony: %{project_id: project_id}, tracker: tracker}
          when is_binary(project_id) and is_map(tracker) ->
            {project_id, Tracker.identity(tracker)}

          _ ->
            {nil, nil}
        end
    end
  end

  defp safe_settings do
    case Config.settings() do
      {:ok, settings} -> settings
      _ -> nil
    end
  rescue
    _error -> nil
  end

  defp load_fenced_work_items(nil), do: MapSet.new()

  defp load_fenced_work_items(ledger) do
    case TransitionAttemptLedger.list_reconciliation_candidates(ledger) do
      {:ok, attempts} ->
        attempts
        |> Enum.map(&Map.get(&1, :work_item_id))
        |> Enum.filter(&is_binary/1)
        |> MapSet.new()

      {:error, _reason} ->
        # A corrupt or unreadable safety ledger must fail closed. The caller
        # still owns the process lifecycle; no work item is authorized until a
        # fresh request can establish a durable record.
        MapSet.new()
    end
  end

  defp callback(opts, key, default) do
    callback = Keyword.get(opts, key, default)

    if is_function(callback) do
      {:ok, callback}
    else
      {:error, {:invalid_callback, key}}
    end
  end

  defp invoke(fun, args) when is_function(fun) do
    cond do
      is_function(fun, length(args)) -> apply(fun, args)
      is_function(fun, 1) -> fun.(List.first(args))
      is_function(fun, 0) -> fun.()
      true -> {:error, :invalid_callback_arity}
    end
  rescue
    _error -> {:error, :callback_failed}
  catch
    _kind, _reason -> {:error, :callback_failed}
  end

  defp invoke_suspend(nil, _args), do: :ok
  defp invoke_suspend(fun, args), do: invoke(fun, args)

  defp default_load_context(orchestrator, %SemanticTransitionIntent{} = intent, refresh_contract) do
    case Orchestrator.transition_context(orchestrator, intent.work_item_id) do
      {:ok, context} ->
        with {:ok, context} <- refresh_contract_context(context, refresh_contract) do
          fresh_pre_context(intent, context)
        end

      :unavailable ->
        {:error, :transition_context_unavailable}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:invalid_transition_context, other}}
    end
  rescue
    _error -> {:error, :transition_context_unavailable}
  end

  defp refresh_contract_context(context, refresh_contract) when is_map(context) do
    case invoke(refresh_contract, [context]) do
      {:ok, %ProviderProjectContract{} = contract} ->
        update_refreshed_contract(context, contract)

      {:error, reason} ->
        {:error, {:provider_contract_unavailable, reason}}

      other ->
        {:error, {:provider_contract_unavailable, other}}
    end
  end

  defp update_refreshed_contract(context, %ProviderProjectContract{} = contract) do
    case Map.get(context, :provider_project_contract) do
      %ProviderProjectContract{} = expected ->
        if ProviderProjectContract.fingerprint(expected) == ProviderProjectContract.fingerprint(contract) do
          {:ok,
           context
           |> Map.put(:provider_project_contract, contract)
           |> Map.put(:provider_contract_fingerprint, ProviderProjectContract.fingerprint(contract))}
        else
          {:error, :provider_contract_drift}
        end

      _missing ->
        {:error, :provider_project_contract_required}
    end
  end

  defp default_refresh_contract(%{provider_project_contract: %ProviderProjectContract{} = contract}) do
    case Tracker.fetch_project_snapshot() do
      {:ok, snapshot} ->
        validation = PlaneProjectContract.validate(contract, snapshot)

        if validation.status == :valid and
             validation.expected_fingerprint == validation.observed_fingerprint do
          {:ok, contract}
        else
          {:error, {:provider_contract_untrusted, validation.status}}
        end

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:invalid_provider_snapshot, other}}
    end
  end

  defp default_refresh_contract(_context), do: {:error, :provider_project_contract_required}

  defp fresh_pre_context(%SemanticTransitionIntent{} = intent, context) when is_map(context) do
    with {:ok, [%Issue{} = issue]} <- Tracker.fetch_issues_by_ids([intent.work_item_id]),
         {:ok, observation} <- ProviderObservation.from_issue(issue, provider_observation_opts(context)),
         :ok <- validate_observation_scope(observation, Map.get(context, :provider_project_contract)),
         {:ok, canonical_state} <- fresh_canonical_state(observation, context),
         true <- canonical_state == intent.requested_from,
         {:ok, assessment} <-
           fresh_assessment(
             observation,
             intent.requested_from,
             intent.guard_evidence,
             Map.put(context, :responsibility, intent.responsibility)
           ),
         true <- LifecycleAssessment.validated?(assessment) do
      {:ok,
       context
       |> Map.put(:provider_observation, observation)
       |> Map.put(:pre_observation_evidence, observation)
       |> Map.put(:current_state, canonical_state)
       |> Map.put(:pre_assessment_evidence, assessment)
       |> Map.put(:guard_evidence, assessment.satisfied_guards)
       |> Map.put(:fresh_read_at, observation.observed_at)}
    else
      {:ok, []} -> {:error, :work_item_not_found}
      false -> {:error, :source_state_changed}
      {:error, reason} -> {:error, {:fresh_context_unavailable, reason}}
      _other -> {:error, :fresh_context_unavailable}
    end
  end

  defp fresh_pre_context(_intent, _context), do: {:error, :fresh_context_unavailable}

  defp provider_observation_opts(_context) do
    [
      provider: :plane,
      observed_at: DateTime.utc_now()
    ]
  end

  defp fresh_canonical_state(%ProviderObservation{} = observation, context) do
    case Map.get(context, :provider_project_contract) do
      %ProviderProjectContract{} = contract -> ProviderObservation.map_state(observation, contract)
      _ -> {:error, :provider_project_contract_required}
    end
  end

  defp fresh_assessment(observation, prior_state, evidence, context) do
    contract = Map.get(context, :provider_project_contract)

    assessment_context = %{
      provider_project_contract: contract,
      subject: {:work_item, observation.work_item_id},
      responsibility: Map.get(context, :responsibility),
      runtime_attempt_id: Map.get(context, :runtime_attempt_id, :transition_coordinator),
      lineage_generation: Map.get(context, :lineage_generation, 0)
    }

    assessment = LifecycleAssessment.assess(observation, prior_state, evidence, assessment_context)
    {:ok, assessment}
  end

  defp validate_observation_scope(%ProviderObservation{} = observation, %ProviderProjectContract{} = contract) do
    if observation.workspace_id == contract.workspace_id and observation.project_id == contract.project_id do
      :ok
    else
      {:error, :wrong_project}
    end
  end

  defp validate_observation_scope(_observation, _contract),
    do: {:error, :provider_project_contract_required}

  defp default_submit(%TransitionAttempt{} = attempt, context) do
    opts =
      []
      |> maybe_put_option(:tracker_settings, Map.get(context, :tracker_settings))
      |> maybe_put_option(:provider_project_contract, Map.get(context, :provider_project_contract))
      |> maybe_put_option(:pre_observation, Map.get(context, :provider_observation))

    Tracker.controlled_transition(attempt.work_item_id, attempt.requested_to, opts)
  end

  defp maybe_put_option(opts, _key, nil), do: opts
  defp maybe_put_option(opts, key, value), do: Keyword.put(opts, key, value)

  defp default_verify(%TransitionAttempt{} = attempt, context, refresh_contract) do
    with {:ok, context} <- refresh_contract_context(context, refresh_contract),
         {:ok, [%Issue{} = issue]} <- Tracker.fetch_issues_by_ids([attempt.work_item_id]),
         {:ok, observation} <- ProviderObservation.from_issue(issue, provider_observation_opts(context)),
         :ok <- validate_observation_scope(observation, Map.get(context, :provider_project_contract)),
         {:ok, assessment} <-
           fresh_assessment(
             observation,
             attempt.requested_from,
             attempt.guard_evidence,
             context
             |> Map.put(:responsibility, attempt.responsibility)
             |> Map.put_new(:runtime_attempt_id, attempt.runtime_attempt_id)
             |> Map.put_new(:lineage_generation, attempt.lineage_generation)
           ) do
      if assessment.status == :validated and assessment.validated_state == attempt.requested_to do
        {:verified,
         %{
           assessment: assessment,
           post_observation_evidence: observation,
           provider_project_contract: Map.get(context, :provider_project_contract),
           post_contract_fingerprint: contract_fingerprint(Map.get(context, :provider_project_contract)),
           work_item: Map.get(context, :work_item),
           context_token: Map.get(context, :context_token),
           status: :validated
         }}
      else
        {:indeterminate,
         %{
           reason: :target_not_confirmed,
           assessment: assessment,
           post_observation_evidence: observation,
           provider_project_contract: Map.get(context, :provider_project_contract),
           post_contract_fingerprint: contract_fingerprint(Map.get(context, :provider_project_contract)),
           work_item: Map.get(context, :work_item),
           context_token: Map.get(context, :context_token)
         }}
      end
    else
      {:ok, []} -> {:indeterminate, :work_item_not_found}
      {:error, reason} -> {:indeterminate, {:fresh_verification_unavailable, reason}}
      _other -> {:indeterminate, :fresh_verification_unavailable}
    end
  end

  defp default_apply_verified(orchestrator, %TransitionAttempt{} = attempt, context)
       when is_map(context) do
    case build_verified_work_item(attempt, context) do
      {:ok, %WorkItem{} = work_item} ->
        Orchestrator.apply_transition_result(
          orchestrator,
          attempt.work_item_id,
          work_item,
          expected_context_token: Map.get(context, :context_token)
        )

      {:error, _reason} ->
        Orchestrator.request_refresh(orchestrator)
    end
  end

  defp default_apply_verified(orchestrator, _attempt, _context),
    do: Orchestrator.request_refresh(orchestrator)

  defp contract_fingerprint(%ProviderProjectContract{} = contract),
    do: ProviderProjectContract.fingerprint(contract)

  defp contract_fingerprint(_contract), do: nil

  defp build_verified_work_item(
         %TransitionAttempt{} = attempt,
         %{
           assessment: %LifecycleAssessment{},
           post_observation_evidence: %ProviderObservation{} = observation,
           provider_project_contract: %ProviderProjectContract{} = contract,
           work_item: %WorkItem{} = prior
         }
       ) do
    issue = %Issue{
      id: prior.id,
      native_ref: prior.native_ref,
      identifier: prior.identifier,
      title: prior.title,
      description: prior.description,
      priority: prior.priority,
      state: observation.provider_state_name,
      branch_name: prior.branch_name,
      url: prior.url,
      assignee_id: prior.assignee_id,
      workspace_id: observation.workspace_id,
      project_id: observation.project_id,
      provider_state_id: observation.provider_state_id,
      provider_state_group: observation.provider_state_group,
      blocked_by: prior.blocked_by,
      dependency_completeness: prior.dependency_completeness,
      labels: prior.labels,
      dispatchable: prior.validated_lifecycle_state == :ready,
      created_at: prior.created_at,
      updated_at: observation.provider_updated_at || prior.updated_at
    }

    WorkItem.from_issue(issue, %{
      provider: :plane,
      observed_at: observation.observed_at,
      prior_validated_lifecycle_state: attempt.requested_from,
      prior_authority_disposition: prior.authority_disposition,
      evidence: attempt.guard_evidence,
      provider_project_contract: contract
    })
  end

  defp build_verified_work_item(_attempt, _context), do: {:error, :verified_projection_unavailable}
end
