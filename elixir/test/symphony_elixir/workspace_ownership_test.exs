defmodule SymphonyElixir.WorkspaceOwnershipTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Workspace.Ownership

  test "exposes only durable ownership states" do
    assert Ownership.states() == [:reserved, :provisioning, :owned, :release_pending, :released]
    assert Enum.all?(Ownership.states(), &Ownership.valid_state?/1)
    refute Ownership.valid_state?(:unknown)
    assert Ownership.terminal?(:released)
    refute Ownership.terminal?(:owned)
    refute Ownership.terminal?(:unknown)
  end

  test "enforces the ownership lifecycle and terminal release" do
    assert Ownership.transition_allowed?(:reserved, :provisioning)
    refute Ownership.transition_allowed?(:reserved, :release_pending)
    assert Ownership.transition_allowed?(:provisioning, :owned)
    assert Ownership.transition_allowed?(:owned, :release_pending)
    assert Ownership.transition_allowed?(:release_pending, :owned)
    assert Ownership.transition_allowed?(:release_pending, :released)

    refute Ownership.transition_allowed?(:reserved, :owned)
    refute Ownership.transition_allowed?(:owned, :released)
    refute Ownership.transition_allowed?(:released, :reserved)
    refute Ownership.transition_allowed?(:unknown, :owned)

    assert {:ok, :provisioning} = Ownership.transition(:reserved, :provisioning)

    assert {:error, {:invalid_transition, :released, :reserved}} =
             Ownership.transition(:released, :reserved)

    assert {:error, {:invalid_state, :unknown}} = Ownership.transition(:unknown, :owned)
  end

  test "derives collision-safe workspace keys from identifiers" do
    assert Ownership.workspace_key("ABC-123") == "ABC-123"
    assert Ownership.workspace_key("ABC/123") == "ABC_123--e40e9a389ac15baf"
    assert Ownership.workspace_key(nil) == "issue"
  end

  test "publishes the durable record schema without runtime lineage fields" do
    assert :issue_identifier in Ownership.record_keys()
    refute :ownership_generation in Ownership.record_keys()
    refute :runtime_attempt_id in Ownership.record_keys()
    refute :session_id in Ownership.record_keys()
  end
end
