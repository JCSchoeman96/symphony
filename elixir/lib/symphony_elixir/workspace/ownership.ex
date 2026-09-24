defmodule SymphonyElixir.Workspace.Ownership do
  @moduledoc """
  Pure values and transitions for durable workspace ownership.

  This module has no filesystem or runtime state. The ledger owns persistence;
  this module only defines the state machine and the collision-safe workspace
  key derivation used by it.
  """

  @states [:reserved, :provisioning, :owned, :release_pending, :released]

  @transitions %{
    reserved: [:provisioning],
    provisioning: [:owned, :release_pending],
    owned: [:release_pending],
    release_pending: [:owned, :released],
    released: []
  }

  @record_keys [
    :schema_version,
    :project_namespace,
    :tracker_identity,
    :issue_identifier,
    :work_item_id,
    :workspace_key,
    :workspace_ownership_id,
    :location,
    :worker_host,
    :trusted_host_identity,
    :configured_root,
    :configured_root_identity,
    :canonical_root,
    :canonical_workspace_path,
    :top_level_filesystem_identity,
    :release_origin,
    :state,
    :created_at,
    :updated_at
  ]

  @type state :: :reserved | :provisioning | :owned | :release_pending | :released

  @type filesystem_identity ::
          String.t()
          | {integer(), non_neg_integer()}
          | {integer(), integer(), non_neg_integer()}
          | %{required(:device) => integer(), required(:inode) => non_neg_integer()}
          | %{
              required(:major_device) => integer(),
              required(:minor_device) => integer(),
              required(:inode) => non_neg_integer()
            }

  @type record :: %{atom() => term()}

  @spec states() :: [state()]
  def states, do: @states

  @spec record_keys() :: [atom()]
  def record_keys, do: @record_keys

  @spec valid_state?(term()) :: boolean()
  def valid_state?(state), do: state in @states

  @spec terminal?(term()) :: boolean()
  def terminal?(:released), do: true
  def terminal?(_state), do: false

  @spec transition_allowed?(term(), term()) :: boolean()
  def transition_allowed?(from, to) when from in @states and to in @states do
    to in Map.fetch!(@transitions, from)
  end

  def transition_allowed?(_from, _to), do: false

  @spec valid_transition?(term(), term()) :: boolean()
  def valid_transition?(from, to), do: transition_allowed?(from, to)

  @spec transition(term(), term()) :: {:ok, state()} | {:error, term()}
  def transition(from, to) do
    cond do
      not valid_state?(from) -> {:error, {:invalid_state, from}}
      not valid_state?(to) -> {:error, {:invalid_state, to}}
      transition_allowed?(from, to) -> {:ok, to}
      true -> {:error, {:invalid_transition, from, to}}
    end
  end

  @spec workspace_key(String.t() | nil | term()) :: String.t()
  def workspace_key(%{identifier: identifier}), do: workspace_key(identifier)

  def workspace_key(identifier) when is_binary(identifier) do
    safe_identifier = String.replace(identifier, ~r/[^a-zA-Z0-9._-]/, "_")

    if safe_identifier == identifier do
      safe_identifier
    else
      "#{safe_identifier}--#{short_identifier_hash(identifier)}"
    end
  end

  def workspace_key(_identifier), do: "issue"

  defp short_identifier_hash(identifier) do
    :crypto.hash(:sha256, identifier)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end
end
