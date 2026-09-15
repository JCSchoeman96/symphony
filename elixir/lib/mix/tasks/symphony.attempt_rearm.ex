defmodule Mix.Tasks.Symphony.AttemptRearm do
  use Mix.Task

  alias SymphonyElixir.AgentRuntime.AttemptLedger
  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Tracker
  alias SymphonyElixir.Workflow

  @shortdoc "Rearm one exhausted durable attempt lineage"

  @moduledoc """
  Rearms one exhausted attempt lineage for a host operator.

  The old exhausted lineage is retained as durable history and the operation
  creates a new lineage with fresh safety counters. This task is intentionally
  host-only; it is not registered as a runtime or Codex tool.

  Usage:

      mix symphony.attempt_rearm --project-id symphony-main --issue-id ENG-123 \\
        --reason "provider state verified" --operator alice --timestamp 1700000000000

  Optional `--ledger-path` and `--workflow` arguments are useful for explicit
  administrative operations and deterministic recovery procedures.
  """

  @switches [
    project_id: :string,
    issue_id: :string,
    reason: :string,
    operator: :string,
    timestamp: :integer,
    ledger_path: :string,
    workflow: :string,
    help: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    {opts, argv, invalid} = OptionParser.parse(args, strict: @switches, aliases: [h: :help])

    cond do
      opts[:help] ->
        Mix.shell().info(@moduledoc)

      invalid != [] ->
        Mix.raise("Invalid option(s): #{inspect(invalid)}")

      argv != [] ->
        Mix.raise("Unexpected argument(s): #{inspect(argv)}")

      true ->
        rearm(opts)
    end
  end

  defp rearm(opts) do
    project_id = required_opt(opts, :project_id)
    issue_id = required_opt(opts, :issue_id)
    reason = required_opt(opts, :reason)
    operator = required_opt(opts, :operator)
    timestamp = required_timestamp_opt(opts)

    with :ok <- validate_project_id(project_id),
         {:ok, settings} <- load_settings(opts[:workflow]),
         :ok <- validate_workflow_identity(settings, project_id),
         {:ok, ledger} <- open_ledger(project_id, settings, opts),
         result <-
           AttemptLedger.rearm(
             ledger,
             issue_id,
             reason,
             operator,
             timestamp
           ),
         :ok <- close_ledger(ledger) do
      case result do
        {:ok, %{lineage_id: lineage_id}} ->
          Mix.shell().info("Rearmed issue #{issue_id} in project #{project_id} as #{lineage_id}")
          :ok

        {:error, reason} ->
          Mix.raise("Unable to rearm issue #{issue_id}: #{inspect(reason)}")
      end
    else
      {:error, reason} ->
        Mix.raise(format_error(reason))
    end
  end

  defp load_settings(nil) do
    case Config.settings() do
      {:ok, settings} -> {:ok, settings}
      {:error, reason} -> {:error, {:workflow_config_unavailable, reason}}
    end
  end

  defp load_settings(path) when is_binary(path) do
    with {:ok, workflow} <- Workflow.load(Path.expand(path)),
         {:ok, settings} <- Schema.parse(workflow.config),
         :ok <- Config.validate_settings(settings) do
      {:ok, settings}
    else
      {:error, reason} -> {:error, {:workflow_config_unavailable, reason}}
    end
  end

  defp validate_workflow_identity(%{agent: %{routing: "routed"}, symphony: %{project_id: project_id}}, project_id),
    do: :ok

  defp validate_workflow_identity(%{agent: %{routing: "routed"}, symphony: %{project_id: configured}}, project_id),
    do: {:error, {:workflow_project_identity_mismatch, configured, project_id}}

  defp validate_workflow_identity(_settings, _project_id), do: :ok

  defp open_ledger(project_id, settings, opts) do
    identity = Tracker.identity(settings.tracker)
    ledger_path = AttemptLedger.path_for(project_id, path: opts[:ledger_path])

    case AttemptLedger.open(project_id, identity, path: ledger_path) do
      {:ok, ledger} -> {:ok, ledger}
      {:error, reason} -> {:error, {:attempt_ledger_unavailable, reason}}
    end
  end

  defp close_ledger(ledger) do
    case AttemptLedger.close(ledger) do
      :ok -> :ok
      {:error, reason} -> {:error, {:attempt_ledger_close_failed, reason}}
    end
  end

  defp validate_project_id(project_id) do
    if Schema.valid_project_id?(project_id), do: :ok, else: {:error, {:invalid_symphony_project_id, project_id}}
  end

  defp required_opt(opts, key) do
    case opts[key] do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: Mix.raise("Missing required option --#{key_to_cli(key)}"), else: value

      _ ->
        Mix.raise("Missing required option --#{key_to_cli(key)}")
    end
  end

  defp required_timestamp_opt(opts) do
    case opts[:timestamp] do
      timestamp when is_integer(timestamp) and timestamp >= 0 ->
        timestamp

      timestamp when is_integer(timestamp) ->
        Mix.raise("Invalid option --timestamp")

      _ ->
        Mix.raise("Missing required option --timestamp")
    end
  end

  defp key_to_cli(key), do: key |> Atom.to_string() |> String.replace("_", "-")

  defp format_error({:workflow_config_unavailable, reason}),
    do: "Unable to load workflow configuration: #{inspect(reason)}"

  defp format_error({:attempt_ledger_unavailable, reason}),
    do: "Unable to open attempt ledger: #{inspect(reason)}"

  defp format_error({:attempt_ledger_close_failed, reason}),
    do: "Unable to close attempt ledger: #{inspect(reason)}"

  defp format_error({:workflow_project_identity_mismatch, configured, requested}),
    do: "Workflow project_id #{inspect(configured)} does not match requested project #{inspect(requested)}"

  defp format_error(reason), do: "Invalid attempt rearm request: #{inspect(reason)}"
end
