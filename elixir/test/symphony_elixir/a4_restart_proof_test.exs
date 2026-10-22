Code.require_file("../support/a4/restart_proof.exs", __DIR__)

defmodule SymphonyElixir.A4RestartProofTest do
  use ExUnit.Case, async: false

  test "a separate VM restart fences the prior proof token and submitted work item" do
    evidence = SymphonyElixir.A4RestartProof.run!()

    assert evidence.first_vm_os_pid != evidence.second_vm_os_pid
    assert evidence.first_vm_os_pid > 0
    assert evidence.second_vm_os_pid > 0
    assert evidence.pre_restart_token_ready == false
    assert evidence.recovered_attempt.state == :mutation_submitted
    assert evidence.recovered_attempt.provider_request_id == evidence.provider_request_id
    assert evidence.prior_manifest["provider_request_id"] == evidence.provider_request_id

    assert evidence.old_token_result ==
             {:error, {:dispatch_witness_failed, :proof_token_owner_mismatch}}

    assert evidence.transition_result == {:error, :transition_fenced}
    assert evidence.manifest_requests_after_restart == 0
    assert evidence.helper_launches == 0
    assert evidence.finch_processes_after_restart == 0
    assert evidence.callback_log == ""
  end
end
