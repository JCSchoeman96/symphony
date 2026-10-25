Mix.start()
Application.ensure_all_started(:hex)

defmodule H100LockedHexDependencies do
  alias Mix.Dep.Lock

  @max_dependencies 1_000
  @max_materialized_files 50_000
  @max_materialized_paths 100_000
  @max_materialized_bytes 536_870_912
  @max_package_archive_bytes 16_777_216
  @max_total_archive_bytes 536_870_912
  @name_pattern ~r/\A[a-z][a-z0-9_-]*\z/
  @app_pattern ~r/\A[A-Za-z][A-Za-z0-9_-]*\z/
  @version_pattern ~r/\A[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?(?:\+[A-Za-z0-9.-]+)?\z/
  @checksum_pattern ~r/\A[0-9a-f]{64}\z/

  def run([lock_path, deps_path]) do
    with {:ok, lock} <- read_lock(lock_path),
         :ok <- require_fresh_deps_path(deps_path) do
      File.mkdir!(deps_path)

      try do
        {entries, archive_bytes} =
          lock
          |> Enum.sort_by(fn {app, _entry} -> Atom.to_string(app) end)
          |> Enum.reduce({[], 0}, fn {app, entry}, {records, total_bytes} ->
            record = materialize_entry(app, entry, deps_path)
            next_bytes = total_bytes + record.archive_bytes

            if next_bytes > @max_total_archive_bytes do
              fail("locked Hex archives exceed their total size bound")
            end

            {[record | records], next_bytes}
          end)

        materialized_source = inventory_materialized_tree(deps_path)

        inventory =
          entries
          |> Enum.reverse()
          |> Enum.map(fn record ->
            Enum.join(
              [record.app, record.name, record.version, record.repo, record.inner_checksum, record.outer_checksum],
              <<0>>
            ) <> "\n"
          end)
          |> IO.iodata_to_binary()
          |> then(fn value -> :crypto.hash(:sha256, value) end)
          |> Base.encode16(case: :lower)

        IO.puts("H100_LOCKED_HEX_PROVENANCE #{length(entries)} #{archive_bytes} #{inventory} #{materialized_source}")
      rescue
        _error ->
          File.rm_rf(deps_path)
          IO.puts(:stderr, "H100_LOCKED_HEX_FAILURE materialization_failed")
          System.halt(1)
      end
    else
      {:error, reason} -> fail(reason)
    end
  end

  def run(_arguments), do: fail("locked Hex materializer arguments are invalid")

  defp read_lock(path) do
    case Lock.read(path) do
      lock when is_map(lock) and map_size(lock) <= @max_dependencies -> {:ok, lock}
      _ -> {:error, "candidate mix.lock is malformed or exceeds its dependency bound"}
    end
  rescue
    _ -> {:error, "candidate mix.lock could not be parsed"}
  end

  defp require_fresh_deps_path(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      _ -> {:error, "candidate dependency destination is not fresh"}
    end
  end

  defp materialize_entry(
         app,
         {:hex, name, version, inner, managers, _dependencies, repo, outer},
         deps_path
       )
       when is_atom(app) and is_atom(name) and is_binary(version) and is_binary(repo) and is_list(managers) do
    app_name = Atom.to_string(app)
    package_name = Atom.to_string(name)
    validate_hex_entry!(app_name, package_name, version, inner, managers, repo, outer)

    archive = Hex.SCM.cache_path(repo, package_name, version)
    archive_bytes = bounded_archive_size!(archive)
    expected_outer = decode_checksum!(outer)
    outer_actual = archive_outer_checksum!(archive)
    verify_outer_checksum!(outer_actual, expected_outer)

    destination = Path.join(deps_path, app_name)
    unpacked = Hex.Tar.unpack!(archive, destination)
    verify_unpacked_package!(unpacked, package_name, version, inner, expected_outer)
    write_hex_manifest!(destination, name, version, inner, managers, repo, outer)
    verify_hex_manifest!(destination, name, version, inner, managers, repo, outer)
    dependency_record(app_name, package_name, version, repo, inner, outer, archive_bytes)
  end

  defp materialize_entry(_app, _entry, _deps_path),
    do: fail("candidate lock contains a non-Hex or unsupported dependency")

  defp validate_hex_entry!(app_name, package_name, version, inner, managers, repo, outer) do
    valid_names = Regex.match?(@app_pattern, app_name) and Regex.match?(@name_pattern, package_name)
    valid_release = Regex.match?(@version_pattern, version) and repo == "hexpm"
    valid_managers = Enum.all?(managers, &is_atom/1)
    valid_checksums = Regex.match?(@checksum_pattern, inner) and Regex.match?(@checksum_pattern, outer)

    if valid_names and valid_release and valid_managers and valid_checksums do
      :ok
    else
      fail("candidate lock contains an unsupported Hex dependency entry")
    end
  end

  defp bounded_archive_size!(archive) do
    case File.lstat(archive) do
      {:ok, %{type: :regular, size: size}} when size > 0 and size <= @max_package_archive_bytes -> size
      _ -> fail("locked Hex package archive is missing or outside its size bound")
    end
  end

  defp decode_checksum!(checksum), do: Base.decode16!(checksum, case: :lower)

  defp archive_outer_checksum!(archive) do
    case Hex.Tar.outer_checksum(archive) do
      {:ok, checksum} -> checksum
      _ -> fail("locked Hex package archive could not be checksummed")
    end
  end

  defp verify_outer_checksum!(actual, expected) do
    if :crypto.hash_equals(actual, expected) do
      :ok
    else
      fail("locked Hex package outer checksum does not match mix.lock")
    end
  end

  defp verify_unpacked_package!(unpacked, package_name, version, inner, expected_outer) do
    expected_inner = decode_checksum!(inner)

    valid_checksums =
      :crypto.hash_equals(unpacked.inner_checksum, expected_inner) and
        :crypto.hash_equals(unpacked.outer_checksum, expected_outer)

    valid_identity =
      unpacked.metadata["name"] == package_name and
        unpacked.metadata["version"] == version

    unless valid_checksums and valid_identity do
      fail("locked Hex package identity or checksums do not match mix.lock")
    end
  end

  defp write_hex_manifest!(destination, name, version, inner, managers, repo, outer) do
    manifest = %{
      name: Atom.to_string(name),
      version: version,
      inner_checksum: inner,
      outer_checksum: outer,
      repo: repo,
      managers: managers
    }

    File.write!(Path.join(destination, ".hex"), :erlang.term_to_binary({{:hex, 2, 0}, manifest}))
  end

  defp verify_hex_manifest!(destination, name, version, inner, managers, repo, outer) do
    lock = {:hex, name, version, inner, managers, [], repo, outer}

    if Hex.SCM.lock_status(dest: destination, lock: lock) == :ok do
      :ok
    else
      fail("materialized Hex package manifest does not match mix.lock")
    end
  end

  defp dependency_record(app_name, package_name, version, repo, inner, outer, archive_bytes) do
    %{app: app_name, name: package_name, version: version, repo: repo}
    |> Map.merge(%{inner_checksum: inner, outer_checksum: outer, archive_bytes: archive_bytes})
  end

  defp inventory_materialized_tree(root) do
    {files, _count, _total_bytes, _path_count} = collect_materialized_files(root, "", [], 0, 0, 0)

    files
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce(:crypto.hash_init(:sha256), fn {relative, path, size}, digest ->
      relative_bytes = IO.iodata_to_binary(relative)
      file_digest = file_sha256(path)

      :crypto.hash_update(
        digest,
        <<byte_size(relative_bytes)::32, relative_bytes::binary, size::64, file_digest::binary>>
      )
    end)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp collect_materialized_files(directory, relative, files, count, total_bytes, path_count) do
    children = directory |> File.ls!() |> Enum.sort()

    Enum.reduce(children, {files, count, total_bytes, path_count}, fn name, {items, file_count, byte_count, item_count} ->
      path = Path.join(directory, name)
      relative_path = if relative == "", do: name, else: Path.join(relative, name)
      next_path_count = item_count + 1

      validate_materialized_path!(next_path_count, relative_path)

      case File.lstat(path) do
        {:ok, %{type: :directory}} ->
          collect_materialized_files(path, relative_path, items, file_count, byte_count, next_path_count)

        {:ok, %{type: :regular, size: size}} ->
          {next_count, next_bytes} = checked_materialized_file_totals!(file_count, byte_count, size)

          {[{relative_path, path, size} | items], next_count, next_bytes, next_path_count}

        _ ->
          fail("materialized dependency tree contains an unsupported path")
      end
    end)
  end

  defp validate_materialized_path!(path_count, relative_path) do
    if path_count > @max_materialized_paths or length(Path.split(relative_path)) > 128 do
      fail("materialized dependency tree exceeds its path bound")
    end
  end

  defp checked_materialized_file_totals!(file_count, byte_count, size) do
    next_count = file_count + 1
    next_bytes = byte_count + size

    if next_count > @max_materialized_files or next_bytes > @max_materialized_bytes do
      fail("materialized dependency tree exceeds its fixed bound")
    end

    {next_count, next_bytes}
  end

  defp file_sha256(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, device} ->
        try do
          digest = hash_file_chunks(device, :crypto.hash_init(:sha256))
          :crypto.hash_final(digest)
        after
          File.close(device)
        end

      {:error, _reason} ->
        fail("materialized dependency file could not be hashed")
    end
  end

  defp hash_file_chunks(device, digest) do
    case IO.binread(device, 65_536) do
      :eof -> digest
      {:error, _reason} -> fail("materialized dependency file could not be read")
      chunk -> hash_file_chunks(device, :crypto.hash_update(digest, chunk))
    end
  end

  defp fail(reason), do: raise(ArgumentError, reason)
end

H100LockedHexDependencies.run(System.argv())
