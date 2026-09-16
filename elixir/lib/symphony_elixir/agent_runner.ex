defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single tracker work item in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.{AgentRuntime, Config, PromptBuilder, Tracker, Workspace}
  alias SymphonyElixir.AgentRuntime.{Profile, Route, Router}
  alias SymphonyElixir.Dependency.Guard
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.WorkControl.{LifecycleAssessment, WorkflowLifecycle, WorkItem}

  @type worker_host :: String.t() | nil

  @doc false
  @spec continue_with_issue_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:continue, Issue.t()} | {:done, Issue.t()} | {:error, term()}
  def continue_with_issue_for_test(%Issue{} = issue, issue_state_fetcher)
      when is_function(issue_state_fetcher, 1) do
    continue_with_issue?(issue, issue_state_fetcher)
  end

  @doc false
  @spec continuation_prompt_for_test(Issue.t(), Route.t(), pos_integer(), pos_integer()) ::
          String.t()
  def continuation_prompt_for_test(%Issue{} = issue, %Route{} = route, turn_number, max_turns)
      when is_integer(turn_number) and is_integer(max_turns) do
    build_turn_prompt(issue, [route: route], turn_number, max_turns)
  end

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host =
      selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    case route_from_options(issue, opts) do
      {:ok, route} ->
        run_with_route(issue, codex_update_recipient, opts, worker_host, route)

      {:error, reason} ->
        Logger.error("Agent route resolution failed for #{issue_context(issue)}: #{inspect(reason)}")

        raise RuntimeError,
              "Agent route resolution failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_with_route(issue, codex_update_recipient, opts, worker_host, route) do
    case validate_routed_attempt(route, opts) do
      :ok ->
        run_validated_attempt(issue, codex_update_recipient, opts, worker_host, route)

      {:error, reason} ->
        Logger.error("Agent route authority validation failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent route authority validation failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_validated_attempt(issue, codex_update_recipient, opts, worker_host, route) do
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
    max_turns = max_turns_for_run(route, opts)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issues_by_ids/1)
    runtime = Keyword.get(opts, :runtime, AgentRuntime.Codex)

    runtime_opts =
      opts
      |> Keyword.put(:worker_host, worker_host)
      |> profile_runtime_options(route)
      |> Keyword.put(:agent_tool_context, agent_tool_context(issue, route, opts))

    role_prompt = PromptBuilder.role_prompt(route)

    with {:ok, session} <- runtime.start_session(workspace, runtime_opts) do
      context = %{
        runtime: runtime,
        session: session,
        workspace: workspace,
        issue: issue,
        codex_update_recipient: codex_update_recipient,
        opts: runtime_opts,
        issue_state_fetcher: issue_state_fetcher,
        route: route,
        role_prompt: role_prompt,
        work_item: Keyword.get(opts, :work_item)
      }

      run_runtime_session(runtime, session, fn ->
        do_run_codex_turns(context, 1, max_turns)
      end)
    end
  end

  defp do_run_codex_turns(context, turn_number, max_turns) do
    prompt_opts = Keyword.put(context.opts, :role_prompt, context.role_prompt)
    prompt = build_turn_prompt(context.issue, prompt_opts, turn_number, max_turns)

    with {:ok, _turn_result} <-
           context.runtime.run_turn(
             context.session,
             prompt,
             context.issue,
             Keyword.put(
               context.opts,
               :on_message,
               codex_message_handler(context.codex_update_recipient, context.issue)
             )
           ) do
      Logger.info(
        "Completed agent run for #{issue_context(context.issue)} " <>
          "workspace=#{context.workspace} turn=#{turn_number}/#{max_turns}"
      )

      case continue_with_issue_and_route(
             context.issue,
             context.issue_state_fetcher,
             context.route,
             context.work_item,
             context.opts
           ) do
        {:continue, refreshed_issue, refreshed_route, refreshed_work_item} ->
          continue_after_turn(
            context,
            refreshed_issue,
            refreshed_route,
            refreshed_work_item,
            turn_number,
            max_turns
          )

        {:continue, refreshed_issue, refreshed_route} ->
          continue_after_turn(
            context,
            refreshed_issue,
            refreshed_route,
            nil,
            turn_number,
            max_turns
          )

        {:done, _refreshed_issue} ->
          :ok

        {:suspended, refreshed_issue, assessment} ->
          notify_lifecycle_suspended(
            context.codex_update_recipient,
            refreshed_issue,
            assessment
          )

          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp run_runtime_session(runtime, session, fun) when is_function(fun, 0) do
    execution_result =
      try do
        {:returned, fun.()}
      catch
        kind, reason -> {:raised, kind, reason, __STACKTRACE__}
      end

    case stop_runtime_session(runtime, session) do
      :ok ->
        restore_execution_result(execution_result)

      {:error, {:session_not_active, :stopped}} ->
        restore_execution_result(execution_result)

      {:error, reason} ->
        {:error, {:runtime_stop_failed, reason}}
    end
  end

  defp stop_runtime_session(runtime, session) do
    case runtime.stop_session(session) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_result, other}}
    end
  rescue
    exception -> {:error, {:exception, exception}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp restore_execution_result({:returned, result}), do: result

  defp restore_execution_result({:raised, kind, reason, stacktrace}) do
    :erlang.raise(kind, reason, stacktrace)
  end

  defp continue_after_turn(
         context,
         refreshed_issue,
         refreshed_route,
         refreshed_work_item,
         turn_number,
         max_turns
       ) do
    decision = dependency_decision(refreshed_issue, refreshed_route, context.opts)

    cond do
      decision.allowed? != true ->
        notify_dependency_blocked(context.codex_update_recipient, refreshed_issue, decision)
        :ok

      route_changed?(context.route, refreshed_route) ->
        notify_route_change(
          context.codex_update_recipient,
          refreshed_issue,
          context.route,
          refreshed_route
        )

        :ok

      turn_number >= max_turns ->
        Logger.info(
          "Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; " <>
            "returning control to orchestrator"
        )

        :ok

      true ->
        Logger.info(
          "Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion " <>
            "turn=#{turn_number}/#{max_turns}"
        )

        next_opts =
          context.opts
          |> maybe_put_work_item(refreshed_work_item)
          |> Keyword.put(
            :agent_tool_context,
            agent_tool_context(refreshed_issue, refreshed_route, context.opts)
          )

        next_context = %{
          context
          | issue: refreshed_issue,
            route: refreshed_route,
            opts: next_opts,
            work_item: refreshed_work_item
        }

        do_run_codex_turns(next_context, turn_number + 1, max_turns)
    end
  end

  defp continue_with_issue_and_route(issue, issue_state_fetcher, nil, _work_item, _opts) do
    case continue_with_issue?(issue, issue_state_fetcher) do
      {:continue, refreshed_issue} -> {:continue, refreshed_issue, nil}
      other -> other
    end
  end

  defp continue_with_issue_and_route(
         issue,
         issue_state_fetcher,
         %Route{} = route,
         work_item,
         opts
       ) do
    refreshed_result =
      if Config.settings!().agent.routing == "legacy" do
        continue_with_issue?(issue, issue_state_fetcher)
      else
        continue_with_routed_issue?(issue, issue_state_fetcher)
      end

    case refreshed_result do
      {:continue, %Issue{} = refreshed_issue} ->
        if Config.settings!().agent.routing == "legacy" do
          {:continue, refreshed_issue, Route.legacy(refreshed_issue)}
        else
          assess_routed_continuation(
            refreshed_issue,
            route,
            work_item,
            Keyword.get(opts, :guard_evidence, [])
          )
        end

      {:done, _refreshed_issue} = done ->
        done

      other ->
        other
    end
  end

  defp assess_routed_continuation(
         %Issue{} = issue,
         %Route{} = route,
         %WorkItem{} = prior_work_item,
         evidence
       ) do
    opts = %{
      provider: Config.settings!().tracker.kind,
      observed_at: issue.updated_at || DateTime.utc_now(),
      prior_validated_lifecycle_state: prior_work_item.validated_lifecycle_state,
      prior_authority_disposition: prior_work_item.authority_disposition,
      evidence: evidence_for_observation(issue, prior_work_item, evidence)
    }

    case WorkItem.from_issue(issue, opts) do
      {:ok, %WorkItem{} = work_item} ->
        case routed_continuation_route(work_item, prior_work_item, route) do
          {:ok, %Route{} = next_route} ->
            {:continue, issue, next_route, work_item}

          :error ->
            {:suspended, issue, work_item.lifecycle_assessment}
        end

      {:error, _reason} ->
        {:suspended, issue, nil}
    end
  end

  defp assess_routed_continuation(%Issue{} = issue, _route, _work_item, _evidence),
    do: {:suspended, issue, nil}

  defp routed_continuation_route(
         %WorkItem{} = work_item,
         %WorkItem{} = prior_work_item,
         %Route{} = current_route
       ) do
    cond do
      not LifecycleAssessment.validated?(work_item.lifecycle_assessment) ->
        :error

      not WorkItem.authority_available?(work_item) ->
        :error

      current_route.responsibility !=
          WorkflowLifecycle.responsibility(prior_work_item.validated_lifecycle_state) ->
        :error

      true ->
        settings = Config.settings!()

        case Router.resolve(work_item, settings.agent.profiles, settings.agent.routes) do
          {:ok, %Route{} = next_route} -> {:ok, next_route}
          {:error, _reason} -> :error
        end
    end
  end

  defp evidence_for_observation(
         %Issue{state: state},
         %WorkItem{
           validated_lifecycle_state: validated_state,
           lifecycle_assessment: assessment
         },
         evidence
       ) do
    evidence_for_observation(state, validated_state, assessment.satisfied_guards, evidence)
  end

  defp evidence_for_observation(state, validated_state, prior_evidence, forward_evidence) do
    case WorkflowLifecycle.parse(state) do
      {:ok, ^validated_state} -> prior_evidence
      _ -> forward_evidence
    end
  end

  defp continue_with_routed_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher)
       when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if routed_issue_in_scope?(refreshed_issue) do
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

  defp continue_with_routed_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp notify_lifecycle_suspended(recipient, %Issue{id: issue_id}, assessment)
       when is_pid(recipient) and is_binary(issue_id) do
    send(recipient, {:agent_lifecycle_suspended, issue_id, assessment})
    :ok
  end

  defp notify_lifecycle_suspended(_recipient, _issue, _assessment), do: :ok

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

  defp notify_dependency_blocked(recipient, %Issue{id: issue_id}, decision)
       when is_pid(recipient) and is_binary(issue_id) do
    send(recipient, {:agent_dependency_blocked, issue_id, dependency_metadata(decision)})
    :ok
  end

  defp notify_dependency_blocked(_recipient, _issue, _decision), do: :ok

  defp maybe_put_work_item(opts, %WorkItem{} = work_item),
    do: Keyword.put(opts, :work_item, work_item)

  defp maybe_put_work_item(opts, _work_item), do: Keyword.delete(opts, :work_item)

  defp dependency_metadata(decision) when is_map(decision) do
    Map.take(decision, [
      :allowed?,
      :dependency_completeness,
      :merge_permitted?,
      :dependency_status,
      :dependent_state,
      :responsibility,
      :reason,
      :blockers,
      :unresolved_blockers,
      :invalidated_blockers,
      :diagnostic
    ])
  end

  defp dependency_decision(%Issue{} = issue, %Route{responsibility: responsibility}, opts) do
    Guard.evaluate(issue, responsibility, dependency_policy_options(opts))
  end

  defp dependency_decision(_issue, _route, _opts), do: %{allowed?: true}

  defp agent_tool_context(%Issue{} = issue, %Route{} = route, opts) do
    context = %{
      issue_id: issue.id,
      current_issue_state: issue.state,
      responsibility: route.responsibility,
      dependency_decision: dependency_decision_from_options(issue, route, opts),
      work_control: Keyword.get(opts, :work_control, %{}),
      guard_evidence: Keyword.get(opts, :guard_evidence, [])
    }

    case Keyword.get(opts, :work_item) do
      %WorkItem{validated_lifecycle_state: state} = work_item ->
        Map.merge(context, %{trusted_lifecycle_state: state, work_item: work_item})

      _missing_work_item ->
        context
    end
  end

  defp agent_tool_context(%Issue{} = issue, _route, _opts) do
    %{
      issue_id: issue.id,
      current_issue_state: issue.state,
      responsibility: nil,
      dependency_decision: %{allowed?: false, dependency_completeness: :unavailable}
    }
  end

  defp dependency_decision_from_options(issue, route, opts) do
    case Keyword.get(opts, :dependency_decision) do
      %{allowed?: _} = decision -> decision
      _ -> dependency_decision(issue, route, opts)
    end
  end

  defp dependency_policy_options(opts) when is_list(opts) do
    settings = Config.settings!()

    options = [
      active_states: settings.tracker.active_states || [],
      terminal_states: settings.tracker.terminal_states || []
    ]

    case Keyword.get(opts, :work_control) do
      work_control when is_map(work_control) -> Keyword.put(options, :work_control, work_control)
      _missing -> options
    end
  end

  defp max_turns_for_route(%Route{profile: %Profile{max_turns: max_turns}}), do: max_turns
  defp max_turns_for_route(_route), do: Config.settings!().agent.max_turns

  defp max_turns_for_run(%Route{} = route, _opts), do: max_turns_for_route(route)

  defp max_turns_for_run(_route, opts),
    do: Keyword.get(opts, :max_turns, max_turns_for_route(nil))

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

  defp validate_routed_attempt(%Route{} = route, opts) do
    if Config.settings!().agent.routing == "routed" do
      validate_routed_work_item(route, Keyword.get(opts, :work_item))
    else
      :ok
    end
  end

  defp validate_routed_attempt(_route, _opts) do
    if Config.settings!().agent.routing == "legacy" do
      :ok
    else
      {:error, :canonical_work_item_required}
    end
  end

  defp validate_routed_work_item(_route, work_item) when not is_struct(work_item, WorkItem),
    do: {:error, :canonical_work_item_required}

  defp validate_routed_work_item(route, %WorkItem{} = work_item) do
    cond do
      not LifecycleAssessment.validated?(work_item.lifecycle_assessment) ->
        {:error, :lifecycle_validation_required}

      not WorkItem.authority_available?(work_item) ->
        {:error, :authority_unavailable}

      true ->
        validate_routed_route(route, work_item)
    end
  end

  defp validate_routed_route(route, %WorkItem{} = work_item) do
    settings = Config.settings!()

    case Router.resolve(work_item, settings.agent.profiles, settings.agent.routes) do
      {:ok, ^route} -> :ok
      {:ok, _other_route} -> {:error, :route_authority_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_put_route(opts, nil), do: opts
  defp maybe_put_route(opts, %Route{} = route), do: Keyword.put(opts, :route, route)

  defp route_log_context(nil), do: ""

  defp route_log_context(%Route{} = route) do
    " profile=#{route.profile_name} runtime=#{route.runtime_name} responsibility=#{route.responsibility}"
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns), do: PromptBuilder.build_prompt(issue, opts)

  defp build_turn_prompt(_issue, opts, turn_number, max_turns) do
    continuation = """
    Continuation guidance:

    - The previous Codex turn completed normally, but the tracker work item is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """

    case Keyword.fetch(opts, :role_prompt) do
      {:ok, role_prompt} ->
        PromptBuilder.with_role_prompt(continuation, Keyword.get(opts, :route), role_prompt)

      :error ->
        PromptBuilder.with_role_prompt(continuation, Keyword.get(opts, :route))
    end
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher)
       when is_binary(issue_id) do
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

  defp routed_issue_in_scope?(%Issue{} = issue) do
    required_labels = Config.settings!().tracker.required_labels
    labels = Issue.label_names(issue)

    Enum.all?(required_labels, fn required_label ->
      Enum.any?(labels, fn label -> normalize_label(label) == normalize_label(required_label) end)
    end)
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

  defp normalize_label(label) when is_binary(label) do
    label
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
