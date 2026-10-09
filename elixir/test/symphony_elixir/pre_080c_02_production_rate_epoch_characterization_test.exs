defmodule SymphonyElixir.Pre080C02.Clock do
  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec monotonic(pid()) :: integer()
  def monotonic(pid), do: GenServer.call(pid, :monotonic)

  @spec system(pid()) :: integer()
  def system(pid), do: GenServer.call(pid, :system)

  @spec schedule(pid(), pid(), term(), non_neg_integer()) :: reference()
  def schedule(pid, destination, message, delay) do
    GenServer.call(pid, {:schedule, destination, message, delay})
  end

  @spec advance_next(pid()) :: :advanced | :empty
  def advance_next(pid), do: GenServer.call(pid, :advance_next)

  @spec advance(pid(), non_neg_integer()) :: :ok
  def advance(pid, delta) when is_integer(delta) and delta >= 0, do: GenServer.call(pid, {:advance, delta})

  @spec now(pid()) :: integer()
  def now(pid), do: monotonic(pid)

  @impl true
  def init(opts) do
    {:ok, %{now: 0, unix_ms: Keyword.get(opts, :unix_ms, 1_800_000_000_000), timers: [], next_sequence: 0}}
  end

  @impl true
  def handle_call(:monotonic, _from, state), do: {:reply, state.now, state}
  def handle_call(:system, _from, state), do: {:reply, state.unix_ms + state.now, state}

  def handle_call({:schedule, destination, message, delay}, _from, state) do
    ref = make_ref()
    timer = %{ref: ref, due_at: state.now + delay, sequence: state.next_sequence, destination: destination, message: message}
    {:reply, ref, %{state | timers: [timer | state.timers], next_sequence: state.next_sequence + 1}}
  end

  def handle_call(:advance_next, _from, %{timers: []} = state), do: {:reply, :empty, state}

  def handle_call(:advance_next, _from, state) do
    timers = Enum.sort_by(state.timers, &{&1.due_at, &1.sequence})

    case Enum.find_index(timers, &Process.alive?(&1.destination)) do
      nil ->
        {:reply, :empty, %{state | timers: []}}

      index ->
        timer = Enum.at(timers, index)
        {:reply, :advanced, advance_state(state, timer.due_at)}
    end
  end

  def handle_call({:advance, delta}, _from, state) do
    {:reply, :ok, advance_state(state, state.now + delta)}
  end

  defp advance_state(state, target_time) do
    timers = Enum.sort_by(state.timers, &{&1.due_at, &1.sequence})
    {due, future} = Enum.split_while(timers, &(&1.due_at <= target_time))

    Enum.each(due, fn timer ->
      if Process.alive?(timer.destination), do: send(timer.destination, timer.message)
    end)

    %{state | now: max(state.now, target_time), timers: future}
  end
end

defmodule SymphonyElixir.Pre080C02.Provider do
  alias SymphonyElixir.Plane.Adapter

  @spec fetch_project_snapshot(keyword()) :: term()
  def fetch_project_snapshot(opts) do
    Adapter.fetch_project_snapshot(Keyword.put(opts, :request_fun, request_fun()))
  end

  @spec fetch_dependency_graph(keyword()) :: term()
  def fetch_dependency_graph(opts) do
    Adapter.fetch_dependency_graph(Keyword.put(opts, :request_fun, request_fun()))
  end

  @spec fetch_issues_by_ids([String.t()], keyword()) :: term()
  def fetch_issues_by_ids(ids, opts) do
    Adapter.fetch_issues_by_ids(ids, Keyword.put(opts, :request_fun, request_fun()))
  end

  defp request_fun, do: Application.fetch_env!(:symphony_elixir, :pre_080c_02_request_fun)
end

defmodule SymphonyElixir.Pre080C02.Runner do
  @spec run(SymphonyElixir.Tracker.Issue.t(), pid(), keyword()) :: :ok
  def run(issue, _recipient, _opts) do
    test_pid = Application.fetch_env!(:symphony_elixir, :pre_080c_02_test_pid)
    send(test_pid, {:pre_080c_02_runner_started, self(), issue.id})

    receive do
      :release_pre_080c_02_runner -> :ok
    after
      30_000 -> :ok
    end
  end
end

defmodule SymphonyElixir.Pre080C02ProductionRateEpochCharacterizationTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.AgentRuntimeSupervisor
  alias SymphonyElixir.Dependency.Graph
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Plane.{Adapter, Client, ReadScheduler}
  alias SymphonyElixir.Plane.WebhookDelivery.EventIdentity
  alias SymphonyElixir.Pre080C02.Clock
  alias SymphonyElixir.Pre080C02.Provider
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.WorkControl.{AuthorityDisposition, LifecycleAssessment, ProviderObservation, WorkItem}
  alias SymphonyElixir.Workflow
  alias SymphonyElixir.WorkflowStore

  @scope %{
    workspace_slug: "workspace-1",
    workspace_id: "00000000-0000-4000-8000-000000000001",
    project_id: "00000000-0000-4000-8000-000000000002"
  }
  @state_names %{
    backlog: "Backlog",
    planning: "Planning",
    ready: "Ready",
    in_progress: "In Progress",
    in_review: "In Review",
    changes_requested: "Changes Requested",
    ready_to_merge: "Ready to Merge",
    merging: "Merging",
    blocked: "Blocked",
    done: "Done",
    canceled: "Canceled"
  }
  @state_groups %{
    backlog: "backlog",
    planning: "unstarted",
    ready: "unstarted",
    in_progress: "started",
    in_review: "started",
    changes_requested: "started",
    ready_to_merge: "started",
    merging: "started",
    blocked: "started",
    done: "completed",
    canceled: "cancelled"
  }
  @required_item_counts [1_000, 5_000, 10_000]
  @record_fields [
    :item_count,
    :edge_count,
    :work_item_page_gets,
    :relation_logical_gets,
    :project_gets,
    :state_page_gets,
    :total_logical_gets,
    :scheduler_attempt_starts,
    :retry_attempts,
    :request_start_timestamp_counts,
    :request_class_counts,
    :max_starts_per_rolling_window,
    :peak_in_flight,
    :queue_high_water,
    :control_start_latency_ms,
    :orchestrator_snapshot_latency_ms,
    :modeled_last_start_ms,
    :test_wall_elapsed_ms,
    :test_cpu_elapsed_ms,
    :epoch_count,
    :published_epoch_count,
    :superseded_epoch_count,
    :full_reacquisition_count,
    :targeted_read_count,
    :scc_pass_count,
    :final_epoch_status,
    :graph_complete,
    :observed_node_count,
    :observed_edge_count,
    :dispatch_authority_during_acquisition,
    :orchestrator_mailbox_high_water,
    :scheduler_mailbox_high_water,
    :acquisition_task_memory_high_water,
    :acquisition_task_mailbox_high_water,
    :orchestrator_memory_bytes,
    :orchestrator_memory_baseline_bytes,
    :scheduler_memory_baseline_bytes,
    :beam_total_memory_baseline_bytes,
    :beam_total_memory_high_water_bytes,
    :orchestrator_memory_published_bytes,
    :scheduler_memory_published_bytes,
    :scheduler_memory_bytes,
    :process_count_delta,
    :process_count_baseline,
    :process_count_after_completion,
    :task_supervisor_children_high_water,
    :task_supervisor_children_after_completion,
    :provider_attempt_starts,
    :epoch_logical_requests,
    :epoch_attempts,
    :initial_epoch_status,
    :coverage_generation,
    :required_generation,
    :scheduler_queue_after_completion,
    :scheduler_in_flight_after_completion,
    :orchestrator_mailbox_after_completion,
    :scheduler_mailbox_after_completion,
    :graph_external_size_bytes,
    :post_gc_total_memory_bytes,
    :dispatch_unavailable_duration_ms
  ]

  @tag timeout: 900_000
  test "characterizes production-paced complete Plane epochs at the supported size boundaries" do
    for item_count <- @required_item_counts do
      result = run_epoch(item_count)
      assert result.item_count == item_count
      page_count = div(item_count + 99, 100)
      assert result.work_item_page_gets == 2 * page_count
      assert result.relation_logical_gets == item_count
      assert result.project_gets == 2
      assert result.state_page_gets == 2

      assert result.total_logical_gets ==
               item_count + result.work_item_page_gets + result.project_gets + result.state_page_gets

      assert result.total_logical_gets == item_count + 2 * page_count + 4
      assert result.retry_attempts == 0
      assert result.scheduler_attempt_starts == result.total_logical_gets + result.retry_attempts
      assert result.provider_attempt_starts == result.scheduler_attempt_starts
      assert result.epoch_logical_requests == result.total_logical_gets
      assert result.epoch_attempts == result.scheduler_attempt_starts

      assert result.request_class_counts == %{
               bulk_relation: item_count,
               bulk_enumeration: 2 * div(item_count + 99, 100),
               bulk_states: 2,
               control_project: 2
             }

      assert List.first(result.request_start_timestamp_counts) == [0, 60]
      assert result.max_starts_per_rolling_window <= 60
      assert rolling_window_spacing_valid?(result.provider_request_records, 60_000)
      assert result.peak_in_flight <= 4
      assert result.epoch_count == 1
      assert result.published_epoch_count == 1
      assert result.superseded_epoch_count == 0
      assert result.scc_pass_count == 1
      assert result.final_epoch_status == :current
      assert result.initial_epoch_status == :refreshing
      refute result.dispatch_authority_during_acquisition
      assert result.coverage_generation == 0
      assert result.coverage_generation == result.required_generation
      assert result.scheduler_queue_after_completion == 0
      assert result.scheduler_in_flight_after_completion == 0
      assert result.task_supervisor_children_after_completion == 0
      assert result.task_supervisor_children_high_water <= 1
      assert result.orchestrator_mailbox_after_completion == 0
      assert result.scheduler_mailbox_after_completion == 0
      assert result.acquisition_task_mailbox_high_water >= 0
      assert result.graph_complete
      assert result.orchestrator_snapshot_latency_ms >= 0
      assert result.queue_high_water <= 64
      assert result.process_count_delta < item_count
      assert result.process_count_after_completion <= result.process_count_baseline + 32
      assert result.modeled_last_start_ms == max(div(result.scheduler_attempt_starts - 1, 60) * 60_000, 0)
      assert result.observed_node_count == item_count
      assert result.observed_edge_count == item_count * 5

      record = Enum.map(@record_fields, fn key -> [Atom.to_string(key), Map.fetch!(result, key)] end)
      IO.puts("PRE-080C-02 " <> Jason.encode!(record))
    end
  end

  test "virtual clock advances explicitly and delivers due timers in stable order" do
    {:ok, clock} = Clock.start_link(unix_ms: 1_000_000)
    Clock.schedule(clock, self(), :first, 5)
    Clock.schedule(clock, self(), :second, 5)
    Clock.schedule(clock, self(), :later, 10)

    assert :ok = Clock.advance(clock, 5)
    assert Clock.now(clock) == 5
    assert Clock.system(clock) == 1_000_005
    assert_receive :first
    assert_receive :second
    refute_receive :later

    assert :ok = Clock.advance(clock, 5)
    assert Clock.now(clock) == 10
    assert_receive :later
    GenServer.stop(clock)
  end

  test "shared Plane control reads wait for pacing capacity and jump queued bulk work" do
    {:ok, clock} = Clock.start_link([])
    {:ok, log} = Agent.start_link(fn -> [] end)

    time_provider = %{
      monotonic_time: fn -> Clock.monotonic(clock) end,
      system_time: fn -> Clock.system(clock) end,
      send_after: fn destination, message, delay -> Clock.schedule(clock, destination, message, delay) end
    }

    {:ok, scheduler} =
      ReadScheduler.start_link(
        max_concurrency: 4,
        queue_limit: 64,
        start_limit: 60,
        start_window_ms: 60_000,
        time_provider: time_provider
      )

    on_exit(fn ->
      stop_process(scheduler)
      stop_process(clock)
      stop_process(log)
    end)

    config = %{
      base_url: "https://api.plane.so",
      workspace_slug: "workspace-1",
      workspace_id: "workspace-stable-1",
      project_id: @scope.project_id,
      api_key: "test-key"
    }

    project_id = @scope.project_id

    request_fun = fn request ->
      Agent.update(log, &[%{path: request.path, at: Clock.now(clock)} | &1])

      body =
        if String.contains?(request.path, "/relations/"),
          do: %{"blocked_by" => [], "blocking" => []},
          else: %{"id" => @scope.project_id, "name" => "Project", "workspace_slug" => "workspace-1"}

      {:ok, %{status: 200, body: body}}
    end

    for _ <- 1..60 do
      assert {:ok, %{"id" => ^project_id}} = Client.get_project(config, scheduler: scheduler, request_fun: request_fun)
    end

    submitted_at = Clock.now(clock)

    bulk =
      Task.async(fn ->
        Client.get_work_item_relations(config, "item-1", scheduler: scheduler, request_fun: request_fun)
      end)

    control =
      Task.async(fn ->
        result = Client.get_project(config, scheduler: scheduler, request_fun: request_fun)
        {result, Clock.now(clock)}
      end)

    eventually(fn -> ReadScheduler.stats(scheduler).queue_length == 2 end)
    refute Enum.any?(Agent.get(log, & &1), &(&1.at > submitted_at))
    assert :advanced = Clock.advance_next(clock)

    assert eventually(fn ->
             Enum.any?(Agent.get(log, & &1), &(&1.path =~ "/projects/#{@scope.project_id}/" and &1.at == 60_000))
           end)

    assert Enum.all?(Enum.filter(Agent.get(log, & &1), &(&1.at == 60_000)), &(&1.path =~ "/projects/#{@scope.project_id}/"))

    assert {:ok, %{"blocked_by" => [], "blocking" => []}} = Task.await(bulk, 1_000)
    assert {{:ok, %{"id" => ^project_id}}, completed_at} = Task.await(control, 1_000)
    assert completed_at == 60_000

    starts = Agent.get(log, &Enum.reverse(&1))
    assert length(starts) == 62
    assert starts |> Enum.at(60) |> Map.fetch!(:path) =~ "/projects/#{@scope.project_id}/"
    assert starts |> Enum.at(61) |> Map.fetch!(:path) =~ "/relations/"

    IO.puts(
      "PRE-080C-02 " <>
        Jason.encode!([
          ["scenario", "shared_control_read"],
          ["window_limit", 60],
          ["window_ms", 60_000],
          ["queued_bulk_ahead", 1],
          ["control_start_ms", 60_000],
          ["control_completion_ms", completed_at],
          ["start_order_at_reopen", ["control_project", "bulk_relation"]]
        ])
    )
  end

  test "available pacing quota lets a queued control Client read go before bulk work" do
    parent = self()
    {:ok, clock} = Clock.start_link([])
    {:ok, sequence} = Agent.start_link(fn -> 0 end)

    time_provider = %{
      monotonic_time: fn -> Clock.monotonic(clock) end,
      system_time: fn -> Clock.system(clock) end,
      send_after: fn destination, message, delay -> Clock.schedule(clock, destination, message, delay) end
    }

    {:ok, scheduler} =
      ReadScheduler.start_link(
        max_concurrency: 1,
        queue_limit: 5,
        start_limit: 60,
        start_window_ms: 60_000,
        time_provider: time_provider
      )

    on_exit(fn ->
      stop_process(scheduler)
      stop_process(clock)
      stop_process(sequence)
    end)

    config = %{
      base_url: "https://api.plane.so",
      workspace_slug: "workspace-1",
      workspace_id: "workspace-stable-1",
      project_id: @scope.project_id,
      api_key: "test-key"
    }

    project_id = @scope.project_id

    request_fun = fn request ->
      call_index = Agent.get_and_update(sequence, &{&1, &1 + 1})
      kind = if call_index == 0, do: :initial, else: if(String.contains?(request.path, "/relations/"), do: :bulk, else: :control)
      send(parent, {:client_request_started, kind, self()})

      if kind == :initial do
        receive do
          :release_initial_request -> :ok
        end
      end

      body =
        if kind == :bulk,
          do: %{"blocked_by" => [], "blocking" => []},
          else: %{"id" => @scope.project_id, "name" => "Project", "workspace_slug" => "workspace-1"}

      {:ok, %{status: 200, body: body}}
    end

    initial = Task.async(fn -> Client.get_project(config, scheduler: scheduler, request_fun: request_fun) end)
    assert_receive {:client_request_started, :initial, initial_request_pid}

    bulk = Task.async(fn -> Client.get_work_item_relations(config, "item-1", scheduler: scheduler, request_fun: request_fun) end)
    control = Task.async(fn -> Client.get_project(config, scheduler: scheduler, request_fun: request_fun) end)
    assert eventually(fn -> ReadScheduler.stats(scheduler).queue_length == 2 end)

    send(initial_request_pid, :release_initial_request)

    assert_receive {:client_request_started, :control, _control_request_pid}
    assert_receive {:client_request_started, :bulk, _bulk_request_pid}
    assert {:ok, %{"id" => ^project_id}} = Task.await(initial, 1_000)
    assert {:ok, %{"id" => ^project_id}} = Task.await(control, 1_000)
    assert {:ok, %{"blocked_by" => [], "blocking" => []}} = Task.await(bulk, 1_000)
    assert ReadScheduler.stats(scheduler).attempts == 3

    stop_process(scheduler)
    stop_process(clock)
    stop_process(sequence)
  end

  test "Orchestrator targeted control reads share the scheduler with an active bulk epoch" do
    available = start_runtime(1_000, nil, nil, false)
    on_exit(fn -> stop_runtime(available) end)
    Agent.update(available.provider, &%{&1 | hold_bulk_relations?: true})
    send(available.orchestrator, :tick)

    active_epoch_started? =
      eventually(
        fn ->
          stats = ReadScheduler.stats(available.scheduler)

          stats.current_concurrency == 4 and
            length(Agent.get(available.provider, & &1.held_provider_requests)) == 4 and
            :sys.get_state(available.orchestrator).plane_epoch_status == :refreshing
        end,
        200
      )

    assert active_epoch_started?,
           inspect({ReadScheduler.stats(available.scheduler), Map.take(:sys.get_state(available.orchestrator), [:plane_epoch_status, :plane_epoch_task])})

    initial_held = Agent.get(available.provider, & &1.held_provider_requests)
    assert length(initial_held) == 4

    config = %{
      base_url: "https://api.plane.so",
      workspace_slug: "workspace-1",
      workspace_id: @scope.workspace_id,
      project_id: @scope.project_id,
      api_key: "test-key"
    }

    request_fun = Application.fetch_env!(:symphony_elixir, :pre_080c_02_request_fun)

    queued_bulk =
      Task.async(fn ->
        Client.get_work_item_relations(config, "item-999", scheduler: available.scheduler, request_fun: request_fun)
      end)

    assert eventually(fn -> ReadScheduler.stats(available.scheduler).queued_bulk > 0 end)
    assert {:ok, :scheduled} = Orchestrator.accept_plane_webhook(available.orchestrator, item_event(40_010, "item-0"))

    assert eventually(fn ->
             stats = ReadScheduler.stats(available.scheduler)
             stats.queued_control == 1 and stats.queued_bulk > 0
           end)

    starts_before_release = length(Agent.get(available.provider, & &1.starts))

    send(hd(initial_held), :release_held_provider_request)

    assert eventually(fn ->
             Agent.get(available.provider, fn state -> Enum.count(state.starts, &direct_item_path?(&1.path)) == 1 end)
           end)

    available_control_start =
      Agent.get(available.provider, & &1.starts)
      |> Enum.find(&direct_item_path?(&1.path))

    assert available_control_start.timestamp == 0
    assert length(Agent.get(available.provider, & &1.starts)) > starts_before_release
    Agent.update(available.provider, &%{&1 | hold_bulk_relations?: false})
    Enum.each(Agent.get(available.provider, & &1.held_provider_requests), &send(&1, :release_held_provider_request))
    assert {:ok, %{"blocked_by" => _blocked_by, "blocking" => _blocking}} = Task.await(queued_bulk, 1_000)
    drive_until_current(available.orchestrator, available.scheduler, available.clock, available.process_baseline, 1_000)

    assert eventually(fn ->
             state = :sys.get_state(available.orchestrator)
             map_size(state.plane_webhook_tasks) == 0 and map_size(state.plane_webhook_pending) == 0
           end)

    exhausted = start_runtime(1_000)
    on_exit(fn -> stop_runtime(exhausted) end)
    assert await_pacing_boundary(exhausted.scheduler)
    assert ReadScheduler.stats(exhausted.scheduler).queued_bulk > 0
    assert {:ok, :scheduled} = Orchestrator.accept_plane_webhook(exhausted.orchestrator, item_event(40_011, "item-0"))
    assert eventually(fn -> ReadScheduler.stats(exhausted.scheduler).queued_control == 1 end)
    refute Enum.any?(Agent.get(exhausted.provider, & &1.starts), &direct_item_path?(&1.path))

    assert advance_clock_until(exhausted.clock, fn ->
             starts = Agent.get(exhausted.provider, & &1.starts)
             Enum.any?(starts, &direct_item_path?(&1.path))
           end)

    exhausted_control_start =
      Agent.get(exhausted.provider, & &1.starts)
      |> Enum.find(&direct_item_path?(&1.path))

    assert exhausted_control_start.timestamp == 60_000
    drive_until_current(exhausted.orchestrator, exhausted.scheduler, exhausted.clock, exhausted.process_baseline, 1_000)

    assert eventually(fn ->
             state = :sys.get_state(exhausted.orchestrator)
             map_size(state.plane_webhook_tasks) == 0 and map_size(state.plane_webhook_pending) == 0
           end)

    available_control_completion =
      Agent.get(available.provider, & &1.completions)
      |> Enum.find(&direct_item_path?(&1.path))

    exhausted_control_completion =
      Agent.get(exhausted.provider, & &1.completions)
      |> Enum.find(&direct_item_path?(&1.path))

    assert available_control_completion.timestamp == available_control_start.timestamp
    assert exhausted_control_completion.timestamp == exhausted_control_start.timestamp

    IO.puts(
      "PRE-080C-02 " <>
        Jason.encode!([
          ["scenario", "orchestrator_control_reads_during_bulk_epoch"],
          ["active_bulk_epoch", true],
          ["available_quota_control_start_ms", available_control_start.timestamp],
          ["available_quota_control_completion_ms", available_control_completion.timestamp],
          ["exhausted_quota_control_start_ms", exhausted_control_start.timestamp],
          ["exhausted_quota_control_completion_ms", exhausted_control_completion.timestamp],
          ["shared_window_limit", 60],
          ["shared_window_ms", 60_000],
          ["available_quota_queue_priority", true],
          ["exhausted_quota_delay_ms", exhausted_control_start.timestamp],
          ["available_quota_targeted_work_drained", true],
          ["exhausted_quota_targeted_work_drained", true]
        ])
    )

    stop_runtime(available)
    stop_runtime(exhausted)
  end

  test "webhook delivery and event identities are deduplicated before targeted reads" do
    runtime = start_runtime(1_000)
    on_exit(fn -> stop_runtime(runtime) end)
    drive_until_current(runtime.orchestrator, runtime.scheduler, runtime.clock, runtime.process_baseline, 1_000)

    Agent.update(runtime.provider, &%{&1 | hold_targeted_ids: MapSet.new(["item-0"])})
    identity = item_event(40_001, "item-0")
    assert {:ok, :scheduled} = Orchestrator.accept_plane_webhook(runtime.orchestrator, identity)
    assert advance_clock_until(runtime.clock, fn -> is_pid(Agent.get(runtime.provider, & &1.held_targeted_request)) end)
    after_first = :sys.get_state(runtime.orchestrator)
    assert {:ok, :duplicate_delivery} = Orchestrator.accept_plane_webhook(runtime.orchestrator, identity)

    duplicate_event = %{identity | delivery_id: "00000000-0000-4000-8002-000000009c42"}
    assert {:ok, :duplicate_event} = Orchestrator.accept_plane_webhook(runtime.orchestrator, duplicate_event)

    after_duplicates = :sys.get_state(runtime.orchestrator)
    snapshot = Orchestrator.snapshot(runtime.orchestrator, 1_000)
    starts = Agent.get(runtime.provider, &Enum.reverse(&1.starts))
    targeted_starts = Enum.count(starts, &direct_item_path?(&1.path))

    assert snapshot.plane_webhook.duplicate_delivery == 1
    assert snapshot.plane_webhook.duplicate_event == 1
    assert map_size(after_duplicates.plane_webhook_tasks) == map_size(after_first.plane_webhook_tasks)
    assert map_size(after_duplicates.plane_webhook_pending) == map_size(after_first.plane_webhook_pending)
    assert after_duplicates.plane_epoch_task == after_first.plane_epoch_task
    assert targeted_starts == 1
    held_targeted_request = Agent.get(runtime.provider, & &1.held_targeted_request)
    send(held_targeted_request, :release_held_targeted_request)

    drained? =
      advance_clock_until(runtime.clock, fn ->
        state = :sys.get_state(runtime.orchestrator)
        map_size(state.plane_webhook_tasks) == 0 and map_size(state.plane_webhook_pending) == 0
      end)

    assert drained?, "duplicate webhook targeted work did not drain after release"

    IO.puts(
      "PRE-080C-02 " <>
        Jason.encode!([
          ["scenario", "webhook_identity_deduplication"],
          ["duplicate_delivery", snapshot.plane_webhook.duplicate_delivery],
          ["duplicate_event", snapshot.plane_webhook.duplicate_event],
          ["targeted_reads", targeted_starts],
          ["request_starts_after_duplicate_deliveries", 0]
        ])
    )
  end

  test "distinct targeted webhook items stay separate within available capacity" do
    runtime = start_runtime(1_000)
    on_exit(fn -> stop_runtime(runtime) end)
    drive_until_current(runtime.orchestrator, runtime.scheduler, runtime.clock, runtime.process_baseline, 1_000)
    ids = Enum.map(0..4, &"item-#{&1}")
    Agent.update(runtime.provider, &%{&1 | hold_targeted_ids: MapSet.new(ids)})

    results =
      ids
      |> Enum.with_index(41_000)
      |> Enum.map(fn {id, sequence} -> Orchestrator.accept_plane_webhook(runtime.orchestrator, item_event(sequence, id)) end)

    assert Enum.all?(results, &(&1 == {:ok, :scheduled}))
    assert advance_clock_until(runtime.clock, fn -> length(Agent.get(runtime.provider, & &1.held_targeted_requests)) == 2 end)

    held_state = :sys.get_state(runtime.orchestrator)
    provider_before_release = Agent.get(runtime.provider, & &1)
    assert map_size(held_state.plane_webhook_tasks) == 2
    assert map_size(held_state.plane_webhook_pending) == 3
    assert :queue.len(held_state.plane_webhook_queue) == 3
    assert held_state.plane_epoch_status == :current
    assert is_nil(held_state.plane_webhook_full_epoch_dirty_generation)
    assert Enum.count(provider_before_release.starts, &String.ends_with?(&1.path, "/work-items/")) == 20

    Agent.update(runtime.provider, &%{&1 | hold_targeted_ids: MapSet.new()})
    Enum.each(provider_before_release.held_targeted_requests, &send(&1, :release_held_targeted_request))

    drained? =
      advance_clock_until(runtime.clock, fn ->
        state = :sys.get_state(runtime.orchestrator)
        map_size(state.plane_webhook_tasks) == 0 and map_size(state.plane_webhook_pending) == 0
      end)

    assert drained?, "distinct webhook targeted work did not drain after release"

    IO.puts(
      "PRE-080C-02 " <>
        Jason.encode!([
          ["scenario", "distinct_targeted_items_inside_capacity"],
          ["distinct_items", length(ids)],
          ["in_flight_peak", 2],
          ["pending_peak", 3],
          ["full_epoch_dirty_generation", held_state.plane_webhook_full_epoch_dirty_generation]
        ])
    )
  end

  test "runtime supervisor keeps the production one-for-all child topology" do
    assert {:ok, {flags, children}} =
             AgentRuntimeSupervisor.init(name: Module.concat(__MODULE__, "TopologyCheck"))

    assert flags.strategy == :one_for_all

    assert Enum.map(children, &elem(&1.start, 0)) == [
             SymphonyElixir.Plane.ReadScheduler,
             Task.Supervisor,
             SymphonyElixir.Orchestrator,
             SymphonyElixir.TransitionCoordinator
           ]
  end

  test "rejects a provider item-set mutation between opening and closing enumeration" do
    {:ok, scheduler} = ReadScheduler.start_link()
    settings = SymphonyElixir.Config.settings!().tracker
    enumeration = Agent.start_link(fn -> 0 end) |> elem(1)

    on_exit(fn ->
      stop_process(scheduler)
      stop_process(enumeration)
    end)

    request_fun = fn request ->
      cond do
        String.ends_with?(request.path, "/work-items/") ->
          enumeration_index = Agent.get_and_update(enumeration, &{&1, &1 + 1})
          item = if enumeration_index == 0, do: item(0), else: item(1)
          {:ok, %{status: 200, body: page([item], 1)}}

        String.ends_with?(request.path, "/relations/") ->
          {:ok, %{status: 200, body: %{"blocked_by" => [], "blocking" => []}}}
      end
    end

    assert {:error, :node_set_changed} =
             Adapter.fetch_dependency_graph(
               tracker_settings: settings,
               request_fun: request_fun,
               scheduler: scheduler
             )

    assert Agent.get(enumeration, & &1) == 2
    assert ReadScheduler.stats(scheduler).attempts == 3

    record = [
      ["scenario", "provider_set_mutation"],
      ["logical_request_count", 3],
      ["result", "node_set_changed"],
      ["graph_published", false]
    ]

    IO.puts("PRE-080C-02 " <> Jason.encode!(record))
  end

  test "repeated signalled edits supersede epochs until a quiet acquisition publishes" do
    runtime = start_runtime(1_000)

    initial =
      drive_until_current(runtime.orchestrator, runtime.scheduler, runtime.clock, runtime.process_baseline, 1_000)

    initial_state = :sys.get_state(runtime.orchestrator)
    assert initial_state.plane_epoch_status == :current
    edit_window_started_at = Clock.now(runtime.clock)

    dispatch_candidate =
      runtime.orchestrator
      |> :sys.get_state()
      |> Map.fetch!(:dependency_graph)
      |> Map.fetch!(:nodes)
      |> Map.fetch!("item-0")
      |> dispatchable_work_item()

    :sys.replace_state(runtime.orchestrator, fn state ->
      %{state | work_control: Map.put(state.work_control, dispatch_candidate.id, dispatch_candidate)}
    end)

    Agent.update(runtime.provider, &%{&1 | relation_revision: 1})
    assert {:ok, :scheduled} = Orchestrator.accept_plane_webhook(runtime.orchestrator, project_event(1))
    refreshing = :sys.get_state(runtime.orchestrator)
    assert refreshing.plane_epoch_status == :refreshing
    assert is_map(refreshing.plane_epoch_task)
    assert Graph.complete?(refreshing.dependency_graph)

    dispatchable_ids =
      for {id, work_item} <- refreshing.work_control,
          WorkItem.dispatchable?(work_item),
          do: id

    assert dispatchable_ids != []
    running_before_refresh_poll = Map.keys(refreshing.running) |> MapSet.new()
    send(runtime.orchestrator, :run_poll_cycle)
    during_refresh_poll = :sys.get_state(runtime.orchestrator)
    assert MapSet.new(Map.keys(during_refresh_poll.running)) == running_before_refresh_poll
    assert during_refresh_poll.plane_epoch_status == :refreshing
    refute_receive {:pre_080c_02_runner_started, _runner_pid, _issue_id}, 20

    Agent.update(runtime.provider, &%{&1 | relation_revision: 2})
    assert {:ok, :scheduled} = Orchestrator.accept_plane_webhook(runtime.orchestrator, project_event(2))
    assert {:ok, :scheduled} = Orchestrator.accept_plane_webhook(runtime.orchestrator, project_event(3))
    after_churn = :sys.get_state(runtime.orchestrator)
    assert after_churn.plane_epoch_task.pid == refreshing.plane_epoch_task.pid
    assert after_churn.plane_epoch_task.coverage_generation < after_churn.plane_reconciliation_generation

    superseded_pid = refreshing.plane_epoch_task.pid

    driver =
      Task.async(fn ->
        drive_until_current(runtime.orchestrator, runtime.scheduler, runtime.clock, runtime.process_baseline, 1_000)
      end)

    assert eventually(fn ->
             state = :sys.get_state(runtime.orchestrator)
             state.plane_epoch_status == :refreshing and state.plane_epoch_task.pid != superseded_pid
           end)

    third_epoch = :sys.get_state(runtime.orchestrator)
    assert third_epoch.dependency_graph == initial_state.dependency_graph
    assert third_epoch.plane_epoch_coverage_generation == initial_state.plane_epoch_coverage_generation
    assert third_epoch.plane_epoch_coverage_generation < third_epoch.plane_epoch_task.coverage_generation
    refute Process.alive?(superseded_pid)
    Agent.update(runtime.provider, &%{&1 | relation_revision: 4})
    assert {:ok, :scheduled} = Orchestrator.accept_plane_webhook(runtime.orchestrator, project_event(4))
    assert :sys.get_state(runtime.orchestrator).plane_epoch_task.pid == third_epoch.plane_epoch_task.pid
    state_after_signals = :sys.get_state(runtime.orchestrator)

    assert state_after_signals.plane_epoch_task.coverage_generation <
             state_after_signals.plane_reconciliation_generation

    follow_up = Task.await(driver, 10_000)
    final = :sys.get_state(runtime.orchestrator)
    provider_stats = Agent.get(runtime.provider, & &1)

    assert final.plane_epoch_status == :current
    assert is_nil(final.plane_epoch_task)
    assert final.plane_epoch_coverage_generation >= final.plane_reconciliation_generation
    assert is_nil(final.plane_webhook_full_epoch_dirty_generation)
    assert Graph.complete?(final.dependency_graph)
    assert length(provider_stats.starts) == 4 * (1_000 + 2 * 10 + 4)
    assert "item-999" in Map.fetch!(final.dependency_graph.edges, "item-5")
    assert final.plane_epoch_coverage_generation > initial_state.plane_epoch_coverage_generation

    assert follow_up.process_count_high_water < runtime.process_baseline + 100
    assert initial.process_count_high_water < runtime.process_baseline + 100

    epoch_count = div(length(provider_stats.starts), 1_024)

    published_epoch_count =
      Enum.count([initial_state, final], fn state ->
        state.plane_epoch_status == :current and Graph.complete?(state.dependency_graph) and
          state.plane_epoch_task == nil
      end)

    superseded_epoch_count = epoch_count - published_epoch_count

    assert epoch_count == 4
    assert published_epoch_count == 2
    assert superseded_epoch_count == 2

    IO.puts(
      "PRE-080C-02 " <>
        Jason.encode!([
          ["scenario", "signalled_edits_and_follow_up"],
          ["epoch_count", epoch_count],
          ["published_epoch_count", published_epoch_count],
          ["superseded_epoch_count", superseded_epoch_count],
          ["dirty_events_during_refresh", 3],
          ["superseded_epoch_process_terminated", not Process.alive?(superseded_pid)],
          ["published_graph_unchanged_until_follow_up", third_epoch.dependency_graph == initial_state.dependency_graph],
          ["dispatch_starts_during_refresh_poll", 0],
          ["dispatchable_work_items_during_refresh", length(dispatchable_ids)],
          ["dispatch_fence_opened_after_fresh_follow_up", final.plane_epoch_status == :current],
          ["provider_request_count", length(provider_stats.starts)],
          ["parallel_full_acquisitions", 1],
          ["final_epoch_status", Atom.to_string(final.plane_epoch_status)],
          ["dirty_to_current_modeled_ms", Clock.now(runtime.clock) - edit_window_started_at],
          ["same_id_relation_revision", 4],
          ["same_id_added_edge", ["item-5", "item-999"]],
          [
            "final_edge_count",
            Enum.reduce(final.dependency_graph.edges, 0, fn {_id, ids}, count -> count + length(ids) end)
          ],
          ["modeled_duration_ms", Clock.now(runtime.clock)]
        ])
    )

    stop_runtime(runtime)
  end

  test "dispatch stays fenced during refresh until a valid publication" do
    runtime = start_runtime(1_000, nil, nil, false)
    request_fun = Application.fetch_env!(:symphony_elixir, :pre_080c_02_request_fun)
    {:ok, graph_result} = Agent.start_link(fn -> :pending end)
    on_exit(fn -> stop_process(graph_result) end)

    graph_task =
      Task.async(fn ->
        result =
          Adapter.fetch_dependency_graph(
            tracker_settings: SymphonyElixir.Config.settings!().tracker,
            request_fun: request_fun,
            scheduler: runtime.scheduler
          )

        Agent.update(graph_result, fn _previous -> result end)
        result
      end)

    assert advance_clock_until(runtime.clock, fn -> Agent.get(graph_result, & &1) != :pending end)
    assert {:ok, graph} = Task.await(graph_task, 1_000)

    issue = Map.fetch!(graph.nodes, "item-0")
    work_item = dispatchable_work_item(issue)

    :sys.replace_state(runtime.orchestrator, fn state ->
      %{
        state
        | dependency_graph: graph,
          plane_epoch_id: graph.epoch,
          plane_epoch_status: :current,
          plane_epoch_task: nil,
          work_control: Map.put(state.work_control, issue.id, work_item),
          recovery_ledger_status: :disabled,
          dependency_diagnostics: %{}
      }
    end)

    initial = :sys.get_state(runtime.orchestrator)
    assert Graph.complete?(initial.dependency_graph)
    assert Orchestrator.should_dispatch_issue_for_test(issue, initial)
    refresh_started_at = Clock.now(runtime.clock)
    assert {:ok, :scheduled} = Orchestrator.accept_plane_webhook(runtime.orchestrator, project_event(50_001))
    assert eventually(fn -> :sys.get_state(runtime.orchestrator).plane_epoch_status == :refreshing end)
    send(runtime.orchestrator, :run_poll_cycle)
    refreshing = :sys.get_state(runtime.orchestrator)

    assert refreshing.plane_epoch_task != nil
    assert Orchestrator.should_dispatch_issue_for_test(issue, refreshing)
    refute_receive {:pre_080c_02_runner_started, _runner_pid, _issue_id}, 20

    driver =
      Task.async(fn ->
        drive_until_current(runtime.orchestrator, runtime.scheduler, runtime.clock, runtime.process_baseline, 1_000)
      end)

    assert is_map(Task.await(driver, 10_000))
    published = :sys.get_state(runtime.orchestrator)
    assert published.plane_epoch_status == :current
    assert Graph.complete?(published.dependency_graph)
    published_work_item = Map.fetch!(published.work_control, issue.id)
    assert LifecycleAssessment.validated?(published_work_item.lifecycle_assessment)
    assert AuthorityDisposition.active?(published_work_item.authority_disposition)
    assert_receive {:pre_080c_02_runner_started, runner_pid, "item-0"}, 1_000
    published = :sys.get_state(runtime.orchestrator)
    assert Map.has_key?(published.running, "item-0")
    send(runner_pid, :release_pre_080c_02_runner)
    assert eventually(fn -> not Process.alive?(runner_pid) end)

    IO.puts(
      "PRE-080C-02 " <>
        Jason.encode!([
          ["scenario", "dispatch_gate_during_refresh"],
          ["routable_item_id", issue.id],
          ["running_during_refresh", map_size(refreshing.running)],
          ["runner_started_during_refresh", false],
          ["runner_started_after_publication", Map.has_key?(published.running, issue.id)],
          ["dispatch_unavailable_modeled_ms", Clock.now(runtime.clock) - refresh_started_at],
          ["final_epoch_status", Atom.to_string(published.plane_epoch_status)]
        ])
    )

    stop_runtime(runtime)
  end

  @tag timeout: 900_000
  test "same-item churn and distinct-item overflow stay bounded during a paced full epoch" do
    runtime = start_runtime(1_000)
    on_exit(fn -> stop_runtime(runtime) end)
    drive_until_current(runtime.orchestrator, runtime.scheduler, runtime.clock, runtime.process_baseline, 1_000)
    refresh_started_at = Clock.now(runtime.clock)
    Agent.update(runtime.provider, &%{&1 | hold_targeted_ids: MapSet.put(&1.hold_targeted_ids, "item-0")})

    assert {:ok, :scheduled} = Orchestrator.accept_plane_webhook(runtime.orchestrator, project_event(30))
    assert await_pacing_boundary(runtime.scheduler)
    epoch_pid = :sys.get_state(runtime.orchestrator).plane_epoch_task.pid
    first_same_item = Orchestrator.accept_plane_webhook(runtime.orchestrator, item_event(10_001, "item-0"))
    assert first_same_item == {:ok, :scheduled}
    assert advance_clock_until(runtime.clock, fn -> is_pid(Agent.get(runtime.provider, & &1.held_targeted_request)) end)

    same_item_results =
      Enum.map(10_002..11_001, fn sequence ->
        Orchestrator.accept_plane_webhook(runtime.orchestrator, item_event(sequence, "item-0"))
      end)

    same_item_state = :sys.get_state(runtime.orchestrator)
    same_item_coalesced = Enum.count(same_item_results, &(&1 == {:ok, :coalesced}))
    assert same_item_coalesced == 1_000
    assert map_size(same_item_state.plane_webhook_tasks) == 1
    assert map_size(same_item_state.plane_webhook_pending) == 1
    assert same_item_state.plane_epoch_task.pid == epoch_pid

    distinct_results =
      Enum.map(1..1_000, fn sequence ->
        Orchestrator.accept_plane_webhook(
          runtime.orchestrator,
          item_event(sequence + 20_000, "item-#{rem(sequence - 1, 1_000)}")
        )
      end)

    distinct_state = :sys.get_state(runtime.orchestrator)
    assert Enum.all?(distinct_results, &(&1 in [{:ok, :scheduled}, {:ok, :coalesced}]))
    assert map_size(distinct_state.plane_webhook_tasks) <= 2
    assert map_size(distinct_state.plane_webhook_pending) <= 64
    assert :queue.len(distinct_state.plane_webhook_queue) <= 64
    assert distinct_state.plane_epoch_task.pid == epoch_pid

    assert distinct_state.plane_webhook_full_epoch_dirty_generation >
             distinct_state.plane_epoch_task.coverage_generation

    held_targeted_requests = Agent.get(runtime.provider, & &1.held_targeted_requests)
    Agent.update(runtime.provider, &%{&1 | hold_targeted_ids: MapSet.new()})
    Enum.each(held_targeted_requests, &send(&1, :release_held_targeted_request))
    drive_until_current(runtime.orchestrator, runtime.scheduler, runtime.clock, runtime.process_baseline, 1_000)

    assert advance_clock_until(runtime.clock, fn ->
             state = :sys.get_state(runtime.orchestrator)
             scheduler = ReadScheduler.stats(runtime.scheduler)

             state.plane_epoch_status == :current and is_nil(state.plane_epoch_task) and
               map_size(state.plane_webhook_tasks) == 0 and map_size(state.plane_webhook_pending) == 0 and
               :queue.is_empty(state.plane_webhook_queue) and scheduler.queue_length == 0 and
               scheduler.current_concurrency == 0 and Task.Supervisor.children(runtime.task_supervisor) == []
           end)

    final = :sys.get_state(runtime.orchestrator)
    provider_stats = Agent.get(runtime.provider, & &1)
    targeted_attempt_starts = Enum.count(provider_stats.starts, &direct_item_path?(&1.path))
    full_epoch_count = div(Enum.count(provider_stats.starts, &String.ends_with?(&1.path, "/work-items/")), 20)
    assert final.plane_epoch_status == :current
    assert Graph.complete?(final.dependency_graph)
    assert full_epoch_count >= 2

    assert ReadScheduler.stats(runtime.scheduler).queue_length == 0
    assert ReadScheduler.stats(runtime.scheduler).current_concurrency == 0
    assert Task.Supervisor.children(runtime.task_supervisor) == []

    IO.puts(
      "PRE-080C-02 " <>
        Jason.encode!([
          ["scenario", "same_item_and_distinct_item_webhook_churn"],
          ["same_item_events", 1_001],
          ["same_item_coalesced", same_item_coalesced],
          ["distinct_item_events", 1_000],
          ["distinct_pending", map_size(distinct_state.plane_webhook_pending)],
          ["distinct_queue_length", :queue.len(distinct_state.plane_webhook_queue)],
          ["distinct_targeted_tasks", map_size(distinct_state.plane_webhook_tasks)],
          ["dirty_generation_exceeds_coverage", true],
          ["full_epochs_in_flight", 1],
          ["targeted_work_drained", true],
          ["scheduler_work_drained", true],
          ["task_supervisor_drained", true],
          ["provider_attempt_starts", length(provider_stats.starts)],
          ["targeted_request_attempt_starts", targeted_attempt_starts],
          ["full_epoch_count", full_epoch_count],
          ["modeled_refresh_duration_ms", Clock.now(runtime.clock) - refresh_started_at],
          ["final_epoch_status", Atom.to_string(final.plane_epoch_status)]
        ])
    )

    stop_runtime(runtime)
  end

  test "runtime restart discards partial epoch work and begins enumeration again" do
    first_runtime = start_runtime(1_000)
    assert await_pacing_boundary(first_runtime.scheduler)
    partial_count = length(Agent.get(first_runtime.provider, & &1.starts))
    assert partial_count == 60
    first_state = :sys.get_state(first_runtime.orchestrator)
    old_epoch_pid = first_state.plane_epoch_task.pid
    assert first_state.plane_epoch_status == :refreshing
    assert ReadScheduler.stats(first_runtime.scheduler).starts_in_window == 60

    stop_runtime_processes(first_runtime)
    refute Process.alive?(old_epoch_pid)
    restarted = start_runtime(1_000, first_runtime.clock, first_runtime.provider, false)
    candidate = restart_candidate()

    :sys.replace_state(restarted.orchestrator, fn state ->
      %{state | work_control: Map.put(state.work_control, candidate.id, dispatchable_work_item(candidate)), recovery_ledger_status: :disabled}
    end)

    unavailable_state = :sys.get_state(restarted.orchestrator)
    assert unavailable_state.plane_epoch_status == :unavailable
    refute Orchestrator.should_dispatch_issue_for_test(candidate, unavailable_state)
    refute_receive {:pre_080c_02_runner_started, _runner_pid, _issue_id}, 20
    assert ReadScheduler.stats(restarted.scheduler).attempts == 0
    assert ReadScheduler.stats(restarted.scheduler).starts_in_window == 0
    send(restarted.orchestrator, :tick)
    assert eventually(fn -> :sys.get_state(restarted.orchestrator).plane_epoch_status == :refreshing end)
    restarted_state = :sys.get_state(restarted.orchestrator)
    restarted_scheduler_stats = ReadScheduler.stats(restarted.scheduler)
    assert restarted_state.plane_epoch_status == :refreshing
    assert restarted_state.plane_epoch_task.pid != old_epoch_pid
    assert restarted_scheduler_stats.starts_in_window < 60
    assert restarted_scheduler_stats.attempts < 60
    assert restarted_scheduler_stats.starts_in_window == restarted_scheduler_stats.attempts

    send(restarted.orchestrator, :run_poll_cycle)
    assert eventually(fn -> map_size(:sys.get_state(restarted.orchestrator).running) == 0 end)

    drive_until_current(restarted.orchestrator, restarted.scheduler, restarted.clock, restarted.process_baseline, 1_000)

    all_requests = Agent.get(restarted.provider, & &1.starts)
    assert length(all_requests) == partial_count + 1_024
    provider_window_high_water = max_rolling_starts(Enum.map(all_requests, & &1.timestamp), 60_000)
    assert provider_window_high_water == 120

    restarted_requests = Enum.take(all_requests, 1_024)
    assert Enum.count(restarted_requests, &String.ends_with?(&1.path, "/work-items/")) == 20
    final_state = :sys.get_state(restarted.orchestrator)
    assert final_state.plane_epoch_status == :current
    assert final_state.plane_epoch_coverage_generation >= final_state.plane_reconciliation_generation
    assert_receive {:pre_080c_02_runner_started, runner_pid, "item-0"}, 1_000
    assert Map.has_key?(final_state.running, candidate.id)
    send(runner_pid, :release_pre_080c_02_runner)
    assert eventually(fn -> not Process.alive?(runner_pid) end)

    IO.puts(
      "PRE-080C-02 " <>
        Jason.encode!([
          ["scenario", "runtime_restart"],
          ["partial_requests_discarded", partial_count],
          ["provider_max_starts_per_rolling_60s_across_restart", provider_window_high_water],
          ["scheduler_pacing_history", "process-local; reset by scheduler restart"],
          ["full_reenumeration_requests", Enum.count(restarted_requests, &String.ends_with?(&1.path, "/work-items/"))],
          ["total_provider_requests", length(all_requests)],
          ["candidate_dispatchable_before_publication", false],
          ["candidate_runner_started_after_publication", Map.has_key?(final_state.running, candidate.id)],
          ["final_epoch_status", "current"],
          ["modeled_reacquisition_ms", Clock.now(restarted.clock)]
        ])
    )

    stop_runtime(restarted)
  end

  setup do
    previous_api_key = System.get_env("PLANE_API_KEY")
    previous_test_pid = Application.get_env(:symphony_elixir, :pre_080c_02_test_pid)
    previous_workflow_path = Application.get_env(:symphony_elixir, :workflow_file_path)
    previous_attempt_ledger_root = Application.get_env(:symphony_elixir, :attempt_ledger_root)
    System.put_env("PLANE_API_KEY", "pre-080c-02-test-secret")
    Application.put_env(:symphony_elixir, :pre_080c_02_test_pid, self())

    root = Path.join(System.tmp_dir!(), "pre-080c-02-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    workflow_path = Path.join(root, "WORKFLOW.md")
    Application.put_env(:symphony_elixir, :attempt_ledger_root, Path.join(root, "attempt-ledger"))
    Workflow.set_workflow_file_path(workflow_path)
    write_workflow!(Path.join(root, "workspaces"), "routed")

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :pre_080c_02_request_fun)

      case previous_test_pid do
        nil -> Application.delete_env(:symphony_elixir, :pre_080c_02_test_pid)
        test_pid -> Application.put_env(:symphony_elixir, :pre_080c_02_test_pid, test_pid)
      end

      File.rm_rf!(root)

      case previous_workflow_path do
        nil -> Workflow.clear_workflow_file_path()
        path -> Workflow.set_workflow_file_path(path)
      end

      case previous_attempt_ledger_root do
        nil -> Application.delete_env(:symphony_elixir, :attempt_ledger_root)
        path -> Application.put_env(:symphony_elixir, :attempt_ledger_root, path)
      end

      case previous_api_key do
        nil -> System.delete_env("PLANE_API_KEY")
        key -> System.put_env("PLANE_API_KEY", key)
      end
    end)

    :ok
  end

  defp run_epoch(item_count) do
    {:ok, clock} = Clock.start_link([])
    {:ok, provider} = Agent.start_link(fn -> provider_state(item_count) end)
    request_fun = fn request -> respond(provider, clock, request) end
    Application.put_env(:symphony_elixir, :pre_080c_02_request_fun, request_fun)

    time_provider = %{
      monotonic_time: fn -> Clock.monotonic(clock) end,
      system_time: fn -> Clock.system(clock) end,
      send_after: fn destination, message, delay -> Clock.schedule(clock, destination, message, delay) end
    }

    {:ok, scheduler} =
      ReadScheduler.start_link(
        max_concurrency: 4,
        queue_limit: 64,
        start_limit: 60,
        start_window_ms: 60_000,
        time_provider: time_provider
      )

    {:ok, task_supervisor} = Task.Supervisor.start_link()

    orchestrator_name = Module.concat(__MODULE__, "Orchestrator#{System.unique_integer([:positive])}")

    {:ok, orchestrator} =
      Orchestrator.start_link(
        name: orchestrator_name,
        start_quiesced: true,
        tracker: Provider,
        read_scheduler: scheduler,
        task_supervisor: task_supervisor,
        agent_runner: SymphonyElixir.Pre080C02.Runner
      )

    on_exit(fn ->
      stop_process(orchestrator)
      stop_process(task_supervisor)
      stop_process(scheduler)
      stop_process(clock)
      stop_process(provider)
    end)

    :sys.replace_state(orchestrator, fn state ->
      if is_reference(state.tick_timer_ref), do: Process.cancel_timer(state.tick_timer_ref)
      tick_token = make_ref()
      tick_timer_ref = Process.send_after(self(), {:tick, tick_token}, 3_600_000)

      %{
        state
        | startup_reconciliation: :ready,
          poll_interval_ms: 3_600_000,
          tick_timer_ref: tick_timer_ref,
          tick_token: tick_token,
          next_poll_due_at_ms: System.monotonic_time(:millisecond) + 3_600_000
      }
    end)

    process_baseline = length(Process.list())
    orchestrator_memory_baseline_bytes = process_memory(orchestrator)
    scheduler_memory_baseline_bytes = process_memory(scheduler)
    beam_total_memory_baseline_bytes = :erlang.memory(:total)
    send(orchestrator, :tick)
    assert eventually(fn -> :sys.get_state(orchestrator).plane_epoch_status == :refreshing end)
    snapshot_started_at = System.monotonic_time(:microsecond)
    startup_snapshot = Orchestrator.snapshot(orchestrator, 1_000)
    orchestrator_snapshot_latency_ms = div(System.monotonic_time(:microsecond) - snapshot_started_at, 1_000)
    measurements = drive_until_current(orchestrator, scheduler, clock, process_baseline, item_count)
    state = :sys.get_state(orchestrator)
    graph = state.dependency_graph
    provider_stats = Agent.get(provider, & &1)
    scheduler_stats = ReadScheduler.stats(scheduler)
    request_metrics = state.plane_epoch_metrics.request_metrics
    starts = Enum.map(provider_stats.starts, & &1.timestamp)
    request_class_counts = Enum.frequencies_by(provider_stats.starts, &request_class(&1.path))
    page_count = div(item_count + 99, 100)
    epoch_count = div(Map.get(request_class_counts, :bulk_enumeration, 0), 2 * page_count)
    published_epoch_count = if state.plane_epoch_status == :current and Graph.complete?(graph), do: epoch_count, else: 0
    graph_bytes = :erlang.external_size(graph)
    orchestrator_memory_published_bytes = process_memory(orchestrator)
    scheduler_memory_published_bytes = process_memory(scheduler)
    :erlang.garbage_collect(orchestrator)
    :erlang.garbage_collect(scheduler)

    result = %{
      item_count: item_count,
      edge_count: item_count * 5,
      work_item_page_gets: Map.get(request_class_counts, :bulk_enumeration, 0),
      relation_logical_gets: Map.get(request_class_counts, :bulk_relation, 0),
      project_gets: Enum.count(provider_stats.starts, &String.ends_with?(&1.path, "/projects/#{@scope.project_id}/")),
      state_page_gets: Map.get(request_class_counts, :bulk_states, 0),
      total_logical_gets: scheduler_stats.logical_read_count,
      scheduler_attempt_starts: scheduler_stats.attempts,
      provider_attempt_starts: length(provider_stats.starts),
      epoch_logical_requests: :atomics.get(request_metrics, 1),
      epoch_attempts: :atomics.get(request_metrics, 2),
      retry_attempts: scheduler_stats.retries,
      request_start_timestamp_counts:
        starts
        |> Enum.frequencies()
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(&Tuple.to_list/1),
      request_class_counts: request_class_counts,
      max_starts_per_rolling_window: max_rolling_starts(starts, 60_000),
      peak_in_flight: max(scheduler_stats.peak_concurrency, provider_stats.peak_in_flight),
      queue_high_water: measurements.queue_high_water,
      control_start_latency_ms: nil,
      orchestrator_snapshot_latency_ms: orchestrator_snapshot_latency_ms,
      modeled_last_start_ms: if(starts == [], do: 0, else: Enum.max(starts)),
      test_wall_elapsed_ms: measurements.wall_elapsed_ms,
      test_cpu_elapsed_ms: measurements.cpu_elapsed_ms,
      epoch_count: epoch_count,
      published_epoch_count: published_epoch_count,
      superseded_epoch_count: epoch_count - published_epoch_count,
      full_reacquisition_count: epoch_count,
      targeted_read_count: Enum.count(provider_stats.starts, &direct_item_path?(&1.path)),
      scc_pass_count: :atomics.get(state.plane_epoch_metrics.request_metrics, 5),
      final_epoch_status: state.plane_epoch_status,
      initial_epoch_status: startup_snapshot.plane_epoch.status,
      coverage_generation: state.plane_epoch_coverage_generation,
      required_generation: state.plane_reconciliation_generation,
      scheduler_queue_after_completion: scheduler_stats.queue_length,
      scheduler_in_flight_after_completion: scheduler_stats.current_concurrency,
      orchestrator_mailbox_after_completion: message_queue_length(orchestrator),
      scheduler_mailbox_after_completion: message_queue_length(scheduler),
      acquisition_task_mailbox_high_water: measurements.acquisition_task_mailbox_high_water,
      graph_complete: Graph.complete?(graph),
      observed_node_count: map_size(graph.nodes),
      observed_edge_count: Enum.reduce(graph.edges, 0, fn {_id, ids}, count -> count + length(ids) end),
      dispatch_authority_during_acquisition: startup_snapshot.plane_epoch.status == :current,
      orchestrator_mailbox_high_water: measurements.orchestrator_mailbox_high_water,
      scheduler_mailbox_high_water: measurements.scheduler_mailbox_high_water,
      acquisition_task_memory_high_water: measurements.acquisition_task_memory_high_water,
      orchestrator_memory_bytes: process_memory(orchestrator),
      orchestrator_memory_baseline_bytes: orchestrator_memory_baseline_bytes,
      scheduler_memory_baseline_bytes: scheduler_memory_baseline_bytes,
      beam_total_memory_baseline_bytes: beam_total_memory_baseline_bytes,
      beam_total_memory_high_water_bytes: measurements.beam_total_memory_high_water_bytes,
      orchestrator_memory_published_bytes: orchestrator_memory_published_bytes,
      scheduler_memory_published_bytes: scheduler_memory_published_bytes,
      scheduler_memory_bytes: process_memory(scheduler),
      process_count_delta: measurements.process_count_high_water - process_baseline,
      process_count_baseline: process_baseline,
      process_count_after_completion: length(Process.list()),
      task_supervisor_children_high_water: measurements.task_supervisor_children_high_water,
      task_supervisor_children_after_completion: length(Task.Supervisor.children(task_supervisor)),
      graph_external_size_bytes: graph_bytes,
      post_gc_total_memory_bytes: :erlang.memory(:total),
      dispatch_unavailable_duration_ms: Clock.now(clock),
      provider_request_records: Enum.reverse(provider_stats.starts)
    }

    stop_process(orchestrator)
    stop_process(task_supervisor)
    stop_process(scheduler)
    stop_process(clock)
    stop_process(provider)
    result
  end

  defp start_runtime(item_count, clock \\ nil, provider \\ nil, start_epoch? \\ true) do
    clock = clock || start_link!(Clock, [])
    provider = provider || start_link!(Agent, fn -> provider_state(item_count) end)
    Application.put_env(:symphony_elixir, :pre_080c_02_request_fun, fn request -> respond(provider, clock, request) end)

    time_provider = %{
      monotonic_time: fn -> Clock.monotonic(clock) end,
      system_time: fn -> Clock.system(clock) end,
      send_after: fn destination, message, delay -> Clock.schedule(clock, destination, message, delay) end
    }

    {:ok, scheduler} =
      ReadScheduler.start_link(
        max_concurrency: 4,
        queue_limit: 64,
        start_limit: 60,
        start_window_ms: 60_000,
        time_provider: time_provider
      )

    {:ok, task_supervisor} = Task.Supervisor.start_link()
    name = Module.concat(__MODULE__, "Orchestrator#{System.unique_integer([:positive])}")

    {:ok, orchestrator} =
      Orchestrator.start_link(
        name: name,
        start_quiesced: true,
        tracker: Provider,
        read_scheduler: scheduler,
        task_supervisor: task_supervisor,
        agent_runner: SymphonyElixir.Pre080C02.Runner
      )

    :sys.replace_state(orchestrator, fn state ->
      %{state | startup_reconciliation: :ready, poll_interval_ms: 3_600_000}
    end)

    process_baseline = length(Process.list())
    if start_epoch?, do: send(orchestrator, :tick)

    runtime = %{
      clock: clock,
      provider: provider,
      scheduler: scheduler,
      task_supervisor: task_supervisor,
      orchestrator: orchestrator,
      process_baseline: process_baseline
    }

    on_exit(fn -> stop_runtime(runtime) end)
    runtime
  end

  defp stop_runtime(runtime) do
    stop_runtime_processes(runtime)
    stop_process(runtime.clock)
    stop_process(runtime.provider)
  end

  defp stop_runtime_processes(runtime) do
    stop_process(runtime.orchestrator)
    stop_process(runtime.task_supervisor)
    stop_process(runtime.scheduler)
  end

  defp start_link!(module, argument) do
    {:ok, pid} = module.start_link(argument)
    pid
  end

  defp await_pacing_boundary(scheduler, attempts \\ 100)

  defp await_pacing_boundary(scheduler, attempts) when attempts > 0 do
    stats = ReadScheduler.stats(scheduler)

    if stats.starts_in_window == 60 and stats.queue_length > 0 do
      true
    else
      Process.sleep(10)
      await_pacing_boundary(scheduler, attempts - 1)
    end
  end

  defp await_pacing_boundary(_scheduler, 0), do: false

  defp advance_clock_until(clock, condition, attempts \\ 1_000)

  defp advance_clock_until(_clock, _condition, 0), do: false

  defp advance_clock_until(clock, condition, attempts) do
    if condition.() do
      true
    else
      case Clock.advance_next(clock) do
        :advanced -> Process.sleep(2)
        :empty -> Process.sleep(5)
      end

      advance_clock_until(clock, condition, attempts - 1)
    end
  end

  defp project_event(sequence) do
    suffix = sequence |> Integer.to_string(16) |> String.pad_leading(12, "0")

    %EventIdentity{
      version: "v2",
      workspace_id: @scope.workspace_id,
      webhook_id: "00000000-0000-4000-8000-000000000001",
      delivery_id: "00000000-0000-4000-8000-#{suffix}",
      event_id: "00000000-0000-4000-8001-#{suffix}",
      event: "project.updated",
      entity_id: @scope.project_id,
      entity_type: "project",
      project_hint: @scope.project_id
    }
  end

  defp item_event(sequence, item_id) do
    suffix = sequence |> Integer.to_string(16) |> String.pad_leading(12, "0")

    %EventIdentity{
      version: "v2",
      workspace_id: @scope.workspace_id,
      webhook_id: "00000000-0000-4000-8000-000000000001",
      delivery_id: "00000000-0000-4000-8002-#{suffix}",
      event_id: "00000000-0000-4000-8003-#{suffix}",
      event: "workitem.updated",
      entity_id: item_id,
      entity_type: "work_item",
      project_hint: @scope.project_id
    }
  end

  defp drive_until_current(orchestrator, scheduler, clock, process_baseline, _item_count) do
    started_at = System.monotonic_time(:millisecond)
    cpu_started_at = :erlang.statistics(:runtime) |> elem(0)

    drive(
      orchestrator,
      scheduler,
      clock,
      process_baseline,
      %{
        queue_high_water: 0,
        orchestrator_mailbox_high_water: 0,
        scheduler_mailbox_high_water: 0,
        acquisition_task_memory_high_water: 0,
        acquisition_task_mailbox_high_water: 0,
        beam_total_memory_high_water_bytes: :erlang.memory(:total),
        task_supervisor_children_high_water: 0,
        process_count_high_water: process_baseline,
        wall_elapsed_ms: 0,
        cpu_elapsed_ms: 0
      },
      started_at,
      cpu_started_at
    )
  end

  defp drive(orchestrator, scheduler, clock, process_baseline, sample, started_at, cpu_started_at) do
    state = :sys.get_state(orchestrator)
    scheduler_stats = ReadScheduler.stats(scheduler)
    sample = sample_progress(sample, orchestrator, scheduler, process_baseline, state, scheduler_stats)

    if epoch_complete?(state) do
      finish_sample(sample, started_at, cpu_started_at)
    else
      advance_or_wait(clock, scheduler_stats)
      drive(orchestrator, scheduler, clock, process_baseline, sample, started_at, cpu_started_at)
    end
  end

  defp sample_progress(sample, orchestrator, scheduler, process_baseline, state, scheduler_stats) do
    process_count = length(Process.list())
    orchestrator_mailbox_length = message_queue_length(orchestrator)
    scheduler_mailbox_length = message_queue_length(scheduler)
    task_supervisor_children = length(Task.Supervisor.children(state.task_supervisor))
    acquisition_task_mailbox = task_mailbox_length(state)

    %{
      sample
      | queue_high_water: max(sample.queue_high_water, scheduler_stats.queue_length),
        orchestrator_mailbox_high_water: max(sample.orchestrator_mailbox_high_water, orchestrator_mailbox_length),
        scheduler_mailbox_high_water: max(sample.scheduler_mailbox_high_water, scheduler_mailbox_length),
        acquisition_task_memory_high_water: max(sample.acquisition_task_memory_high_water, task_memory(state)),
        acquisition_task_mailbox_high_water: max(sample.acquisition_task_mailbox_high_water, acquisition_task_mailbox),
        process_count_high_water: max(sample.process_count_high_water, process_count),
        beam_total_memory_high_water_bytes: max(sample.beam_total_memory_high_water_bytes, :erlang.memory(:total)),
        task_supervisor_children_high_water: max(sample.task_supervisor_children_high_water, task_supervisor_children)
    }
    |> Map.update!(:process_count_high_water, &max(&1, process_baseline))
  end

  defp epoch_complete?(state),
    do: state.plane_epoch_status == :current and is_nil(state.plane_epoch_task)

  defp finish_sample(sample, started_at, cpu_started_at) do
    wall_elapsed_ms = System.monotonic_time(:millisecond) - started_at
    cpu_elapsed_ms = max((:erlang.statistics(:runtime) |> elem(0)) - cpu_started_at, 0)
    %{sample | wall_elapsed_ms: wall_elapsed_ms, cpu_elapsed_ms: cpu_elapsed_ms}
  end

  defp advance_or_wait(clock, scheduler_stats) do
    pacing_blocked? = scheduler_stats.starts_in_window >= 60 and scheduler_stats.queue_length > 0
    slot_available? = scheduler_stats.current_concurrency < 4

    if pacing_blocked? and slot_available? do
      case Clock.advance_next(clock) do
        :advanced -> :ok
        :empty -> Process.sleep(1)
      end
    else
      Process.sleep(1)
    end
  end

  defp task_memory(%{plane_epoch_task: %{pid: pid}}), do: process_memory(pid)
  defp task_memory(_state), do: 0

  defp task_mailbox_length(%{plane_epoch_task: %{pid: pid}}), do: message_queue_length(pid)
  defp task_mailbox_length(_state), do: 0

  defp provider_state(item_count) do
    items = Enum.map(0..(item_count - 1), &item/1)
    states = Enum.map([:backlog, :planning, :ready, :in_progress, :in_review, :changes_requested, :ready_to_merge, :merging, :blocked, :done, :canceled], &state/1)

    %{
      item_count: item_count,
      items: items,
      states: states,
      starts: [],
      active: 0,
      peak_in_flight: 0,
      relation_revision: 0,
      hold_targeted_ids: MapSet.new(),
      held_targeted_request: nil,
      held_targeted_requests: [],
      hold_bulk_relations?: false,
      held_provider_requests: [],
      completions: []
    }
  end

  defp respond(provider, clock, request) do
    timestamp = Clock.now(clock)

    Agent.update(provider, fn state ->
      starts = [%{timestamp: timestamp, path: request.path, method: request.method, identity: request_identity(request)} | state.starts]
      active = state.active + 1
      %{state | starts: starts, active: active, peak_in_flight: max(state.peak_in_flight, active)}
    end)

    provider_state = Agent.get(provider, & &1)

    hold_request? =
      (provider_state.hold_bulk_relations? and String.contains?(request.path, "/relations/")) or
        (direct_item_path?(request.path) and MapSet.member?(provider_state.hold_targeted_ids, request_item_id(request.path)))

    if hold_request? do
      request_pid = self()

      Agent.update(provider, fn state ->
        %{
          state
          | held_targeted_request: request_pid,
            held_targeted_requests: [request_pid | state.held_targeted_requests],
            held_provider_requests: [request_pid | state.held_provider_requests]
        }
      end)

      receive do
        :release_held_targeted_request -> :ok
        :release_held_provider_request -> :ok
      after
        30_000 -> raise "held targeted provider request was not released"
      end
    end

    response = response_for(Agent.get(provider, & &1), request)

    Agent.update(provider, fn state ->
      completion = %{timestamp: Clock.now(clock), path: request.path}
      %{state | active: state.active - 1, completions: [completion | state.completions]}
    end)

    response
  end

  defp direct_item_path?(path), do: String.contains?(path, "/work-items/item-") and not String.contains?(path, "/relations/")

  defp request_item_id(path) do
    path |> String.split("/work-items/") |> List.last() |> String.trim_trailing("/")
  end

  defp response_for(state, %{path: path, params: params}) do
    case response_kind(path) do
      :project -> project_response()
      :states -> states_response(state.states)
      :work_item_page -> work_item_page_response(state, params)
      {:work_item, id} -> work_item_response(id)
      {:relation, id} -> relation_response(state, id)
      :unexpected -> {:error, {:unexpected_path, path}}
    end
  end

  defp response_kind(path) do
    cond do
      String.ends_with?(path, "/projects/#{@scope.project_id}/") -> :project
      String.ends_with?(path, "/states/") -> :states
      String.ends_with?(path, "/work-items/") -> :work_item_page
      direct_item_path?(path) -> {:work_item, request_item_id(path)}
      String.contains?(path, "/relations/") -> {:relation, path |> String.split("/") |> Enum.at(-3)}
      true -> :unexpected
    end
  end

  defp project_response do
    body = %{
      "id" => @scope.project_id,
      "name" => "Project",
      "identifier" => "PROJ",
      "workspace_slug" => "workspace-1"
    }

    {:ok, %{status: 200, body: body}}
  end

  defp states_response(states), do: {:ok, %{status: 200, body: page(states, length(states))}}

  defp work_item_page_response(state, params) do
    page_size = 100
    page_index = if is_binary(params["cursor"]), do: String.to_integer(params["cursor"]), else: 0
    page_items = Enum.slice(state.items, page_index * page_size, page_size)
    next? = (page_index + 1) * page_size < state.item_count
    next_cursor = if next?, do: Integer.to_string(page_index + 1), else: nil
    {:ok, %{status: 200, body: page(page_items, state.item_count, next?, next_cursor)}}
  end

  defp work_item_response(id) do
    index = id |> String.replace_prefix("item-", "") |> String.to_integer()
    {:ok, %{status: 200, body: item(index)}}
  end

  defp relation_response(state, id) do
    index = id |> String.replace_prefix("item-", "") |> String.to_integer()
    blocker_indexes = relation_blockers(index)
    blocker_indexes = add_relation_revision_edge(blocker_indexes, index, state)
    blocked_by = Enum.map(blocker_indexes, &%{"issue_id" => "item-#{&1}", "project_id" => @scope.project_id})
    {:ok, %{status: 200, body: %{"blocked_by" => blocked_by, "blocking" => []}}}
  end

  defp relation_blockers(index) when index < 5, do: []
  defp relation_blockers(index) when index in 10..14, do: Enum.to_list(0..9)
  defp relation_blockers(_index), do: Enum.to_list(0..4)

  defp add_relation_revision_edge(blockers, index, state) do
    if index == state.item_count - 1 and state.relation_revision >= 4, do: blockers ++ [5], else: blockers
  end

  defp item(index) do
    %{
      "id" => "item-#{index}",
      "name" => "ITEM-#{index}",
      "state" => %{"id" => "state-ready", "name" => "Ready", "group" => "unstarted"},
      "project" => @scope.project_id,
      "workspace" => @scope.workspace_id,
      "updated_at" => "2026-09-17T08:09:10Z"
    }
  end

  defp dispatchable_work_item(issue) do
    {:ok, observation} = ProviderObservation.from_issue(issue, %{provider: "plane"})

    assessment = %LifecycleAssessment{
      work_item_id: issue.id,
      provider_observation: observation,
      mapped_state: :ready,
      validated_state: :ready,
      status: :validated,
      required_guards: [],
      satisfied_guards: [],
      missing_guards: [],
      reason: nil,
      assessed_at: DateTime.utc_now()
    }

    %WorkItem{
      id: issue.id,
      provider_observation: observation,
      lifecycle_assessment: assessment,
      validated_lifecycle_state: :ready,
      authority_disposition: %{
        AuthorityDisposition.derive(assessment)
        | status: :eligible,
          lifecycle_state: :ready
      },
      dependency_completeness: :complete
    }
  end

  defp restart_candidate do
    %Issue{
      id: "item-0",
      identifier: "ITEM-0",
      title: "ITEM-0",
      state: "Ready",
      workspace_id: @scope.workspace_id,
      project_id: @scope.project_id,
      provider_state_id: "state-ready",
      provider_state_group: :unstarted,
      dispatchable: true
    }
  end

  defp state(name) do
    %{
      "id" => "state-#{name}",
      "name" => Map.fetch!(@state_names, name),
      "group" => Map.fetch!(@state_groups, name),
      "project" => @scope.project_id,
      "workspace" => @scope.workspace_id
    }
  end

  defp request_identity(%{path: path}) do
    if String.contains?(path, "/relations/"), do: path |> String.split("/") |> Enum.at(-3), else: path
  end

  defp request_class(path) do
    cond do
      String.ends_with?(path, "/relations/") -> :bulk_relation
      String.ends_with?(path, "/work-items/") -> :bulk_enumeration
      String.ends_with?(path, "/states/") -> :bulk_states
      true -> :control_project
    end
  end

  defp page(items, total, next? \\ false, cursor \\ nil) do
    %{"results" => items, "count" => length(items), "total_results" => total, "next_page_results" => next?, "next_cursor" => cursor}
  end

  defp max_rolling_starts(starts, window_ms) do
    Enum.max(Enum.map(starts, fn start -> Enum.count(starts, &(&1 >= start and &1 < start + window_ms)) end), fn -> 0 end)
  end

  defp rolling_window_spacing_valid?(request_records, window_ms) do
    timestamps = request_records |> Enum.map(& &1.timestamp) |> Enum.sort()

    timestamps
    |> Enum.chunk_every(61, 1, :discard)
    |> Enum.all?(fn window -> Enum.at(window, 60) - hd(window) >= window_ms end)
  end

  defp eventually(fun, attempts \\ 100)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false

  defp process_memory(pid) when is_pid(pid) do
    case Process.info(pid, :memory) do
      {:memory, bytes} -> bytes
      nil -> 0
    end
  end

  defp process_memory(_pid), do: 0

  defp message_queue_length(pid),
    do:
      case(Process.info(pid, :message_queue_len),
        do: (
          {:message_queue_len, length} -> length
          nil -> 0
        )
      )

  defp stop_process(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid)
      catch
        :exit, _reason -> :ok
      end
    end
  end

  defp write_workflow!(workspace_root, routing) do
    contract = %{
      "schema_version" => 1,
      "provider" => "plane",
      "workspace_id" => @scope.workspace_id,
      "project_id" => @scope.project_id,
      "state_mappings" =>
        Map.new(["backlog", "planning", "ready", "in_progress", "in_review", "changes_requested", "ready_to_merge", "merging", "blocked", "done", "canceled"], fn key ->
          state_name = state(String.to_atom(key))["name"]
          {key, %{"state_id" => "state-#{key}", "name" => state_name}}
        end)
    }

    provider = %{"workspace_slug" => @scope.workspace_slug, "workspace_id" => @scope.workspace_id, "project_id" => @scope.project_id, "api_key" => "$PLANE_API_KEY"}

    workflow = """
    ---
    provider_project_contract: #{Jason.encode!(contract)}
    tracker:
      kind: "plane"
      provider: #{Jason.encode!(provider)}
      active_states: ["Ready"]
      terminal_states: ["Done"]
    symphony:
      project_id: "pre-080c-02-test"
    polling:
      interval_ms: 86400000
    workspace:
      root: #{inspect(workspace_root)}
    agent:
      routing: "#{routing}"
      max_concurrent_agents: 1
      max_turns: 1
    source_control:
      kind: "github"
      repository: "octo/symphony"
      repository_id: 1368436395
      base_branch: "main"
      token_env: "GITHUB_TOKEN"
      required_checks:
        - context: "make-all"
          app_id: 15368
          subject: "head"
    ---
    Production rate characterization fixture.
    """

    File.write!(Workflow.workflow_file_path(), workflow)
    assert :ok = WorkflowStore.force_reload()
  end
end
