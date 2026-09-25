defmodule SymphonyElixir.PlaneReadSchedulerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Plane.ReadScheduler

  defmodule ExitingRegistry do
    def whereis_name(_name), do: exit(:registry_unavailable)
  end

  test "executes a read and exposes bounded concurrency stats" do
    {:ok, scheduler} = ReadScheduler.start_link(max_concurrency: 2)

    assert {:ok, %{status: 200}} =
             ReadScheduler.execute(scheduler, :control, fn -> {:ok, %{status: 200}} end)

    stats = ReadScheduler.stats(scheduler)
    assert stats.logical_requests == 1
    assert stats.attempts == 1
    assert stats.current_concurrency == 0
    assert stats.peak_concurrency == 1
  end

  test "executes reads through a registered scheduler name" do
    name = String.to_atom("read_scheduler_#{System.unique_integer([:positive])}")
    {:ok, scheduler} = ReadScheduler.start_link(name: name)

    assert {:ok, :named} = ReadScheduler.execute(name, :control, fn -> {:ok, :named} end)

    GenServer.stop(scheduler)
  end

  test "rejects invalid classes and unavailable schedulers" do
    assert {:error, :invalid_read_class} =
             ReadScheduler.execute(self(), :unknown, fn -> {:ok, :unused} end)

    assert {:error, :scheduler_unavailable} =
             ReadScheduler.execute(:missing_read_scheduler, :control, fn -> {:ok, :unused} end)
  end

  test "rejects invalid rolling window settings and contains request exceptions" do
    assert {:error, :invalid_start_window} = ReadScheduler.start_link(start_window_ms: 0)

    {:ok, scheduler} = ReadScheduler.start_link(backoff_base_ms: 1, max_backoff_ms: 10)

    assert {:error, {:request_failed, :error, %RuntimeError{message: "request_boom"}}} =
             ReadScheduler.execute(scheduler, :control, fn -> raise "request_boom" end)
  end

  test "returns unavailable when a scheduler stops before admission" do
    {:ok, scheduler} = ReadScheduler.start_link()
    GenServer.stop(scheduler)

    assert {:error, :scheduler_unavailable} =
             ReadScheduler.execute(scheduler, :control, fn -> {:ok, :unused} end)
  end

  test "ignores stale attempt and timer messages" do
    {:ok, scheduler} = ReadScheduler.start_link()

    send(scheduler, {:attempt_result, make_ref(), self(), 1, {:ok, :stale}})
    send(scheduler, {:retry_ready, make_ref(), make_ref()})
    send(scheduler, {:throttle_expired, make_ref()})
    send(scheduler, {:pacing_expired, make_ref()})
    send(scheduler, {:DOWN, make_ref(), :process, self(), :normal})
    send(scheduler, :unrecognized_scheduler_message)

    eventually(fn -> Process.info(scheduler, :message_queue_len) |> elem(1) == 0 end)
    assert ReadScheduler.stats(scheduler).logical_requests == 0
    assert {:error, :not_found} = GenServer.call(scheduler, {:cancel, make_ref(), self()})
  end

  test "rejects a duplicate registered scheduler name" do
    name = String.to_atom("read_scheduler_duplicate_#{System.unique_integer([:positive])}")
    {:ok, scheduler} = ReadScheduler.start_link(name: name)

    assert {:error, {:already_started, ^scheduler}} = ReadScheduler.start_link(name: name)
  end

  test "limits concurrent reads to the configured global permit count" do
    {:ok, scheduler} = ReadScheduler.start_link(max_concurrency: 2, queue_limit: 10)
    parent = self()
    {:ok, gate} = Agent.start_link(fn -> false end)

    tasks =
      for _ <- 1..5 do
        Task.async(fn ->
          ReadScheduler.execute(scheduler, :dependency, fn ->
            send(parent, :started)
            wait_for_gate(gate)
            {:ok, :done}
          end)
        end)
      end

    assert_receive :started
    assert_receive :started
    refute_receive :started, 50
    assert ReadScheduler.stats(scheduler).current_concurrency == 2

    Agent.update(gate, fn _ -> true end)
    assert Enum.all?(Task.await_many(tasks, 1_000), &(&1 == {:ok, :done}))
    assert ReadScheduler.stats(scheduler).peak_concurrency == 2
  end

  test "prioritizes control reads ahead of queued bulk and dependency reads" do
    {:ok, scheduler} =
      ReadScheduler.start_link(max_concurrency: 1, queue_limit: 5, start_limit: 20)

    parent = self()
    {:ok, first_gate} = Agent.start_link(fn -> false end)
    {:ok, control_gate} = Agent.start_link(fn -> false end)

    first =
      Task.async(fn ->
        ReadScheduler.execute(scheduler, :dependency, fn ->
          send(parent, {:started, :first})
          wait_for_gate(first_gate)
          {:ok, :first}
        end)
      end)

    assert_receive {:started, :first}

    queued_bulk =
      Task.async(fn ->
        ReadScheduler.execute(scheduler, :bulk, fn ->
          send(parent, {:started, :bulk})
          {:ok, :bulk}
        end)
      end)

    queued_dependency =
      Task.async(fn ->
        ReadScheduler.execute(scheduler, :dependency, fn ->
          send(parent, {:started, :dependency})
          {:ok, :dependency}
        end)
      end)

    queued_control =
      Task.async(fn ->
        ReadScheduler.execute(scheduler, :control, fn ->
          send(parent, {:started, :control})
          wait_for_gate(control_gate)
          {:ok, :control}
        end)
      end)

    Agent.update(first_gate, fn _ -> true end)

    assert_receive {:started, :control}
    refute_receive {:started, :bulk}, 20
    refute_receive {:started, :dependency}, 20

    Agent.update(control_gate, fn _ -> true end)
    assert {:ok, :first} = Task.await(first, 1_000)
    assert {:ok, :control} = Task.await(queued_control, 1_000)
    assert {:ok, :bulk} = Task.await(queued_bulk, 1_000)
    assert {:ok, :dependency} = Task.await(queued_dependency, 1_000)
  end

  test "fails closed when the bounded waiting queue is full" do
    {:ok, scheduler} = ReadScheduler.start_link(max_concurrency: 1, queue_limit: 1)
    parent = self()
    {:ok, gate} = Agent.start_link(fn -> false end)

    running =
      Task.async(fn ->
        ReadScheduler.execute(scheduler, :dependency, fn ->
          send(parent, :running)
          wait_for_gate(gate)
          {:ok, :running}
        end)
      end)

    assert_receive :running

    waiting =
      Task.async(fn ->
        ReadScheduler.execute(scheduler, :dependency, fn -> {:ok, :waiting} end)
      end)

    # Wait until the scheduler has admitted the waiting call before probing the
    # next admission. This keeps the capacity assertion independent of task
    # scheduling order.
    eventually(fn -> ReadScheduler.stats(scheduler).queue_length == 1 end)

    assert {:error, :at_capacity} =
             ReadScheduler.execute(scheduler, :dependency, fn -> {:ok, :rejected} end)

    Agent.update(gate, fn _ -> true end)
    assert {:ok, :running} = Task.await(running, 1_000)
    assert {:ok, :waiting} = Task.await(waiting, 1_000)
  end

  test "retries one rate limited GET after Retry-After and pauses new starts" do
    {:ok, scheduler} =
      ReadScheduler.start_link(
        max_concurrency: 1,
        queue_limit: 5,
        throttle_fallback_ms: 10,
        max_backoff_ms: 100
      )

    attempts = Agent.start_link(fn -> 0 end) |> elem(1)

    result =
      ReadScheduler.execute(scheduler, :dependency, fn ->
        attempt = Agent.get_and_update(attempts, &{&1, &1 + 1})

        if attempt == 0,
          do: {:error, {:rate_limited, %{headers: %{"retry-after" => "0.02"}}}},
          else: {:ok, %{status: 200}}
      end)

    assert {:ok, %{status: 200}} = result
    assert Agent.get(attempts, & &1) == 2

    stats = ReadScheduler.stats(scheduler)
    assert stats.throttle_count == 1
    assert stats.retries == 1
    assert stats.backoff_count == 1
    assert stats.last_retry_after_ms == 20
  end

  test "a 429 pauses other queued GETs while allowing the one retry after the pause" do
    {:ok, scheduler} =
      ReadScheduler.start_link(
        max_concurrency: 1,
        queue_limit: 3,
        throttle_fallback_ms: 10,
        max_backoff_ms: 100
      )

    parent = self()
    attempts = Agent.start_link(fn -> 0 end) |> elem(1)

    rate_limited =
      Task.async(fn ->
        ReadScheduler.execute(scheduler, :dependency, fn ->
          attempt = Agent.get_and_update(attempts, &{&1, &1 + 1})

          if attempt == 0 do
            send(parent, {:rate_limited_started, self()})

            receive do
              :release_rate_limit ->
                {:error, {:rate_limited, %{headers: %{"retry-after" => "0.05"}}}}
            end
          else
            {:ok, :recovered}
          end
        end)
      end)

    assert_receive {:rate_limited_started, request_pid}

    queued_read =
      Task.async(fn ->
        ReadScheduler.execute(scheduler, :bulk, fn ->
          send(parent, :queued_read_started)
          {:ok, :started}
        end)
      end)

    eventually(fn -> ReadScheduler.stats(scheduler).queue_length == 1 end)
    send(request_pid, :release_rate_limit)

    refute_receive :queued_read_started, 20
    assert_receive :queued_read_started, 1_000
    assert {:ok, :recovered} = Task.await(rate_limited, 1_000)
    assert {:ok, :started} = Task.await(queued_read, 1_000)
  end

  test "uses X-RateLimit-Reset as an epoch timestamp separately from Retry-After" do
    reset = System.system_time(:second) + 1

    {:ok, scheduler} = ReadScheduler.start_link(max_backoff_ms: 100, throttle_fallback_ms: 5)

    assert {:error, {:rate_limited, _metadata}} =
             ReadScheduler.execute(scheduler, :control, fn ->
               {:error, {:rate_limited, %{headers: %{"retry-after" => "0", "x-ratelimit-reset" => Integer.to_string(reset)}}}}
             end)

    stats = ReadScheduler.stats(scheduler)
    assert stats.last_rate_limit_reset_at == reset
    assert stats.last_retry_after_ms == 0
    assert stats.retries == 1
  end

  test "pauses new reads at the provider remaining-request safety floor" do
    {:ok, scheduler} =
      ReadScheduler.start_link(
        max_concurrency: 1,
        queue_limit: 2,
        throttle_fallback_ms: 40,
        max_backoff_ms: 100
      )

    assert {:ok, %{status: 200}} =
             ReadScheduler.execute(scheduler, :control, fn ->
               {:ok,
                %{
                  status: 200,
                  headers: %{
                    "x-ratelimit-remaining" => "4",
                    "x-ratelimit-reset" => Integer.to_string(System.system_time(:second))
                  }
                }}
             end)

    parent = self()

    queued_read =
      Task.async(fn ->
        ReadScheduler.execute(scheduler, :bulk, fn ->
          send(parent, :safety_paused_read_started)
          {:ok, :started}
        end)
      end)

    refute_receive :safety_paused_read_started, 10
    assert_receive :safety_paused_read_started, 1_000
    assert {:ok, :started} = Task.await(queued_read, 1_000)

    stats = ReadScheduler.stats(scheduler)
    assert stats.safety_pause_count == 1
    assert stats.last_rate_limit_remaining == 4
  end

  test "retries transient 5xx and transport failures once, but does not retry permanent failures" do
    for first_result <- [
          {:error, :timeout},
          {:error, {:transport_error, :closed}},
          {:ok, %{status: 503}}
        ] do
      {:ok, scheduler} = ReadScheduler.start_link(backoff_base_ms: 1, max_backoff_ms: 10)
      attempts = Agent.start_link(fn -> 0 end) |> elem(1)

      assert {:ok, :recovered} =
               ReadScheduler.execute(scheduler, :control, fn ->
                 attempt = Agent.get_and_update(attempts, &{&1, &1 + 1})
                 if attempt == 0, do: first_result, else: {:ok, :recovered}
               end)

      assert Agent.get(attempts, & &1) == 2
    end

    for result <- [
          {:error, :unauthorized},
          {:error, :not_found},
          {:error, :provider_malformed},
          :malformed_result
        ] do
      {:ok, scheduler} = ReadScheduler.start_link()
      attempts = Agent.start_link(fn -> 0 end) |> elem(1)

      assert ^result =
               ReadScheduler.execute(scheduler, :control, fn ->
                 Agent.update(attempts, &(&1 + 1))
                 result
               end)

      assert Agent.get(attempts, & &1) == 1
    end
  end

  test "honors a bounded wait timeout and reclaims a queued request" do
    {:ok, scheduler} = ReadScheduler.start_link(max_concurrency: 1, queue_limit: 2)
    parent = self()
    {:ok, gate} = Agent.start_link(fn -> false end)

    running =
      Task.async(fn ->
        ReadScheduler.execute(scheduler, :dependency, fn ->
          send(parent, :running)
          wait_for_gate(gate)
          {:ok, :running}
        end)
      end)

    assert_receive :running

    assert {:error, :wait_timeout} =
             ReadScheduler.execute(
               scheduler,
               :bulk,
               fn ->
                 send(parent, :should_not_start)
                 {:ok, :late}
               end,
               wait_timeout: 20
             )

    Agent.update(gate, fn _ -> true end)
    assert {:ok, :running} = Task.await(running, 1_000)
    refute_receive :should_not_start, 50
    assert ReadScheduler.stats(scheduler).queue_length == 0
  end

  test "cancels a rate limited request while its retry is waiting in backoff" do
    {:ok, scheduler} =
      ReadScheduler.start_link(max_backoff_ms: 200, throttle_fallback_ms: 200)

    parent = self()

    caller =
      Task.async(fn ->
        ReadScheduler.execute(
          scheduler,
          :dependency,
          fn ->
            send(parent, {:rate_limit_attempt, self()})

            receive do
              :return_rate_limit -> {:error, {:rate_limited, %{headers: %{}}}}
            end
          end,
          wait_timeout: 40
        )
      end)

    assert_receive {:rate_limit_attempt, request_pid}, 1_000
    send(request_pid, :return_rate_limit)
    eventually(fn -> ReadScheduler.stats(scheduler).backoff_count == 1 end)

    assert {:error, :wait_timeout} = Task.await(caller, 1_000)
    eventually(fn -> ReadScheduler.stats(scheduler).queue_length == 0 end)
    assert ReadScheduler.stats(scheduler).retries == 1
  end

  test "caller cancellation reclaims an in-flight permit" do
    {:ok, scheduler} = ReadScheduler.start_link(max_concurrency: 1)
    parent = self()

    caller =
      spawn(fn ->
        ReadScheduler.execute(scheduler, :dependency, fn ->
          send(parent, :started)
          Process.sleep(:infinity)
        end)
      end)

    assert_receive :started
    Process.exit(caller, :kill)
    eventually(fn -> ReadScheduler.stats(scheduler).current_concurrency == 0 end)

    assert {:ok, :available} =
             ReadScheduler.execute(scheduler, :control, fn -> {:ok, :available} end)
  end

  test "reports request worker termination and reclaims its permit" do
    {:ok, scheduler} = ReadScheduler.start_link(max_concurrency: 1)
    parent = self()

    caller =
      Task.async(fn ->
        ReadScheduler.execute(scheduler, :dependency, fn ->
          send(parent, {:worker_started, self()})
          Process.sleep(:infinity)
        end)
      end)

    assert_receive {:worker_started, worker}, 1_000
    Process.exit(worker, :kill)

    assert {:error, {:request_terminated, :killed}} = Task.await(caller, 1_000)
    assert ReadScheduler.stats(scheduler).current_concurrency == 0
  end

  test "does not retry when explicitly disabled for a mutation boundary" do
    {:ok, scheduler} = ReadScheduler.start_link(backoff_base_ms: 1)
    attempts = Agent.start_link(fn -> 0 end) |> elem(1)

    assert {:error, :provider_unavailable} =
             ReadScheduler.execute(
               scheduler,
               :control,
               fn ->
                 Agent.update(attempts, &(&1 + 1))
                 {:error, :provider_unavailable}
               end,
               retry: false
             )

    assert Agent.get(attempts, & &1) == 1
    assert ReadScheduler.stats(scheduler).retries == 0
  end

  test "enforces the four permit and sixty starts per minute ceilings" do
    assert {:error, :invalid_concurrency_limit} = ReadScheduler.start_link(max_concurrency: 5)
    assert {:error, :invalid_start_limit} = ReadScheduler.start_link(start_limit: 61)
    assert {:error, :invalid_backoff_limit} = ReadScheduler.start_link(max_backoff_ms: 60_001)

    assert {:ok, scheduler} = ReadScheduler.start_link(max_concurrency: 1, start_limit: 1)
    assert {:ok, :ok} = ReadScheduler.execute(scheduler, :control, fn -> {:ok, :ok} end)
  end

  test "delays the sixty-first read until the rolling start window opens" do
    {:ok, scheduler} =
      ReadScheduler.start_link(
        max_concurrency: 4,
        queue_limit: 64,
        start_limit: 60,
        start_window_ms: 1_000
      )

    parent = self()

    tasks =
      for index <- 1..61 do
        Task.async(fn ->
          ReadScheduler.execute(scheduler, :bulk, fn ->
            send(parent, {:read_started, index, System.monotonic_time(:millisecond)})
            {:ok, index}
          end)
        end)
      end

    starts =
      Enum.map(1..61, fn _index ->
        assert_receive {:read_started, _request_index, started_at}, 3_000
        started_at
      end)
      |> Enum.sort()

    assert Enum.at(starts, 60) - Enum.at(starts, 0) >= 900
    assert Enum.all?(Task.await_many(tasks, 3_000), &match?({:ok, _value}, &1))
    assert ReadScheduler.stats(scheduler).attempts == 61
  end

  test "paces queued reads after the per-window start limit is reached" do
    {:ok, scheduler} =
      ReadScheduler.start_link(max_concurrency: 1, queue_limit: 2, start_limit: 1, start_window_ms: 100)

    parent = self()
    {:ok, gate} = Agent.start_link(fn -> false end)

    first =
      Task.async(fn ->
        ReadScheduler.execute(scheduler, :control, fn ->
          send(parent, :first_paced_read_started)
          wait_for_gate(gate)
          {:ok, :first}
        end)
      end)

    assert_receive :first_paced_read_started

    second =
      Task.async(fn ->
        ReadScheduler.execute(scheduler, :bulk, fn ->
          send(parent, {:second_paced_read_started, System.monotonic_time(:millisecond)})
          {:ok, :second}
        end)
      end)

    eventually(fn -> ReadScheduler.stats(scheduler).queue_length == 1 end)
    released_at = System.monotonic_time(:millisecond)
    Agent.update(gate, fn _ -> true end)

    assert_receive {:second_paced_read_started, started_at}, 1_000
    assert started_at - released_at >= 80
    assert {:ok, :first} = Task.await(first, 1_000)
    assert {:ok, :second} = Task.await(second, 1_000)
  end

  test "retries provider-unavailable GETs once" do
    {:ok, scheduler} = ReadScheduler.start_link(backoff_base_ms: 1, max_backoff_ms: 10)
    attempts = Agent.start_link(fn -> 0 end) |> elem(1)

    assert {:ok, :recovered} =
             ReadScheduler.execute(scheduler, :control, fn ->
               attempt = Agent.get_and_update(attempts, &{&1, &1 + 1})
               if attempt == 0, do: {:error, :provider_unavailable}, else: {:ok, :recovered}
             end)

    assert Agent.get(attempts, & &1) == 2
    assert ReadScheduler.stats(scheduler).retries == 1
  end

  test "keeps list-valued Retry-After seconds separate from reset epoch seconds" do
    reset = System.system_time(:second) + 1

    {:ok, scheduler} =
      ReadScheduler.start_link(max_backoff_ms: 100, throttle_fallback_ms: 5)

    assert {:error, {:rate_limited, _metadata}} =
             ReadScheduler.execute(scheduler, :control, fn ->
               {:error,
                {:rate_limited,
                 %{
                   headers: [
                     {"Retry-After", ["0.01"]},
                     {"X-RateLimit-Reset", [Integer.to_string(reset)]}
                   ]
                 }}}
             end)

    stats = ReadScheduler.stats(scheduler)
    assert stats.last_retry_after_seconds == 0.01
    assert stats.last_retry_after_ms == 10
    assert stats.last_rate_limit_reset_at == reset
  end

  test "ignores malformed rate-limit header entries without crashing the scheduler" do
    {:ok, scheduler} = ReadScheduler.start_link(throttle_fallback_ms: 1, max_backoff_ms: 10)

    assert {:error, {:rate_limited, _metadata}} =
             ReadScheduler.execute(scheduler, :dependency, fn ->
               {:error, {:rate_limited, %{headers: [%{bad: :entry}, {make_ref(), "0"}, {"retry-after", [nil]}]}}}
             end)

    assert ReadScheduler.stats(scheduler).attempts == 2

    assert {:error, {:rate_limited, _metadata}} =
             ReadScheduler.execute(
               scheduler,
               :control,
               fn -> {:error, {:rate_limited, %{headers: %{"retry-after" => "not-a-number"}}}} end,
               retry: false
             )

    assert ReadScheduler.stats(scheduler).attempts == 3
  end

  test "does not retry unknown provider errors" do
    for result <- [{:error, {:unknown, :timeout}}, :malformed] do
      {:ok, scheduler} = ReadScheduler.start_link(backoff_base_ms: 1, max_backoff_ms: 10)
      attempts = Agent.start_link(fn -> 0 end) |> elem(1)

      assert ^result =
               ReadScheduler.execute(scheduler, :dependency, fn ->
                 Agent.update(attempts, &(&1 + 1))
                 result
               end)

      assert Agent.get(attempts, & &1) == 1
    end
  end

  test "classifies alternate status and transport result forms without retrying" do
    for result <- [
          {:ok, %{"status" => 429}},
          {:error, {:provider_status, 429}},
          {:error, {:http_error, 429, :throttled}},
          {:error, :rate_limited},
          {:error, %{reason: :timeout}},
          {:error, %{kind: :closed}}
        ] do
      {:ok, scheduler} = ReadScheduler.start_link(throttle_fallback_ms: 1, max_backoff_ms: 10)

      assert ^result =
               ReadScheduler.execute(scheduler, :control, fn -> result end, retry: false)

      stats = ReadScheduler.stats(scheduler)
      assert stats.attempts == 1

      if match?({:ok, %{"status" => 429}}, result) or
           match?({:error, {:provider_status, 429}}, result) or
           match?({:error, {:http_error, 429, _}}, result) or result == {:error, :rate_limited} do
        assert stats.throttle_count == 1
      else
        assert stats.throttle_count == 0
      end
    end
  end

  test "parses atom keyed and malformed rate limit metadata safely" do
    {:ok, scheduler} = ReadScheduler.start_link(max_backoff_ms: 100, throttle_fallback_ms: 1)

    assert {:error, {:rate_limited, _metadata}} =
             ReadScheduler.execute(
               scheduler,
               :control,
               fn ->
                 {:error,
                  {:rate_limited,
                   %{
                     headers: %{
                       :retry_after => [0.01],
                       "x-ratelimit-remaining" => ["3"],
                       "x-ratelimit-reset" => ["-1"]
                     }
                   }}}
               end,
               retry: false
             )

    stats = ReadScheduler.stats(scheduler)
    assert stats.last_retry_after_seconds == 0.01
    assert stats.last_retry_after_ms == 10
    assert stats.last_rate_limit_remaining == 3
    assert stats.last_rate_limit_reset_at == nil
  end

  test "parses numeric rate limit headers and tolerates absent header collections" do
    reset = System.system_time(:second) + 1
    {:ok, scheduler} = ReadScheduler.start_link(max_backoff_ms: 100, throttle_fallback_ms: 1)

    assert {:error, {:rate_limited, _metadata}} =
             ReadScheduler.execute(
               scheduler,
               :control,
               fn ->
                 {:error,
                  {:rate_limited,
                   %{
                     headers: %{
                       :retry_after => 0,
                       "x-ratelimit-remaining" => 3,
                       "x-ratelimit-reset" => [[Integer.to_string(reset)]]
                     }
                   }}}
               end,
               retry: false
             )

    stats = ReadScheduler.stats(scheduler)
    assert stats.last_retry_after_seconds == 0
    assert stats.last_rate_limit_remaining == 3
    assert stats.last_rate_limit_reset_at == reset

    assert {:error, {:rate_limited, _metadata}} =
             ReadScheduler.execute(
               scheduler,
               :control,
               fn ->
                 {:error, {:rate_limited, %{headers: nil}}}
               end,
               retry: false
             )

    assert ReadScheduler.stats(scheduler).attempts == 2
  end

  test "contains failures while monitoring malformed scheduler references" do
    assert {:error, :scheduler_unavailable} =
             ReadScheduler.execute({:via, ExitingRegistry, :missing}, :control, fn -> {:ok, :unused} end)
  end

  test "returns a bounded scheduler termination error and kills in-flight work" do
    {:ok, scheduler} = ReadScheduler.start_link(max_concurrency: 1)
    Process.unlink(scheduler)
    parent = self()

    caller =
      spawn(fn ->
        result =
          ReadScheduler.execute(scheduler, :dependency, fn ->
            send(parent, :started)
            Process.sleep(:infinity)
          end)

        send(parent, {:scheduler_result, result})
      end)

    assert_receive :started
    eventually(fn -> ReadScheduler.stats(scheduler).current_concurrency == 1 end)
    GenServer.stop(scheduler, :shutdown)

    assert_receive {:scheduler_result, {:error, :scheduler_terminated}}, 1_000
    refute Process.alive?(caller)
  end

  test "scheduler crashes cancel its request worker and release its caller" do
    {:ok, scheduler} = ReadScheduler.start_link(max_concurrency: 1)
    Process.unlink(scheduler)
    parent = self()

    caller =
      spawn(fn ->
        result =
          ReadScheduler.execute(scheduler, :dependency, fn ->
            send(parent, {:request_pid, self()})
            Process.sleep(:infinity)
          end)

        send(parent, {:scheduler_result, result})
      end)

    assert_receive {:request_pid, request_pid}
    Process.exit(scheduler, :kill)

    assert_receive {:scheduler_result, {:error, :scheduler_terminated}}, 1_000
    eventually(fn -> not Process.alive?(request_pid) end)
    refute Process.alive?(caller)
  end

  test "rejects unbounded caller waits" do
    {:ok, scheduler} = ReadScheduler.start_link()

    assert {:error, :invalid_request_options} =
             ReadScheduler.execute(scheduler, :control, fn -> {:ok, :unused} end, wait_timeout: :infinity)
  end

  defp wait_for_gate(gate) do
    if Agent.get(gate, & &1) do
      :ok
    else
      Process.sleep(1)
      wait_for_gate(gate)
    end
  end

  defp eventually(fun, attempts \\ 20)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: flunk("condition did not become true")
end
