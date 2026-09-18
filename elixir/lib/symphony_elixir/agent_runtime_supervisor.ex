defmodule SymphonyElixir.AgentRuntimeSupervisor do
  @moduledoc """
  Supervises the scheduler authority together with its agent tasks.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    task_supervisor_name =
      Keyword.get(opts, :task_supervisor_name, SymphonyElixir.TaskSupervisor)

    orchestrator_name = Keyword.get(opts, :orchestrator_name, SymphonyElixir.Orchestrator)

    transition_coordinator_name =
      Keyword.get_lazy(opts, :transition_coordinator_name, fn ->
        case Keyword.get(opts, :name, __MODULE__) do
          runtime_name when runtime_name == __MODULE__ -> SymphonyElixir.TransitionCoordinator
          runtime_name when is_atom(runtime_name) -> Module.concat(runtime_name, "TransitionCoordinator")
          _other -> SymphonyElixir.TransitionCoordinator
        end
      end)

    transition_coordinator_opts =
      opts
      |> Keyword.get(:transition_coordinator_opts, [])
      |> Keyword.merge(name: transition_coordinator_name, orchestrator: orchestrator_name)

    children = [
      Supervisor.child_spec(
        {Task.Supervisor, name: task_supervisor_name},
        id: task_supervisor_name
      ),
      Supervisor.child_spec(
        {SymphonyElixir.Orchestrator, name: orchestrator_name, task_supervisor: task_supervisor_name},
        id: orchestrator_name
      ),
      Supervisor.child_spec(
        {SymphonyElixir.TransitionCoordinator, transition_coordinator_opts},
        id: transition_coordinator_name
      )
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
