defmodule SymphonyElixir.AgentRuntime.RuntimeIsolation do
  @moduledoc """
  Serializes and caches real Codex isolation verification by runtime fingerprint.
  """

  use GenServer

  alias SymphonyElixir.Codex.IsolationProfile

  @type evidence :: %{
          status: :verifying | :verified | :failed | :stale,
          fingerprint: String.t(),
          executable: Path.t(),
          version: String.t(),
          platform: term(),
          result: term()
        }

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name)

    if is_atom(name) do
      GenServer.start_link(__MODULE__, opts, name: name)
    else
      GenServer.start_link(__MODULE__, opts)
    end
  end

  @spec admit(String.t() | nil, Path.t(), keyword()) ::
          {:ok, evidence()} | {:error, term()}
  def admit(worker_host, _executable, _opts) when is_binary(worker_host) do
    {:error, {:runtime_isolation_unavailable, :remote_containment_unproven}}
  end

  def admit(nil, executable, opts) do
    case admission_server(opts) do
      {:ok, server} -> verify(executable, Keyword.put(opts, :server, server))
      :error -> {:error, {:runtime_isolation_unavailable, :verifier_unavailable}}
    end
  end

  @spec verify(Path.t(), keyword()) :: {:ok, evidence()} | {:error, term()}
  def verify(executable, opts \\ []) when is_binary(executable) do
    server = Keyword.get(opts, :server, __MODULE__)

    with {:ok, identity} <- IsolationProfile.runtime_identity(executable),
         {:ok, server} <- ensure_server(server) do
      try do
        GenServer.call(server, {:verify, identity}, :infinity)
      catch
        :exit, _reason -> {:error, {:runtime_isolation_unavailable, :verifier_unavailable}}
      end
    end
  end

  @spec evidence(Path.t(), keyword()) :: evidence() | nil | {:error, term()}
  def evidence(executable, opts \\ []) when is_binary(executable) do
    server = Keyword.get(opts, :server, __MODULE__)

    with {:ok, identity} <- IsolationProfile.runtime_identity(executable),
         {:ok, server} <- ensure_server(server) do
      GenServer.call(server, {:evidence, fingerprint(identity)})
    end
  end

  @spec clear(keyword()) :: :ok
  def clear(opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)

    with {:ok, server} <- ensure_server(server) do
      GenServer.call(server, :clear)
    end
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       records: %{},
       current_by_path: %{},
       probe: Keyword.get(opts, :probe, &default_probe/1)
     }}
  end

  @impl true
  def handle_call({:verify, identity}, _from, state) do
    fingerprint = fingerprint(identity)
    path = identity.executable

    state = mark_previous_fingerprint_stale(state, path, fingerprint)

    case Map.get(state.records, fingerprint) do
      %{status: :verified} = evidence ->
        {:reply, {:ok, evidence}, state}

      %{status: :failed, result: reason} ->
        {:reply, {:error, {:runtime_isolation_failed, reason}}, state}

      _missing_or_stale ->
        verifying = base_evidence(identity, fingerprint, :verifying, :verifying)
        state = %{state | records: Map.put(state.records, fingerprint, verifying)}
        result = run_probe(state.probe, identity)
        evidence = build_evidence(identity, fingerprint, result)

        next_state = %{
          state
          | records: Map.put(state.records, fingerprint, evidence),
            current_by_path: Map.put(state.current_by_path, path, fingerprint)
        }

        case evidence.status do
          :verified -> {:reply, {:ok, evidence}, next_state}
          :failed -> {:reply, {:error, {:runtime_isolation_failed, evidence.result}}, next_state}
        end
    end
  end

  def handle_call({:evidence, fingerprint}, _from, state) do
    {:reply, Map.get(state.records, fingerprint), state}
  end

  def handle_call(:clear, _from, state) do
    {:reply, :ok, %{state | records: %{}, current_by_path: %{}}}
  end

  defp ensure_server(server) when is_pid(server), do: {:ok, server}

  defp ensure_server(server) when is_atom(server) do
    case Process.whereis(server) do
      pid when is_pid(pid) ->
        {:ok, pid}

      nil ->
        case GenServer.start(__MODULE__, [], name: server) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, {:runtime_isolation_unavailable, {:verifier_start_failed, reason}}}
        end
    end
  end

  defp registered_server(server) when is_pid(server) do
    if Process.alive?(server), do: {:ok, server}, else: :error
  end

  defp registered_server(server) when is_atom(server) do
    case Process.whereis(server) do
      pid when is_pid(pid) -> {:ok, pid}
      nil -> :error
    end
  end

  defp registered_server(_server), do: :error

  defp admission_server(opts) do
    if test_environment?() and Keyword.has_key?(opts, :server) do
      registered_server(Keyword.get(opts, :server))
    else
      supervised_server()
    end
  end

  defp supervised_server do
    with supervisor when is_pid(supervisor) <- Process.whereis(SymphonyElixir.Supervisor),
         {__MODULE__, child_pid, _type, _modules} <-
           Enum.find(Supervisor.which_children(supervisor), fn
             {__MODULE__, pid, _type, _modules} when is_pid(pid) -> true
             _child -> false
           end),
         ^child_pid <- Process.whereis(__MODULE__) do
      {:ok, child_pid}
    else
      _ -> :error
    end
  catch
    :exit, _reason -> :error
  end

  defp test_environment? do
    Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) and Mix.env() == :test
  rescue
    _reason -> false
  end

  defp mark_previous_fingerprint_stale(state, path, fingerprint) do
    case Map.get(state.current_by_path, path) do
      nil ->
        state

      ^fingerprint ->
        state

      previous_fingerprint ->
        records =
          case Map.get(state.records, previous_fingerprint) do
            nil -> state.records
            previous -> Map.put(state.records, previous_fingerprint, %{previous | status: :stale})
          end

        %{state | records: records}
    end
  end

  defp run_probe(probe, identity) when is_function(probe, 1) do
    case probe.(identity) do
      :ok -> :ok
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, safe_reason(reason)}
      _other -> {:error, :invalid_probe_result}
    end
  rescue
    _error -> {:error, :probe_raised}
  catch
    _kind, _reason -> {:error, :probe_failed}
  end

  defp default_probe(identity) do
    IsolationProfile.run_actual_probe(identity.executable, identity.native_executable)
  end

  defp build_evidence(identity, fingerprint, :ok) do
    base_evidence(identity, fingerprint, :verified, :verified)
  end

  defp build_evidence(identity, fingerprint, {:ok, result}) do
    base_evidence(identity, fingerprint, :verified, sanitize_probe_result(result))
  end

  defp build_evidence(identity, fingerprint, {:error, reason}) do
    base_evidence(identity, fingerprint, :failed, safe_reason(reason))
  end

  defp base_evidence(identity, fingerprint, status, result) do
    %{
      status: status,
      fingerprint: fingerprint,
      executable: identity.executable,
      version: identity.version,
      platform: identity.platform,
      result: result
    }
  end

  defp sanitize_probe_result(result) when is_map(result) do
    Map.take(result, [:read_only, :reviewer_read, :workspace_write, :fixer_write, :platform])
  end

  defp sanitize_probe_result(_result), do: :verified

  defp safe_reason(reason) when is_atom(reason), do: reason

  defp safe_reason({tag, detail}) when is_atom(tag) and is_atom(detail), do: {tag, detail}

  defp safe_reason({tag, access, result, process_mismatch})
       when is_atom(tag) and is_atom(access) and is_map(result) and is_boolean(process_mismatch),
       do: {tag, access, result, process_mismatch}

  defp safe_reason(_reason), do: :probe_failed

  defp fingerprint(identity) do
    identity
    |> Map.take([
      :executable,
      :native_executable,
      :size,
      :mtime,
      :inode,
      :digest,
      :native_size,
      :native_mtime,
      :native_inode,
      :native_digest,
      :version,
      :platform
    ])
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
