defmodule SymphonyElixir.SourceControl.AgentTool do
  @moduledoc """
  Narrow reviewer-only semantic source-control read tool.
  """

  alias SymphonyElixir.AgentRuntime.Authority
  alias SymphonyElixir.SourceControl

  @tool_name "source_control_read_current_candidate_status"

  @empty_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "properties" => %{}
  }

  @spec tool_name() :: String.t()
  def tool_name, do: @tool_name

  @spec agent_tool_specs() :: [map()]
  def agent_tool_specs do
    [
      %{
        "name" => @tool_name,
        "description" => "Read-only host-scoped candidate and CI verification status for the current work item.",
        "inputSchema" => @empty_input_schema
      }
    ]
  end

  @spec agent_tool_specs(map()) :: [map()]
  def agent_tool_specs(%{responsibility: "review"}), do: agent_tool_specs()
  def agent_tool_specs(_context), do: []

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(@tool_name, arguments, opts) when is_list(opts) do
    with :ok <- validate_empty_arguments(arguments),
         :ok <- authorize_read(opts),
         host_context <- host_context(opts) do
      success_response(SourceControl.read_current_candidate_status(host_context, source_control_opts(opts)))
    else
      {:error, :unauthorized} -> failure_response("Source-control read is not authorized for this runtime.")
      {:error, :invalid_arguments} -> failure_response("Source-control read accepts no arguments.")
      {:error, reason} -> failure_response("Source-control read failed: #{inspect(reason)}")
    end
  end

  def execute(_tool, _arguments, _opts), do: failure_response("Unsupported source-control tool.")

  defp authorize_read(opts) do
    case Keyword.get(opts, :agent_tool_context) do
      %{route: route, responsibility: "review"} ->
        Authority.authorize_source_control_operation(route, :read_current_candidate_status)

      _ ->
        {:error, :unauthorized}
    end
  end

  defp host_context(opts) do
    case Keyword.get(opts, :agent_tool_context) do
      context when is_map(context) -> context
      _ -> %{}
    end
  end

  defp source_control_opts(opts) do
    Keyword.get(opts, :source_control_opts, [])
  end

  defp validate_empty_arguments(arguments) when arguments in [nil, %{}, []], do: :ok

  defp validate_empty_arguments(arguments) when is_map(arguments) do
    if map_size(arguments) == 0, do: :ok, else: {:error, :invalid_arguments}
  end

  defp validate_empty_arguments(_arguments), do: {:error, :invalid_arguments}

  defp success_response(payload) do
    %{
      "success" => true,
      "output" => Jason.encode!(payload),
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => Jason.encode!(payload)
        }
      ]
    }
  end

  defp failure_response(message) do
    payload = %{"error" => %{"message" => message}}

    %{
      "success" => false,
      "output" => Jason.encode!(payload),
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => Jason.encode!(payload)
        }
      ]
    }
  end
end
