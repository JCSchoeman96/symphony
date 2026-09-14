defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{Config, Orchestrator, StatusDashboard, Workspace}

  @spec state_payload(GenServer.name(), timeout()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        payload = %{
          generated_at: generated_at,
          counts: %{
            running: length(snapshot.running),
            retrying: length(snapshot.retrying),
            blocked: length(Map.get(snapshot, :blocked, []))
          },
          running: Enum.map(snapshot.running, &running_entry_payload/1),
          retrying: Enum.map(snapshot.retrying, &retry_entry_payload/1),
          blocked: Enum.map(Map.get(snapshot, :blocked, []), &blocked_entry_payload/1),
          codex_totals: snapshot.codex_totals,
          rate_limits: Orchestrator.observability_rate_limits(snapshot.rate_limits)
        }

        payload
        |> put_when_present(:recent_attempts, recent_attempts_payload(Map.get(snapshot, :recent_attempts)))
        |> put_when_present(:dependency_diagnostics, dependency_diagnostics_payload(Map.get(snapshot, :dependency_diagnostics)))
        |> put_when_present(:dependency_graph, dependency_graph_payload(snapshot))

      :timeout ->
        %{generated_at: generated_at, error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      :unavailable ->
        %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  @spec issue_payload(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
        retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))
        blocked = Enum.find(Map.get(snapshot, :blocked, []), &(&1.identifier == issue_identifier))
        dependency = Enum.find(Map.get(snapshot, :dependency_diagnostics, []), &matches_issue?(&1, issue_identifier))

        recent_attempts =
          snapshot
          |> Map.get(:recent_attempts, [])
          |> Enum.filter(&matches_issue?(&1, issue_identifier))

        if is_nil(running) and is_nil(retry) and is_nil(blocked) and is_nil(dependency) do
          {:error, :issue_not_found}
        else
          {:ok, issue_payload_body(issue_identifier, running, retry, blocked, dependency, recent_attempts)}
        end

      _ ->
        {:error, :issue_not_found}
    end
  end

  @spec refresh_payload(GenServer.name()) :: {:ok, map()} | {:error, :unavailable}
  def refresh_payload(orchestrator) do
    case Orchestrator.request_refresh(orchestrator) do
      :unavailable ->
        {:error, :unavailable}

      payload ->
        {:ok, Map.update!(payload, :requested_at, &DateTime.to_iso8601/1)}
    end
  end

  defp issue_payload_body(issue_identifier, running, retry, blocked, dependency, recent_attempts) do
    attempts =
      %{
        restart_count: restart_count(retry),
        current_retry_attempt: retry_attempt(retry)
      }
      |> put_when_present(:counters, attempt_counters(issue_entry(running, retry, blocked)))

    payload = %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(running, retry, blocked, dependency),
      status: issue_status(running, retry, blocked, dependency),
      attempts: attempts,
      workspace: %{
        path: workspace_path(issue_identifier, running, retry, blocked),
        host: workspace_host(running, retry, blocked)
      },
      running: optional_running_payload(running),
      retry: optional_retry_payload(retry),
      blocked: optional_blocked_payload(blocked),
      logs: %{
        codex_session_logs: []
      },
      recent_events: recent_events_payload(recent_event_entry(running, blocked)),
      last_error: safe_error(issue_last_error(blocked, retry, dependency)),
      tracked: %{}
    }

    put_when_present(payload, :dependency, dependency_payload(dependency))
    |> put_when_present(:recent_attempts, recent_attempts_payload(recent_attempts))
    |> put_when_present(:status_reason, issue_status_reason(running, retry, blocked, dependency))
  end

  defp issue_entry(running, retry, blocked), do: running || retry || blocked

  defp optional_running_payload(nil), do: nil
  defp optional_running_payload(running), do: running_issue_payload(running)

  defp optional_retry_payload(nil), do: nil
  defp optional_retry_payload(retry), do: retry_issue_payload(retry)

  defp optional_blocked_payload(nil), do: nil
  defp optional_blocked_payload(blocked), do: blocked_issue_payload(blocked)

  defp recent_event_entry(running, _blocked) when not is_nil(running), do: running
  defp recent_event_entry(_running, blocked), do: blocked

  defp issue_last_error(blocked, retry, dependency) do
    blocked_error(blocked) || retry_error(retry) || dependency_error(dependency)
  end

  defp blocked_error(%{} = blocked), do: Map.get(blocked, :error)
  defp blocked_error(_blocked), do: nil

  defp retry_error(%{} = retry), do: Map.get(retry, :error)
  defp retry_error(_retry), do: nil

  defp issue_id_from_entries(running, retry, blocked, dependency),
    do:
      (running && running.issue_id) ||
        (retry && retry.issue_id) ||
        (blocked && blocked.issue_id) ||
        (dependency && dependency.issue_id)

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(running, _retry, _blocked, _dependency) when not is_nil(running), do: "running"
  defp issue_status(nil, retry, _blocked, _dependency) when not is_nil(retry), do: "retrying"
  defp issue_status(nil, nil, blocked, _dependency) when not is_nil(blocked), do: "blocked"

  defp issue_status(nil, nil, nil, dependency) when not is_nil(dependency) do
    if dependency_denied?(dependency), do: "dependency_blocked", else: "observed"
  end

  defp issue_status(nil, nil, nil, nil), do: "unknown"

  defp issue_status_reason(running, retry, blocked, dependency) do
    cond do
      running -> Orchestrator.observability_termination_reason(Map.get(running, :termination_reason))
      retry -> Orchestrator.observability_termination_reason(Map.get(retry, :termination_reason))
      blocked -> Orchestrator.observability_termination_reason(Map.get(blocked, :termination_reason))
      dependency_denied?(dependency) -> :dependency_blocked
      dependency -> :observed
      true -> nil
    end
  end

  defp running_entry_payload(entry) do
    payload = %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      issue_url: Map.get(entry, :issue_url),
      state: entry.state,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: entry.session_id,
      turn_count: Map.get(entry, :turn_count, 0),
      last_event: Orchestrator.observability_event(entry.last_codex_event),
      last_message: summarize_message(entry.last_codex_message),
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(entry.last_codex_timestamp),
      tokens: %{
        input_tokens: entry.codex_input_tokens,
        output_tokens: entry.codex_output_tokens,
        total_tokens: entry.codex_total_tokens
      }
    }

    payload
    |> put_observability_fields(entry)
    |> put_when_present(:profile_name, Map.get(entry, :profile_name))
    |> put_when_present(:runtime_name, Map.get(entry, :runtime_name))
    |> put_when_present(:responsibility, Map.get(entry, :responsibility))
    |> put_when_present(:route_fingerprint, Map.get(entry, :route_fingerprint))
    |> put_when_present(:dependency, dependency_payload(Map.get(entry, :dependency)))
    |> put_when_present(:route_change_termination, route_change_flag(entry))
    |> put_when_present(:route_change, Orchestrator.observability_route_change(Map.get(entry, :route_change)))
  end

  defp retry_entry_payload(entry) do
    payload = %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      issue_url: Map.get(entry, :issue_url),
      attempt: entry.attempt,
      due_at: due_at_iso8601(entry.due_in_ms),
      error: safe_error(entry.error),
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path)
    }

    payload
    |> put_observability_fields(entry)
    |> put_when_present(:profile_name, Map.get(entry, :profile_name))
    |> put_when_present(:runtime_name, Map.get(entry, :runtime_name))
    |> put_when_present(:responsibility, Map.get(entry, :responsibility))
    |> put_when_present(:route_fingerprint, Map.get(entry, :route_fingerprint))
    |> put_when_present(:route_change, Orchestrator.observability_route_change(Map.get(entry, :route_change)))
  end

  defp blocked_entry_payload(entry) do
    payload = %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      issue_url: Map.get(entry, :issue_url),
      state: entry.state,
      error: safe_error(entry.error),
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: entry.session_id,
      blocked_at: iso8601(entry.blocked_at),
      last_event: Orchestrator.observability_event(entry.last_codex_event),
      last_message: summarize_message(entry.last_codex_message),
      last_event_at: iso8601(entry.last_codex_timestamp)
    }

    payload
    |> put_observability_fields(entry)
    |> put_when_present(:profile_name, Map.get(entry, :profile_name))
    |> put_when_present(:runtime_name, Map.get(entry, :runtime_name))
    |> put_when_present(:responsibility, Map.get(entry, :responsibility))
    |> put_when_present(:dependency, dependency_payload(Map.get(entry, :dependency)))
  end

  defp running_issue_payload(running) do
    payload = %{
      worker_host: Map.get(running, :worker_host),
      workspace_path: Map.get(running, :workspace_path),
      session_id: running.session_id,
      turn_count: Map.get(running, :turn_count, 0),
      state: running.state,
      started_at: iso8601(running.started_at),
      last_event: Orchestrator.observability_event(running.last_codex_event),
      last_message: summarize_message(running.last_codex_message),
      last_event_at: iso8601(running.last_codex_timestamp),
      tokens: %{
        input_tokens: running.codex_input_tokens,
        output_tokens: running.codex_output_tokens,
        total_tokens: running.codex_total_tokens
      }
    }

    payload
    |> put_observability_fields(running)
    |> put_when_present(:profile_name, Map.get(running, :profile_name))
    |> put_when_present(:runtime_name, Map.get(running, :runtime_name))
    |> put_when_present(:responsibility, Map.get(running, :responsibility))
    |> put_when_present(:route_fingerprint, Map.get(running, :route_fingerprint))
    |> put_when_present(:dependency, dependency_payload(Map.get(running, :dependency)))
    |> put_when_present(:route_change_termination, route_change_flag(running))
    |> put_when_present(:route_change, Orchestrator.observability_route_change(Map.get(running, :route_change)))
  end

  defp retry_issue_payload(retry) do
    payload = %{
      attempt: retry.attempt,
      due_at: due_at_iso8601(retry.due_in_ms),
      error: safe_error(retry.error),
      worker_host: Map.get(retry, :worker_host),
      workspace_path: Map.get(retry, :workspace_path)
    }

    payload
    |> put_observability_fields(retry)
    |> put_when_present(:profile_name, Map.get(retry, :profile_name))
    |> put_when_present(:runtime_name, Map.get(retry, :runtime_name))
    |> put_when_present(:responsibility, Map.get(retry, :responsibility))
    |> put_when_present(:route_fingerprint, Map.get(retry, :route_fingerprint))
    |> put_when_present(:route_change, Orchestrator.observability_route_change(Map.get(retry, :route_change)))
  end

  defp blocked_issue_payload(blocked) do
    payload = %{
      worker_host: Map.get(blocked, :worker_host),
      workspace_path: Map.get(blocked, :workspace_path),
      session_id: blocked.session_id,
      state: blocked.state,
      error: safe_error(blocked.error),
      blocked_at: iso8601(blocked.blocked_at),
      last_event: Orchestrator.observability_event(blocked.last_codex_event),
      last_message: summarize_message(blocked.last_codex_message),
      last_event_at: iso8601(blocked.last_codex_timestamp)
    }

    payload
    |> put_observability_fields(blocked)
    |> put_when_present(:profile_name, Map.get(blocked, :profile_name))
    |> put_when_present(:runtime_name, Map.get(blocked, :runtime_name))
    |> put_when_present(:responsibility, Map.get(blocked, :responsibility))
    |> put_when_present(:dependency, dependency_payload(Map.get(blocked, :dependency)))
  end

  defp put_observability_fields(payload, entry) do
    payload
    |> put_when_present(:session_id, Map.get(entry, :session_id))
    |> put_when_present(:sandbox, Map.get(entry, :sandbox))
    |> put_when_present(:attempt_counters, attempt_counters(entry))
    |> put_when_present(:dependency_completeness, Orchestrator.observability_completeness(Map.get(entry, :dependency_completeness)))
    |> put_when_present(:termination_reason, Orchestrator.observability_termination_reason(Map.get(entry, :termination_reason)))
    |> put_when_present(:delay_type, Map.get(entry, :delay_type))
  end

  defp attempt_counters(entry) when is_map(entry) do
    case Map.get(entry, :attempt_counters) do
      counters when is_map(counters) ->
        counters
        |> Map.take([:ordinary_failures, :ordinary_retries, :review_cycles, :capacity_waits, :continuations, :route_changes])
        |> Enum.map(fn {key, value} -> {key, if(is_integer(value) and value >= 0, do: value, else: 0)} end)
        |> Map.new()

      _ ->
        nil
    end
  end

  defp attempt_counters(_entry), do: nil

  defp dependency_diagnostics_payload(diagnostics) when is_list(diagnostics) do
    Enum.map(diagnostics, &dependency_payload/1)
  end

  defp dependency_diagnostics_payload(_diagnostics), do: []

  defp dependency_graph_payload(snapshot) when is_map(snapshot) do
    case Map.fetch(snapshot, :dependency_graph) do
      {:ok, graph} -> Orchestrator.observability_graph(graph)
      :error -> nil
    end
  end

  defp recent_attempts_payload(attempts) when is_list(attempts) do
    attempts
    |> Enum.take(20)
    |> Enum.map(&recent_attempt_payload/1)
  end

  defp recent_attempts_payload(_attempts), do: []

  defp recent_attempt_payload(entry) when is_map(entry) do
    payload = %{
      issue_id: Map.get(entry, :issue_id),
      issue_identifier: Map.get(entry, :identifier),
      issue_url: Map.get(entry, :issue_url),
      attempt: Map.get(entry, :attempt, 0),
      error: safe_error(Map.get(entry, :error)),
      at: iso8601(Map.get(entry, :at))
    }

    payload
    |> put_observability_fields(entry)
    |> put_when_present(:profile_name, Map.get(entry, :profile_name))
    |> put_when_present(:runtime_name, Map.get(entry, :runtime_name))
    |> put_when_present(:responsibility, Map.get(entry, :responsibility))
    |> put_when_present(:route_fingerprint, Map.get(entry, :route_fingerprint))
    |> put_when_present(:worker_host, Map.get(entry, :worker_host))
    |> put_when_present(:workspace_path, Map.get(entry, :workspace_path))
    |> put_when_present(:dependency, dependency_payload(Map.get(entry, :dependency)))
  end

  defp recent_attempt_payload(_entry), do: %{termination_reason: :invalid_attempt}

  defp dependency_payload(nil), do: nil
  defp dependency_payload(%{} = dependency), do: Orchestrator.observability_dependency(dependency)
  defp dependency_payload(_dependency), do: nil

  defp dependency_error(%{allowed?: false, reason: reason}), do: safe_reason(reason) |> to_string()
  defp dependency_error(%{"allowed?" => false, "reason" => reason}), do: safe_reason(reason) |> to_string()
  defp dependency_error(_dependency), do: nil

  defp dependency_denied?(%{allowed?: false}), do: true
  defp dependency_denied?(%{"allowed?" => false}), do: true
  defp dependency_denied?(_dependency), do: false

  defp safe_error(value), do: Orchestrator.observability_error(value)

  defp safe_reason(reason) when is_atom(reason), do: reason
  defp safe_reason({kind, _detail}) when is_atom(kind), do: kind
  defp safe_reason(_reason), do: :redacted

  defp matches_issue?(entry, issue_identifier) when is_map(entry) do
    Map.get(entry, :identifier) == issue_identifier or Map.get(entry, "identifier") == issue_identifier or
      Map.get(entry, :issue_id) == issue_identifier or Map.get(entry, "issue_id") == issue_identifier
  end

  defp matches_issue?(_entry, _issue_identifier), do: false

  defp route_change_flag(entry) do
    case Map.get(entry, :route_change_termination) do
      true -> true
      _ -> nil
    end
  end

  defp put_when_present(payload, _key, nil), do: payload
  defp put_when_present(payload, _key, []), do: payload
  defp put_when_present(payload, _key, %{} = value) when map_size(value) == 0, do: payload
  defp put_when_present(payload, key, value), do: Map.put(payload, key, value)

  defp workspace_path(issue_identifier, running, retry, blocked) do
    (running && Map.get(running, :workspace_path)) ||
      (retry && Map.get(retry, :workspace_path)) ||
      (blocked && Map.get(blocked, :workspace_path)) ||
      Path.join(Config.settings!().workspace.root, Workspace.workspace_key(issue_identifier))
  end

  defp workspace_host(running, retry, blocked) do
    (running && Map.get(running, :worker_host)) ||
      (retry && Map.get(retry, :worker_host)) ||
      (blocked && Map.get(blocked, :worker_host))
  end

  defp recent_events_payload(nil), do: []

  defp recent_events_payload(entry) do
    [
      %{
        at: iso8601(entry.last_codex_timestamp),
        event: Orchestrator.observability_event(entry.last_codex_event),
        message: summarize_message(entry.last_codex_message)
      }
    ]
    |> Enum.reject(&is_nil(&1.at))
  end

  defp summarize_message(nil), do: nil

  defp summarize_message(message) do
    message = Orchestrator.observability_codex_message(message)

    if contains_redacted_marker?(message) do
      "codex event details redacted"
    else
      StatusDashboard.humanize_codex_message(message)
    end
  end

  defp contains_redacted_marker?(%DateTime{}), do: false

  defp contains_redacted_marker?(%{} = value) do
    Map.get(value, :redacted, false) == true or Map.get(value, "redacted", false) == true or
      Enum.any?(value, fn {_key, nested} -> contains_redacted_marker?(nested) end)
  end

  defp contains_redacted_marker?(value) when is_list(value),
    do: Enum.any?(value, &contains_redacted_marker?/1)

  defp contains_redacted_marker?(_value), do: false

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_due_in_ms), do: nil

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil
end
