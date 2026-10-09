defmodule SymphonyElixir.TransitionCoordinatorDefaultPathOrchestrator do
  @moduledoc false

  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def handle_call({:transition_context, _work_item_id, _opts}, _from, opts) do
    {:reply, Keyword.get(opts, :transition_context, :unavailable), opts}
  end

  def handle_call({:suspend_work_item, _work_item_id, _reason}, _from, opts) do
    {:reply, Keyword.get(opts, :suspend_result, :ok), opts}
  end

  def handle_call({:apply_transition_result, _work_item_id, work_item, _opts}, _from, opts) do
    if pid = Keyword.get(opts, :apply_recipient) do
      send(pid, {:applied, work_item})
    end

    {:reply, :ok, opts}
  end

  def handle_call(:request_refresh, _from, opts) do
    if pid = Keyword.get(opts, :refresh_recipient) do
      send(pid, :refresh_requested)
    end

    {:reply, :ok, opts}
  end

  def handle_call(_message, _from, opts), do: {:reply, :ok, opts}
end
