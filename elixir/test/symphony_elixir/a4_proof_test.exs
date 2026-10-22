defmodule SymphonyElixir.WorkControl.A4ProofTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.WorkControl.A4Proof
  alias SymphonyElixir.WorkControl.{ProviderMutationEnvelope, TransitionAttempt}

  test "rejects acquisition before the persisted mutation boundary without contacting the controller" do
    controller = self()
    capability = capability(controller)
    attempt = %TransitionAttempt{state: :prepared}

    envelope = %ProviderMutationEnvelope{
      provider_request_id: "preq_00000000-0000-4000-8000-000000000001",
      transition_attempt_id: "attempt-1",
      work_item_id: "work-1",
      provider: :plane,
      workspace_id: "workspace-1",
      project_id: "project-1",
      requested_from: :started,
      requested_to: :completed,
      target_provider_state_id: "state-1",
      target_provider_state_group: :completed,
      provider_contract_fingerprint: "fingerprint",
      submitted_at: DateTime.utc_now()
    }

    assert {:error, {:dispatch_witness_failed, :mutation_not_persisted}} =
             A4Proof.acquire(capability, attempt, envelope, binding_data())

    refute_received {:a4_manifest_request, _, _, _, _}
  end

  test "consume requires a ready token and atomically accepts only one use" do
    {reply_to, reply_monitor} = test_reply_channel(self())

    token = %A4Proof{
      owner: self(),
      controller: self(),
      controller_ref: make_ref(),
      controller_monitor: Process.monitor(self()),
      reply_to: reply_to,
      reply_monitor: reply_monitor,
      bindings: binding_data(),
      manifest: %{},
      expiry: System.monotonic_time(:millisecond) + 2_000,
      ready: %{bound_port: 1234},
      used: :atomics.new(2, signed: false)
    }

    assert :ok = A4Proof.consume(token, binding_data())
    assert_receive {:DOWN, ^reply_monitor, :process, ^reply_to, _reason}, 100
    assert {:error, {:dispatch_witness_failed, :proof_token_consumed}} = A4Proof.consume(token, binding_data())
  end

  test "rejects a token from another owner process" do
    token = %A4Proof{owner: spawn(fn -> Process.sleep(5_000) end)}
    assert {:error, {:dispatch_witness_failed, :proof_token_owner_mismatch}} = A4Proof.ready(token)
  end

  test "rejects a controller capability on another BEAM node before requesting a manifest" do
    {attempt, envelope} = submitted_identity()
    remote_controller = remote_pid()
    assert node(remote_controller) != node()

    assert {:error, {:dispatch_witness_failed, :remote_proof_controller}} =
             A4Proof.acquire(capability(remote_controller), attempt, envelope, binding_data())

    refute_received {:a4_manifest_request, _, _, _, _}
  end

  test "release clears the controller monitor owned by the token process" do
    controller = spawn(fn -> Process.sleep(5_000) end)
    monitor = Process.monitor(controller)
    token = %A4Proof{owner: self(), controller: controller, controller_monitor: monitor}

    assert :ok = A4Proof.release(token)
    Process.exit(controller, :kill)
    refute_receive {:DOWN, ^monitor, :process, ^controller, _reason}
  end

  test "release is prompt when the reply receiver was already stopped" do
    reply_to = spawn(fn -> :ok end)
    reply_monitor = Process.monitor(reply_to)
    token = %A4Proof{owner: self(), reply_to: reply_to, reply_monitor: reply_monitor}

    assert :ok = A4Proof.release(token)
    started_at = System.monotonic_time(:millisecond)
    assert :ok = A4Proof.release(token)
    assert System.monotonic_time(:millisecond) - started_at < 100
  end

  test "consume rejects a controller duplicate queued after READY" do
    {attempt, envelope} = submitted_identity()
    capability = capability(self())

    controller =
      spawn(fn ->
        receive do
          {:a4_manifest_request, reply_to, ref, request_id, _safe} ->
            payload = manifest_payload(envelope, attempt, capability)
            send(reply_to, {:a4_manifest_response, self(), ref, request_id, payload})
        end

        receive do
          {:a4_ready_request, reply_to, ref, request_id, _safe} ->
            send(reply_to, {:a4_ready_response, self(), ref, request_id, valid_ready(envelope)})
        end

        receive do
          :finish -> :ok
        end
      end)

    capability = %{capability | controller: controller}

    assert {:ok, token} = A4Proof.acquire(capability, attempt, envelope, binding_data())
    assert {:ok, ready_token} = A4Proof.ready(token)

    send(
      self(),
      {:a4_ready_response, controller, token.controller_ref, make_ref(), valid_ready(envelope)}
    )

    assert {:error, {:dispatch_witness_failed, :duplicate_or_unsolicited_controller_message}} =
             A4Proof.consume(ready_token, binding_data())

    send(controller, :finish)
  end

  test "consume rejects a READY duplicate sent after the first reply returns" do
    test_pid = self()
    {attempt, envelope} = submitted_identity()
    capability = capability(self())

    controller =
      spawn(fn ->
        receive do
          {:a4_manifest_request, reply_to, ref, request_id, _safe} ->
            payload = manifest_payload(envelope, attempt, capability)
            send(reply_to, {:a4_manifest_response, self(), ref, request_id, payload})
        end

        receive do
          {:a4_ready_request, reply_to, ref, request_id, _safe} ->
            response = {:a4_ready_response, self(), ref, request_id, valid_ready(envelope)}
            send(reply_to, response)

            receive do
              :send_late_duplicate ->
                send(reply_to, response)
                send(test_pid, :late_duplicate_sent)
            end
        end

        receive do
          :finish -> :ok
        end
      end)

    capability = %{capability | controller: controller}

    assert {:ok, token} = A4Proof.acquire(capability, attempt, envelope, binding_data())
    assert {:ok, ready_token} = A4Proof.ready(token)

    send(controller, :send_late_duplicate)
    assert_receive :late_duplicate_sent

    assert {:error, {:dispatch_witness_failed, :duplicate_or_unsolicited_controller_message}} =
             A4Proof.consume(ready_token, binding_data())

    send(controller, :finish)
  end

  test "rejects a manifest with conflicting atom and string identity keys" do
    {attempt, envelope} = submitted_identity()
    capability = capability(self())
    wrong_request_id = "preq_00000000-0000-4000-8000-000000000002"

    controller =
      spawn(fn ->
        receive do
          {:a4_manifest_request, reply_to, ref, request_id, _safe} ->
            payload =
              manifest_payload(envelope, attempt, capability, manifest_overrides: %{"provider_request_id" => wrong_request_id})

            payload = %{
              payload
              | manifest: Map.put(payload.manifest, :provider_request_id, envelope.provider_request_id)
            }

            send(reply_to, {:a4_manifest_response, self(), ref, request_id, payload})
        end

        receive do
          :finish -> :ok
        end
      end)

    on_exit(fn -> Process.exit(controller, :kill) end)
    capability = %{capability | controller: controller}

    assert {:error, {:dispatch_witness_failed, {:proof_manifest_mismatch, :canonical_or_hash}}} =
             A4Proof.acquire(capability, attempt, envelope, binding_data())
  end

  test "reply channel exits when the manifest authorization expires" do
    test_pid = self()
    {attempt, envelope} = submitted_identity()
    capability = %{capability(self()) | timeout_ms: 5_000}

    controller =
      spawn(fn ->
        receive do
          {:a4_manifest_request, reply_to, ref, request_id, _safe} ->
            expires_at = DateTime.add(DateTime.utc_now(), 250, :millisecond) |> DateTime.to_iso8601()
            payload = manifest_payload(envelope, attempt, capability, manifest_overrides: %{"expires_at" => expires_at})
            send(test_pid, {:reply_channel_pid, reply_to})
            send(reply_to, {:a4_manifest_response, self(), ref, request_id, payload})
        end

        receive do
          :finish -> :ok
        end
      end)

    on_exit(fn -> Process.exit(controller, :kill) end)
    capability = %{capability | controller: controller}

    assert {:ok, token} = A4Proof.acquire(capability, attempt, envelope, binding_data())
    assert_receive {:reply_channel_pid, reply_to}
    reply_monitor = Process.monitor(reply_to)

    assert_receive {:DOWN, ^reply_monitor, :process, ^reply_to, _reason}, 1_000
    assert :ok = A4Proof.release(token)
  end

  test "rejects oversized request bounds and envelope identity drift before controller messaging" do
    {attempt, envelope} = submitted_identity()
    capability = capability(self())

    assert {:error, {:dispatch_witness_failed, {:proof_manifest_mismatch, :body_bytes}}} =
             A4Proof.acquire(capability, attempt, envelope, %{binding_data() | body_bytes: 513})

    assert {:error, {:dispatch_witness_failed, {:proof_manifest_mismatch, :path_bytes}}} =
             A4Proof.acquire(capability, attempt, envelope, %{binding_data() | path_bytes: 2049})

    assert {:error, {:dispatch_witness_failed, :persisted_attempt_envelope_mismatch}} =
             A4Proof.acquire(
               capability,
               attempt,
               %{envelope | target_provider_state_id: "moved"},
               binding_data()
             )

    refute_received {:a4_manifest_request, _, _, _, _}
  end

  test "rejects a manifest response from a different controller reference" do
    {attempt, envelope} = submitted_identity()
    parent = self()
    capability = capability(self())

    controller =
      spawn(fn ->
        receive do
          {:a4_manifest_request, reply_to, _ref, request_id, _safe} ->
            payload = manifest_payload(envelope, attempt, capability)
            send(reply_to, {:a4_manifest_response, self(), make_ref(), request_id, payload})
            send(parent, :controller_replied)
        end
      end)

    capability = %{capability | controller: controller}

    assert {:error, {:dispatch_witness_failed, :wrong_controller_reference}} =
             A4Proof.acquire(capability, attempt, envelope, binding_data())

    assert_received :controller_replied
    refute_received {:a4_ready_request, _, _, _, _}
  end

  test "controller replies use a one-use receiver instead of the token owner" do
    {attempt, envelope} = submitted_identity()
    parent = self()
    capability = capability(self())

    controller =
      spawn(fn ->
        receive do
          {:a4_manifest_request, reply_to, ref, request_id, _safe} ->
            send(parent, {:manifest_reply_pid, reply_to})
            payload = manifest_payload(envelope, attempt, capability)
            send(reply_to, {:a4_manifest_response, self(), ref, request_id, payload})
        end

        receive do
          :finish -> :ok
        end
      end)

    capability = %{capability | controller: controller}
    assert {:ok, token} = A4Proof.acquire(capability, attempt, envelope, binding_data())
    assert_received {:manifest_reply_pid, reply_pid}
    refute reply_pid == self()
    reply_monitor = Process.monitor(reply_pid)
    assert :ok = A4Proof.release(token)
    assert_receive {:DOWN, ^reply_monitor, :process, ^reply_pid, _reason}
    send(controller, :finish)
  end

  test "reply receiver exits when its request owner dies before replying" do
    {attempt, envelope} = submitted_identity()
    parent = self()
    capability = capability(self())

    controller =
      spawn(fn ->
        receive do
          {:a4_manifest_request, reply_to, _ref, _request_id, _safe} ->
            send(parent, {:manifest_reply_pid, reply_to})
            Process.sleep(10_000)
        end
      end)

    capability = %{capability | controller: controller, timeout_ms: 5_000}

    owner =
      spawn(fn ->
        A4Proof.acquire(capability, attempt, envelope, binding_data())
      end)

    assert_receive {:manifest_reply_pid, reply_pid}
    reply_monitor = Process.monitor(reply_pid)

    try do
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^reply_monitor, :process, ^reply_pid, _reason}, 500
    after
      if Process.alive?(reply_pid), do: Process.exit(reply_pid, :kill)
      Process.exit(controller, :kill)
    end
  end

  test "rejects a manifest whose reported hash does not match its canonical bytes" do
    {attempt, envelope} = submitted_identity()
    capability = capability(self())

    controller =
      spawn(fn ->
        receive do
          {:a4_manifest_request, reply_to, ref, request_id, _safe} ->
            payload = manifest_payload(envelope, attempt, capability)
            corrupt = %{payload | sha256: String.duplicate("0", 64)}
            send(reply_to, {:a4_manifest_response, self(), ref, request_id, corrupt})
        end
      end)

    capability = %{capability | controller: controller}

    assert {:error, {:dispatch_witness_failed, {:proof_manifest_mismatch, :canonical_or_hash}}} =
             A4Proof.acquire(capability, attempt, envelope, binding_data())
  end

  test "fails promptly when the controller exits or withholds its manifest response" do
    {attempt, envelope} = submitted_identity()
    parent = self()
    capability = capability(self())

    exiting_controller =
      spawn(fn ->
        receive do
          {:a4_manifest_request, _reply_to, _ref, _request_id, _safe} -> exit(:kill)
        end
      end)

    exiting_capability = %{capability | controller: exiting_controller}

    assert {:error, {:dispatch_witness_failed, {:proof_controller_exit, :controller_failed}}} =
             A4Proof.acquire(exiting_capability, attempt, envelope, binding_data())

    silent_controller =
      spawn(fn ->
        receive do
          {:a4_manifest_request, _reply_to, _ref, _request_id, _safe} ->
            send(parent, :silent_controller_received)
        end

        Process.sleep(1_000)
      end)

    silent_capability = %{capability | controller: silent_controller, timeout_ms: 25}

    assert {:error, {:dispatch_witness_failed, :proof_manifest_timeout}} =
             A4Proof.acquire(silent_capability, attempt, envelope, binding_data())

    assert_received :silent_controller_received
    Process.exit(silent_controller, :kill)
  end

  test "rejects an expired manifest before returning a token" do
    {attempt, envelope} = submitted_identity()
    parent = self()
    capability = capability(self())

    controller =
      spawn(fn ->
        receive do
          {:a4_manifest_request, reply_to, ref, request_id, _safe} ->
            payload = manifest_payload(envelope, attempt, capability, expired: true)
            send(reply_to, {:a4_manifest_response, self(), ref, request_id, payload})
            send(parent, :controller_replied)
        end
      end)

    capability = %{capability | controller: controller}

    assert {:error, {:dispatch_witness_failed, {:proof_manifest_mismatch, :expires_at}}} =
             A4Proof.acquire(capability, attempt, envelope, binding_data())

    assert_received :controller_replied
    refute_received {:a4_ready_request, _, _, _, _}
  end

  test "token expires when the manifest window ends even if its local timeout is longer" do
    {attempt, envelope} = submitted_identity()
    capability = capability(self())
    expires_at = DateTime.add(DateTime.utc_now(), 1_000, :millisecond) |> DateTime.to_iso8601()

    controller =
      spawn(fn ->
        receive do
          {:a4_manifest_request, reply_to, ref, request_id, _safe} ->
            payload =
              manifest_payload(envelope, attempt, capability, manifest_overrides: %{"expires_at" => expires_at})

            send(reply_to, {:a4_manifest_response, self(), ref, request_id, payload})
        end

        receive do
          {:a4_ready_request, reply_to, ref, request_id, _safe} ->
            send(reply_to, {:a4_ready_response, self(), ref, request_id, valid_ready(envelope)})

          :finish ->
            :ok
        end
      end)

    capability = %{capability | controller: controller, timeout_ms: 10_000}

    assert {:ok, token} = A4Proof.acquire(capability, attempt, envelope, binding_data())
    Process.sleep(1_050)

    assert {:error, {:dispatch_witness_failed, :proof_token_expired}} = A4Proof.ready(token)
    refute_received {:a4_ready_request, _, _, _, _}
    send(controller, :finish)
  end

  test "rejects manifest timestamps with invalid JSON types without raising" do
    {attempt, envelope} = submitted_identity()
    capability = capability(self())

    for {field, value, mismatch_field} <- [
          {"not_before", 123, :expires_at},
          {"expires_at", %{"unexpected" => true}, :expires_at}
        ] do
      controller =
        manifest_controller(attempt, envelope, capability, %{field => value})

      assert {:error, {:dispatch_witness_failed, {:proof_manifest_mismatch, ^mismatch_field}}} =
               A4Proof.acquire(
                 %{capability | controller: controller},
                 attempt,
                 envelope,
                 binding_data()
               )
    end
  end

  test "rejects a manifest map with non-text keys without raising" do
    {attempt, envelope} = submitted_identity()
    capability = capability(self())

    controller =
      spawn(fn ->
        receive do
          {:a4_manifest_request, reply_to, ref, request_id, _safe} ->
            payload = manifest_payload(envelope, attempt, capability)
            malformed = %{payload | manifest: Map.put(payload.manifest, {:unexpected, :key}, "invalid")}
            send(reply_to, {:a4_manifest_response, self(), ref, request_id, malformed})
        end
      end)

    assert {:error, {:dispatch_witness_failed, {:proof_manifest_mismatch, :canonical_or_hash}}} =
             A4Proof.acquire(
               %{capability | controller: controller},
               attempt,
               envelope,
               binding_data()
             )

    refute_received {:a4_ready_request, _, _, _, _}
  end

  test "rejects a READY response with an invalid port" do
    {attempt, envelope} = submitted_identity()
    parent = self()
    capability = capability(self())

    controller =
      spawn(fn ->
        receive do
          {:a4_manifest_request, reply_to, ref, request_id, _safe} ->
            payload = manifest_payload(envelope, attempt, capability)
            send(reply_to, {:a4_manifest_response, self(), ref, request_id, payload})
        end

        receive do
          {:a4_ready_request, reply_to, ref, request_id, _safe} ->
            send(
              reply_to,
              {:a4_ready_response, self(), ref, request_id,
               %{
                 provider_request_id: envelope.provider_request_id,
                 listen_host: "127.0.0.1",
                 bound_port: 0,
                 script_blob_sha256: String.duplicate("c", 64)
               }}
            )

            send(parent, :ready_replied)
        end

        receive do
          :finish -> :ok
        end
      end)

    capability = %{capability | controller: controller}
    assert {:ok, token} = A4Proof.acquire(capability, attempt, envelope, binding_data())
    assert {:error, {:dispatch_witness_failed, {:proof_manifest_mismatch, :ready}}} = A4Proof.ready(token)
    assert_received :ready_replied
    send(controller, :finish)
  end

  test "rejects each manifest identity field before requesting READY" do
    {attempt, envelope} = submitted_identity()

    identity_cases = [
      {"provider_request_id", "preq_00000000-0000-4000-8000-000000000002"},
      {"transition_attempt_id", "attempt-other"},
      {"work_item_id", "work-other"},
      {"workspace_id", "workspace-other"},
      {"project_id", "project-other"},
      {"target_state_id", "target-other"},
      {"method", "POST"},
      {"origin_base_url", "https://other.invalid"},
      {"origin_authority", "other.invalid:443"},
      {"candidate_sha", String.duplicate("d", 40)},
      {"candidate_tree", String.duplicate("e", 40)}
    ]

    for {key, value} <- identity_cases do
      capability = capability(self())
      controller = manifest_controller(attempt, envelope, capability, %{key => value})
      capability = %{capability | controller: controller}

      assert {:error, {:dispatch_witness_failed, {:proof_manifest_mismatch, _field}}} =
               A4Proof.acquire(capability, attempt, envelope, binding_data()),
             key

      refute_received {:a4_ready_request, _, _, _, _}
      send(controller, :finish)
    end
  end

  test "fails closed for wrong, duplicate, and malformed READY responses and controller exit or timeout" do
    {attempt, envelope} = submitted_identity()

    cases = [
      {:wrong_ref, :wrong_controller_reference},
      {:wrong_pid, :wrong_controller_reference},
      {:duplicate, :duplicate_or_unsolicited_controller_message},
      {:malformed, :invalid_ready_response},
      {:malformed_key, {:proof_manifest_mismatch, :ready}},
      {:credential_environment, {:proof_manifest_mismatch, :ready}},
      {:python_version, {:proof_manifest_mismatch, :ready}},
      {:oversized, {:proof_manifest_mismatch, :ready}},
      {:exit, {:proof_controller_exit, :controller_failed}},
      {:timeout, :proof_ready_timeout}
    ]

    for {mode, expected_reason} <- cases do
      capability = capability(self())
      capability = if mode == :timeout, do: %{capability | timeout_ms: 40}, else: capability
      controller = ready_controller(attempt, envelope, capability, mode)
      capability = %{capability | controller: controller}

      assert {:ok, token} = A4Proof.acquire(capability, attempt, envelope, binding_data())
      assert {:error, {:dispatch_witness_failed, ^expected_reason}} = A4Proof.ready(token)
      refute Process.whereis(A4Proof.finch_name())
      refute_received :witness_ack
      send(controller, :finish)
    end
  end

  test "rejects an expired token from its original owner before requesting READY" do
    {attempt, envelope} = submitted_identity()
    capability = capability(self())
    controller = manifest_controller(attempt, envelope, capability, %{})
    capability = %{capability | controller: controller}

    assert {:ok, token} = A4Proof.acquire(capability, attempt, envelope, binding_data())
    expired = %{token | expiry: System.monotonic_time(:millisecond) - 1}
    assert {:error, {:dispatch_witness_failed, :proof_token_expired}} = A4Proof.ready(expired)
    refute_received {:a4_ready_request, _, _, _, _}
    send(controller, :finish)
  end

  test "does not accept READY before a preflight token exists" do
    assert {:error, {:dispatch_witness_failed, :proof_token_owner_mismatch}} = A4Proof.ready(nil)
    refute_received {:a4_ready_request, _, _, _, _}
  end

  test "validates the controller manifest and READY before one-shot consume" do
    test_pid = self()
    {attempt, envelope} = submitted_identity()
    binding = binding_data()
    capability = capability(self())

    controller =
      spawn(fn ->
        receive do
          {:a4_manifest_request, reply_to, ref, request_id, safe_request} ->
            send(test_pid, {:safe_request, safe_request})
            payload = manifest_payload(envelope, attempt, capability)
            send(reply_to, {:a4_manifest_response, self(), ref, request_id, payload})
        end

        receive do
          {:a4_ready_request, reply_to, ref, request_id, ready_request} ->
            assert ready_request.provider_request_id == envelope.provider_request_id

            send(reply_to, {
              :a4_ready_response,
              self(),
              ref,
              request_id,
              %{
                type: "READY",
                provider_request_id: envelope.provider_request_id,
                listen_host: "127.0.0.1",
                bound_port: 41_001,
                python_version: "3.12",
                script_blob_sha256: manifest_payload(envelope, attempt, capability).manifest["relay_script_blob_sha256"],
                environment_names: ["LANG", "PATH"]
              }
            })
        end

        receive do
          {:a4_manifest_request, reply_to, ref, request_id, _safe_request} ->
            payload = manifest_payload(envelope, attempt, capability)
            send(reply_to, {:a4_manifest_response, self(), ref, request_id, payload})

          :finish ->
            :ok
        end

        receive do
          :finish -> :ok
        end
      end)

    capability = %{capability | controller: controller}
    assert {:ok, token} = A4Proof.acquire(capability, attempt, envelope, binding)
    assert_received {:safe_request, safe_request}
    refute Map.has_key?(safe_request, :body)
    refute Map.has_key?(safe_request, :path)

    assert {:ok, ready_token} = A4Proof.ready(token)
    assert ready_token.ready.bound_port == 41_001
    assert {:error, {:dispatch_witness_failed, _}} = A4Proof.ready(token)
    assert :ok = A4Proof.consume(ready_token, binding)

    assert {:error, {:dispatch_witness_failed, :proof_already_active}} =
             A4Proof.acquire(capability, attempt, envelope, binding)

    send(controller, :finish)
  end

  defp capability(controller) do
    %{
      controller: controller,
      ref: make_ref(),
      timeout_ms: 100,
      candidate_sha: String.duplicate("a", 40),
      candidate_tree: String.duplicate("b", 40),
      gate: :atomics.new(1, signed: false)
    }
  end

  defp remote_pid do
    local_node = Atom.to_string(node())
    remote_node = "r@" <> String.duplicate("x", byte_size(local_node) - 2)

    self()
    |> :erlang.term_to_binary()
    |> :binary.replace(local_node, remote_node)
    |> :erlang.binary_to_term()
  end

  defp test_reply_channel(owner) do
    reply_to =
      spawn(fn ->
        owner_monitor = Process.monitor(owner)
        test_reply_channel_loop(owner, owner_monitor)
      end)

    {reply_to, Process.monitor(reply_to)}
  end

  defp test_reply_channel_loop(owner, owner_monitor) do
    receive do
      {:DOWN, ^owner_monitor, :process, ^owner, _reason} ->
        :ok

      {:a4_controller_reply_check, ^owner, check_ref, _expiry} ->
        send(owner, {:a4_controller_reply_checked, self(), check_ref})
        test_reply_channel_loop(owner, owner_monitor)

      {:a4_controller_reply_close, ^owner, close_ref} ->
        send(owner, {:a4_controller_reply_closed, self(), close_ref})
    end
  end

  defp submitted_identity do
    request_id = "preq_00000000-0000-4000-8000-000000000001"

    values = %{
      state: :mutation_submitted,
      provider_request_id: request_id,
      transition_attempt_id: "attempt-1",
      work_item_id: "work-1",
      workspace_id: "workspace-1",
      project_id: "project-1",
      target_provider_state_id: "state-1"
    }

    attempt = struct(TransitionAttempt, values)

    envelope = %ProviderMutationEnvelope{
      provider_request_id: request_id,
      transition_attempt_id: "attempt-1",
      work_item_id: "work-1",
      provider: :plane,
      workspace_id: "workspace-1",
      project_id: "project-1",
      requested_from: :started,
      requested_to: :completed,
      target_provider_state_id: "state-1",
      target_provider_state_group: :completed,
      provider_contract_fingerprint: "fingerprint",
      submitted_at: DateTime.utc_now()
    }

    {attempt, envelope}
  end

  defp manifest_payload(envelope, attempt, capability, opts \\ []) do
    manifest = %{
      "schema" => "a4-v2_1",
      "manifest_id" => "manifest-1",
      "experiment_scope" => "single_designated_state_patch",
      "provider_request_id" => envelope.provider_request_id,
      "transition_attempt_id" => attempt.transition_attempt_id,
      "work_item_id" => attempt.work_item_id,
      "workspace_id" => attempt.workspace_id,
      "project_id" => attempt.project_id,
      "target_state_id" => attempt.target_provider_state_id,
      "method" => "PATCH",
      "origin_kind" => "live_plane",
      "origin_authority" => "api.plane.so:443",
      "origin_base_url" => "https://api.plane.so",
      "candidate_sha" => capability.candidate_sha,
      "candidate_tree" => capability.candidate_tree,
      "relay_script_blob_sha256" => String.duplicate("c", 64),
      "python_path" => "/usr/bin/python3",
      "python_version" => "3.12",
      "max_dispatch" => 1,
      "max_connect" => 1,
      "max_client_app_records" => 1,
      "tls_versions" => ["tlsv1.2"],
      "not_before" => DateTime.add(DateTime.utc_now(), -60, :second) |> DateTime.to_iso8601(),
      "expires_at" =>
        DateTime.add(DateTime.utc_now(), if(Keyword.get(opts, :expired, false), do: -120, else: 300), :second)
        |> DateTime.to_iso8601(),
      "operator_authorization_ref" => "auth-1",
      "manifest_sha256" => ""
    }

    manifest = Map.merge(manifest, Keyword.get(opts, :manifest_overrides, %{}))

    hash =
      manifest
      |> Map.delete("manifest_sha256")
      |> canonical_json()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    manifest = Map.put(manifest, "manifest_sha256", hash)
    json = canonical_json(manifest)
    %{manifest: manifest, canonical_json: json, sha256: hash}
  end

  defp canonical_json(map) do
    ordered = Jason.OrderedObject.new(map |> Enum.sort_by(&elem(&1, 0)))
    Jason.encode!(ordered)
  end

  defp manifest_controller(attempt, envelope, capability, overrides) do
    spawn(fn ->
      receive do
        {:a4_manifest_request, reply_to, ref, request_id, _safe} ->
          payload = manifest_payload(envelope, attempt, capability, manifest_overrides: overrides)
          send(reply_to, {:a4_manifest_response, self(), ref, request_id, payload})
      end

      receive do
        {:a4_ready_request, reply_to, ref, request_id, _safe} ->
          send(reply_to, {:a4_ready_response, self(), ref, request_id, valid_ready(envelope)})

        :finish ->
          :ok
      after
        500 -> :ok
      end
    end)
  end

  defp ready_controller(attempt, envelope, capability, mode) do
    parent = self()

    spawn(fn ->
      receive do
        {:a4_manifest_request, reply_to, ref, request_id, _safe} ->
          payload = manifest_payload(envelope, attempt, capability)
          send(reply_to, {:a4_manifest_response, self(), ref, request_id, payload})
      end

      receive do
        {:a4_ready_request, reply_to, ref, request_id, _safe} ->
          case mode do
            :exit ->
              exit(:kill)

            :timeout ->
              Process.sleep(100)

            :duplicate ->
              response = {:a4_ready_response, self(), ref, request_id, valid_ready(envelope)}
              queue_competing_ready_responses(reply_to, response)

            _ ->
              send_ready_response(mode, reply_to, parent, ref, request_id, envelope)
          end
      end

      receive do
        :finish -> :ok
      after
        500 -> :ok
      end
    end)
  end

  defp queue_competing_ready_responses(reply_to, response) do
    controller = self()
    true = :erlang.suspend_process(reply_to)

    try do
      workers =
        Enum.map(1..2, fn _index ->
          spawn(fn ->
            send(reply_to, response)
            send(controller, {:ready_delivery_queued, self()})
          end)
        end)

      Enum.each(workers, fn worker ->
        receive do
          {:ready_delivery_queued, ^worker} -> :ok
        after
          500 -> raise "duplicate READY delivery did not queue"
        end
      end)
    after
      :erlang.resume_process(reply_to)
    end
  end

  defp send_ready_response(mode, reply_to, parent, ref, request_id, envelope) do
    ready = valid_ready(envelope)
    long_version = %{ready | python_version: String.duplicate("3", 100)}

    responses = %{
      wrong_ref: {:a4_ready_response, self(), make_ref(), request_id, ready},
      wrong_pid: {:a4_ready_response, parent, ref, request_id, ready},
      malformed: {:a4_ready_response, self(), ref, request_id, :malformed},
      malformed_key: {:a4_ready_response, self(), ref, request_id, Map.put(ready, {:unexpected, :key}, "invalid")},
      credential_environment: {:a4_ready_response, self(), ref, request_id, %{ready | environment_names: ["PLANE_API_KEY"]}},
      python_version: {:a4_ready_response, self(), ref, request_id, long_version},
      oversized: {:a4_ready_response, self(), ref, request_id, oversized_ready(ready)}
    }

    send(reply_to, Map.fetch!(responses, mode))
  end

  defp oversized_ready(ready) do
    names = Enum.map(1..64, &String.duplicate(Integer.to_string(&1), 128))
    %{ready | environment_names: names}
  end

  defp valid_ready(envelope) do
    %{
      type: "READY",
      provider_request_id: envelope.provider_request_id,
      listen_host: "127.0.0.1",
      bound_port: 41_002,
      python_version: "3.12",
      script_blob_sha256: String.duplicate("c", 64),
      environment_names: ["LANG", "PATH"]
    }
  end

  defp binding_data do
    %{
      witness_required?: true,
      durable?: true,
      origin_base_url: "https://api.plane.so",
      origin_authority: "api.plane.so:443",
      method: "PATCH",
      body_bytes: 25,
      path_bytes: 50
    }
  end
end
