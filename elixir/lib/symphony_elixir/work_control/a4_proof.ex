defmodule SymphonyElixir.WorkControl.A4Proof do
  @moduledoc """
  Owner-bound, one-use authorization for the A4 proof transport.

  This module only exchanges bounded messages with the host controller. It
  never starts a helper or a Finch process.
  """

  alias SymphonyElixir.WorkControl.{ProviderMutationEnvelope, TransitionAttempt}

  @max_timeout_ms 30_000
  @max_body_bytes 512
  @max_path_bytes 2048
  @max_ready_bytes 16_384
  @ready_fields ~w(type provider_request_id listen_host bound_port python_version script_blob_sha256 environment_names)a
  @manifest_fields ~w(
    schema manifest_id experiment_scope provider_request_id transition_attempt_id work_item_id
    workspace_id project_id target_state_id method origin_kind origin_authority origin_base_url
    candidate_sha candidate_tree relay_script_blob_sha256 python_path python_version max_dispatch
    max_connect max_client_app_records tls_versions not_before expires_at operator_authorization_ref
    manifest_sha256
  )a

  defstruct [
    :owner,
    :controller,
    :controller_ref,
    :controller_monitor,
    :reply_to,
    :reply_monitor,
    :bindings,
    :manifest,
    :expiry,
    :ready,
    :used
  ]

  @type t :: %__MODULE__{}

  @spec acquire(map(), TransitionAttempt.t(), ProviderMutationEnvelope.t(), map()) ::
          {:ok, t()} | {:error, {:dispatch_witness_failed, term()}}
  def acquire(capability, %TransitionAttempt{} = attempt, %ProviderMutationEnvelope{} = envelope, binding)
      when is_map(capability) and is_map(binding) do
    with :ok <- validate_capability(capability),
         :ok <- validate_boundary(attempt, envelope),
         :ok <- validate_request_binding(binding) do
      monitor = Process.monitor(capability.controller)
      monitored_capability = Map.put(capability, :monitor, monitor)

      case acquire_exchange(monitored_capability, attempt, envelope, binding) do
        {:ok, %__MODULE__{} = token} ->
          {:ok, token}

        error ->
          Process.demonitor(monitor, [:flush])
          error
      end
    else
      {:error, reason} -> failure(reason)
    end
  end

  def acquire(_capability, _attempt, _envelope, _binding), do: failure(:invalid_proof_preflight)

  defp acquire_exchange(capability, attempt, envelope, binding) do
    owner = self()
    deadline = monotonic_ms() + capability.timeout_ms

    {reply_to, reply_monitor} =
      spawn_monitor(fn -> wait_for_controller_messages(owner, deadline) end)

    capability = Map.merge(capability, %{reply_to: reply_to, reply_monitor: reply_monitor})

    case acquire_exchange_with_reply_channel(capability, attempt, envelope, binding) do
      {:ok, %__MODULE__{} = token} ->
        {:ok, token}

      error ->
        stop_reply_receiver(reply_to, reply_monitor)
        error
    end
  end

  defp acquire_exchange_with_reply_channel(capability, attempt, envelope, binding) do
    with request_id <- make_ref(),
         request <- safe_request(attempt, envelope, capability, binding),
         {:ok, response} <- request_manifest(capability, request_id, request),
         {:ok, manifest} <- validate_manifest(response, attempt, envelope, capability, binding),
         {:ok, expiry} <- manifest_bound_expiry(manifest, capability.timeout_ms),
         :ok <- check_reply_channel(Map.put(capability, :expiry, expiry)),
         :ok <- no_duplicate_messages(),
         :ok <- claim_session(capability) do
      {:ok,
       %__MODULE__{
         owner: self(),
         controller: capability.controller,
         controller_ref: capability.ref,
         controller_monitor: capability.monitor,
         reply_to: capability.reply_to,
         reply_monitor: capability.reply_monitor,
         bindings: binding,
         manifest: manifest,
         expiry: expiry,
         ready: false,
         used: :atomics.new(2, signed: false)
       }}
    else
      {:error, reason} -> failure(reason)
    end
  end

  @spec ready(t()) :: {:ok, t()} | {:error, {:dispatch_witness_failed, term()}}
  def ready(%__MODULE__{owner: owner, ready: false} = token) when owner == self() do
    with :ok <- token_live(token),
         :ok <- claim_ready(token),
         request_id <- make_ref(),
         {:ok, ready} <- request_ready(token, request_id),
         :ok <- validate_ready(ready, token),
         :ok <- check_reply_channel(token),
         :ok <- no_duplicate_messages() do
      {:ok, %{token | ready: ready}}
    else
      {:error, reason} -> failure(reason)
    end
  end

  def ready(%__MODULE__{owner: owner} = _token) when owner == self(), do: failure(:proof_ready_already_received)

  def ready(_token), do: failure(:proof_token_owner_mismatch)

  @spec consume(t(), map()) :: :ok | {:error, {:dispatch_witness_failed, term()}}
  def consume(%__MODULE__{owner: owner} = token, binding) when owner == self() and is_map(binding) do
    case :atomics.get(token.used, 1) do
      1 -> failure(:proof_token_consumed)
      0 -> consume_unused(token, binding)
      _ -> failure(:proof_token_not_ready)
    end
  end

  def consume(_token, _binding), do: failure(:proof_token_owner_mismatch)

  defp consume_unused(token, binding) do
    with :ok <- token_live(token),
         true <- is_map(token.ready),
         true <- safe_equal?(token.bindings, binding),
         :ok <- check_reply_channel(token),
         :ok <- no_duplicate_messages(),
         :ok <- :atomics.compare_exchange(token.used, 1, 0, 1),
         :ok <- close_reply_channel(token),
         :ok <- no_duplicate_messages() do
      :ok
    else
      false -> failure(:proof_token_binding_mismatch)
      1 -> failure(:proof_token_consumed)
      {:error, reason} -> failure(reason)
      _ -> failure(:proof_token_not_ready)
    end
  end

  @spec release(t()) :: :ok
  def release(%__MODULE__{owner: owner, controller_monitor: monitor} = token)
      when owner == self() do
    stop_reply_receiver(token.reply_to, token.reply_monitor)

    if is_reference(monitor), do: Process.demonitor(monitor, [:flush])
    :ok
  end

  def release(_token), do: :ok

  @spec finch_name() :: atom()
  def finch_name, do: SymphonyElixir.H100TransportProofFinch

  defp validate_capability(%{
         controller: pid,
         ref: ref,
         timeout_ms: timeout,
         candidate_sha: sha,
         candidate_tree: tree,
         gate: gate
       })
       when is_pid(pid) and is_reference(ref) and is_integer(timeout) and timeout in 1..@max_timeout_ms and
              is_binary(sha) and is_binary(tree) do
    cond do
      node(pid) != node() ->
        {:error, :remote_proof_controller}

      :atomics.info(gate)[:size] == 1 and Process.alive?(pid) ->
        :ok

      true ->
        {:error, :proof_controller_unavailable}
    end
  rescue
    _ -> {:error, :invalid_proof_controller_capability}
  end

  defp validate_capability(_), do: {:error, :invalid_proof_controller_capability}

  defp claim_session(capability) do
    case :atomics.compare_exchange(capability.gate, 1, 0, 1) do
      :ok -> :ok
      _ -> {:error, :proof_already_active}
    end
  end

  defp claim_ready(token) do
    case :atomics.compare_exchange(token.used, 2, 0, 1) do
      :ok -> :ok
      _ -> {:error, :proof_ready_already_requested}
    end
  end

  defp validate_boundary(%TransitionAttempt{state: :mutation_submitted} = attempt, envelope) do
    if ProviderMutationEnvelope.valid?(envelope) and
         attempt.provider_request_id == envelope.provider_request_id and
         attempt.transition_attempt_id == envelope.transition_attempt_id and
         attempt.work_item_id == envelope.work_item_id and
         attempt.workspace_id == envelope.workspace_id and
         attempt.project_id == envelope.project_id and
         attempt.target_provider_state_id == envelope.target_provider_state_id do
      :ok
    else
      {:error, :persisted_attempt_envelope_mismatch}
    end
  end

  defp validate_boundary(_attempt, _envelope), do: {:error, :mutation_not_persisted}

  defp validate_request_binding(binding) do
    with :ok <- validate_binding_flags(binding),
         :ok <- validate_binding_origin(binding),
         :ok <- validate_binding_method(binding),
         :ok <- validate_body_bound(binding) do
      validate_path_bound(binding)
    end
  end

  defp validate_binding_flags(binding) do
    cond do
      binding[:witness_required?] != true -> {:error, :witness_required}
      binding[:durable?] != true -> {:error, :durable_proof_ledger_required}
      true -> :ok
    end
  end

  defp validate_binding_origin(binding) do
    if is_binary(binding[:origin_base_url]) and is_binary(binding[:origin_authority]),
      do: :ok,
      else: {:error, :invalid_origin}
  end

  defp validate_binding_method(binding) do
    if binding[:method] == "PATCH", do: :ok, else: {:error, {:proof_manifest_mismatch, :method}}
  end

  defp validate_body_bound(binding) do
    if bounded_nonnegative?(binding[:body_bytes], @max_body_bytes),
      do: :ok,
      else: {:error, {:proof_manifest_mismatch, :body_bytes}}
  end

  defp validate_path_bound(binding) do
    path_matches? =
      not Map.has_key?(binding, :path) or
        (is_binary(binding.path) and byte_size(binding.path) == binding[:path_bytes])

    if path_matches? and bounded_nonnegative?(binding[:path_bytes], @max_path_bytes),
      do: :ok,
      else: {:error, {:proof_manifest_mismatch, :path_bytes}}
  end

  defp safe_request(attempt, envelope, capability, binding) do
    %{
      provider_request_id: envelope.provider_request_id,
      transition_attempt_id: attempt.transition_attempt_id,
      work_item_id: attempt.work_item_id,
      workspace_id: attempt.workspace_id,
      project_id: attempt.project_id,
      target_state_id: attempt.target_provider_state_id,
      candidate_sha: capability.candidate_sha,
      candidate_tree: capability.candidate_tree,
      origin_base_url: binding.origin_base_url,
      origin_authority: binding.origin_authority,
      method: binding.method,
      body_bytes: binding.body_bytes,
      path_bytes: binding.path_bytes
    }
  end

  defp request_manifest(capability, request_id, request) do
    message = {:a4_manifest_request, nil, capability.ref, request_id, request}

    capability
    |> request_once(message, :proof_manifest_timeout)
    |> validate_manifest_response(capability, request_id)
  end

  defp request_ready(token, request_id) do
    message = {:a4_ready_request, nil, token.controller_ref, request_id, ready_request(token)}
    timeout_ms = max(token.expiry - monotonic_ms(), 0)

    capability = %{
      controller: token.controller,
      ref: token.controller_ref,
      monitor: token.controller_monitor,
      reply_to: token.reply_to,
      reply_monitor: token.reply_monitor,
      expiry: token.expiry,
      timeout_ms: timeout_ms
    }

    capability
    |> request_once(message, :proof_ready_timeout)
    |> validate_ready_response(capability, request_id)
  end

  defp request_once(capability, request, timeout_reason) do
    request_id = elem(request, 3)
    reply_to = capability.reply_to
    reply_monitor = capability.reply_monitor
    deadline = monotonic_ms() + capability.timeout_ms

    send(reply_to, {:a4_controller_reply_expect, self(), request_id})
    send(capability.controller, put_elem(request, 1, reply_to))

    receive_controller_reply(
      capability,
      reply_to,
      reply_monitor,
      request_id,
      deadline,
      timeout_reason
    )
  end

  defp wait_for_controller_messages(owner, deadline) do
    owner_monitor = Process.monitor(owner)

    receive do
      {:DOWN, ^owner_monitor, :process, ^owner, _reason} ->
        :ok

      {:a4_controller_reply_expect, ^owner, request_id} ->
        forward_controller_messages(owner, owner_monitor, deadline, request_id, false)
    after
      max(deadline - monotonic_ms(), 0) -> :ok
    end
  end

  defp forward_controller_messages(owner, owner_monitor, deadline, request_id, replied?) do
    receive do
      {:DOWN, ^owner_monitor, :process, ^owner, _reason} ->
        :ok

      {:a4_controller_reply_check, ^owner, check_ref, requested_expiry} ->
        deadline = requested_expiry
        send(owner, {:a4_controller_reply_checked, self(), check_ref})
        forward_controller_messages(owner, owner_monitor, deadline, request_id, replied?)

      {:a4_controller_reply_close, ^owner, close_ref} ->
        send(owner, {:a4_controller_reply_closed, self(), close_ref})
        :ok

      {:a4_controller_reply_expect, ^owner, next_request_id} ->
        forward_controller_messages(owner, owner_monitor, deadline, next_request_id, false)

      message when not replied? ->
        send(owner, {:a4_controller_message, self(), message})

        forward_controller_messages(owner, owner_monitor, deadline, request_id, true)

      _duplicate ->
        send(owner, {:a4_controller_duplicate, self(), request_id})
        :ok
    after
      max(deadline - monotonic_ms(), 0) -> :ok
    end
  end

  defp receive_controller_reply(
         capability,
         reply_to,
         reply_monitor,
         request_id,
         deadline,
         timeout_reason,
         controller_exit_reason \\ nil
       ) do
    receive do
      {:a4_controller_message, ^reply_to, response} ->
        {:ok, response}

      {:a4_controller_duplicate, ^reply_to, _request_id} ->
        {:error, :duplicate_or_unsolicited_controller_message}

      {:DOWN, monitor, :process, _pid, reason} when monitor == capability.monitor ->
        receive_controller_reply(
          capability,
          reply_to,
          reply_monitor,
          request_id,
          deadline,
          timeout_reason,
          safe_exit_reason(reason)
        )

      {:DOWN, monitor, :process, ^reply_to, _reason} when monitor == reply_monitor ->
        if controller_exit_reason do
          {:error, {:proof_controller_exit, controller_exit_reason}}
        else
          if Process.alive?(capability.controller) do
            {:error, :proof_reply_receiver_failed}
          else
            {:error, {:proof_controller_exit, :controller_failed}}
          end
        end
    after
      max(deadline - monotonic_ms(), 0) ->
        if controller_exit_reason do
          {:error, {:proof_controller_exit, controller_exit_reason}}
        else
          {:error, timeout_reason}
        end
    end
  end

  defp check_reply_channel(%{reply_to: reply_to, reply_monitor: reply_monitor, expiry: expiry})
       when is_pid(reply_to) and is_reference(reply_monitor) and is_integer(expiry) do
    check_ref = make_ref()
    send(reply_to, {:a4_controller_reply_check, self(), check_ref, expiry})

    receive do
      {:a4_controller_reply_checked, ^reply_to, ^check_ref} ->
        :ok

      {:a4_controller_duplicate, ^reply_to, _request_id} ->
        {:error, :duplicate_or_unsolicited_controller_message}

      {:DOWN, ^reply_monitor, :process, ^reply_to, _reason} ->
        {:error, :proof_reply_receiver_failed}
    after
      @max_timeout_ms -> {:error, :proof_reply_receiver_failed}
    end
  end

  defp check_reply_channel(_), do: {:error, :proof_reply_receiver_failed}

  defp close_reply_channel(%{reply_to: reply_to, reply_monitor: reply_monitor})
       when is_pid(reply_to) and is_reference(reply_monitor) do
    close_ref = make_ref()
    send(reply_to, {:a4_controller_reply_close, self(), close_ref})

    receive do
      {:a4_controller_reply_closed, ^reply_to, ^close_ref} ->
        :ok

      {:a4_controller_duplicate, ^reply_to, _request_id} ->
        {:error, :duplicate_or_unsolicited_controller_message}

      {:DOWN, ^reply_monitor, :process, ^reply_to, _reason} ->
        {:error, :proof_reply_receiver_failed}
    after
      @max_timeout_ms -> {:error, :proof_reply_receiver_failed}
    end
  end

  defp close_reply_channel(_), do: {:error, :proof_reply_receiver_failed}

  defp stop_reply_receiver(reply_to, reply_monitor) do
    reply_running? = is_pid(reply_to) and node(reply_to) == node() and Process.alive?(reply_to)

    if reply_running? do
      Process.exit(reply_to, :kill)

      if is_reference(reply_monitor) do
        receive do
          {:DOWN, ^reply_monitor, :process, ^reply_to, _reason} -> :ok
        after
          1_000 -> :ok
        end
      end
    end

    if is_reference(reply_monitor), do: Process.demonitor(reply_monitor, [:flush])
    if is_pid(reply_to), do: flush_reply_channel_messages(reply_to)
    :ok
  end

  defp flush_reply_channel_messages(reply_to) do
    receive do
      {:a4_controller_message, ^reply_to, _message} -> flush_reply_channel_messages(reply_to)
      {:a4_controller_duplicate, ^reply_to, _request_id} -> flush_reply_channel_messages(reply_to)
      {:a4_controller_reply_checked, ^reply_to, _check_ref} -> flush_reply_channel_messages(reply_to)
    after
      0 -> :ok
    end
  end

  defp validate_manifest_response(
         {:ok, {:a4_manifest_response, pid, ref, response_request_id, response}},
         capability,
         request_id
       )
       when pid == capability.controller and ref == capability.ref and response_request_id == request_id,
       do: {:ok, response}

  defp validate_manifest_response(
         {:ok, {:a4_manifest_response, _pid, _ref, response_request_id, _response}},
         _capability,
         request_id
       )
       when response_request_id == request_id,
       do: {:error, :wrong_controller_reference}

  defp validate_manifest_response({:ok, _response}, _capability, _request_id),
    do: {:error, :invalid_manifest_response}

  defp validate_manifest_response({:error, _reason} = error, _capability, _request_id), do: error

  defp validate_manifest(
         %{canonical_json: json, sha256: hash, manifest: manifest},
         attempt,
         envelope,
         capability,
         binding
       )
       when is_binary(json) and is_binary(hash) and is_map(manifest) do
    if byte_size(json) > 16_384 do
      {:error, {:proof_manifest_mismatch, :manifest_bytes}}
    else
      validate_manifest_json(json, hash, manifest, attempt, envelope, capability, binding)
    end
  end

  defp validate_manifest(_, _, _, _, _), do: {:error, {:proof_manifest_mismatch, :shape}}

  defp validate_manifest_json(json, hash, manifest, attempt, envelope, capability, binding) do
    with {:ok, decoded} <- Jason.decode(json),
         true <- valid_manifest_keys?(manifest),
         true <- decoded == stringify_keys(manifest),
         {:ok, canonical} <- canonical_json(decoded),
         true <- canonical == json,
         true <- hash == manifest_hash(decoded),
         true <- manifest_value(decoded, :manifest_sha256) == hash,
         true <- exact_fields?(decoded),
         :ok <- manifest_fields(manifest, attempt, envelope, capability, binding) do
      {:ok, manifest}
    else
      false -> {:error, {:proof_manifest_mismatch, :canonical_or_hash}}
      {:error, {:proof_manifest_mismatch, _field}} = error -> error
      {:error, _} -> {:error, {:proof_manifest_mismatch, :canonical_json}}
    end
  end

  defp manifest_fields(manifest, attempt, envelope, capability, binding) do
    checks = [
      {manifest_value(manifest, :schema) == "a4-v2_1", :schema},
      {manifest_value(manifest, :experiment_scope) == "single_designated_state_patch", :experiment_scope},
      {manifest_value(manifest, :provider_request_id) == envelope.provider_request_id, :provider_request_id},
      {manifest_value(manifest, :transition_attempt_id) == attempt.transition_attempt_id, :transition_attempt_id},
      {manifest_value(manifest, :work_item_id) == attempt.work_item_id, :work_item_id},
      {manifest_value(manifest, :workspace_id) == attempt.workspace_id, :workspace_id},
      {manifest_value(manifest, :project_id) == attempt.project_id, :project_id},
      {manifest_value(manifest, :target_state_id) == attempt.target_provider_state_id, :target_state_id},
      {manifest_value(manifest, :method) == binding.method, :method},
      {manifest_value(manifest, :origin_base_url) == binding.origin_base_url, :origin_base_url},
      {manifest_value(manifest, :origin_authority) == binding.origin_authority, :origin_authority},
      {valid_origin?(manifest, binding), :origin_authority},
      {manifest_value(manifest, :candidate_sha) == capability.candidate_sha, :candidate_sha},
      {manifest_value(manifest, :candidate_tree) == capability.candidate_tree, :candidate_tree},
      {valid_hex?(manifest_value(manifest, :relay_script_blob_sha256), 64), :relay_script_blob_sha256},
      {valid_text?(manifest_value(manifest, :manifest_id)), :manifest_id},
      {valid_text?(manifest_value(manifest, :operator_authorization_ref)), :operator_authorization_ref},
      {valid_text?(manifest_value(manifest, :python_path)), :python_path},
      {valid_text?(manifest_value(manifest, :python_version)), :python_version},
      {manifest_value(manifest, :max_dispatch) == 1, :max_dispatch},
      {manifest_value(manifest, :max_connect) == 1, :max_connect},
      {manifest_value(manifest, :max_client_app_records) == 1, :max_client_app_records},
      {manifest_value(manifest, :tls_versions) in [["tlsv1.2"], [":tlsv1.2"]], :tls_versions},
      {valid_window?(manifest), :expires_at}
    ]

    case Enum.find(checks, fn {ok, _field} -> not ok end) do
      nil -> :ok
      {_false, field} -> {:error, {:proof_manifest_mismatch, field}}
    end
  end

  defp valid_window?(manifest) do
    with not_before_value when is_binary(not_before_value) <- manifest_value(manifest, :not_before),
         expires_value when is_binary(expires_value) <- manifest_value(manifest, :expires_at),
         {:ok, not_before, _} <- DateTime.from_iso8601(not_before_value),
         {:ok, expires, _} <- DateTime.from_iso8601(expires_value) do
      now = DateTime.utc_now()
      DateTime.compare(not_before, now) != :gt and DateTime.compare(expires, now) == :gt
    else
      _ -> false
    end
  end

  defp manifest_bound_expiry(manifest, timeout_ms) do
    with expires_value when is_binary(expires_value) <- manifest_value(manifest, :expires_at),
         {:ok, expires, _offset} <- DateTime.from_iso8601(expires_value),
         remaining_ms when remaining_ms > 0 <- DateTime.diff(expires, DateTime.utc_now(), :millisecond) do
      {:ok, monotonic_ms() + min(timeout_ms, remaining_ms)}
    else
      _ -> {:error, {:proof_manifest_mismatch, :expires_at}}
    end
  end

  defp valid_origin?(manifest, binding) do
    case manifest_value(manifest, :origin_kind) do
      "live_plane" ->
        binding.origin_authority == "api.plane.so:443" and
          binding.origin_base_url == "https://api.plane.so"

      "local_qualification" ->
        String.starts_with?(binding.origin_authority, "127.0.0.1:")

      _ ->
        false
    end
  end

  defp ready_request(token),
    do: %{
      provider_request_id: manifest_value(token.manifest, :provider_request_id),
      relay_script_blob_sha256: manifest_value(token.manifest, :relay_script_blob_sha256)
    }

  defp validate_ready_response(
         {:ok, {:a4_ready_response, pid, ref, response_request_id, ready}},
         capability,
         request_id
       )
       when pid == capability.controller and ref == capability.ref and response_request_id == request_id,
       do: {:ok, ready}

  defp validate_ready_response(
         {:ok, {:a4_ready_response, _pid, _ref, response_request_id, _ready}},
         _capability,
         request_id
       )
       when response_request_id == request_id,
       do: {:error, :wrong_controller_reference}

  defp validate_ready_response({:ok, _response}, _capability, _request_id),
    do: {:error, :invalid_ready_response}

  defp validate_ready_response({:error, _reason} = error, _capability, _request_id), do: error

  defp validate_ready(ready, token) when is_map(ready) do
    manifest = token.manifest

    checks = [
      {:erlang.external_size(ready) <= @max_ready_bytes, :size},
      {exact_ready_fields?(ready), :fields},
      {valid_ready_identity?(ready, manifest), :identity},
      {valid_ready_listener?(ready), :listener},
      {valid_ready_runtime?(ready, manifest), :runtime},
      {valid_environment_names?(manifest_value(ready, :environment_names)), :environment_names}
    ]

    case Enum.find(checks, fn {valid?, _field} -> not valid? end) do
      nil -> :ok
      {_invalid, _field} -> {:error, {:proof_manifest_mismatch, :ready}}
    end
  end

  defp validate_ready(_, _), do: {:error, :invalid_ready_response}

  defp valid_ready_identity?(ready, manifest) do
    manifest_value(ready, :type) == "READY" and
      manifest_value(ready, :provider_request_id) == manifest_value(manifest, :provider_request_id)
  end

  defp valid_ready_listener?(ready) do
    port = manifest_value(ready, :bound_port)
    manifest_value(ready, :listen_host) == "127.0.0.1" and is_integer(port) and port in 1..65_535
  end

  defp valid_ready_runtime?(ready, manifest) do
    manifest_value(ready, :python_version) == manifest_value(manifest, :python_version) and
      manifest_value(ready, :script_blob_sha256) == manifest_value(manifest, :relay_script_blob_sha256)
  end

  defp exact_ready_fields?(ready) do
    keys = Map.keys(ready)

    Enum.all?(keys, &(is_atom(&1) or is_binary(&1))) and
      Enum.sort(Enum.map(keys, &to_string/1)) == Enum.sort(Enum.map(@ready_fields, &Atom.to_string/1))
  end

  defp valid_environment_names?(names) when is_list(names) and length(names) <= 64 do
    Enum.all?(names, fn name ->
      is_binary(name) and byte_size(name) in 1..128 and not forbidden_environment_name?(name)
    end) and length(Enum.uniq(names)) == length(names)
  end

  defp valid_environment_names?(_names), do: false

  defp forbidden_environment_name?(name) do
    Regex.match?(~r/(_TOKEN|_SECRET|_API_KEY|PASSWORD)/i, name) or
      String.upcase(name) in ["SSH_AUTH_SOCK", "SSH_AGENT_PID", "GIT_ASKPASS"]
  end

  defp token_live(%__MODULE__{expiry: expiry, controller: controller}) do
    cond do
      monotonic_ms() >= expiry -> {:error, :proof_token_expired}
      not Process.alive?(controller) -> {:error, :proof_controller_unavailable}
      true -> :ok
    end
  end

  defp safe_equal?(a, b) do
    left = :crypto.hash(:sha256, :erlang.term_to_binary(a))
    right = :crypto.hash(:sha256, :erlang.term_to_binary(b))
    left == right
  end

  defp canonical_json(map) do
    map |> sort_json() |> Jason.encode()
  end

  defp manifest_hash(decoded) do
    decoded
    |> Map.delete("manifest_sha256")
    |> canonical_json()
    |> case do
      {:ok, canonical} -> :crypto.hash(:sha256, canonical) |> Base.encode16(case: :lower)
      _ -> ""
    end
  end

  defp exact_fields?(decoded) do
    Enum.sort(Map.keys(decoded)) == Enum.sort(Enum.map(@manifest_fields, &Atom.to_string/1))
  end

  defp valid_manifest_keys?(manifest),
    do: Enum.all?(Map.keys(manifest), &is_binary/1)

  defp no_duplicate_messages do
    receive do
      message
      when is_tuple(message) and tuple_size(message) > 0 and
             elem(message, 0) in [
               :a4_manifest_response,
               :a4_ready_response,
               :a4_controller_message,
               :a4_controller_duplicate
             ] ->
        {:error, :duplicate_or_unsolicited_controller_message}
    after
      0 -> :ok
    end
  end

  defp sort_json(map) when is_map(map),
    do:
      Jason.OrderedObject.new(
        map
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(fn {key, value} -> {key, sort_json(value)} end)
      )

  defp sort_json(list) when is_list(list), do: Enum.map(list, &sort_json/1)
  defp sort_json(value), do: value

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
  defp manifest_value(manifest, key), do: Map.get(manifest, key) || Map.get(manifest, Atom.to_string(key))
  defp bounded_nonnegative?(value, max), do: is_integer(value) and value >= 0 and value <= max
  defp valid_text?(value), do: is_binary(value) and String.trim(value) != ""

  defp valid_hex?(value, length) do
    is_binary(value) and byte_size(value) == length and Regex.match?(~r/\A[0-9a-f]+\z/, value)
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
  defp safe_exit_reason(reason) when reason in [:normal, :shutdown], do: reason
  defp safe_exit_reason(_reason), do: :controller_failed
  defp failure(reason), do: {:error, {:dispatch_witness_failed, reason}}
end
