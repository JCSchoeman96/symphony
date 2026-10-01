defmodule SymphonyElixir.TrackerReadAttestationTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{Config, TestSupport, Tracker, Workflow, WorkflowStore}

  alias SymphonyElixir.Dependency.Graph
  alias SymphonyElixir.Tracker.Issue

  alias SymphonyElixir.WorkControl.{
    CompletionProof,
    ProviderObservation,
    ProviderProjectContract,
    WorkflowLifecycle,
    WorkItem
  }

  @settings %{
    kind: "plane",
    api_key: "tracker-api-key-for-signing",
    endpoint: "https://api.plane.so",
    provider: %{
      "workspace_slug" => "workspace-1",
      "workspace_id" => "workspace-stable-1",
      "project_id" => "project-1",
      "api_key" => "$PLANE_API_KEY"
    },
    secret_environment_names: ["PLANE_API_KEY"]
  }

  setup do
    previous_signing_key = Application.get_env(:symphony_elixir, :completion_proof_signing_key)
    previous_plane_key = System.get_env("PLANE_API_KEY")
    Application.delete_env(:symphony_elixir, :completion_proof_signing_key)

    on_exit(fn ->
      restore_application_env(:completion_proof_signing_key, previous_signing_key)
      restore_env("PLANE_API_KEY", previous_plane_key)
    end)

    :ok
  end

  test "configured no-options Plane reads close completion through the trusted Tracker path" do
    with_plane_workflow(fn settings ->
      Application.put_env(:symphony_elixir, :completion_proof_signing_key, @settings.api_key)
      install_plane_req_adapter()

      project_contract = contract()
      merge_verified = TestSupport.completion_proof_fixture("item-1", project_contract)

      assert {:ok, [%Issue{} = issue]} = Tracker.fetch_issues_by_ids(["item-1"])
      assert %ProviderObservation{} = observation = issue.tracker_read_observation
      assert observation.provider == :plane
      assert observation.work_item_id == "item-1"
      assert ProviderObservation.valid_tracker_read?(observation)

      expected_key = :crypto.hash(:sha256, "symphony-tracker-read-v1:" <> settings.tracker.api_key)

      expected_signature =
        :crypto.mac(:hmac, :sha256, expected_key, ProviderObservation.tracker_read_payload(observation))

      supplied_signature =
        observation.tracker_read_signature
        |> String.replace_prefix("sha256:", "")
        |> Base.decode16!(case: :lower)

      assert :crypto.hash_equals(supplied_signature, expected_signature)

      assert {:ok, %CompletionProof{stage: :completed} = completed_proof} =
               CompletionProof.close(merge_verified, observation, project_contract)

      assert {:ok, completed_work_item} =
               WorkItem.from_issue(issue, %{
                 provider: :plane,
                 provider_observation: observation,
                 prior_validated_lifecycle_state: :merging,
                 evidence: [merge_verified],
                 provider_project_contract: project_contract
               })

      assert completed_proof in completed_work_item.lifecycle_assessment.satisfied_guards
      assert WorkItem.dependency_satisfying?(completed_work_item)

      metrics = :atomics.new(8, [])

      assert {:ok, %Graph{nodes: %{"item-1" => %Issue{} = graph_issue}}} =
               Tracker.fetch_dependency_graph_for_epoch(make_ref(), metrics)

      assert %ProviderObservation{} = graph_observation = graph_issue.tracker_read_observation
      assert ProviderObservation.valid_tracker_read?(graph_observation)
    end)
  end

  test "ProviderObservation requires a Plane receipt key when verifying a signature" do
    observation = %ProviderObservation{
      tracker_read_signature: "sha256:" <> Base.encode16(<<0::256>>, case: :lower)
    }

    refute ProviderObservation.valid_tracker_read?(observation)
  end

  test "Tracker rejects malformed issue and dependency epoch read contexts" do
    assert {:error, :current_issue_refresh_unsupported} = Tracker.fetch_issues_by_ids(:invalid)

    assert {:error, :invalid_dependency_epoch_context} =
             Tracker.fetch_dependency_graph_for_epoch(make_ref(), :atomics.new(1, []))

    assert {:error, :invalid_dependency_epoch_context} =
             Tracker.fetch_dependency_graph_for_epoch(make_ref(), make_ref())

    assert {:error, :invalid_dependency_epoch_context} =
             Tracker.fetch_dependency_graph_for_epoch(:invalid_epoch, :atomics.new(8, []))
  end

  test "Tracker does not attest epoch graphs for non-Plane providers" do
    with_plane_workflow(fn _settings ->
      File.write!(Workflow.workflow_file_path(), memory_workflow())
      assert :ok = WorkflowStore.force_reload()

      assert {:error, :dependency_graph_unsupported} =
               Tracker.fetch_dependency_graph_for_epoch(make_ref(), :atomics.new(8, []))
    end)
  end

  defp with_plane_workflow(fun) do
    previous_workflow_path = Application.get_env(:symphony_elixir, :workflow_file_path)
    previous_signing_key = Application.get_env(:symphony_elixir, :completion_proof_signing_key)
    previous_plane_key = System.get_env("PLANE_API_KEY")
    previous_req_options = Req.default_options()
    root = Path.join(System.tmp_dir!(), "tracker-attestation-#{System.unique_integer([:positive])}")
    workflow_path = Path.join(root, "WORKFLOW.md")

    File.mkdir_p!(root)
    System.put_env("PLANE_API_KEY", @settings.api_key)
    Application.delete_env(:symphony_elixir, :completion_proof_signing_key)
    File.write!(workflow_path, plane_workflow())
    Workflow.set_workflow_file_path(workflow_path)
    assert :ok = WorkflowStore.force_reload()

    try do
      fun.(Config.settings!())
    after
      restore_application_env(:workflow_file_path, previous_workflow_path)
      restore_application_env(:completion_proof_signing_key, previous_signing_key)
      restore_env("PLANE_API_KEY", previous_plane_key)
      Req.default_options(previous_req_options)

      if Process.whereis(WorkflowStore), do: WorkflowStore.force_reload()
      File.rm_rf(root)
    end
  end

  defp plane_workflow do
    """
    ---
    symphony:
      project_id: tracker-attestation-test
    tracker:
      kind: plane
      provider:
        workspace_slug: workspace-1
        workspace_id: workspace-stable-1
        project_id: project-1
      api_key: "$PLANE_API_KEY"
    agent:
      routing: routed
    source_control:
      kind: github
      repository: octo/symphony
      repository_id: 1368436395
      base_branch: main
      token_env: GITHUB_TOKEN
      required_checks:
        - context: make-all
          app_id: 15368
          subject: head
    ---
    Tracker attestation test.
    """
  end

  defp memory_workflow do
    """
    ---
    symphony:
      project_id: tracker-attestation-memory-test
    tracker:
      kind: memory
    ---
    Tracker attestation test.
    """
  end

  defp install_plane_req_adapter do
    Req.default_options(
      adapter: fn request ->
        path = request.url.path

        response =
          cond do
            is_binary(path) and String.ends_with?(path, "/work-items/item-1/") ->
              plane_item()

            is_binary(path) and String.ends_with?(path, "/work-items/") ->
              %{
                "results" => [plane_item()],
                "count" => 1,
                "total_results" => 1,
                "next_page_results" => false,
                "next_cursor" => nil
              }

            is_binary(path) and String.ends_with?(path, "/relations/") ->
              %{"blocked_by" => [], "blocking" => []}

            true ->
              raise "unexpected Plane request path #{inspect(path)}"
          end

        {request, Req.Response.new(status: 200, body: Jason.encode!(response))}
      end
    )
  end

  defp plane_item do
    %{
      "id" => "item-1",
      "name" => "Work",
      "state" => %{"id" => "state-done", "name" => "Done", "group" => "completed"},
      "project" => "project-1",
      "workspace" => "workspace-stable-1",
      "updated_at" => "2026-09-17T08:09:10Z"
    }
  end

  defp contract do
    state_mappings =
      Map.new(WorkflowLifecycle.states(), fn state ->
        {state, %{state_id: "state-#{state}", name: WorkflowLifecycle.display(state)}}
      end)

    {:ok, contract} =
      ProviderProjectContract.new(%{
        schema_version: 1,
        provider: :plane,
        workspace_id: "workspace-stable-1",
        project_id: "project-1",
        state_mappings: state_mappings,
        dependency_relation_semantics: %{blocked_by: :blocked_by, blocking: :blocking}
      })

    contract
  end

  defp restore_application_env(key, nil), do: Application.delete_env(:symphony_elixir, key)

  defp restore_application_env(key, value),
    do: Application.put_env(:symphony_elixir, key, value)

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
