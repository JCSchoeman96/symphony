defmodule SymphonyElixir.A4ClientTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Plane.Client
  alias SymphonyElixir.Plane.Adapter
  alias SymphonyElixir.WorkControl.A4Proof
  alias SymphonyElixir.WorkControl.{ProviderMutationEnvelope, ProviderProjectContract, TransitionAttempt, WorkflowLifecycle}

  test "rejects an invalid proof session before invoking an alternate transport" do
    parent = self()

    assert {:error, {:dispatch_witness_failed, _reason}} =
             Client.update_work_item_state(
               %{
                 base_url: "https://api.plane.so",
                 workspace_slug: "workspace",
                 workspace_id: "workspace-id",
                 project_id: "project",
                 api_key: "secret"
               },
               "item-1",
               "state-done",
               a4_session: :invalid,
               request_fun: fn _request ->
                 send(parent, :transport_called)
                 {:ok, %{status: 204}}
               end
             )

    refute_received :transport_called
  end

  test "accepts only the matching local proof origin before a proof session fails closed" do
    config = %{
      base_url: "https://127.0.0.1:44321",
      workspace_slug: "workspace",
      workspace_id: "workspace-id",
      project_id: "project",
      api_key: "secret"
    }

    session = %{
      manifest: %{
        origin_kind: :local_qualification,
        origin_base_url: config.base_url,
        origin_authority: "127.0.0.1:44321"
      }
    }

    assert {:error, {:dispatch_witness_failed, :witness_required}} =
             Client.update_work_item_state(config, "item-1", "state-done", a4_session: session)

    assert Process.whereis(SymphonyElixir.H100TransportProofFinch) == nil
  end

  test "TLS probe options enforce peer verification and TLS 1.2" do
    options = Client.tls_options("api.plane.so")

    assert options[:verify] == :verify_peer
    assert options[:versions] == [:"tlsv1.2"]
    assert options[:cacerts] == :public_key.cacerts_get()
    assert options[:server_name_indication] == ~c"api.plane.so"
  end

  test "wraps controlled adapter validation failures as A4 preinvoke failures" do
    original_api_key = System.get_env("PLANE_API_KEY")
    System.delete_env("PLANE_API_KEY")

    on_exit(fn ->
      if is_nil(original_api_key), do: System.delete_env("PLANE_API_KEY"), else: System.put_env("PLANE_API_KEY", original_api_key)
    end)

    state_mappings =
      Map.new(WorkflowLifecycle.states(), fn state ->
        {state, %{state_id: "state-#{state}", name: WorkflowLifecycle.display(state)}}
      end)

    {:ok, contract} =
      ProviderProjectContract.new(%{
        schema_version: 1,
        provider: :plane,
        workspace_id: "workspace-id",
        project_id: "project",
        state_mappings: state_mappings,
        dependency_relation_semantics: %{blocked_by: :blocked_by, blocking: :blocking}
      })

    tracker_settings = %{
      kind: "plane",
      provider: %{
        workspace_slug: "workspace",
        workspace_id: "workspace-id",
        project_id: "project",
        api_key: "$PLANE_API_KEY"
      },
      secret_environment_names: ["PLANE_API_KEY"]
    }

    assert {:error, {:dispatch_witness_failed, {:adapter_preflight_failed, :missing_plane_api_key}}} =
             Adapter.submit_controlled_transition("item-1", :in_progress,
               tracker_settings: tracker_settings,
               provider_project_contract: contract,
               a4_session: :test_session,
               dispatch_witness_required?: true,
               request_fun: fn _request -> flunk("adapter preflight failure must not invoke transport") end
             )

    assert {:error, :missing_plane_api_key} =
             Adapter.submit_controlled_transition("item-1", :in_progress,
               tracker_settings: tracker_settings,
               provider_project_contract: contract,
               dispatch_witness_required?: true,
               request_fun: fn _request -> flunk("adapter preflight failure must not invoke transport") end
             )
  end

  test "rejects a transition attempt mismatch before READY and releases the acquired controller monitor" do
    {attempt, envelope} = submitted_identity()
    parent = self()
    capability = capability(self())
    binding = mutation_binding()

    controller =
      spawn(fn ->
        receive do
          {:a4_manifest_request, reply_to, ref, request_id, _safe_request} ->
            payload = manifest_payload(envelope, attempt, capability)
            send(reply_to, {:a4_manifest_response, self(), ref, request_id, payload})
        end

        receive do
          :stop -> :ok
        end
      end)

    capability = %{capability | controller: controller}
    assert {:ok, token} = A4Proof.acquire(capability, attempt, envelope, binding)

    assert {:error, {:dispatch_witness_failed, {:proof_manifest_mismatch, :transition_attempt_id}}} =
             Client.update_work_item_state(client_config(), "item-1", "state-done",
               a4_session: token,
               provider_mutation_envelope: %{envelope | transition_attempt_id: "attempt-2"},
               dispatch_witness_required?: true,
               request_fun: fn _request ->
                 send(parent, :transport_called)
                 {:ok, %{status: 204}}
               end
             )

    assert Process.demonitor(token.controller_monitor, [:info]) == false
    refute_received :unexpected_ready
    refute_received :transport_called
    send(controller, :stop)
  end

  defp client_config do
    %{
      base_url: "https://api.plane.so",
      workspace_slug: "workspace",
      workspace_id: "workspace-id",
      project_id: "project",
      api_key: "secret"
    }
  end

  defp submitted_identity do
    attempt = %TransitionAttempt{
      state: :mutation_submitted,
      transition_attempt_id: "attempt-1",
      provider_request_id: "preq_00000000-0000-4000-8000-000000000001",
      work_item_id: "item-1",
      workspace_id: "workspace-id",
      project_id: "project",
      target_provider_state_id: "state-done"
    }

    envelope = %ProviderMutationEnvelope{
      provider_request_id: attempt.provider_request_id,
      transition_attempt_id: attempt.transition_attempt_id,
      work_item_id: attempt.work_item_id,
      provider: :plane,
      workspace_id: attempt.workspace_id,
      project_id: attempt.project_id,
      requested_from: :started,
      requested_to: :completed,
      target_provider_state_id: attempt.target_provider_state_id,
      target_provider_state_group: :completed,
      provider_contract_fingerprint: "fingerprint",
      submitted_at: DateTime.utc_now()
    }

    {attempt, envelope}
  end

  defp capability(controller) do
    %{
      controller: controller,
      ref: make_ref(),
      timeout_ms: 500,
      candidate_sha: String.duplicate("a", 40),
      candidate_tree: String.duplicate("b", 40),
      gate: :atomics.new(1, signed: false)
    }
  end

  defp mutation_binding do
    path = "/api/v1/workspaces/workspace/projects/project/work-items/item-1/"

    %{
      witness_required?: true,
      durable?: true,
      origin_base_url: "https://api.plane.so",
      origin_authority: "api.plane.so:443",
      method: "PATCH",
      path: path,
      path_bytes: byte_size(path),
      body_bytes: byte_size(Jason.encode!(%{"state" => "state-done"}))
    }
  end

  defp manifest_payload(envelope, attempt, capability) do
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
      "expires_at" => DateTime.add(DateTime.utc_now(), 300, :second) |> DateTime.to_iso8601(),
      "operator_authorization_ref" => "auth-1",
      "manifest_sha256" => ""
    }

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
    Jason.OrderedObject.new(map |> Enum.sort_by(&elem(&1, 0))) |> Jason.encode!()
  end
end
