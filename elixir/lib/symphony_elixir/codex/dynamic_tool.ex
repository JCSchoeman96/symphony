defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Dispatches client-side tool calls to tracker and source-control semantic tools.
  """

  alias SymphonyElixir.SourceControl.AgentTool, as: SourceControlAgentTool
  alias SymphonyElixir.Tracker

  @spec execute(String.t() | nil, term(), map(), keyword()) :: map()
  def execute(tool, arguments, binding, opts \\ []) do
    if source_control_tool?(tool) do
      SourceControlAgentTool.execute(tool, arguments, source_control_opts(binding, opts))
    else
      Tracker.execute_bound_agent_tool(binding, tool, arguments, opts)
    end
  end

  @spec bind(keyword()) :: map()
  def bind(opts \\ []) do
    tracker_binding = Tracker.bind_agent_tools(opts)

    tracker_binding
    |> Map.put(:tool_specs, tracker_binding.tool_specs ++ source_control_tool_specs(opts))
    |> Map.put(
      :secret_environment_names,
      Enum.uniq(tracker_binding.secret_environment_names ++ SymphonyElixir.SourceControl.secret_environment_names())
    )
  end

  defp source_control_tool_specs(opts) do
    case Keyword.get(opts, :agent_tool_context) do
      context when is_map(context) -> SourceControlAgentTool.agent_tool_specs(context)
      _ -> []
    end
  end

  defp source_control_tool?(tool) do
    tool == SourceControlAgentTool.tool_name()
  end

  defp source_control_opts(binding, opts) do
    opts
    |> Keyword.put(:agent_tool_context, Map.get(binding, :agent_tool_context, %{}))
    |> Keyword.put(:source_control_opts, Map.get(binding, :source_control_opts, []))
  end
end
