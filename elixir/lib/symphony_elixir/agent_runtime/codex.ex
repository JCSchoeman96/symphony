defmodule SymphonyElixir.AgentRuntime.Codex do
  @moduledoc """
  Codex App Server implementation of the generic agent runtime contract.
  """

  @behaviour SymphonyElixir.AgentRuntime

  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Tracker.Issue

  @spec start_session(Path.t(), keyword()) :: {:ok, AppServer.session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    AppServer.start_session(workspace, opts)
  end

  @spec run_turn(AppServer.session(), String.t(), Issue.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def run_turn(session, prompt, issue, opts \\ []) do
    AppServer.run_turn(session, prompt, issue, opts)
  end

  @spec stop_session(AppServer.session()) :: :ok
  def stop_session(session), do: AppServer.stop_session(session)
end
