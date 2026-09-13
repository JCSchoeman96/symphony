defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single tracker work item in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.{AgentRuntime, Config, PromptBuilder, Tracker, Workspace}
  alias SymphonyElixir.AgentRuntime.{Profile, Route, Router}
  alias SymphonyElixir.Tracker.Issue

  @type worker_host :: String.t() | nil

  @doc false
  @spec continue_with_issue_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:continue, Issue.t()} | {:done, Issue.t()} | {:error, term()}
  def continue_with_issue_for_test(%Issue{} = issue, issue_state_fetcher)
      when is_function(issue_state_fetcher, 1) do
    continue_with_issue?(issue, issue_state_fetcher)
  end

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    case route_from_options(issue, opts) do
      {:ok, route} ->
        opts = maybe_put_route(opts, route)

        Logger.info(
          "Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}" <>
            route_log_context(route)
        )

        case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
            raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
        end

      {:error, reason} ->
        Logger.error("Agent route resolution failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent route resolution failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
            run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host)
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp codex_message_handler(recipient, issue) do
    fn message ->
      send_codex_update(recipient, issue, message)
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    route = Keyword.get(opts, :route)
    max_turns = Keyword.get(opts, :max_turns, max_turns_for_route(route))
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issues_by_ids/1)
    runtime = Keyword.get(opts, :runtime, AgentRuntime.Codex)
    runtime_opts = opts |> Keyword.put(:worker_host, worker_host) |> profile_runtime_options(route)

    with {:ok, session} <- runtime.start_session(workspace, runtime_opts) do
      try do
        do_run_codex_turns(
          runtime,
          session,
          workspace,
          issue,
          codex_update_recipient,
          opts,
          issue_state_fetcher,
          1,
          max_turns,
          route
        )
      after
        runtime.stop_session(session)
      end
    end
  end

  defp do_run_codex_turns(
         runtime,
         app_session,
         workspace,
         issue,
         codex_update_recipient,
         opts,
         issue_state_fetcher,
         turn_number,
         max_turns,
         route
       ) do
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns)

    with {:ok, turn_session} <-
           runtime.run_turn(
             app_session,
             prompt,
             issue,
             Keyword.put(opts, :on_message, codex_message_handler(codex_update_recipient, issue))
           ) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

      case continue_with_issue_and_route(issue, issue_state_fetcher, route) do
        {:continue, refreshed_issue, refreshed_route} ->
          if route_changed?(route, refreshed_route) do
            notify_route_change(codex_update_recipient, refreshed_issue, route, refreshed_route)
            :ok
          else
            if turn_number < max_turns do
              Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

              do_run_codex_turns(
                runtime,
                app_session,
                workspace,
                refreshed_issue,
                codex_update_recipient,
                opts,
                issue_state_fetcher,
                turn_number + 1,
                max_turns,
                refreshed_route
              )
            else
              Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

              :ok
            end
          end

        {:done, _refreshed_issue} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp continue_with_issue_and_route(issue, issue_state_fetcher, nil) do
    case continue_with_issue?(issue, issue_state_fetcher) do
      {:continue, refreshed_issue} -> {:continue, refreshed_issue, nil}
      other -> other
    end
  end

  defp continue_with_issue_and_route(issue, issue_state_fetcher, %Route{}) do
    case continue_with_issue?(issue, issue_state_fetcher) do
      {:continue, %Issue{} = refreshed_issue} ->
        case Router.resolve(refreshed_issue, Config.settings!().agent.profiles) do
          {:ok, %Route{} = refreshed_route} ->
            {:continue, refreshed_issue, refreshed_route}

          {:error, reason} ->
            {:error, {:route_resolution_failed, reason}}
        end

      other ->
        other
    end
  end

  defp route_changed?(nil, nil), do: false
  defp route_changed?(%Route{} = left, %Route{} = right), do: not Route.same?(left, right)
  defp route_changed?(_left, _right), do: true

  defp notify_route_change(
         recipient,
         %Issue{id: issue_id},
         %Route{} = previous_route,
         %Route{} = next_route
       )
       when is_pid(recipient) and is_binary(issue_id) do
    send(recipient, {:agent_route_changed, issue_id, previous_route, next_route})
    :ok
  end

  defp notify_route_change(_recipient, _issue, _previous_route, _next_route), do: :ok

  defp max_turns_for_route(%Route{profile: %Profile{max_turns: max_turns}}), do: max_turns
  defp max_turns_for_route(_route), do: Config.settings!().agent.max_turns

  defp profile_runtime_options(opts, %Route{profile: %Profile{} = profile}) do
    Keyword.merge(opts, Profile.runtime_options(profile))
  end

  defp profile_runtime_options(opts, _route), do: opts

  defp route_from_options(_issue, opts) do
    case Keyword.get(opts, :route) do
      nil -> {:ok, nil}
      %Route{} = route -> {:ok, route}
      route -> {:error, {:invalid_route, route}}
    end
  end

  defp maybe_put_route(opts, nil), do: opts
  defp maybe_put_route(opts, %Route{} = route), do: Keyword.put(opts, :route, route)

  defp route_log_context(nil), do: ""

  defp route_log_context(%Route{} = route) do
    " profile=#{route.profile_name} runtime=#{route.runtime_name} responsibility=#{route.responsibility}"
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns), do: PromptBuilder.build_prompt(issue, opts)

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous Codex turn completed normally, but the tracker work item is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) and issue_routable?(refreshed_issue) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp issue_routable?(%Issue{} = issue) do
    Issue.routable?(issue, Config.settings!().tracker.required_labels)
  end

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
