defmodule SymphonyElixir.SourceControl.RepositoryProbe do
  @moduledoc """
  Fixed read-only host git observation for workspace HEAD and cleanliness.
  """

  alias SymphonyElixir.SSH

  @type probe_result :: %{
          clean?: boolean(),
          head_sha: String.t() | nil,
          error: term() | nil
        }

  @spec probe(map(), keyword()) :: {:ok, probe_result()} | {:error, term()}
  def probe(repository_context, opts \\ []) when is_map(repository_context) do
    workspace_path = Map.get(repository_context, :workspace_path)
    worker_host = Map.get(repository_context, :worker_host)

    cond do
      not is_binary(workspace_path) or String.trim(workspace_path) == "" ->
        {:error, :workspace_unavailable}

      is_binary(worker_host) and String.trim(worker_host) != "" ->
        remote_probe(worker_host, workspace_path, opts)

      true ->
        local_probe(workspace_path, opts)
    end
  end

  @spec clean_worktree?(map(), keyword()) :: boolean()
  def clean_worktree?(repository_context, opts \\ []) do
    case probe(repository_context, opts) do
      {:ok, %{clean?: true}} -> true
      _ -> false
    end
  end

  defp local_probe(workspace_path, opts) do
    runner = Keyword.get(opts, :command_runner, &local_command/2)

    with {:ok, status_output} <- runner.(workspace_path, "git -C #{shell_escape(workspace_path)} status --porcelain"),
         {:ok, head_output} <- runner.(workspace_path, "git -C #{shell_escape(workspace_path)} rev-parse HEAD") do
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

  defp remote_probe(worker_host, workspace_path, opts) do
    runner = Keyword.get(opts, :remote_command_runner, &remote_command/3)
    command = "git -C #{shell_escape(workspace_path)} status --porcelain && git -C #{shell_escape(workspace_path)} rev-parse HEAD"

    case runner.(worker_host, command, opts) do
      {:ok, output} ->
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

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp split_status_and_head(lines) do
    case Enum.split(lines, -1) do
      {[], []} -> {[], []}
      {status_lines, [head]} -> {status_lines, [head]}
    end
  end

  defp local_command(_workspace_path, command) do
    case System.cmd("bash", ["-lc", command], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, _status} -> {:error, {:git_command_failed, String.trim(output)}}
    end
  end

  defp remote_command(worker_host, command, opts) do
    case SSH.run(worker_host, command, Keyword.take(opts, [:env])) do
      {:ok, {output, 0}} -> {:ok, output}
      {:ok, {output, _status}} -> {:error, {:git_command_failed, String.trim(output)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\\''") <> "'"
  end
end
