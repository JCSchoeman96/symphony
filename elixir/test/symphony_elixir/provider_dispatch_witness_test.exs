defmodule SymphonyElixir.ProviderDispatchWitnessTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.WorkControl.{ProviderDispatchWitness, ProviderMutationEnvelope}

  @request_id "preq_00000000-0000-4000-8000-000000000001"
  @now ~U[2026-10-19 09:00:00Z]

  test "acknowledges the exact Finch request identity before transport" do
    parent = self()
    envelope = envelope()
    request = finch_request(@request_id)

    result =
      ProviderDispatchWitness.dispatch(
        envelope,
        request,
        fn witness ->
          send(parent, {:witness, witness})
          {:ok, witness.provider_request_id}
        end,
        true,
        fn exact_request ->
          send(parent, {:transport, exact_request})
          {:ok, :response}
        end
      )

    assert result == {:ok, :response}
    assert_receive {:witness, witness}
    assert ProviderDispatchWitness.valid?(witness)
    assert witness.provider_request_id == @request_id
    assert witness.transition_attempt_id == "transition-1"
    assert witness.work_item_id == "work-1"
    assert witness.requested_from == :merging
    assert witness.requested_to == :done
    assert witness.target_provider_state_id == "state-done"
    assert witness.dispatch_observed_at != nil

    refute Map.has_key?(Map.from_struct(witness), :headers)
    refute Map.has_key?(Map.from_struct(witness), :body)
    refute Map.has_key?(Map.from_struct(witness), :credential)
    refute Map.has_key?(Map.from_struct(witness), :provider_response)

    assert_receive {:transport, ^request}
    refute_received {:witness, _}
  end

  test "fails closed on missing, throwing, rejected, and mismatched acknowledgments" do
    failing_sinks = [
      nil,
      fn _witness -> raise "sink unavailable" end,
      fn _witness -> {:error, :offline} end,
      fn _witness -> {:ok, "preq_00000000-0000-4000-8000-000000000002"} end
    ]

    for sink <- failing_sinks do
      parent = self()

      assert {:error, {:dispatch_witness_failed, _reason}} =
               ProviderDispatchWitness.dispatch(
                 envelope(),
                 finch_request(@request_id),
                 sink,
                 true,
                 fn _request ->
                   send(parent, :transport_called)
                   {:ok, :response}
                 end
               )

      refute_received :transport_called
    end
  end

  test "rejects a Finch request carrying a different correlation identity before witness or transport" do
    parent = self()

    assert {:error, {:dispatch_witness_failed, :request_identity_mismatch}} =
             ProviderDispatchWitness.dispatch(
               envelope(),
               finch_request("preq_00000000-0000-4000-8000-000000000002"),
               fn _witness ->
                 send(parent, :witness_called)
                 {:ok, @request_id}
               end,
               true,
               fn _request ->
                 send(parent, :transport_called)
                 {:ok, :response}
               end
             )

    refute_received :witness_called
    refute_received :transport_called
  end

  defp envelope do
    %ProviderMutationEnvelope{
      provider_request_id: @request_id,
      transition_attempt_id: "transition-1",
      work_item_id: "work-1",
      provider: :plane,
      workspace_id: "workspace-1",
      project_id: "project-1",
      requested_from: :merging,
      requested_to: :done,
      target_provider_state_id: "state-done",
      target_provider_state_group: :completed,
      provider_contract_fingerprint: "sha256:contract",
      submitted_at: @now
    }
  end

  defp finch_request(request_id) do
    Finch.build(:patch, "https://api.plane.so/api/v1/work-items/work-1/", [], ~s({"state":"state-done"}))
    |> Finch.Request.put_private(ProviderDispatchWitness.private_request_id_key(), request_id)
  end
end
