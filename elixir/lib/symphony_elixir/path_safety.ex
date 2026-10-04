defmodule SymphonyElixir.PathSafety do
  @moduledoc false

  @spec canonicalize(Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def canonicalize(path) when is_binary(path) do
    expanded_path = Path.expand(path)
    {root, segments} = split_absolute_path(expanded_path)

    case resolve_segments(root, [], segments, []) do
      {:ok, canonical_path} ->
        {:ok, canonical_path}

      {:error, reason} ->
        {:error, {:path_canonicalize_failed, expanded_path, reason}}
    end
  end

  defp split_absolute_path(path) when is_binary(path) do
    [root | segments] = Path.split(path)
    {root, segments}
  end

  @spec resolve_segments(String.t(), [String.t()], [String.t()], [String.t()]) ::
          {:ok, String.t()} | {:error, term()}
  defp resolve_segments(root, resolved_segments, [], _visited_symlinks),
    do: {:ok, join_path(root, resolved_segments)}

  defp resolve_segments(root, resolved_segments, [segment | rest], visited_symlinks) do
    candidate_path = join_path(root, resolved_segments ++ [segment])

    case File.lstat(candidate_path) do
      {:ok, %File.Stat{type: :symlink}} ->
        follow_symlink(candidate_path, root, resolved_segments, rest, visited_symlinks)

      {:ok, _stat} ->
        resolve_segments(root, resolved_segments ++ [segment], rest, visited_symlinks)

      {:error, :enoent} ->
        {:ok, join_path(root, resolved_segments ++ [segment | rest])}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec follow_symlink(String.t(), String.t(), [String.t()], [String.t()], [String.t()]) ::
          {:ok, String.t()} | {:error, term()}
  defp follow_symlink(candidate_path, root, resolved_segments, rest, visited_symlinks) do
    if candidate_path in visited_symlinks do
      {:error, :eloop}
    else
      case File.read_link(candidate_path) do
        {:ok, target} ->
          resolved_target = Path.expand(target, join_path(root, resolved_segments))
          {target_root, target_segments} = split_absolute_path(resolved_target)

          resolve_segments(
            target_root,
            [],
            target_segments ++ rest,
            [candidate_path | visited_symlinks]
          )

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp join_path(root, segments) when is_list(segments) do
    Enum.reduce(segments, root, fn segment, acc -> Path.join(acc, segment) end)
  end
end
