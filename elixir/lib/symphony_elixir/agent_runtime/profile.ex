defmodule SymphonyElixir.AgentRuntime.Profile do
  @moduledoc """
  Normalized configuration for one logical agent responsibility.
  """

  @enforce_keys [:name, :responsibility, :runtime, :command, :prompt, :sandbox, :max_turns]
  defstruct [
    :name,
    :responsibility,
    :runtime,
    :command,
    :model,
    :prompt,
    :sandbox,
    :max_turns,
    :concurrency_class
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          responsibility: String.t(),
          runtime: String.t(),
          command: String.t() | nil,
          model: String.t() | nil,
          prompt: String.t() | nil,
          sandbox: String.t(),
          max_turns: pos_integer(),
          concurrency_class: String.t() | nil
        }

  @responsibilities ~w(planning implementation review correction merge)
  @runtimes ~w(codex deferred)
  @sandboxes ~w(read-only workspace-write)

  @spec default_profiles(String.t(), pos_integer()) :: %{String.t() => t()}
  def default_profiles(command, max_turns) when is_binary(command) and is_integer(max_turns) do
    [
      {"planner", "planning", "codex", "read-only", "planner"},
      {"builder", "implementation", "codex", "workspace-write", "builder"},
      {"reviewer", "review", "codex", "read-only", "reviewer"},
      {"fixer", "correction", "codex", "workspace-write", "fixer"},
      {"merge_gatekeeper", "merge", "deferred", "read-only", nil}
    ]
    |> Map.new(fn {name, responsibility, runtime, sandbox, prompt} ->
      {name,
       %__MODULE__{
         name: name,
         responsibility: responsibility,
         runtime: runtime,
         command: if(runtime == "codex", do: command, else: nil),
         model: nil,
         prompt: prompt,
         sandbox: sandbox,
         max_turns: max_turns,
         concurrency_class: nil
       }}
    end)
  end

  @spec resolve_profiles(map() | nil, String.t(), pos_integer()) ::
          {:ok, %{String.t() => t()}} | {:error, term()}
  def resolve_profiles(raw_profiles, command, max_turns)
      when (is_map(raw_profiles) or is_nil(raw_profiles)) and is_binary(command) and
             is_integer(max_turns) do
    defaults = default_profiles(command, max_turns)
    raw_profiles = raw_profiles || %{}

    Enum.reduce_while(raw_profiles, {:ok, defaults}, fn {raw_name, raw_profile}, {:ok, profiles} ->
      name = normalize_name(raw_name)

      case Map.fetch(defaults, name) do
        {:ok, default} ->
          case normalize_profile(name, raw_profile, default) do
            {:ok, profile} -> {:cont, {:ok, Map.put(profiles, name, profile)}}
            {:error, message} -> {:halt, {:error, {:invalid_profile, name, message}}}
          end

        :error ->
          case normalize_custom_profile(name, raw_profile, command, max_turns) do
            {:ok, profile} -> {:cont, {:ok, Map.put(profiles, name, profile)}}
            {:error, message} -> {:halt, {:error, {:invalid_profile, name, message}}}
          end
      end
    end)
  end

  @spec runtime_options(t()) :: keyword()
  def runtime_options(%__MODULE__{} = profile) do
    [
      profile: profile,
      command: profile.command,
      model: profile.model,
      sandbox: profile.sandbox
    ]
  end

  @spec normalize_name(term()) :: String.t()
  def normalize_name(name) do
    name
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/\s+/, "_")
  end

  @spec responsibility?(term()) :: boolean()
  def responsibility?(responsibility), do: normalize_token(responsibility) in @responsibilities

  @spec runtime?(term()) :: boolean()
  def runtime?(runtime), do: normalize_token(runtime) in @runtimes

  @spec sandbox?(term()) :: boolean()
  def sandbox?(sandbox), do: normalize_token(sandbox) in @sandboxes

  defp normalize_profile(name, %__MODULE__{} = profile, _default) do
    if profile.name == name do
      {:ok, profile}
    else
      {:error, "name must match profile key"}
    end
  end

  defp normalize_profile(name, raw_profile, default) when is_map(raw_profile) do
    attrs = normalize_keys(raw_profile)

    with {:ok, responsibility} <- required_token(attrs, "responsibility", default.responsibility, @responsibilities),
         {:ok, runtime} <- required_token(attrs, "runtime", default.runtime, @runtimes),
         {:ok, command} <- command_value(attrs, default.command, runtime),
         {:ok, model} <- optional_string(attrs, "model"),
         {:ok, prompt} <- optional_string(attrs, "prompt", default.prompt),
         {:ok, sandbox} <- required_token(attrs, "sandbox", default.sandbox, @sandboxes),
         {:ok, max_turns} <- positive_integer(attrs, "max_turns", default.max_turns),
         {:ok, concurrency_class} <- optional_string(attrs, "concurrency_class") do
      {:ok,
       %__MODULE__{
         name: name,
         responsibility: responsibility,
         runtime: runtime,
         command: command,
         model: model,
         prompt: prompt,
         sandbox: sandbox,
         max_turns: max_turns,
         concurrency_class: concurrency_class
       }}
    end
  end

  defp normalize_profile(_name, _raw_profile, _default), do: {:error, "must be a map"}

  defp normalize_custom_profile(name, raw_profile, command, max_turns) when is_map(raw_profile) do
    attrs = normalize_keys(raw_profile)

    with {:ok, responsibility} <- required_token(attrs, "responsibility", nil, @responsibilities),
         {:ok, runtime} <- required_token(attrs, "runtime", "codex", @runtimes),
         {:ok, profile_command} <- command_value(attrs, command, runtime),
         {:ok, model} <- optional_string(attrs, "model"),
         {:ok, prompt} <- optional_string(attrs, "prompt", name),
         {:ok, sandbox} <- required_token(attrs, "sandbox", "workspace-write", @sandboxes),
         {:ok, profile_max_turns} <- positive_integer(attrs, "max_turns", max_turns),
         {:ok, concurrency_class} <- optional_string(attrs, "concurrency_class") do
      {:ok,
       %__MODULE__{
         name: name,
         responsibility: responsibility,
         runtime: runtime,
         command: profile_command,
         model: model,
         prompt: prompt,
         sandbox: sandbox,
         max_turns: profile_max_turns,
         concurrency_class: concurrency_class
       }}
    end
  end

  defp normalize_custom_profile(_name, _raw_profile, _command, _max_turns),
    do: {:error, "must be a map"}

  defp required_token(attrs, key, default, allowed) do
    value = Map.get(attrs, key, default)

    case normalize_token(value) do
      normalized ->
        if Enum.member?(allowed, normalized) do
          {:ok, normalized}
        else
          {:error, "#{key} must be one of #{Enum.join(allowed, ", ")}"}
        end
    end
  end

  defp command_value(attrs, default, "deferred") do
    case Map.get(attrs, "command", default) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        if String.trim(value) == "" do
          {:error, "command must be a non-empty string for an executable profile"}
        else
          {:ok, value}
        end

      _ ->
        {:error, "command must be a non-empty string for an executable profile"}
    end
  end

  defp command_value(attrs, default, _runtime) do
    case Map.get(attrs, "command", default) do
      value when is_binary(value) ->
        if String.trim(value) == "" do
          {:error, "command must be a non-empty string"}
        else
          {:ok, value}
        end

      _ ->
        {:error, "command must be a non-empty string"}
    end
  end

  defp optional_string(attrs, key, default \\ nil) do
    case Map.get(attrs, key, default) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        if String.trim(value) == "", do: {:error, "#{key} must not be blank"}, else: {:ok, value}

      _ ->
        {:error, "#{key} must be a string"}
    end
  end

  defp positive_integer(attrs, key, default) do
    case Map.get(attrs, key, default) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _ -> {:error, "#{key} must be a positive integer"}
    end
  end

  defp normalize_keys(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), normalize_keys(nested)} end)
  end

  defp normalize_keys(value), do: value

  defp normalize_token(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/\s+/, "-")
  end

  defp normalize_token(_value), do: ""
end
