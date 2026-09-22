defmodule SymphonyElixir.SourceControl.RepositoryProbe do
  @moduledoc """
  Fixed read-only host git observation for workspace HEAD and cleanliness.
  """

  alias SymphonyElixir.{CredentialBoundary, SSH}

  @type probe_result :: %{
          clean?: boolean(),
          head_sha: String.t() | nil,
          error: term() | nil
        }

  @type command_runner ::
          (String.t(), String.t(), [String.t()] ->
             {:ok, String.t()} | {:error, term()})

  @git_config_overrides [
    "-c",
    "core.fsmonitor=",
    "-c",
    "core.hooksPath=",
    "-c",
    "credential.helper=",
    "-c",
    "core.sshCommand="
  ]

  @spec probe(map(), keyword()) :: {:ok, probe_result()} | {:error, term()}
  def probe(repository_context, opts \\ []) when is_map(repository_context) do
    workspace_path = Map.get(repository_context, :workspace_path)
    worker_host = Map.get(repository_context, :worker_host)
    secret_environment_names = Keyword.get(opts, :secret_environment_names, [])

    cond do
      not is_binary(workspace_path) or String.trim(workspace_path) == "" ->
        {:error, :workspace_unavailable}

      is_binary(worker_host) and String.trim(worker_host) != "" ->
        remote_probe(worker_host, workspace_path, secret_environment_names, opts)

      true ->
        local_probe(workspace_path, secret_environment_names, opts)
    end
  end

  @spec clean_worktree?(map(), keyword()) :: boolean()
  def clean_worktree?(repository_context, opts \\ []) do
    case probe(repository_context, opts) do
      {:ok, %{clean?: true}} -> true
      _ -> false
    end
  end

  defp local_probe(workspace_path, secret_environment_names, opts) do
    runner =
      Keyword.get(opts, :command_runner, fn workspace, git_executable, argv ->
        default_command_runner(workspace, git_executable, argv, secret_environment_names)
      end)

    git_executable = Keyword.get(opts, :git_executable, resolve_git_executable())

    with {:ok, git_executable} <- ensure_git_executable(git_executable),
         {:ok, status_output} <-
           runner.(workspace_path, git_executable, status_argv(workspace_path)),
         {:ok, head_output} <-
           runner.(workspace_path, git_executable, rev_parse_argv(workspace_path)) do
      head_sha = String.trim(head_output)

      {:ok,
       %{
         clean?: status_output == "",
         head_sha: if(head_sha == "", do: nil, else: String.downcase(head_sha)),
         error: nil
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp remote_probe(worker_host, workspace_path, secret_environment_names, opts) do
    runner = Keyword.get(opts, :remote_command_runner, &default_remote_command_runner/4)
    git_executable = Keyword.get(opts, :git_executable, resolve_git_executable())

    with {:ok, git_executable} <- ensure_git_executable(git_executable) do
      runner.(worker_host, workspace_path, git_executable, secret_environment_names)
    end
  end

  defp default_command_runner(_workspace_path, git_executable, argv, secret_environment_names) do
    env = CredentialBoundary.probe_process_env(secret_environment_names)

    case System.cmd(git_executable, argv, stderr_to_stdout: true, env: env) do
      {output, 0} -> {:ok, output}
      {output, _status} -> {:error, {:git_command_failed, String.trim(output)}}
    end
  end

  defp default_remote_command_runner(worker_host, workspace_path, git_executable, secret_environment_names) do
    status_command = remote_git_command(git_executable, workspace_path, status_argv(workspace_path))
    head_command = remote_git_command(git_executable, workspace_path, rev_parse_argv(workspace_path))
    command = status_command <> " && " <> head_command
    env = CredentialBoundary.probe_process_env(secret_environment_names)

    case SSH.run(worker_host, command, env: env) do
      {:ok, {output, 0}} ->
        lines = String.split(String.trim_trailing(output), "\n", trim: true)
        {status_lines, head_lines} = split_status_and_head(lines)

        head_sha =
          case List.last(head_lines) do
            value when is_binary(value) and value != "" -> String.downcase(String.trim(value))
            _ -> nil
          end

        {:ok,
         %{
           clean?: status_lines == [],
           head_sha: head_sha,
           error: nil
         }}

      {:ok, {output, _status}} ->
        {:error, {:git_command_failed, String.trim(output)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp remote_git_command(git_executable, workspace_path, argv) do
    config_and_subcommand = Enum.drop(argv, 2)
    args_fragment = Enum.map_join(config_and_subcommand, " ", &shell_escape/1)

    "#{shell_escape(git_executable)} -C #{shell_escape(workspace_path)} #{args_fragment}"
  end

  defp status_argv(workspace_path) do
    ["-C", workspace_path] ++ @git_config_overrides ++ ["status", "--porcelain"]
  end

  defp rev_parse_argv(workspace_path) do
    ["-C", workspace_path] ++ @git_config_overrides ++ ["rev-parse", "HEAD"]
  end

  defp split_status_and_head(lines) do
    case Enum.split(lines, -1) do
      {[], []} -> {[], []}
      {status_lines, [head]} -> {status_lines, [head]}
    end
  end

  defp resolve_git_executable do
    System.find_executable("git")
  end

  defp ensure_git_executable(nil), do: {:error, :git_not_found}
  defp ensure_git_executable(git_executable) when is_binary(git_executable), do: {:ok, git_executable}

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\\''") <> "'"
  end
end
