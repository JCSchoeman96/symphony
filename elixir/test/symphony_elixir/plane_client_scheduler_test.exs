defmodule SymphonyElixir.PlaneClientSchedulerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Plane.{Client, ReadScheduler}

  @config %{
    base_url: "https://api.plane.so",
    workspace_slug: "workspace-1",
    workspace_id: "workspace-id-1",
    project_id: "project-1",
    api_key: "secret"
  }

  test "request doubles bypass the scheduler unless one is explicitly supplied" do
    scheduler = start_scheduler()

    assert {:ok, %{"id" => "project-1"}} =
             Client.get_project(@config,
               request_fun: fn _request -> {:ok, %{status: 200, body: %{"id" => "project-1"}}} end
             )

    assert ReadScheduler.stats(scheduler).logical_requests == 0

    assert {:ok, %{"id" => "project-1"}} =
             Client.get_project(@config,
               scheduler: scheduler,
               request_fun: fn _request -> {:ok, %{status: 200, body: %{"id" => "project-1"}}} end
             )

    stats = ReadScheduler.stats(scheduler)
    assert stats.logical_requests == 1
    assert stats.attempts == 1
  end

  test "AgentRuntimeSupervisor adds one named read scheduler child with injected options" do
    scheduler_name = Module.concat(__MODULE__, "ReadScheduler#{System.unique_integer([:positive])}")

    assert {:ok, {_supervisor_flags, children}} =
             SymphonyElixir.AgentRuntimeSupervisor.init(
               read_scheduler_name: scheduler_name,
               read_scheduler_opts: [max_concurrency: 1]
             )

    scheduler_child = Enum.find(children, &(&1.id == scheduler_name))
    assert scheduler_child != nil
    assert {ReadScheduler, :start_link, [scheduler_opts]} = scheduler_child.start
    assert scheduler_opts[:name] == scheduler_name
    assert scheduler_opts[:max_concurrency] == 1

    orchestrator_child = Enum.find(children, &(&1.id == SymphonyElixir.Orchestrator))
    assert {SymphonyElixir.Orchestrator, :start_link, [orchestrator_opts]} = orchestrator_child.start
    assert orchestrator_opts[:read_scheduler] == scheduler_name
  end

  test "the scheduler retries raw 429 responses and keeps rate-limit fields separate" do
    scheduler = start_scheduler(max_backoff_ms: 20, throttle_fallback_ms: 1)
    attempts = Agent.start_link(fn -> 0 end) |> elem(1)
    reset = System.system_time(:second) + 60

    request_fun = fn _request ->
      attempt = Agent.get_and_update(attempts, &{&1, &1 + 1})

      if attempt == 0 do
        {:ok,
         %{
           status: 429,
           headers: [{"Retry-After", ["0"]}, {"X-RateLimit-Reset", [Integer.to_string(reset)]}],
           body: %{}
         }}
      else
        {:ok, %{status: 200, body: %{"id" => "project-1"}}}
      end
    end

    assert {:ok, %{"id" => "project-1"}} =
             Client.get_project(@config, scheduler: scheduler, request_fun: request_fun)

    assert Agent.get(attempts, & &1) == 2
    stats = ReadScheduler.stats(scheduler)
    assert stats.logical_requests == 1
    assert stats.attempts == 2
    assert stats.last_retry_after_seconds == 0
    assert stats.last_rate_limit_reset_at == reset
  end

  test "sanitizes map and list rate limit headers and ignores invalid request counters" do
    reset = System.system_time(:second) + 10

    cases = [
      {%{"retry-after" => ["0.01"], "x-ratelimit-reset" => [Integer.to_string(reset)]}, 0.01, reset},
      {[{"Retry-After", ["0.02"]}, {"X-RateLimit-Reset", [Integer.to_string(reset)]}], 0.02, reset},
      {[%{malformed: true}, {"Retry-After", ["bad"]}, {"X-RateLimit-Reset", ["-1"]}], nil, nil}
    ]

    for {headers, retry_after, reset_at} <- cases do
      scheduler = start_scheduler(max_backoff_ms: 20, throttle_fallback_ms: 1)
      request_fun = fn _request -> {:error, {:rate_limited, %{headers: headers}}} end

      assert {:error, {:rate_limited, metadata}} =
               Client.get_project(@config,
                 scheduler: scheduler,
                 request_fun: request_fun,
                 request_metrics: :invalid_metrics
               )

      assert metadata.retry_after_seconds == retry_after
      assert metadata.reset_at_unix == reset_at
      assert ReadScheduler.stats(scheduler).attempts == 2
    end
  end

  test "a raw 5xx response is retried before the client maps it to a success" do
    scheduler = start_scheduler(backoff_base_ms: 1, max_backoff_ms: 10)
    attempts = Agent.start_link(fn -> 0 end) |> elem(1)

    request_fun = fn _request ->
      attempt = Agent.get_and_update(attempts, &{&1, &1 + 1})

      if attempt == 0,
        do: {:ok, %{status: 503, headers: [{"X-Request-ID", "request-1"}], body: %{}}},
        else: {:ok, %{status: 200, body: %{"id" => "project-1"}}}
    end

    assert {:ok, %{"id" => "project-1"}} =
             Client.get_project(@config, scheduler: scheduler, request_fun: request_fun)

    assert Agent.get(attempts, & &1) == 2
    assert ReadScheduler.stats(scheduler).attempts == 2
  end

  test "PATCH remains single-shot even when a scheduler is supplied" do
    scheduler = start_scheduler()
    parent = self()

    assert :ok =
             Client.update_work_item_state(@config, "item-1", "state-1",
               scheduler: scheduler,
               request_fun: fn request ->
                 send(parent, {:request, request})
                 {:ok, %{status: 200, body: %{}}}
               end
             )

    assert_receive {:request, %{method: :patch}}
    stats = ReadScheduler.stats(scheduler)
    assert stats.logical_requests == 0
    assert stats.attempts == 0
  end

  test "page-level GETs update logical and actual request metrics" do
    scheduler = start_scheduler()
    request_metrics = :atomics.new(2, [])

    request_fun = fn _request ->
      {:ok,
       %{
         status: 200,
         body: %{
           "results" => [%{"id" => "item-1"}],
           "count" => 1,
           "total_results" => 1,
           "next_page_results" => false,
           "next_cursor" => nil
         }
       }}
    end

    assert {:ok, [%{"id" => "item-1"}]} =
             Client.list_work_items(@config,
               scheduler: scheduler,
               request_fun: request_fun,
               request_metrics: request_metrics
             )

    assert :atomics.get(request_metrics, 1) == 1
    assert :atomics.get(request_metrics, 2) == 1
  end

  defp start_scheduler(opts \\ []) do
    {:ok, scheduler} = ReadScheduler.start_link(Keyword.merge([max_backoff_ms: 20], opts))

    on_exit(fn ->
      if Process.alive?(scheduler) do
        try do
          GenServer.stop(scheduler)
        catch
          :exit, _reason -> :ok
        end
      end
    end)

    scheduler
  end
end
