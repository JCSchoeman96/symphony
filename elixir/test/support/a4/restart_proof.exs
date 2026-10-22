defmodule SymphonyElixir.A4RestartProof do
  alias SymphonyElixir.TransitionCoordinator
  alias SymphonyElixir.WorkControl.A4Proof

  alias SymphonyElixir.WorkControl.{
    ProviderMutationEnvelope,
    SemanticTransitionIntent,
    TransitionAttempt,
    TransitionAttemptLedger
  }

  @identity %{tracker_kind: "plane", provider_scope: %{project_id: "project-a"}}
  @request_id "preq_00000000-0000-4000-8000-000000000117"
  @attempt_id "attempt-a4-restart-q17"
  @work_item_id "work-a4-restart-q17"
  @timeout_ms 10_000
  @script_path Path.expand("connect_helper.py", __DIR__)

  def run! do
    root = Path.join(System.tmp_dir!(), "a4-restart-proof-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    try do
      first = launch_first_vm!(root)
      kill_vm!(first.port, first.os_pid)
      second = launch_second_vm!(root)

      Map.put(second, :first_vm_os_pid, first.os_pid)
    after
      File.rm_rf(root)
    end
  end

  def child!(args) do
    case args do
      ["before", root] -> before_restart!(root)
      ["after", root] -> after_restart!(root)
      _ -> raise ArgumentError, "expected restart phase and root path"
    end
  end

  defp launch_first_vm!(root) do
    executable = System.find_executable("elixir") || raise "elixir executable is required"
    script = Path.expand(__ENV__.file)

    args =
      code_path_args() ++
        ["-r", script, "-e", "SymphonyElixir.A4RestartProof.child!(System.argv())", "--", "before", root]

    port = Port.open({:spawn_executable, String.to_charlist(executable)}, [:binary, :exit_status, :use_stdio, {:args, args}])
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    await_acquired!(port, <<>>)
    %{port: port, os_pid: os_pid}
  end

  defp await_acquired!(port, output) do
    receive do
      {^port, {:data, chunk}} ->
        output = output <> chunk
        if String.contains?(output, "A4_RESTART_PROOF_ACQUIRED"), do: :ok, else: await_acquired!(port, output)

      {^port, {:exit_status, status}} ->
        raise "first BEAM exited before acquiring its token, status=#{status}, output=#{output}"
    after
      @timeout_ms -> raise "first BEAM did not acquire its token"
    end
  end

  defp kill_vm!(port, os_pid) do
    {output, 0} = System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)

    receive do
      {^port, {:exit_status, _status}} -> :ok
    after
      @timeout_ms -> raise "first BEAM did not exit after SIGKILL: #{output}"
    end
  end

  defp launch_second_vm!(root) do
    executable = System.find_executable("elixir") || raise "elixir executable is required"
    script = Path.expand(__ENV__.file)

    args =
      code_path_args() ++
        ["-r", script, "-e", "SymphonyElixir.A4RestartProof.child!(System.argv())", "--", "after", root]

    {output, status} = System.cmd(executable, args, stderr_to_stdout: true)
    if status != 0, do: raise("second BEAM failed with status #{status}: #{output}")

    result = root |> result_path() |> File.read!() |> :erlang.binary_to_term([:safe])
    Map.put(result, :second_vm_os_pid, parse_os_pid!(output))
  end

  defp code_path_args do
    Enum.flat_map(:code.get_path(), &["-pa", List.to_string(&1)])
  end

  defp before_restart!(root) do
    ledger_path = ledger_path(root)
    attempt = submitted_attempt!()
    {:ok, ledger} = TransitionAttemptLedger.open("project-a", @identity, path: ledger_path)
    :ok = TransitionAttemptLedger.put_sync(ledger, attempt)
    :ok = TransitionAttemptLedger.close(ledger)

    {:ok, reopened} = TransitionAttemptLedger.open("project-a", @identity, path: ledger_path)
    {:ok, persisted} = TransitionAttemptLedger.get(reopened, @attempt_id)
    envelope = envelope(persisted)
    capability = capability(self(), make_ref())
    controller = spawn(fn -> controller_loop(envelope, persisted, capability, nil) end)
    capability = %{capability | controller: controller}

    binding = binding_data()
    {:ok, token} = A4Proof.acquire(capability, persisted, envelope, binding)

    saved_token = %{
      owner: token.owner,
      controller: token.controller,
      controller_ref: token.controller_ref,
      controller_monitor: token.controller_monitor,
      bindings: token.bindings,
      manifest: token.manifest,
      expiry: token.expiry,
      ready: token.ready
    }

    File.write!(token_path(root), :erlang.term_to_binary(saved_token))
    :ok = TransitionAttemptLedger.close(reopened)
    IO.puts("A4_RESTART_PROOF_ACQUIRED")

    receive do
      :never -> :ok
    end
  end

  defp after_restart!(root) do
    saved_token = root |> token_path() |> File.read!() |> :erlang.binary_to_term([:safe])
    old_token = struct(A4Proof, Map.put(saved_token, :used, :atomics.new(2, signed: false)))
    token_task = Task.async(fn -> A4Proof.ready(old_token) end)
    old_token_result = Task.await(token_task, @timeout_ms)

    ledger_path = ledger_path(root)
    {:ok, ledger} = TransitionAttemptLedger.open("project-a", @identity, path: ledger_path)
    {:ok, [recovered_attempt]} = TransitionAttemptLedger.list_reconciliation_candidates(ledger)
    {:ok, ^recovered_attempt} = TransitionAttemptLedger.latest_for_work_item(ledger, @work_item_id)

    request_log = Path.join(root, "manifest-requests.log")
    envelope = envelope(recovered_attempt)
    controller_ref = make_ref()
    capability = capability(nil, controller_ref)
    controller = spawn(fn -> controller_loop(envelope, recovered_attempt, capability, request_log) end)
    capability = %{capability | controller: controller}

    callback_log = Path.join(root, "callbacks.log")

    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        ledger: ledger,
        a4_controller: capability,
        load_context: fn _intent ->
          append_line(callback_log, "load_context")
          {:error, :unexpected_context_load}
        end,
        submit: fn _attempt, _context ->
          append_line(callback_log, "provider_redispatch")
          :ok
        end,
        verify: fn _attempt, _context ->
          append_line(callback_log, "provider_verify")
          :ok
        end
      )

    intent = intent()
    transition_result = TransitionCoordinator.request_transition(coordinator, intent)
    {:ok, recovered_attempt} = TransitionAttemptLedger.latest_for_work_item(ledger, @work_item_id)
    callbacks = if File.exists?(callback_log), do: File.read!(callback_log), else: ""
    manifest_requests = if File.exists?(request_log), do: File.read!(request_log), else: ""
    :ok = GenServer.stop(coordinator)
    send(controller, :stop)

    result = %{
      recovered_attempt: recovered_attempt,
      provider_request_id: recovered_attempt.provider_request_id,
      prior_manifest: saved_token.manifest,
      pre_restart_token_ready: saved_token.ready,
      old_token_result: old_token_result,
      transition_result: transition_result,
      manifest_requests_after_restart: line_count(manifest_requests),
      helper_launches: File.ls!(root) |> Enum.count(&String.starts_with?(&1, "helper-launch")),
      finch_processes_after_restart: finch_process_count(),
      callback_log: callbacks
    }

    File.write!(result_path(root), :erlang.term_to_binary(result))
    IO.puts("A4_RESTART_PROOF_COMPLETE os_pid=#{System.pid()}")
  end

  defp submitted_attempt! do
    now = ~U[2026-10-22 10:00:00Z]

    attrs = %{
      attempt_id: @attempt_id,
      transition_attempt_id: @attempt_id,
      work_item_id: @work_item_id,
      requested_from: :ready,
      requested_to: :in_progress,
      responsibility: "implementation",
      guard_evidence: [],
      requested_at: now
    }

    {:ok, attempt} = TransitionAttempt.new(attrs)
    {:ok, authorized} = TransitionAttempt.authorize_intent(attempt, intent())

    fresh_context = %{
      provider: :plane,
      workspace_id: "workspace-a4-restart",
      project_id: "project-a",
      provider_state_id: "state-ready",
      provider_state_group: :unstarted,
      provider_contract_fingerprint: "sha256:a4-restart-contract",
      dependency_epoch_evidence: %{complete?: true}
    }

    {:ok, loaded} = TransitionAttempt.fresh_context_loaded(authorized, fresh_context)

    prepare_context = %{
      target_provider_state_id: "state-in-progress",
      target_provider_state_group: :started,
      provider_contract_fingerprint: "sha256:a4-restart-contract",
      dependency_epoch_evidence: %{complete?: true}
    }

    {:ok, prepared} = TransitionAttempt.prepare(loaded, prepare_context)
    {:ok, fenced} = TransitionAttempt.arm_submission_fence(prepared, %{at: now})

    {:ok, submitted} =
      TransitionAttempt.mark_mutation_submitted(fenced, %{
        at: now,
        provider_request_id: @request_id
      })

    %{
      submitted
      | provider: :plane,
        workspace_id: "workspace-a4-restart",
        project_id: "project-a"
    }
  end

  defp envelope(attempt) do
    %ProviderMutationEnvelope{
      provider_request_id: attempt.provider_request_id,
      transition_attempt_id: attempt.transition_attempt_id,
      work_item_id: attempt.work_item_id,
      provider: :plane,
      workspace_id: attempt.workspace_id,
      project_id: attempt.project_id,
      requested_from: :ready,
      requested_to: :in_progress,
      target_provider_state_id: attempt.target_provider_state_id,
      target_provider_state_group: attempt.target_provider_state_group,
      provider_contract_fingerprint: attempt.provider_contract_fingerprint,
      submitted_at: attempt.submitted_at
    }
  end

  defp capability(controller, ref) do
    %{
      controller: controller,
      ref: ref,
      timeout_ms: @timeout_ms,
      candidate_sha: String.duplicate("a", 40),
      candidate_tree: String.duplicate("b", 40),
      gate: :atomics.new(1, signed: false)
    }
  end

  defp controller_loop(envelope, attempt, capability, request_log) do
    receive do
      {:a4_manifest_request, reply_to, ref, request_id, _safe_request} ->
        if request_log, do: append_line(request_log, "manifest")
        payload = manifest_payload(envelope, attempt, capability)
        send(reply_to, {:a4_manifest_response, self(), ref, request_id, payload})
        controller_loop(envelope, attempt, capability, request_log)

      :stop ->
        :ok
    end
  end

  defp manifest_payload(envelope, attempt, capability) do
    manifest = %{
      "schema" => "a4-v2_1",
      "manifest_id" => "a4-restart-q17",
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
      "relay_script_blob_sha256" => sha256(File.read!(@script_path)),
      "python_path" => "/usr/bin/python3",
      "python_version" => "3.12",
      "max_dispatch" => 1,
      "max_connect" => 1,
      "max_client_app_records" => 1,
      "tls_versions" => ["tlsv1.2"],
      "not_before" => DateTime.add(DateTime.utc_now(), -60, :second) |> DateTime.to_iso8601(),
      "expires_at" => DateTime.add(DateTime.utc_now(), 300, :second) |> DateTime.to_iso8601(),
      "operator_authorization_ref" => "authorization-a4-restart-q17",
      "manifest_sha256" => ""
    }

    hash = manifest |> Map.delete("manifest_sha256") |> canonical_json() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
    manifest = Map.put(manifest, "manifest_sha256", hash)
    json = canonical_json(manifest)
    %{manifest: manifest, canonical_json: json, sha256: hash}
  end

  defp canonical_json(map) do
    ordered = Jason.OrderedObject.new(map |> Enum.sort_by(&elem(&1, 0)))
    Jason.encode!(ordered)
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

  defp intent do
    {:ok, value} =
      SemanticTransitionIntent.new(%{
        work_item_id: @work_item_id,
        requested_from: :ready,
        requested_to: :in_progress,
        responsibility: "implementation",
        guard_evidence: [],
        requested_at: ~U[2026-10-22 10:00:00Z]
      })

    value
  end

  defp finch_process_count do
    Enum.count(Process.registered(), fn name -> String.contains?(Atom.to_string(name), "Finch") end)
  end

  defp append_line(path, value), do: File.write!(path, value <> "\n", [:append])
  defp line_count(value), do: value |> String.split("\n", trim: true) |> length()
  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  defp ledger_path(root), do: Path.join(root, "transition-attempts.dets")
  defp token_path(root), do: Path.join(root, "proof-token.etf")
  defp result_path(root), do: Path.join(root, "result.etf")

  defp parse_os_pid!(output) do
    case Regex.run(~r/os_pid=(\d+)/, output, capture: :all_but_first) do
      [pid] -> String.to_integer(pid)
      _ -> raise "second BEAM did not report its OS PID: #{output}"
    end
  end
end
