defmodule SymphonyElixir.AgentRuntime.Codex do
  @moduledoc """
  Codex App Server implementation of the generic agent runtime contract.
  """

  @behaviour SymphonyElixir.AgentRuntime

  alias SymphonyElixir.AgentRuntime
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Tracker.Issue

  @spec capabilities() :: AgentRuntime.capabilities()
  def capabilities, do: [:streaming, :tool_calls]

  @spec runtime_metadata() :: AgentRuntime.runtime_metadata()
  def runtime_metadata, do: %{name: :codex}

  @spec start_session(Path.t(), keyword()) ::
          {:ok, AgentRuntime.session()} | {:error, AgentRuntime.start_error()}
  def start_session(workspace, opts \\ []) do
    case AppServer.start_session(workspace, opts) do
      {:ok, session} -> {:ok, {make_ref(), session}}
      {:error, reason} -> {:error, {:start_failed, reason}}
    end
  end

  @spec run_turn(AgentRuntime.session(), String.t(), Issue.t(), keyword()) ::
          {:ok, AgentRuntime.turn_result()} | {:error, AgentRuntime.turn_error()}
  def run_turn(session, prompt, issue, opts \\ []) do
    case session_state(session) do
      :not_started -> {:error, {:turn_failed, {:invalid_session, :not_started}}}
      :stopped -> {:error, {:turn_failed, {:session_not_active, :stopped}}}
      :active -> run_active_turn(session, prompt, issue, opts)
    end
  end

  @spec stop_session(AgentRuntime.session()) :: :ok | {:error, AgentRuntime.stop_error()}
  def stop_session(session) do
    case session_state(session) do
      :not_started -> {:error, {:invalid_session, :not_started}}
      :stopped -> {:error, {:session_not_active, :stopped}}
      :active -> stop_active_session(session)
    end
  end

  defp run_active_turn(session, prompt, issue, opts) do
    session = unwrap_session!(session)

    case AppServer.run_turn(session, prompt, issue, opts) do
      {:ok, _result} -> {:ok, :completed}
      {:error, reason} -> {:error, {:turn_failed, reason}}
    end
  end

  defp stop_active_session(session) do
    session = unwrap_session!(session)
    AppServer.stop_session(session)
  end

  defp unwrap_session!({reference, app_session}) when is_reference(reference), do: app_session

  defp session_state({reference, app_session}) when is_reference(reference) do
    session_state(app_session)
  end

  defp session_state(%{port: port} = session) when is_port(port) do
    if valid_session_shape?(session) do
      port_state(port)
    else
      :not_started
    end
  end

  defp session_state(_session), do: :not_started

  # port_info can retain metadata while a closed port is being deallocated.
  # A monitor reports its lifecycle rather than the presence of that metadata.
  defp port_state(port) do
    ref = :erlang.monitor(:port, port)

    try do
      receive do
        {:DOWN, ^ref, :port, ^port, _reason} -> :stopped
      after
        0 -> :active
      end
    after
      Process.demonitor(ref, [:flush])
    end
  end

  defp valid_session_shape?(session) do
    Enum.all?(
      [
        :metadata,
        :approval_policy,
        :auto_approve_requests,
        :turn_sandbox_policy,
        :thread_id,
        :workspace,
        :dynamic_tool_binding
      ],
      &Map.has_key?(session, &1)
    )
  end
end
