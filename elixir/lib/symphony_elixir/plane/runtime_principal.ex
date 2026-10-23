defmodule SymphonyElixir.Plane.RuntimePrincipal do
  @moduledoc """
  Verifies the authenticated Plane user and that user's effective project role
  and required permissions before Plane runtime authority is used.
  """

  alias SymphonyElixir.Plane.Client

  @max_permission_grants 128
  @runtime_api_key_env "PLANE_API_KEY_FERDI"
  @runtime_user_id "920272c2-862e-4592-b13e-b0ba11c91b12"

  @type policy :: %{
          required(:api_key_env) => String.t(),
          required(:user_id) => String.t(),
          required(:principal_kind) => String.t(),
          required(:project_relation) => String.t(),
          required(:required_permissions) => [String.t()]
        }

  @spec verify(Client.config(), policy(), keyword()) :: {:ok, map()} | {:error, term()}
  def verify(config, policy, opts)
      when is_map(config) and is_map(policy) and is_list(opts) do
    with :ok <- validate_policy(policy),
         {:ok, identity} <- Client.get_current_user(config, opts),
         {:ok, principal} <- validate_identity(identity, policy),
         {:ok, permissions} <- Client.get_project_permissions(config, opts),
         {:ok, authorization} <- validate_project_permissions(permissions, policy) do
      {:ok, Map.merge(principal, authorization)}
    end
  end

  def verify(_config, _policy, _opts), do: {:error, :invalid_runtime_principal_policy}

  defp validate_policy(%{
         api_key_env: @runtime_api_key_env,
         user_id: @runtime_user_id,
         principal_kind: "api_key",
         project_relation: "contributor",
         required_permissions: ["workitem:view", "workitem:edit"]
       }),
       do: :ok

  defp validate_policy(_policy), do: {:error, :invalid_runtime_principal_policy}

  defp validate_identity(identity, policy) when is_map(identity) do
    with {:ok, user_id} <- required_uuid(identity, :id),
         {:ok, principal_kind} <- required_string(identity, :principal_kind),
         :ok <- expected_user(user_id, policy.user_id),
         :ok <- expected_principal_kind(principal_kind, policy.principal_kind) do
      {:ok, %{user_id: user_id, principal_kind: principal_kind}}
    end
  end

  defp validate_identity(_identity, _policy), do: {:error, :provider_malformed}

  defp expected_user(expected, expected), do: :ok
  defp expected_user(_observed, _expected), do: {:error, :runtime_principal_identity_mismatch}

  defp expected_principal_kind(expected, expected), do: :ok

  defp expected_principal_kind(_observed, _expected),
    do: {:error, :runtime_principal_kind_mismatch}

  defp validate_project_permissions(permissions, policy) when is_map(permissions) do
    with {:ok, relation} <- required_relation(permissions),
         {:ok, grants} <- required_permission_grants(permissions),
         :ok <- expected_relation(relation, policy.project_relation),
         {:ok, present_required_permissions} <- required_permissions_present(grants, policy.required_permissions) do
      {:ok,
       %{
         project_relation: relation,
         required_permissions: present_required_permissions
       }}
    end
  end

  defp validate_project_permissions(_permissions, _policy), do: {:error, :provider_malformed}

  defp required_relation(permissions) do
    case value(permissions, :relation) do
      {:ok, relation} when is_binary(relation) and byte_size(relation) in 1..128 -> {:ok, relation}
      {:ok, nil} -> {:ok, nil}
      _ -> {:error, :provider_malformed}
    end
  end

  defp required_permission_grants(permissions) do
    case value(permissions, :permission_grants) do
      {:ok, grants} when is_list(grants) ->
        cond do
          not proper_bounded_string_list?(grants, @max_permission_grants) ->
            {:error, :provider_malformed}

          Enum.any?(grants, &(byte_size(&1) > 128)) ->
            {:error, :provider_malformed}

          true ->
            {:ok, grants}
        end

      _ ->
        {:error, :provider_malformed}
    end
  end

  defp expected_relation(expected, expected), do: :ok
  defp expected_relation(_observed, _expected), do: {:error, :runtime_project_relation_mismatch}

  defp required_permissions_present(grants, required) do
    present = Enum.filter(required, &(&1 in grants))
    missing = required -- present

    if missing == [] do
      {:ok, present}
    else
      {:error, {:runtime_permissions_missing, missing}}
    end
  end

  defp required_string(map, key) do
    case value(map, key) do
      {:ok, value} when is_binary(value) and byte_size(value) in 1..128 -> {:ok, value}
      _ -> {:error, :provider_malformed}
    end
  end

  defp required_uuid(map, key) do
    with {:ok, value} <- required_string(map, key),
         true <- String.match?(value, ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/) do
      {:ok, String.downcase(value)}
    else
      _ -> {:error, :provider_malformed}
    end
  end

  defp value(map, key) do
    case {Map.fetch(map, key), Map.fetch(map, Atom.to_string(key))} do
      {{:ok, _atom}, {:ok, _string}} -> :ambiguous
      {{:ok, value}, :error} -> {:ok, value}
      {:error, {:ok, value}} -> {:ok, value}
      {:error, :error} -> :missing
    end
  end

  defp proper_bounded_string_list?(list, limit), do: proper_bounded_string_list?(list, limit, 0)

  defp proper_bounded_string_list?([], _limit, _count), do: true
  defp proper_bounded_string_list?([value | _rest], limit, count) when count == limit and is_binary(value), do: false

  defp proper_bounded_string_list?([value | rest], limit, count) when is_binary(value),
    do: proper_bounded_string_list?(rest, limit, count + 1)

  defp proper_bounded_string_list?(_improper_or_invalid, _limit, _count), do: false
end
