defmodule SymphonyElixir.AgentRuntime.Authority do
  @moduledoc """
  Pure authority checks for routed runtime lifecycle commands.
  """

  alias SymphonyElixir.AgentRuntime.{Profile, Route}
  alias SymphonyElixir.WorkControl.WorkflowLifecycle

  @responsibilities ["planning", "implementation", "review", "correction", "merge"]

  @allowed_commands %{
    "planning" => [{:planning, :ready}],
    "implementation" => [{:ready, :in_progress}, {:in_progress, :in_review}],
    "review" => [{:in_review, :changes_requested}, {:in_review, :ready_to_merge}],
    "correction" => [{:changes_requested, :in_review}],
    "merge" => []
  }

  @spec validate_profile(term()) :: :ok | {:error, map()}
  def validate_profile(%Profile{} = profile) do
    case profile_shape_reason(profile) do
      nil -> validate_effective_policy(profile)
      reason -> invalid_profile(reason)
    end
  end

  def validate_profile(_subject), do: invalid_profile(:not_a_profile)

  @spec authorize_lifecycle_command(term(), term(), term()) :: :ok | {:error, map()}
  def authorize_lifecycle_command(subject, source, target) do
    with :ok <- validate_route(subject),
         :ok <- validate_command(source, target) do
      authorize_command(subject.profile.responsibility, source, target)
    end
  end

  defp profile_shape_reason(%Profile{
         name: name,
         responsibility: responsibility,
         runtime: runtime,
         command: command,
         model: model,
         prompt: prompt,
         sandbox: sandbox,
         max_turns: max_turns,
         concurrency_class: concurrency_class
       }) do
    [
      {not nonempty_binary?(name), :malformed_profile},
      {not is_binary(responsibility), :malformed_profile},
      {is_binary(responsibility) and responsibility not in @responsibilities, :unsupported_responsibility},
      {not nonempty_binary?(runtime), :malformed_profile},
      {not optional_string?(command), :malformed_profile},
      {not optional_string?(model), :malformed_profile},
      {not optional_string?(prompt), :malformed_profile},
      {not nonempty_binary?(sandbox), :malformed_profile},
      {not positive_integer?(max_turns), :malformed_profile},
      {not optional_string?(concurrency_class), :malformed_profile}
    ]
    |> Enum.find_value(fn
      {true, reason} -> reason
      {false, _reason} -> false
    end)
  end

  defp profile_shape_reason(_subject), do: :malformed_profile

  defp nonempty_binary?(value), do: is_binary(value) and String.trim(value) != ""

  defp optional_string?(value), do: is_nil(value) or is_binary(value)

  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp validate_effective_policy(%Profile{} = profile) do
    case Profile.validate_effective_policy(profile) do
      :ok -> :ok
      {:error, message} -> invalid_profile(:effective_policy_invalid, message)
    end
  rescue
    _error -> invalid_profile(:effective_policy_invalid)
  end

  defp validate_route(%Route{} = route) do
    profile = Map.get(route, :profile)

    cond do
      is_nil(profile) -> invalid_subject(:missing_profile)
      not match?(%Profile{}, profile) -> invalid_subject(:invalid_profile)
      not valid_route_shape?(route) -> invalid_subject(:malformed_route)
      true -> validate_route_profile(route, profile)
    end
  end

  defp validate_route(_subject), do: invalid_subject(:not_a_route)

  defp valid_route_shape?(%Route{
         issue_id: issue_id,
         starting_state: starting_state,
         profile_name: profile_name,
         runtime_name: runtime_name,
         responsibility: responsibility,
         fingerprint: fingerprint
       }) do
    [
      nonempty_binary?(issue_id),
      canonical_state_string?(starting_state),
      nonempty_binary?(profile_name),
      nonempty_binary?(runtime_name),
      nonempty_binary?(responsibility),
      nonempty_binary?(fingerprint)
    ]
    |> Enum.all?(& &1)
  end

  defp valid_route_shape?(_subject), do: false

  defp canonical_state_string?(value),
    do: nonempty_binary?(value) and WorkflowLifecycle.canonical?(value)

  defp validate_route_profile(%Route{} = route, %Profile{} = profile) do
    with :ok <- validate_profile(profile),
         :ok <- compare_route_profile(route, profile) do
      validate_route_fingerprint(route)
    end
  end

  defp compare_route_profile(%Route{} = route, %Profile{} = profile) do
    if route.profile_name == profile.name and route.runtime_name == profile.runtime and
         route.responsibility == profile.responsibility do
      :ok
    else
      invalid_subject(:route_profile_mismatch)
    end
  end

  defp validate_route_fingerprint(%Route{} = route) do
    if route.fingerprint == Route.fingerprint(route) do
      :ok
    else
      invalid_subject(:route_fingerprint_mismatch)
    end
  end

  defp validate_command(source, target) when is_atom(source) and is_atom(target) do
    cond do
      is_nil(source) or is_nil(target) -> invalid_command(:malformed_command)
      not WorkflowLifecycle.canonical?(source) -> invalid_command(:unknown_state)
      not WorkflowLifecycle.canonical?(target) -> invalid_command(:unknown_state)
      true -> :ok
    end
  end

  defp validate_command(source, target) do
    cond do
      is_binary(source) and WorkflowLifecycle.canonical?(source) ->
        invalid_command(:noncanonical_state)

      is_binary(target) and WorkflowLifecycle.canonical?(target) ->
        invalid_command(:noncanonical_state)

      not is_atom(source) ->
        invalid_command(command_reason(source))

      not is_atom(target) ->
        invalid_command(command_reason(target))
    end
  end

  defp authorize_command(responsibility, source, target) do
    if {source, target} in Map.fetch!(@allowed_commands, responsibility) do
      :ok
    else
      {:error,
       %{
         code: :not_permitted,
         reason: :command_not_permitted,
         responsibility: responsibility,
         source: source,
         target: target,
         lifecycle_valid?: WorkflowLifecycle.valid_transition?(source, target)
       }}
    end
  end

  defp command_reason(value) when is_binary(value) do
    if WorkflowLifecycle.canonical?(value), do: :noncanonical_state, else: :unknown_state
  end

  defp command_reason(_value), do: :malformed_command

  defp invalid_profile(reason), do: {:error, %{code: :invalid_profile, reason: reason}}

  defp invalid_profile(reason, detail),
    do: {:error, %{code: :invalid_profile, reason: reason, detail: detail}}

  defp invalid_subject(reason), do: {:error, %{code: :invalid_subject, reason: reason}}

  defp invalid_command(reason), do: {:error, %{code: :invalid_command, reason: reason}}
end
