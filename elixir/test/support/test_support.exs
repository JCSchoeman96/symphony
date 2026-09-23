defmodule SymphonyElixir.TestSupport do
  alias SymphonyElixir.Config
  alias SymphonyElixir.Tracker
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.WorkControl.RecoveryLedger
  alias SymphonyElixir.WorkControl.WorkflowLifecycle

  @workflow_prompt "You are an agent for this repository."

  defmacro __using__(_opts) do
    quote do
      use ExUnit.Case
      import ExUnit.CaptureLog

      alias SymphonyElixir.AgentRunner
      alias SymphonyElixir.CLI
      alias SymphonyElixir.Codex.AppServer
      alias SymphonyElixir.Config
      alias SymphonyElixir.HttpServer
      alias SymphonyElixir.Linear.Client
      alias SymphonyElixir.Orchestrator
      alias SymphonyElixir.PromptBuilder
      alias SymphonyElixir.StatusDashboard
      alias SymphonyElixir.Tracker
      alias SymphonyElixir.Tracker.Issue
      alias SymphonyElixir.Workflow
      alias SymphonyElixir.WorkflowStore
      alias SymphonyElixir.Workspace

      import SymphonyElixir.TestSupport,
        only: [
          write_workflow_file!: 1,
          write_workflow_file!: 2,
          restore_env: 2,
          seed_recovery_checkpoint!: 1,
          seed_recovery_checkpoint!: 2,
          seed_orchestrator_recovery_checkpoint!: 2,
          seed_orchestrator_recovery_checkpoint!: 3,
          stop_default_http_server: 0
        ]

      setup do
        workflow_root =
          Path.join(
            System.tmp_dir!(),
            "symphony-elixir-workflow-#{System.unique_integer([:positive])}"
          )

        File.mkdir_p!(workflow_root)
        workflow_file = Path.join(workflow_root, "WORKFLOW.md")
        attempt_ledger_root = Path.join(workflow_root, "attempt-ledger")
        File.mkdir_p!(attempt_ledger_root)
        write_workflow_file!(workflow_file)
        Workflow.set_workflow_file_path(workflow_file)
        Application.put_env(:symphony_elixir, :attempt_ledger_root, attempt_ledger_root)
        if Process.whereis(SymphonyElixir.WorkflowStore), do: SymphonyElixir.WorkflowStore.force_reload()
        stop_default_http_server()

        on_exit(fn ->
          Application.delete_env(:symphony_elixir, :workflow_file_path)
          Application.delete_env(:symphony_elixir, :server_port_override)
          Application.delete_env(:symphony_elixir, :memory_tracker_issues)
          Application.delete_env(:symphony_elixir, :attempt_ledger_root)
          File.rm_rf(workflow_root)
        end)

        :ok
      end
    end
  end

  def write_workflow_file!(path, overrides \\ []) do
    workflow = workflow_content(default_identity_override(path, overrides))
    File.write!(path, workflow)

    if Process.whereis(SymphonyElixir.WorkflowStore) do
      try do
        SymphonyElixir.WorkflowStore.force_reload()
      catch
        :exit, _reason -> :ok
      end
    end

    :ok
  end

  def restore_env(key, nil), do: System.delete_env(key)
  def restore_env(key, value), do: System.put_env(key, value)

  def seed_recovery_checkpoint!(%Issue{} = issue, opts \\ []) when is_list(opts) do
    config = Config.settings!()
    {:ok, lifecycle_state} = WorkflowLifecycle.parse(Keyword.get(opts, :lifecycle_state, issue.state))
    root = Path.join(Application.fetch_env!(:symphony_elixir, :attempt_ledger_root), "work-control-recovery")

    {:ok, ledger} =
      RecoveryLedger.open(
        config.symphony.project_id,
        Tracker.identity(config.tracker),
        root: root
      )

    checkpoint = recovery_checkpoint(issue.id, lifecycle_state, Keyword.get(opts, :evidence, []))
    :ok = RecoveryLedger.put_sync(ledger, checkpoint)
    :ok = RecoveryLedger.close(ledger)
    :ok
  end

  def seed_orchestrator_recovery_checkpoint!(orchestrator, %Issue{} = issue, opts \\ [])
      when is_pid(orchestrator) and is_list(opts) do
    state = :sys.get_state(orchestrator)
    {:ok, lifecycle_state} = WorkflowLifecycle.parse(Keyword.get(opts, :lifecycle_state, issue.state))
    checkpoint = recovery_checkpoint(issue.id, lifecycle_state, Keyword.get(opts, :evidence, []))

    case RecoveryLedger.put_sync(state.recovery_ledger, checkpoint) do
      :ok ->
        :sys.replace_state(orchestrator, fn current ->
          %{current | recovery_checkpoints: Map.put(current.recovery_checkpoints, issue.id, checkpoint)}
        end)

        :ok

      {:error, reason} ->
        raise "unable to seed recovery checkpoint: #{inspect(reason)}"
    end
  end

  defp recovery_checkpoint(work_item_id, lifecycle_state, evidence) do
    %{
      schema_version: RecoveryLedger.schema_version(),
      project_namespace: Config.settings!().symphony.project_id,
      work_item_id: work_item_id,
      last_validated_lifecycle_state: lifecycle_state,
      durable_guard_evidence: durable_mechanical_evidence(evidence),
      active_suspension_context: nil,
      last_terminal_suspension_context: nil,
      updated_at: DateTime.utc_now()
    }
  end

  defp durable_mechanical_evidence(evidence) do
    evidence
    |> Enum.filter(&match?(%{class: :mechanical_guard}, &1))
    |> Enum.map(&Map.take(&1, [:class, :name, :outcome]))
  end

  def stop_default_http_server do
    case Enum.find(Supervisor.which_children(SymphonyElixir.Supervisor), fn
           {SymphonyElixir.HttpServer, _pid, _type, _modules} -> true
           _child -> false
         end) do
      {SymphonyElixir.HttpServer, pid, _type, _modules} when is_pid(pid) ->
        :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.HttpServer)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end

        :ok

      _ ->
        :ok
    end
  end

  defp workflow_content(overrides) do
    config =
      [
        tracker_kind: "linear",
        tracker_endpoint: "https://api.linear.app/graphql",
        tracker_api_token: "token",
        tracker_project_slug: "project",
        tracker_assignee: nil,
        tracker_required_labels: [],
        tracker_active_states: ["Todo", "In Progress"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"],
        poll_interval_ms: 30_000,
        workspace_root: Path.join(System.tmp_dir!(), "symphony_workspaces"),
        worker_ssh_hosts: [],
        worker_max_concurrent_agents_per_host: nil,
        max_concurrent_agents: 10,
        max_turns: 20,
        max_retry_backoff_ms: 300_000,
        max_concurrent_agents_by_state: %{},
        agent_routing: "legacy",
        agent_profiles: nil,
        codex_command: "codex app-server",
        codex_approval_policy: %{reject: %{sandbox_approval: true, rules: true, mcp_elicitations: true}},
        codex_thread_sandbox: "workspace-write",
        codex_turn_sandbox_policy: nil,
        codex_turn_timeout_ms: 3_600_000,
        codex_read_timeout_ms: 5_000,
        codex_stall_timeout_ms: 300_000,
        hook_after_create: nil,
        hook_before_run: nil,
        hook_after_run: nil,
        hook_before_remove: nil,
        hook_timeout_ms: 60_000,
        observability_enabled: true,
        observability_refresh_ms: 1_000,
        observability_render_interval_ms: 16,
        server_port: nil,
        server_host: nil,
        provider_project_contract: nil,
        prompt: @workflow_prompt
      ]
      |> Keyword.merge(overrides)
      |> maybe_default_agent_routing(overrides)
      |> maybe_default_routed_source_control(overrides)

    tracker_kind = Keyword.get(config, :tracker_kind)
    tracker_endpoint = Keyword.get(config, :tracker_endpoint)
    tracker_api_token = Keyword.get(config, :tracker_api_token)
    tracker_project_slug = Keyword.get(config, :tracker_project_slug)
    tracker_assignee = Keyword.get(config, :tracker_assignee)
    tracker_required_labels = Keyword.get(config, :tracker_required_labels)
    tracker_active_states = Keyword.get(config, :tracker_active_states)
    tracker_terminal_states = Keyword.get(config, :tracker_terminal_states)
    poll_interval_ms = Keyword.get(config, :poll_interval_ms)
    workspace_root = Keyword.get(config, :workspace_root)
    worker_ssh_hosts = Keyword.get(config, :worker_ssh_hosts)
    worker_max_concurrent_agents_per_host = Keyword.get(config, :worker_max_concurrent_agents_per_host)
    max_concurrent_agents = Keyword.get(config, :max_concurrent_agents)
    max_turns = Keyword.get(config, :max_turns)
    max_retry_backoff_ms = Keyword.get(config, :max_retry_backoff_ms)
    max_concurrent_agents_by_state = Keyword.get(config, :max_concurrent_agents_by_state)
    agent_routing = Keyword.get(config, :agent_routing)
    agent_profiles = Keyword.get(config, :agent_profiles)
    codex_command = Keyword.get(config, :codex_command)
    codex_approval_policy = Keyword.get(config, :codex_approval_policy)
    codex_thread_sandbox = Keyword.get(config, :codex_thread_sandbox)
    codex_turn_sandbox_policy = Keyword.get(config, :codex_turn_sandbox_policy)
    codex_turn_timeout_ms = Keyword.get(config, :codex_turn_timeout_ms)
    codex_read_timeout_ms = Keyword.get(config, :codex_read_timeout_ms)
    codex_stall_timeout_ms = Keyword.get(config, :codex_stall_timeout_ms)
    hook_after_create = Keyword.get(config, :hook_after_create)
    hook_before_run = Keyword.get(config, :hook_before_run)
    hook_after_run = Keyword.get(config, :hook_after_run)
    hook_before_remove = Keyword.get(config, :hook_before_remove)
    hook_timeout_ms = Keyword.get(config, :hook_timeout_ms)
    observability_enabled = Keyword.get(config, :observability_enabled)
    observability_refresh_ms = Keyword.get(config, :observability_refresh_ms)
    observability_render_interval_ms = Keyword.get(config, :observability_render_interval_ms)
    server_port = Keyword.get(config, :server_port)
    server_host = Keyword.get(config, :server_host)
    provider_project_contract = Keyword.get(config, :provider_project_contract)
    prompt = Keyword.get(config, :prompt)
    symphony_project_id = Keyword.get(config, :symphony_project_id)
    source_control_kind = Keyword.get(config, :source_control_kind)
    source_control_repository = Keyword.get(config, :source_control_repository)
    source_control_repository_id = Keyword.get(config, :source_control_repository_id)
    source_control_base_branch = Keyword.get(config, :source_control_base_branch)
    source_control_token_env = Keyword.get(config, :source_control_token_env)
    source_control_required_checks = Keyword.get(config, :source_control_required_checks)

    sections =
      [
        "---",
        provider_project_contract_yaml(provider_project_contract),
        "tracker:",
        "  kind: #{yaml_value(tracker_kind)}",
        "  endpoint: #{yaml_value(tracker_endpoint)}",
        "  api_key: #{yaml_value(tracker_api_token)}",
        "  project_slug: #{yaml_value(tracker_project_slug)}",
        "  assignee: #{yaml_value(tracker_assignee)}",
        "  required_labels: #{yaml_value(tracker_required_labels)}",
        "  active_states: #{yaml_value(tracker_active_states)}",
        "  terminal_states: #{yaml_value(tracker_terminal_states)}",
        "symphony:",
        "  project_id: #{yaml_value(symphony_project_id)}",
        "polling:",
        "  interval_ms: #{yaml_value(poll_interval_ms)}",
        "workspace:",
        "  root: #{yaml_value(workspace_root)}",
        worker_yaml(worker_ssh_hosts, worker_max_concurrent_agents_per_host),
        "agent:",
        "  max_concurrent_agents: #{yaml_value(max_concurrent_agents)}",
        "  max_turns: #{yaml_value(max_turns)}",
        "  max_retry_backoff_ms: #{yaml_value(max_retry_backoff_ms)}",
        "  max_concurrent_agents_by_state: #{yaml_value(max_concurrent_agents_by_state)}",
        "  routing: #{yaml_value(agent_routing)}",
        agent_profiles_yaml(agent_profiles),
        "codex:",
        "  command: #{yaml_value(codex_command)}",
        "  approval_policy: #{yaml_value(codex_approval_policy)}",
        "  thread_sandbox: #{yaml_value(codex_thread_sandbox)}",
        "  turn_sandbox_policy: #{yaml_value(codex_turn_sandbox_policy)}",
        "  turn_timeout_ms: #{yaml_value(codex_turn_timeout_ms)}",
        "  read_timeout_ms: #{yaml_value(codex_read_timeout_ms)}",
        "  stall_timeout_ms: #{yaml_value(codex_stall_timeout_ms)}",
        hooks_yaml(hook_after_create, hook_before_run, hook_after_run, hook_before_remove, hook_timeout_ms),
        observability_yaml(observability_enabled, observability_refresh_ms, observability_render_interval_ms),
        server_yaml(server_port, server_host),
        source_control_yaml(
          source_control_kind,
          source_control_repository,
          source_control_repository_id,
          source_control_base_branch,
          source_control_token_env,
          source_control_required_checks
        ),
        "---",
        prompt
      ]
      |> Enum.reject(&(&1 in [nil, ""]))

    Enum.join(sections, "\n") <> "\n"
  end

  defp yaml_value(value) when is_binary(value) do
    "\"" <> String.replace(value, "\"", "\\\"") <> "\""
  end

  defp yaml_value(value) when is_integer(value), do: to_string(value)
  defp yaml_value(true), do: "true"
  defp yaml_value(false), do: "false"
  defp yaml_value(nil), do: "null"

  defp yaml_value(values) when is_list(values) do
    "[" <> Enum.map_join(values, ", ", &yaml_value/1) <> "]"
  end

  defp yaml_value(values) when is_map(values) do
    "{" <>
      Enum.map_join(values, ", ", fn {key, value} ->
        "#{yaml_value(to_string(key))}: #{yaml_value(value)}"
      end) <> "}"
  end

  defp yaml_value(value), do: yaml_value(to_string(value))

  defp provider_project_contract_yaml(nil), do: nil

  defp provider_project_contract_yaml(contract) when is_map(contract) do
    "provider_project_contract: #{yaml_value(contract)}"
  end

  defp default_identity_override(path, overrides) do
    if Keyword.get(overrides, :tracker_kind, "linear") == "memory" and
         not Keyword.has_key?(overrides, :symphony_project_id) do
      Keyword.put(overrides, :symphony_project_id, "test-#{:erlang.phash2(Path.expand(path))}")
    else
      overrides
    end
  end

  defp maybe_default_agent_routing(config, overrides) do
    if Keyword.has_key?(overrides, :agent_routing) do
      config
    else
      routing = if Keyword.get(config, :tracker_kind) == "memory", do: "routed", else: "legacy"
      Keyword.put(config, :agent_routing, routing)
    end
  end

  defp maybe_default_routed_source_control(config, overrides) do
    if should_inject_routed_source_control?(config, overrides) do
      config
      |> Keyword.put(:source_control_kind, "github")
      |> Keyword.put(:source_control_repository, "octo/symphony")
      |> Keyword.put(:source_control_repository_id, 1_368_436_395)
      |> Keyword.put(:source_control_base_branch, "main")
      |> Keyword.put(:source_control_token_env, "GITHUB_TOKEN")
      |> Keyword.put(:source_control_required_checks, [
        %{"context" => "make-all", "app_id" => 15_368, "subject" => "head"}
      ])
    else
      config
    end
  end

  defp should_inject_routed_source_control?(config, overrides) do
    Keyword.get(config, :agent_routing) == "routed" and
      not Keyword.has_key?(overrides, :source_control_kind) and
      is_nil(Keyword.get(config, :source_control_kind))
  end

  defp agent_profiles_yaml(nil), do: nil
  defp agent_profiles_yaml(profiles), do: "  profiles: #{yaml_value(profiles)}"

  defp hooks_yaml(nil, nil, nil, nil, timeout_ms), do: "hooks:\n  timeout_ms: #{yaml_value(timeout_ms)}"

  defp hooks_yaml(hook_after_create, hook_before_run, hook_after_run, hook_before_remove, timeout_ms) do
    [
      "hooks:",
      "  timeout_ms: #{yaml_value(timeout_ms)}",
      hook_entry("after_create", hook_after_create),
      hook_entry("before_run", hook_before_run),
      hook_entry("after_run", hook_after_run),
      hook_entry("before_remove", hook_before_remove)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp worker_yaml(ssh_hosts, max_concurrent_agents_per_host)
       when ssh_hosts in [nil, []] and is_nil(max_concurrent_agents_per_host),
       do: nil

  defp worker_yaml(ssh_hosts, max_concurrent_agents_per_host) do
    [
      "worker:",
      ssh_hosts not in [nil, []] && "  ssh_hosts: #{yaml_value(ssh_hosts)}",
      !is_nil(max_concurrent_agents_per_host) &&
        "  max_concurrent_agents_per_host: #{yaml_value(max_concurrent_agents_per_host)}"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join("\n")
  end

  defp observability_yaml(enabled, refresh_ms, render_interval_ms) do
    [
      "observability:",
      "  dashboard_enabled: #{yaml_value(enabled)}",
      "  refresh_ms: #{yaml_value(refresh_ms)}",
      "  render_interval_ms: #{yaml_value(render_interval_ms)}"
    ]
    |> Enum.join("\n")
  end

  defp source_control_yaml(nil, _repository, _repository_id, _base_branch, _token_env, _required_checks), do: nil

  defp source_control_yaml(kind, repository, repository_id, base_branch, token_env, required_checks) do
    checks_yaml =
      case required_checks do
        nil ->
          ""

        checks ->
          checks_lines =
            Enum.map(checks, fn check ->
              "    - context: #{yaml_value(check["context"] || check[:context])}\n" <>
                "      app_id: #{yaml_value(check["app_id"] || check[:app_id])}\n" <>
                "      subject: #{yaml_value(check["subject"] || check[:subject])}"
            end)

          "  required_checks:\n" <> Enum.join(checks_lines, "\n")
      end

    [
      "source_control:",
      "  kind: #{yaml_value(kind)}",
      "  repository: #{yaml_value(repository)}",
      "  repository_id: #{yaml_value(repository_id)}",
      "  base_branch: #{yaml_value(base_branch)}",
      "  token_env: #{yaml_value(token_env)}",
      checks_yaml
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  defp server_yaml(nil, nil), do: nil

  defp server_yaml(port, host) do
    [
      "server:",
      port && "  port: #{yaml_value(port)}",
      host && "  host: #{yaml_value(host)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp hook_entry(_name, nil), do: nil

  defp hook_entry(name, command) when is_binary(command) do
    indented =
      command
      |> String.split("\n")
      |> Enum.map_join("\n", &("    " <> &1))

    "  #{name}: |\n#{indented}"
  end
end
