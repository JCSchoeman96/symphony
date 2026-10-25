defmodule SymphonyElixir.A4TransportProofFixture do
  alias SymphonyElixir.Plane.Client
  alias SymphonyElixir.WorkControl.A4Proof
  alias SymphonyElixir.WorkControl.ProviderMutationEnvelope
  alias SymphonyElixir.WorkControl.SemanticTransitionIntent
  alias SymphonyElixir.WorkControl.TransitionAttempt
  alias SymphonyElixir.WorkControl.TransitionAttemptLedger

  @helper Path.expand("connect_helper.py", __DIR__)
  @timeout 10_000

  def run!(:suppressed_tls12) do
    Application.put_env(:symphony_elixir, :a4_qualification_local_only, true)

    root = Path.join(System.tmp_dir!(), "a4-transport-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit = fn -> File.rm_rf(root) end

    try do
      certificate = make_certificate!(root)
      run_suppression(root, certificate)
    after
      on_exit.()
    end
  end

  defp run_suppression(root, certificate) do
    {:ok, listen_socket} =
      :ssl.listen(0,
        certfile: String.to_charlist(certificate.server_cert),
        keyfile: String.to_charlist(certificate.server_key),
        versions: [:"tlsv1.2"],
        mode: :binary,
        active: false,
        reuseaddr: true
      )

    {:ok, {_ip, origin_port}} = :ssl.sockname(listen_socket)
    origin_authority = "127.0.0.1:#{origin_port}"
    origin_url = "https://#{origin_authority}"
    parent = self()
    origin = spawn_link(fn -> serve_once(listen_socket, parent) end)
    script_sha = sha256(File.read!(@helper))
    {candidate_sha, 0} = System.cmd("git", ["rev-parse", "HEAD"])
    {candidate_tree, 0} = System.cmd("git", ["rev-parse", "HEAD^{tree}"])
    candidate_sha = String.trim(candidate_sha)
    candidate_tree = String.trim(candidate_tree)
    request_id = "preq_00000000-0000-4000-8000-000000000091"
    attempt_id = "a4-qualification-#{System.unique_integer([:positive])}"
    capture_parent = self()
    capture_config = %{base_url: origin_url, workspace_slug: "workspace", workspace_id: "workspace-1", project_id: "project-1", api_key: "qualification-only-placeholder"}

    :ok =
      Client.update_work_item_state(capture_config, "work-1", "state-1",
        request_fun: fn request ->
          send(capture_parent, {:a4_captured_request, request})
          {:ok, %{status: 204}}
        end
      )

    request =
      receive do
        {:a4_captured_request, request} -> request
      after
        @timeout -> raise "Plane client did not build the qualification PATCH"
      end

    path = request.path
    body = Jason.encode!(request.body)

    binding = %{
      origin_base_url: origin_url,
      origin_authority: origin_authority,
      method: "PATCH",
      path: path,
      body_bytes: byte_size(body),
      path_bytes: byte_size(path),
      witness_required?: true,
      durable?: true
    }

    attempt = durable_attempt!(root, request_id, attempt_id)

    envelope = %ProviderMutationEnvelope{
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

    controller_ref = make_ref()
    controller = self()

    capability = %{
      controller: controller,
      ref: controller_ref,
      timeout_ms: @timeout,
      candidate_sha: candidate_sha,
      candidate_tree: candidate_tree,
      gate: :atomics.new(1, signed: false)
    }

    task =
      Task.async(fn ->
        token =
          case A4Proof.acquire(capability, attempt, envelope, binding) do
            {:ok, token} ->
              token

            error ->
              send(parent, {:a4_acquire_error, error})
              raise "A4 preflight failed: #{inspect(error)}"
          end

        Client.update_work_item_state(
          %{
            base_url: origin_url,
            workspace_slug: "workspace",
            workspace_id: "workspace-1",
            project_id: "project-1",
            api_key: "qualification-only-placeholder"
          },
          "work-1",
          "state-1",
          provider_mutation_envelope: envelope,
          dispatch_witness_required?: true,
          dispatch_witness_sink: fn witness ->
            proof_finch_started? = is_pid(Process.whereis(A4Proof.finch_name()))

            send(
              parent,
              {:a4_witness_ack, self(), System.monotonic_time(:microsecond), proof_finch_started?}
            )

            {:ok, witness.provider_request_id}
          end,
          a4_session: token,
          a4_proof_cacerts: [certificate.ca_der]
        )
      end)

    run_controller(task, origin, %{
      ref: controller_ref,
      authority: origin_authority,
      base_url: origin_url,
      path: path,
      request_id: request_id,
      attempt_id: attempt_id,
      script_sha: script_sha,
      candidate_sha: candidate_sha,
      candidate_tree: candidate_tree
    })
  end

  defp run_controller(task, origin, context) do
    receive do
      {:a4_manifest_request, reply_to, ref, request_ref, _safe_request}
      when is_pid(reply_to) and reply_to != task.pid and ref == context.ref ->
        python_path = System.find_executable("python3") || raise "python3 is required"
        {python_version, 0} = System.cmd(python_path, ["--version"], stderr_to_stdout: true)

        manifest = %{
          "schema" => "a4-v2_1",
          "manifest_id" => "qualification-#{System.unique_integer([:positive])}",
          "experiment_scope" => "single_designated_state_patch",
          "provider_request_id" => context.request_id,
          "transition_attempt_id" => context.attempt_id,
          "work_item_id" => "work-1",
          "workspace_id" => "workspace-1",
          "project_id" => "project-1",
          "target_state_id" => "state-1",
          "method" => "PATCH",
          "origin_kind" => "local_qualification",
          "origin_authority" => context.authority,
          "origin_base_url" => context.base_url,
          "candidate_sha" => context.candidate_sha,
          "candidate_tree" => context.candidate_tree,
          "relay_script_blob_sha256" => context.script_sha,
          "python_path" => python_path,
          "python_version" => String.trim(python_version) |> String.replace_prefix("Python ", ""),
          "max_dispatch" => 1,
          "max_connect" => 1,
          "max_client_app_records" => 1,
          "tls_versions" => ["tlsv1.2"],
          "not_before" => DateTime.add(DateTime.utc_now(), -60, :second) |> DateTime.to_iso8601(),
          "expires_at" => DateTime.add(DateTime.utc_now(), 600, :second) |> DateTime.to_iso8601(),
          "operator_authorization_ref" => "local-test-only"
        }

        hash = manifest_hash(manifest)
        full_manifest = Map.put(manifest, "manifest_sha256", hash)
        encoded = canonical_json(full_manifest)
        response = %{canonical_json: encoded, sha256: hash, manifest: full_manifest}
        send(reply_to, {:a4_manifest_response, self(), ref, request_ref, response})
        send(self(), {:a4_manifest_created, System.monotonic_time(:microsecond), hash})
        await_ready(task, origin, context, full_manifest)

      other ->
        raise "unexpected controller event: #{inspect(other)}"
    end
  end

  defp await_ready(task, origin, context, manifest) do
    receive do
      {:a4_acquire_error, error} ->
        raise "#{inspect(error)}"

      {:a4_ready_request, reply_to, ref, request_ref, _safe_ready}
      when is_pid(reply_to) and reply_to != task.pid and ref == context.ref ->
        launch_helper(task, origin, context, reply_to, request_ref, manifest)
    after
      @timeout -> raise "A4 READY request did not arrive, task=#{inspect(Task.yield(task, 0))}"
    end
  end

  defp launch_helper(task, origin, context, reply_to, request_ref, manifest) do
    script = @helper
    python_path = manifest["python_path"]
    path = System.get_env("PATH", "/usr/bin:/bin")
    port = launch_clean_helper(python_path, script, manifest, path)

    receive do
      {^port, {:data, {:eol, line}}} ->
        ready = Jason.decode!(line)
        if ready["type"] != "READY", do: raise("helper did not emit READY")
        ready_response_sent_at = System.monotonic_time(:microsecond)
        send(reply_to, {:a4_ready_response, self(), context.ref, request_ref, ready})
        collect_results(task, origin, port, ready, nil, ready_response_sent_at, nil)
    after
      @timeout -> raise "helper did not become READY"
    end
  end

  defp launch_clean_helper(python_path, script, manifest, path) do
    encoded_manifest = canonical_json(manifest)
    shell_command = "printf %s \"$1\" | exec /usr/bin/env -i PATH=\"$2\" LANG=C.UTF-8 \"$3\" -I \"$4\""
    Port.open({:spawn_executable, ~c"/bin/sh"}, [:binary, :exit_status, :use_stdio, {:line, 65_536}, {:args, ["-c", shell_command, "a4-controller", encoded_manifest, path, python_path, script]}])
  end

  defp collect_results(task, origin, port, ready, origin_result, ready_response_sent_at, witness_ack) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        evidence = Jason.decode!(line)
        collect_results(task, origin, port, Map.merge(ready, evidence), origin_result, ready_response_sent_at, witness_ack)

      {^port, {:exit_status, status}} ->
        transport_result = Task.await(task, @timeout)

        witness_ack =
          witness_ack ||
            receive do
              {:a4_witness_ack, _ack_pid, at, proof_finch_started?} ->
                %{at: at, proof_finch_started?: proof_finch_started?}
            after
              @timeout -> raise "proof witness ACK was not observed"
            end

        origin_result =
          origin_result ||
            receive do
              {:a4_origin_result, ^origin, result} -> result
            after
              @timeout -> raise "TLS origin did not finish"
            end

        helper = Map.new(ready, fn {key, value} -> {safe_atom(key), value} end)

        %{
          result: transport_result,
          origin: origin_result,
          helper: helper,
          helper_exit_status: status,
          finch_stopped?: is_nil(Process.whereis(A4Proof.finch_name())),
          client_tls_version: origin_result.protocol,
          ordering: %{
            ready_response_sent_at: ready_response_sent_at,
            witness_ack_at: witness_ack.at,
            proof_finch_started_at_ack?: witness_ack.proof_finch_started?,
            origin_patch_at: origin_result.observed_at
          }
        }

      {^port, {:data, {:noeol, _fragment}}} ->
        collect_results(task, origin, port, ready, origin_result, ready_response_sent_at, witness_ack)

      {:a4_origin_result, ^origin, result} ->
        collect_results(task, origin, port, ready, result, ready_response_sent_at, witness_ack)

      {:a4_witness_ack, _ack_pid, at, proof_finch_started?} ->
        collect_results(
          task,
          origin,
          port,
          ready,
          origin_result,
          ready_response_sent_at,
          %{at: at, proof_finch_started?: proof_finch_started?}
        )
    after
      12_000 ->
        Port.close(port)
        raise "helper exceeded its external watchdog"
    end
  end

  defp safe_atom("connect_count"), do: :connect_count
  defp safe_atom("upstream_connection_count"), do: :upstream_connection_count
  defp safe_atom("client_application_data_record_count"), do: :client_application_data_record_count
  defp safe_atom("server_application_data_observed"), do: :server_application_data_observed
  defp safe_atom("server_application_data_forwarded"), do: :server_application_data_forwarded
  defp safe_atom("close_reason"), do: :close_reason
  defp safe_atom("type"), do: :type
  defp safe_atom("provider_request_id"), do: :provider_request_id
  defp safe_atom("listen_host"), do: :listen_host
  defp safe_atom("bound_port"), do: :bound_port
  defp safe_atom("python_version"), do: :python_version
  defp safe_atom("script_blob_sha256"), do: :script_blob_sha256
  defp safe_atom("environment_names"), do: :environment_names
  defp safe_atom(_), do: :unknown

  defp serve_once(listen_socket, parent) do
    result =
      with {:ok, transport} <- :ssl.transport_accept(listen_socket, 8_000),
           {:ok, socket} <- :ssl.handshake(transport, 8_000),
           {:ok, connection_info} <- :ssl.connection_information(socket, [:protocol]),
           {:ok, request} <- receive_request(socket, <<>>) do
        result = %{
          patch_count: 1,
          complete_request?: request.complete?,
          method: request.method,
          path: request.path,
          body: request.body,
          body_bytes: byte_size(request.body),
          observed_at: System.monotonic_time(:microsecond),
          response_bytes_received_by_client?: false,
          protocol: connection_info[:protocol]
        }

        send(parent, {:a4_origin_result, self(), result})
        :ssl.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nok")
        result
      else
        error ->
          result = %{
            patch_count: 0,
            complete_request?: false,
            error: inspect(error),
            response_bytes_received_by_client?: false
          }

          send(parent, {:a4_origin_result, self(), result})
          result
      end

    :ssl.close(listen_socket)
    result
  end

  defp receive_request(socket, buffer) do
    case request_from_buffer(buffer) do
      {:ok, request} -> {:ok, request}
      :incomplete -> read_more(socket, buffer)
    end
  end

  defp request_from_buffer(buffer) do
    case :binary.match(buffer, "\r\n\r\n") do
      {header_end, 4} -> request_from_header(buffer, header_end)
      :nomatch -> :incomplete
    end
  end

  defp request_from_header(buffer, header_end) do
    header = binary_part(buffer, 0, header_end)
    [request_line | _headers] = String.split(header, "\r\n")
    [method, path, _version] = String.split(request_line, " ")
    content_length = content_length(header)
    body_start = header_end + 4
    body = binary_part(buffer, body_start, byte_size(buffer) - body_start)

    if byte_size(body) >= content_length do
      {:ok, %{method: method, path: path, body: binary_part(body, 0, content_length), complete?: true}}
    else
      :incomplete
    end
  end

  defp content_length(header) do
    header
    |> String.split("\r\n")
    |> Enum.find_value(0, &content_length_header/1)
  end

  defp content_length_header(line) do
    case String.split(line, ":", parts: 2) do
      [name, value] -> content_length_value(name, value)
      _ -> nil
    end
  end

  defp content_length_value(name, value) do
    if String.downcase(name) == "content-length", do: String.trim(value) |> String.to_integer(), else: nil
  end

  defp read_more(socket, buffer) do
    case :ssl.recv(socket, 0, 5_000) do
      {:ok, bytes} -> receive_request(socket, buffer <> bytes)
      error -> error
    end
  end

  defp make_certificate!(root) do
    ca_key = Path.join(root, "ca.key")
    ca_pem = Path.join(root, "ca.pem")
    server_key = Path.join(root, "server.key")
    server_csr = Path.join(root, "server.csr")
    server_cert = Path.join(root, "server.pem")
    ext = Path.join(root, "server.ext")

    cmd!("openssl", [
      "req",
      "-x509",
      "-newkey",
      "rsa:2048",
      "-nodes",
      "-keyout",
      ca_key,
      "-out",
      ca_pem,
      "-days",
      "1",
      "-subj",
      "/CN=A4 ephemeral test CA",
      "-addext",
      "basicConstraints=critical,CA:TRUE",
      "-addext",
      "keyUsage=critical,keyCertSign,cRLSign"
    ])

    cmd!("openssl", ["req", "-newkey", "rsa:2048", "-nodes", "-keyout", server_key, "-out", server_csr, "-subj", "/CN=127.0.0.1"])
    File.write!(ext, "subjectAltName=IP:127.0.0.1\nextendedKeyUsage=serverAuth\nkeyUsage=digitalSignature,keyEncipherment\n")
    cmd!("openssl", ["x509", "-req", "-in", server_csr, "-CA", ca_pem, "-CAkey", ca_key, "-CAcreateserial", "-out", server_cert, "-days", "1", "-extfile", ext])
    [ca_entry] = :public_key.pem_decode(File.read!(ca_pem))
    {:Certificate, ca_der, :not_encrypted} = ca_entry
    %{ca_pem: ca_pem, ca_der: ca_der, server_cert: server_cert, server_key: server_key}
  end

  defp durable_attempt!(root, request_id, attempt_id) do
    path = Path.join(root, "attempt.dets")
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
    {:ok, ledger} = TransitionAttemptLedger.open("project-1", identity, path: path)
    :ok = TransitionAttemptLedger.put_sync(ledger, submitted)
    :ok = TransitionAttemptLedger.close(ledger)
    {:ok, reopened} = TransitionAttemptLedger.open("project-1", identity, path: path)
    {:ok, persisted_attempt} = TransitionAttemptLedger.get(reopened, attempt_id)
    :ok = TransitionAttemptLedger.close(reopened)
    persisted_attempt
  end

  defp manifest_hash(manifest), do: manifest |> canonical_json() |> sha256()
  defp canonical_json(map), do: Jason.encode!(sort_json(map))
  defp sort_json(map) when is_map(map), do: map |> Enum.sort_by(&elem(&1, 0)) |> Map.new(fn {key, value} -> {key, sort_json(value)} end)
  defp sort_json(value), do: value
  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp cmd!(program, args) do
    case System.cmd(program, args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> raise "#{program} failed (#{status}): #{output}"
    end
  end
end
