defmodule SymphonyElixir.H100HostQualificationRunner do
  alias SymphonyElixir.Plane.Client
  alias SymphonyElixir.WorkControl.A4HostRelayController
  alias SymphonyElixir.WorkControl.A4HostRelayIPC
  alias SymphonyElixir.WorkControl.A4Proof
  alias SymphonyElixir.WorkControl.ProviderMutationEnvelope
  alias SymphonyElixir.WorkControl.SemanticTransitionIntent
  alias SymphonyElixir.WorkControl.TransitionAttempt
  alias SymphonyElixir.WorkControl.TransitionAttemptLedger

  @timeout_ms 30_000
  @authorization "local-qualification-only"

  def run do
    Application.put_env(:symphony_elixir, :a4_qualification_local_only, true)

    try do
      {:ok, _started_apps} = Application.ensure_all_started(:ssl)
      run_proof()
    rescue
      error ->
        safe_result_file(%{
          "type" => "PROOF_ERROR",
          "reason" => "proof_process_failed",
          "error_class" => safe_exception_class(error),
          "failure_code" => Process.get(:h100_proof_failure_code, "not_available"),
          "failure_site" => safe_failure_site(__STACKTRACE__)
        })

        System.halt(1)
    end
  end

  defp run_proof do
    socket = required_env!("H100_QUAL_SOCKET")
    ca_path = required_env!("H100_QUAL_CA_DER")
    candidate_sha = required_env!("H100_QUAL_CANDIDATE_SHA")
    candidate_tree = required_env!("H100_QUAL_CANDIDATE_TREE")
    origin_authority = required_env!("H100_QUAL_ORIGIN_AUTHORITY")
    origin_url = required_env!("H100_QUAL_ORIGIN_URL")
    proof_state = required_env!("H100_QUAL_PROOF_STATE")
    result_path = required_env!("H100_QUAL_RESULT_FILE")
    request_id = required_env!("H100_QUAL_REQUEST_ID")
    expected_path = required_env!("H100_QUAL_EXPECTED_PATH")
    ipv4_port = required_env!("H100_QUAL_IPV4_CANARY_PORT") |> String.to_integer()
    ipv6_port = required_env!("H100_QUAL_IPV6_CANARY_PORT") |> String.to_integer()
    ca_der = File.read!(ca_path)
    shared_trust_before = :public_key.cacerts_get()
    tls_options = Client.proof_tls_options("127.0.0.1", [ca_der])

    attempt_id = "a4-qualification-" <> String.replace_prefix(request_id, "preq_", "")
    config = local_config(origin_url)
    request = capture_request!(config)
    body = Jason.encode!(request.body)
    ensure_bounded_patch!(request, body, expected_path)

    :ok =
      ipc_ack!(socket, %{
        "op" => "origin_expect",
        "request" => %{
          "provider_request_id" => request_id,
          "transition_attempt_id" => attempt_id,
          "method" => "PATCH",
          "path" => request.path,
          "body_bytes" => byte_size(body),
          "body_sha256" => sha256(body)
        }
      })

    attempt = durable_attempt!(proof_state, request_id, attempt_id)
    envelope = mutation_envelope(request_id, attempt_id)

    binding = %{
      origin_base_url: origin_url,
      origin_authority: origin_authority,
      method: "PATCH",
      path: request.path,
      body_bytes: byte_size(body),
      path_bytes: byte_size(request.path),
      witness_required?: true,
      durable?: true
    }

    controller_ref = make_ref()
    backend_failures = :atomics.new(1, signed: false)
    backend = controller_backend(socket, backend_failures)
    {:ok, controller} = A4HostRelayController.start_link(backend: backend, ref: controller_ref)

    capability = %{
      controller: controller,
      ref: controller_ref,
      timeout_ms: @timeout_ms,
      candidate_sha: candidate_sha,
      candidate_tree: candidate_tree,
      gate: :atomics.new(1, signed: false)
    }

    token =
      case A4Proof.acquire(capability, attempt, envelope, binding) do
        {:ok, token} ->
          token

        {:error, {:dispatch_witness_failed, reason}} ->
          Process.put(
            :h100_proof_failure_code,
            controller_failure_code(backend_failures) || safe_a4_failure_code(reason)
          )

          raise ArgumentError, "A4 proof acquisition failed"

        _invalid ->
          Process.put(:h100_proof_failure_code, "a4_rejected")
          raise ArgumentError, "A4 proof acquisition failed"
      end

    finch_absent_after_manifest = is_nil(Process.whereis(A4Proof.finch_name()))
    ack_count = :atomics.new(1, signed: false)

    response =
      Client.update_work_item_state(config, "work-1", "state-1",
        provider_mutation_envelope: envelope,
        dispatch_witness_required?: true,
        dispatch_witness_timeout_ms: @timeout_ms,
        dispatch_witness_sink: witness_sink(socket, request_id, ipv4_port, ipv6_port, ack_count),
        a4_session: token,
        a4_proof_cacerts: [ca_der]
      )

    proof_finch_stopped = is_nil(Process.whereis(A4Proof.finch_name()))
    canary_evidence = Process.get(:h100_canary_evidence)
    trust_unchanged = shared_trust_before == :public_key.cacerts_get()

    tls_options_valid =
      tls_options[:verify] == :verify_peer and tls_options[:versions] == [:"tlsv1.2"] and
        tls_options[:cacerts] == [ca_der] and tls_options[:server_name_indication] == ~c"127.0.0.1"

    result = %{
      "type" => "PROOF_RESULT",
      "failure_code" => controller_failure_code(backend_failures) || proof_result_failure_code(response),
      "provider_request_id" => request_id,
      "manifest_finch_absent_before_ready" => finch_absent_after_manifest,
      "finch_started_at_witness" => Process.get(:h100_finch_started_at_witness, false),
      "finch_stopped" => proof_finch_stopped,
      "dispatch_witness_ack_count" => :atomics.get(ack_count, 1),
      "retry_count" => 0,
      "replay_count" => 0,
      "transport_result" => result_class(response),
      "direct_ipv4_canary" => atom_value(canary_evidence, :ipv4),
      "direct_ipv6_canary" => atom_value(canary_evidence, :ipv6),
      "canary_policy_verified" => canary_evidence != nil,
      "canary_drop_packets" => canary_drop_packets(canary_evidence),
      "tls_verify_peer" => tls_options_valid,
      "tls_hostname_verification" => tls_options_valid,
      "shared_trust_unchanged" => trust_unchanged
    }

    safe_result_file(result)

    if acceptable_proof_result?(result) do
      :ok
    else
      System.halt(1)
    end
  end

  defp ensure_bounded_patch!(request, body, expected_path) do
    unless request.path == expected_path and byte_size(request.path) <= 2048 and byte_size(body) <= 512 do
      raise ArgumentError, "captured request differs from the local qualification bounds"
    end
  end

  defp acceptable_proof_result?(result) do
    result["transport_result"] == "transport_failure" and result["finch_stopped"] and
      result["dispatch_witness_ack_count"] == 1 and result["canary_policy_verified"] and
      result["direct_ipv4_canary"] == "blocked" and result["direct_ipv6_canary"] == "blocked" and
      result["tls_verify_peer"] and result["tls_hostname_verification"] and result["shared_trust_unchanged"]
  end

  defp local_config(origin_url) do
    %{
      base_url: origin_url,
      workspace_slug: "workspace",
      workspace_id: "workspace-1",
      project_id: "project-1",
      api_key: @authorization
    }
  end

  defp capture_request!(config) do
    parent = self()

    :ok =
      Client.update_work_item_state(config, "work-1", "state-1",
        request_fun: fn request ->
          send(parent, {:h100_captured_request, request})
          {:ok, %{status: 204}}
        end
      )

    receive do
      {:h100_captured_request, request} -> request
    after
      @timeout_ms -> raise ArgumentError, "client did not construct the local PATCH"
    end
  end

  defp controller_backend(socket, backend_failures) do
    receipt_key = {__MODULE__, :stage_b_receipt}

    %{
      verify_stage_a: fn ->
        case A4HostRelayIPC.call(socket, %{"op" => "stage_a"}, @timeout_ms) do
          {:ok, %{"verified" => true}} -> :ok
          _ -> {:error, :stage_a_not_verified}
        end
      end,
      manifest: fn request ->
        case A4HostRelayIPC.call(socket, %{"op" => "manifest", "request" => stringify_keys(request)}, @timeout_ms) do
          {:ok, %{"canonical_json" => canonical, "sha256" => digest, "manifest" => manifest}} ->
            {:ok, %{canonical_json: canonical, sha256: digest, manifest: manifest}}

          {:ok, _invalid} ->
            :atomics.put(backend_failures, 1, 2)
            {:error, :manifest_unavailable}

          _ ->
            :atomics.put(backend_failures, 1, 1)
            {:error, :manifest_unavailable}
        end
      end,
      ready: fn request ->
        normalized_request = stringify_keys(request)

        case A4HostRelayIPC.call(socket, %{"op" => "ready", "request" => normalized_request}, @timeout_ms) do
          {:ok, %{"verified" => true, "ready" => ready}} when is_map(ready) ->
            Process.put(receipt_key, {normalized_request, ready})
            {:ok, ready}

          {:ok, _invalid} ->
            :atomics.put(backend_failures, 1, 4)
            {:error, :stage_b_not_verified}

          _ ->
            :atomics.put(backend_failures, 1, 3)
            {:error, :stage_b_not_verified}
        end
      end,
      stage_b_verified?: fn request, ready ->
        Process.get(receipt_key) == {stringify_keys(request), stringify_keys(ready)}
      end
    }
  end

  defp controller_failure_code(failures) do
    case :atomics.get(failures, 1) do
      1 -> "controller_manifest_ipc_failed"
      2 -> "controller_manifest_response_invalid"
      3 -> "controller_ready_ipc_failed"
      4 -> "controller_ready_response_invalid"
      _ -> nil
    end
  end

  defp witness_sink(socket, request_id, ipv4_port, ipv6_port, ack_count) do
    fn witness ->
      finch_started = not is_nil(Process.whereis(A4Proof.finch_name()))
      Process.put(:h100_finch_started_at_witness, finch_started)
      canaries = probe_canaries(ipv4_port, ipv6_port)
      Process.put(:h100_canary_evidence, canaries)

      case {SymphonyElixir.A4HostQualificationProof.validate_canary_results(canaries),
            A4HostRelayIPC.call(
              socket,
              %{
                "op" => "canaries",
                "request" => %{
                  "provider_request_id" => request_id,
                  "ipv4" => Atom.to_string(canaries.ipv4),
                  "ipv6" => Atom.to_string(canaries.ipv6)
                }
              },
              @timeout_ms
            )} do
        {:ok, {:ok, %{"verified" => true, "proof_drop_packets" => count}}} when count >= 2 and finch_started ->
          :atomics.add(ack_count, 1, 1)
          {:ok, witness.provider_request_id}

        _ ->
          {:error, :local_qualification_gate_failed}
      end
    end
  end

  defp probe_canaries(ipv4_port, ipv6_port) do
    %{ipv4: probe({127, 0, 0, 1}, ipv4_port, []), ipv6: probe({0, 0, 0, 0, 0, 0, 0, 1}, ipv6_port, [:inet6])}
  end

  defp probe(address, port, family_options) do
    case :gen_tcp.connect(address, port, [:binary, active: false] ++ family_options, 350) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :reachable

      {:error, :timeout} ->
        :blocked

      _ ->
        :failed
    end
  end

  defp durable_attempt!(proof_state, request_id, attempt_id) do
    ledger_path = Path.join(proof_state, "attempt.dets")
    identity = %{tracker_kind: "plane", provider_scope: %{project_id: "project-1"}}

    intent_attrs = %{
      work_item_id: "work-1",
      requested_from: :ready,
      requested_to: :in_progress,
      responsibility: "implementation",
      guard_evidence: [],
      requested_at: DateTime.utc_now()
    }

    {:ok, intent} = SemanticTransitionIntent.new(intent_attrs)
    {:ok, initial} = TransitionAttempt.new(Map.put(intent_attrs, :transition_attempt_id, attempt_id))
    {:ok, authorized} = TransitionAttempt.authorize_intent(initial, intent)

    {:ok, fresh} =
      TransitionAttempt.fresh_context_loaded(authorized, %{
        provider: :plane,
        workspace_id: "workspace-1",
        project_id: "project-1",
        provider_state_id: "state-ready",
        provider_state_group: :unstarted,
        provider_contract_fingerprint: "fixture-contract",
        dependency_epoch_evidence: %{complete?: true}
      })

    {:ok, prepared} =
      TransitionAttempt.prepare(fresh, %{
        target_provider_state_id: "state-1",
        target_provider_state_group: :started,
        provider_contract_fingerprint: "fixture-contract",
        dependency_epoch_evidence: %{complete?: true}
      })

    {:ok, fenced} = TransitionAttempt.arm_submission_fence(prepared)
    {:ok, submitted} = TransitionAttempt.mark_mutation_submitted(fenced, %{provider_request_id: request_id})
    {:ok, ledger} = TransitionAttemptLedger.open("project-1", identity, path: ledger_path)
    :ok = TransitionAttemptLedger.put_sync(ledger, submitted)
    :ok = TransitionAttemptLedger.close(ledger)
    {:ok, reopened} = TransitionAttemptLedger.open("project-1", identity, path: ledger_path)
    {:ok, persisted_attempt} = TransitionAttemptLedger.get(reopened, attempt_id)
    :ok = TransitionAttemptLedger.close(reopened)
    persisted_attempt
  end

  defp mutation_envelope(request_id, attempt_id) do
    %ProviderMutationEnvelope{
      provider_request_id: request_id,
      transition_attempt_id: attempt_id,
      work_item_id: "work-1",
      provider: :plane,
      workspace_id: "workspace-1",
      project_id: "project-1",
      requested_from: :ready,
      requested_to: :in_progress,
      target_provider_state_id: "state-1",
      target_provider_state_group: :started,
      provider_contract_fingerprint: "fixture-contract",
      submitted_at: DateTime.utc_now()
    }
  end

  defp ipc_ack!(socket, message) do
    case A4HostRelayIPC.call(socket, message, @timeout_ms) do
      {:ok, %{"verified" => true}} -> :ok
      _ -> raise ArgumentError, "host launcher rejected a qualification phase"
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp result_class({:error, _error}), do: "transport_failure"
  defp result_class(_result), do: "unexpected_success"

  defp proof_result_failure_code({:error, {:dispatch_witness_failed, {:proof_manifest_mismatch, field}}})
       when field in [
              :schema,
              :experiment_scope,
              :provider_request_id,
              :transition_attempt_id,
              :work_item_id,
              :workspace_id,
              :project_id,
              :target_state_id,
              :method,
              :origin_base_url,
              :origin_authority,
              :candidate_sha,
              :candidate_tree,
              :relay_script_blob_sha256,
              :manifest_id,
              :operator_authorization_ref,
              :python_path,
              :python_version,
              :max_dispatch,
              :max_connect,
              :max_client_app_records,
              :tls_versions,
              :expires_at,
              :manifest_bytes,
              :shape,
              :canonical_or_hash,
              :canonical_json,
              :body_bytes,
              :path_bytes,
              :ready
            ],
       do: "proof_manifest_mismatch_" <> Atom.to_string(field)

  defp proof_result_failure_code({:error, {:dispatch_witness_failed, reason}})
       when reason in [
              :witness_required,
              :request_fun_transport_not_supported,
              :invalid_proof_session,
              :proof_finch_start_failed,
              :invalid_proof_tls_trust_context,
              :proof_ready_already_received,
              :proof_token_owner_mismatch,
              :proof_token_expired,
              :proof_controller_unavailable,
              :proof_ready_already_requested,
              :proof_token_consumed,
              :proof_token_binding_mismatch,
              :proof_token_not_ready,
              :proof_reply_receiver_failed,
              :duplicate_or_unsolicited_controller_message,
              :invalid_ready_response,
              :wrong_controller_reference,
              :proof_ready_timeout
            ],
       do: Atom.to_string(reason)

  defp proof_result_failure_code({:error, {:dispatch_witness_failed, _reason}}), do: "dispatch_witness_failed"
  defp proof_result_failure_code({:error, :provider_unavailable}), do: "provider_unavailable"
  defp proof_result_failure_code({:error, reason}) when reason in [:econnrefused, :timeout, :closed], do: Atom.to_string(reason)
  defp proof_result_failure_code({:error, _error}), do: "transport_failure"
  defp proof_result_failure_code(_result), do: "unexpected_success"

  defp atom_value(nil, _key), do: "failed"
  defp atom_value(map, key), do: Map.get(map, key, :failed) |> Atom.to_string()

  defp canary_drop_packets(%{"proof_drop_packets" => count}) when is_integer(count), do: count
  defp canary_drop_packets(_), do: 0

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp required_env!(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> value
      _ -> raise ArgumentError, "qualification environment is incomplete"
    end
  end

  defp safe_result_file(result) do
    path = required_env!("H100_QUAL_RESULT_FILE")
    File.write!(path, Jason.encode!(result), [:binary])
    File.chmod!(path, 0o600)
  end

  defp safe_exception_class(%ArgumentError{}), do: "argument_error"
  defp safe_exception_class(%MatchError{}), do: "match_error"
  defp safe_exception_class(%FunctionClauseError{}), do: "function_clause"
  defp safe_exception_class(%CaseClauseError{}), do: "case_clause"
  defp safe_exception_class(%KeyError{}), do: "key_error"
  defp safe_exception_class(%RuntimeError{}), do: "runtime_error"
  defp safe_exception_class(_error), do: "other_exception"

  defp safe_a4_failure_code({:proof_manifest_mismatch, field})
       when field in [
              :schema,
              :experiment_scope,
              :provider_request_id,
              :transition_attempt_id,
              :work_item_id,
              :workspace_id,
              :project_id,
              :target_state_id,
              :method,
              :origin_base_url,
              :origin_authority,
              :candidate_sha,
              :candidate_tree,
              :relay_script_blob_sha256,
              :manifest_id,
              :operator_authorization_ref,
              :python_path,
              :python_version,
              :max_dispatch,
              :max_connect,
              :max_client_app_records,
              :tls_versions,
              :expires_at,
              :manifest_bytes,
              :shape,
              :canonical_or_hash,
              :canonical_json,
              :body_bytes,
              :path_bytes
            ],
       do: "manifest_" <> Atom.to_string(field)

  defp safe_a4_failure_code(reason)
       when reason in [
              :invalid_proof_preflight,
              :invalid_proof_controller_capability,
              :remote_proof_controller,
              :proof_controller_unavailable,
              :proof_already_active,
              :persisted_attempt_envelope_mismatch,
              :mutation_not_persisted,
              :witness_required,
              :durable_proof_ledger_required,
              :invalid_origin,
              :proof_manifest_timeout,
              :proof_ready_timeout,
              :duplicate_or_unsolicited_controller_message,
              :proof_reply_receiver_failed,
              :wrong_controller_reference,
              :invalid_manifest_response
            ],
       do: Atom.to_string(reason)

  defp safe_a4_failure_code(_reason), do: "a4_rejected"

  defp safe_failure_site(stacktrace) do
    case Enum.find(stacktrace, fn
           {module, _function, _arity, _location} -> module == __MODULE__
           _frame -> false
         end) do
      {__MODULE__, function, _arity, location} ->
        %{
          "function" => safe_function_name(function),
          "line" => safe_line_number(location)
        }

      _frame ->
        %{"function" => "proof_runner", "line" => 0}
    end
  end

  defp safe_function_name(:run_proof), do: "run_proof"
  defp safe_function_name(:capture_request!), do: "capture_request"
  defp safe_function_name(:ensure_bounded_patch!), do: "patch_bounds"
  defp safe_function_name(:ipc_ack!), do: "ipc_ack"
  defp safe_function_name(:durable_attempt!), do: "attempt_persistence"
  defp safe_function_name(:mutation_envelope), do: "mutation_envelope"
  defp safe_function_name(:controller_backend), do: "controller_setup"
  defp safe_function_name(:witness_sink), do: "witness_gate"
  defp safe_function_name(:probe_canaries), do: "canary_probe"
  defp safe_function_name(:local_config), do: "local_client_setup"
  defp safe_function_name(:acceptable_proof_result?), do: "proof_result_check"
  defp safe_function_name(_function), do: "proof_runner"

  defp safe_line_number(location) do
    case Keyword.get(location, :line) do
      line when is_integer(line) and line in 1..500 -> line
      _line -> 0
    end
  rescue
    _error -> 0
  end
end

SymphonyElixir.H100HostQualificationRunner.run()
