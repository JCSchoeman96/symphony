defmodule SymphonyElixir.RuntimeIsolationTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.AgentRuntime.RuntimeIsolation
  alias SymphonyElixir.Codex.IsolationProfile

  test "remote workers fail before executable inspection or probing" do
    probe = fn _identity -> flunk("remote admission must not probe or inspect an executable") end
    {:ok, server} = RuntimeIsolation.start_link(probe: probe)

    assert {:error, {:runtime_isolation_unavailable, :remote_containment_unproven}} =
             RuntimeIsolation.admit("worker.example", "/missing/codex", server: server)
  end

  test "admission rejects an invalid test verifier reference" do
    executable = executable!("codex-cli 0.159.3\n")

    assert {:error, {:runtime_isolation_unavailable, :verifier_unavailable}} =
             RuntimeIsolation.admit(nil, executable, server: "not-a-registered-name")
  end

  test "evidence and clear can initialize a named verifier server" do
    server_name = String.to_atom("runtime_isolation_lazy_#{System.unique_integer([:positive])}")
    executable = executable!("codex-cli 0.159.3\n")
    on_exit(fn -> if pid = Process.whereis(server_name), do: GenServer.stop(pid) end)

    assert %{id: ^server_name, start: {RuntimeIsolation, :start_link, [[name: ^server_name]]}} =
             RuntimeIsolation.child_spec(name: server_name)

    assert RuntimeIsolation.evidence(executable, server: server_name) == nil
    assert is_pid(Process.whereis(server_name))
    assert :ok = RuntimeIsolation.clear(server: server_name)
    assert RuntimeIsolation.evidence(executable, server: server_name) == nil
  end

  test "default evidence and clear use the supervised verifier" do
    executable = executable!("codex-cli 0.159.3\n")

    assert RuntimeIsolation.evidence(executable) == nil
    assert :ok = RuntimeIsolation.clear()
  end

  test "non-map probe results are reduced to verified evidence" do
    executable = executable!("codex-cli 0.159.3\n")
    {:ok, server} = RuntimeIsolation.start_link(probe: fn _identity -> {:ok, "private probe detail"} end)

    assert {:ok, %{status: :verified, result: :verified}} =
             RuntimeIsolation.verify(executable, server: server)
  end

  test "admission fails closed when the supervised verifier is missing without starting a fallback" do
    server_name = String.to_atom("runtime_isolation_missing_#{System.unique_integer([:positive])}")
    executable = executable!("codex-cli 0.159.3\n")

    on_exit(fn ->
      case Process.whereis(server_name) do
        pid when is_pid(pid) -> GenServer.stop(pid)
        nil -> :ok
      end
    end)

    assert {:error, {:runtime_isolation_unavailable, :verifier_unavailable}} =
             RuntimeIsolation.admit(nil, executable, server: server_name)

    refute Process.whereis(server_name)
  end

  test "admission rejects an exited verifier pid before runtime execution" do
    executable = executable!("codex-cli 0.159.3\n")
    {:ok, server} = RuntimeIsolation.start_link(probe: fn _identity -> :ok end)
    GenServer.stop(server)

    assert {:error, {:runtime_isolation_unavailable, :verifier_unavailable}} =
             RuntimeIsolation.admit(nil, executable, server: server)
  end

  test "admission rejects a live verifier that is not the supervised child" do
    supervisor = Process.whereis(SymphonyElixir.Supervisor)
    assert is_pid(supervisor)

    assert {RuntimeIsolation, supervised_pid, _type, _modules} =
             Enum.find(Supervisor.which_children(supervisor), fn
               {RuntimeIsolation, pid, _type, _modules} when is_pid(pid) -> true
               _child -> false
             end)

    :ok = Supervisor.terminate_child(supervisor, RuntimeIsolation)

    on_exit(fn ->
      case Process.whereis(RuntimeIsolation) do
        pid when is_pid(pid) -> GenServer.stop(pid)
        nil -> :ok
      end

      assert {:ok, _pid} = Supervisor.restart_child(supervisor, RuntimeIsolation)
    end)

    {:ok, unsupervised_pid} = RuntimeIsolation.start_link(name: RuntimeIsolation, probe: fn _ -> :ok end)
    Process.unlink(unsupervised_pid)

    assert Process.whereis(RuntimeIsolation) == unsupervised_pid
    refute Process.whereis(RuntimeIsolation) == supervised_pid

    executable = executable!("codex-cli 0.159.3\n")

    assert {:error, {:runtime_isolation_unavailable, :verifier_unavailable}} =
             RuntimeIsolation.admit(nil, executable, [])
  end

  test "admission resolves the exact supervised verifier child" do
    supervisor = Process.whereis(SymphonyElixir.Supervisor)
    assert is_pid(supervisor)

    assert {RuntimeIsolation, child_pid, _type, _modules} =
             Enum.find(Supervisor.which_children(supervisor), fn
               {RuntimeIsolation, pid, _type, _modules} when is_pid(pid) -> true
               _child -> false
             end)

    assert Process.whereis(RuntimeIsolation) == child_pid

    executable = executable!("codex-cli 0.159.3\n")
    result = RuntimeIsolation.admit(nil, executable, [])

    refute match?({:error, {:runtime_isolation_unavailable, :verifier_unavailable}}, result)
  end

  test "runtime identity rejects Codex versions without a proved isolation profile" do
    executable = executable!("codex-cli 0.160.0\n")

    assert {:error, {:codex_identity_failed, {:unsupported_codex_version, "codex-cli 0.160.0"}}} =
             IsolationProfile.runtime_identity(executable)
  end

  test "concurrent callers share one verification for an executable fingerprint" do
    executable = executable!("codex-cli 0.159.3\n")
    parent = self()

    probe = fn identity ->
      send(parent, {:probe_started, identity.digest})
      :ok
    end

    {:ok, server} = RuntimeIsolation.start_link(probe: probe)

    callers =
      for _ <- 1..8 do
        Task.async(fn -> RuntimeIsolation.verify(executable, server: server) end)
      end

    results = Enum.map(callers, &Task.await(&1, 1_000))
    assert Enum.all?(results, &match?({:ok, %{status: :verified}}, &1))
    assert_receive {:probe_started, _fingerprint}
    refute_received {:probe_started, _fingerprint}
  end

  test "verification evidence can be read and cleared without exposing extra probe data" do
    executable = executable!("codex-cli 0.159.3\n")
    parent = self()

    probe = fn _identity ->
      send(parent, :probe_started)
      {:ok, %{read_only: :verified, workspace_write: :verified, platform: :linux, private: "sentinel"}}
    end

    {:ok, server} = RuntimeIsolation.start_link(probe: probe)

    try do
      assert RuntimeIsolation.evidence(executable, server: server) == nil
      assert {:ok, %{status: :verified, result: result}} = RuntimeIsolation.verify(executable, server: server)
      assert result == %{read_only: :verified, workspace_write: :verified, platform: :linux}
      assert RuntimeIsolation.evidence(executable, server: server).result == result
      assert :ok = RuntimeIsolation.clear(server: server)
      assert RuntimeIsolation.evidence(executable, server: server) == nil
      assert {:ok, %{status: :verified}} = RuntimeIsolation.verify(executable, server: server)

      assert_receive :probe_started
      assert_receive :probe_started
      refute_received :probe_started
    after
      GenServer.stop(server)
    end
  end

  test "invalid and raised verifier probes fail closed with safe reasons" do
    probe_cases = [
      {fn _identity -> :invalid end, :invalid_probe_result},
      {fn _identity -> {:error, {:credential_config, :unsafe}} end, {:credential_config, :unsafe}},
      {fn _identity -> {:error, {:credential_config, "sentinel-value"}} end, :probe_failed},
      {
        fn _identity -> {:error, {:isolation_failed, :read, %{"probe" => false}, false}} end,
        {:isolation_failed, :read, %{"probe" => false}, false}
      },
      {fn _identity -> raise ArgumentError, "sentinel-value" end, :probe_raised},
      {fn _identity -> throw(:sentinel_value) end, :probe_failed}
    ]

    Enum.each(probe_cases, fn {probe, expected_reason} ->
      executable = executable!("codex-cli 0.159.3\n")
      {:ok, server} = RuntimeIsolation.start_link(probe: probe)

      try do
        assert {:error, {:runtime_isolation_failed, ^expected_reason}} =
                 RuntimeIsolation.verify(executable, server: server)

        assert %{status: :failed, result: ^expected_reason} =
                 RuntimeIsolation.evidence(executable, server: server)
      after
        GenServer.stop(server)
      end
    end)
  end

  test "verifier process failure returns a typed fail-closed admission error" do
    executable = executable!("codex-cli 0.159.3\\n")
    parent = self()

    probe = fn _identity ->
      send(parent, :probe_started)
      receive do: (:continue -> :ok)
    end

    {:ok, server} = RuntimeIsolation.start_link(probe: probe)
    Process.unlink(server)

    caller =
      Task.async(fn ->
        try do
          RuntimeIsolation.verify(executable, server: server)
        catch
          :exit, _reason -> :verifier_exited
        end
      end)

    assert_receive :probe_started, 5_000
    Process.exit(server, :kill)

    assert {:error, {:runtime_isolation_unavailable, :verifier_unavailable}} =
             Task.await(caller, 1_000)
  end

  test "a verified fingerprint becomes stale when the Codex executable changes" do
    executable = executable!("codex-cli 0.159.3\n")
    parent = self()

    probe = fn identity ->
      send(parent, {:verified_probe, identity.digest})
      {:ok, %{read_only: :verified, workspace_write: :verified, platform: :linux}}
    end

    {:ok, server} = RuntimeIsolation.start_link(probe: probe)

    assert {:ok, %{status: :verified, fingerprint: first_fingerprint}} =
             RuntimeIsolation.verify(executable, server: server)

    assert {:ok, %{fingerprint: ^first_fingerprint}} =
             RuntimeIsolation.verify(executable, server: server)

    assert_receive {:verified_probe, first_digest}
    refute_received {:verified_probe, _fingerprint}

    File.write!(executable, "#!/bin/sh\n# changed executable bytes\nprintf 'codex-cli 0.159.3\\n'\n")
    File.chmod!(executable, 0o700)

    assert {:ok, %{status: :verified, fingerprint: second_fingerprint}} =
             RuntimeIsolation.verify(executable, server: server)

    refute second_fingerprint == first_fingerprint
    assert_receive {:verified_probe, second_digest}
    refute second_digest == first_digest

    assert %{records: records} = :sys.get_state(server)
    assert records[first_fingerprint].status == :stale
  end

  test "a failed fingerprint stays failed and a changed executable gets a fresh check" do
    executable = executable!("codex-cli 0.159.3\n")
    parent = self()

    probe = fn identity ->
      send(parent, {:probe, identity.digest})
      {:error, :network_denied_probe_failed}
    end

    {:ok, server} = RuntimeIsolation.start_link(probe: probe)

    assert {:error, {:runtime_isolation_failed, :network_denied_probe_failed}} =
             RuntimeIsolation.verify(executable, server: server)

    assert {:error, {:runtime_isolation_failed, :network_denied_probe_failed}} =
             RuntimeIsolation.verify(executable, server: server)

    assert_receive {:probe, first_fingerprint}
    refute_received {:probe, _fingerprint}

    File.write!(executable, "#!/bin/sh\n# changed executable bytes\nprintf 'codex-cli 0.159.3\\n'\n")
    File.chmod!(executable, 0o700)

    assert {:error, {:runtime_isolation_failed, :network_denied_probe_failed}} =
             RuntimeIsolation.verify(executable, server: server)

    assert_receive {:probe, second_fingerprint}
    refute first_fingerprint == second_fingerprint
  end

  test "permission profile grants only the exact workspace and keeps git metadata read-only" do
    workspace = Path.join(System.tmp_dir!(), "h080b-profile-#{System.unique_integer([:positive])}")
    native = executable!("codex-cli 0.159.3\n")
    File.mkdir_p!(workspace)

    on_exit(fn -> File.rm_rf!(workspace) end)

    assert {:ok, profile} =
             IsolationProfile.build_permission_profile(
               workspace,
               "implementation",
               native
             )

    assert profile.name == "symphony_builder_write"
    assert profile.access == :write
    assert profile.workspace_roots == [Path.expand(workspace)]
    assert profile.network_enabled == false
    assert profile.git_access == :read
    assert profile.native_executable == Path.expand(native)
  end

  test "session homes separate HOME, XDG, and CODEX_HOME and render a named profile" do
    workspace = Path.join(System.tmp_dir!(), "h080b-session-#{System.unique_integer([:positive])}")
    native = executable!("codex-cli 0.159.3\n")
    File.mkdir_p!(workspace)

    assert {:ok, session_home} =
             IsolationProfile.prepare_session_home(
               workspace,
               "planning",
               native
             )

    on_exit(fn -> IsolationProfile.cleanup_session_home(session_home) end)

    assert session_home.home != session_home.codex_home
    assert session_home.xdg_config_home != System.get_env("XDG_CONFIG_HOME")
    assert session_home.permission_profile == "symphony_planner_read"

    config = File.read!(Path.join(session_home.codex_home, "config.toml"))
    assert config =~ "[permissions.symphony_planner_read.filesystem]"
    assert config =~ "\":minimal\" = \"read\""
    refute config =~ "\":root\""
    refute config =~ "\":tmpdir\""
    assert config =~ "enabled = false"
    assert config =~ "allow_login_shell = false"
    assert config =~ Path.expand(workspace)
    refute config =~ "approval_policy"
  end

  test "session setup never adopts an existing root or cleanup removes an unowned path" do
    workspace = Path.join(System.tmp_dir!(), "h080b-session-workspace-#{System.unique_integer([:positive])}")
    native = executable!("codex-cli 0.159.3\n")
    existing_root = Path.join(System.tmp_dir!(), "h080b-existing-session-#{System.unique_integer([:positive])}")
    protected_file = Path.join(existing_root, "keep.txt")
    File.mkdir_p!(workspace)
    File.mkdir_p!(existing_root)
    File.write!(protected_file, "host data")

    on_exit(fn ->
      File.rm_rf!(workspace)
      File.rm_rf!(existing_root)
    end)

    assert {:error, {:ephemeral_home_failed, :eexist}} =
             IsolationProfile.prepare_session_home(
               workspace,
               "planning",
               native,
               root: existing_root
             )

    assert File.read!(protected_file) == "host data"

    new_root = Path.join(System.tmp_dir!(), "h080b-owned-session-#{System.unique_integer([:positive])}")

    assert {:ok, session_home} =
             IsolationProfile.prepare_session_home(
               workspace,
               "planning",
               native,
               root: new_root
             )

    assert {:error, {:runtime_isolation_cleanup_failed, :invalid_session_home}} =
             IsolationProfile.cleanup_session_home(%{root: existing_root})

    assert File.read!(protected_file) == "host data"

    redirected = %{session_home | root: existing_root}

    assert {:error, {:runtime_isolation_cleanup_failed, :ownership_unverified}} =
             IsolationProfile.cleanup_session_home(redirected)

    assert File.read!(protected_file) == "host data"
    assert :ok = IsolationProfile.cleanup_session_home(session_home)
    refute File.exists?(new_root)
  end

  defp executable!(version_output) do
    path = Path.join(System.tmp_dir!(), "h080b-codex-#{System.unique_integer([:positive])}")

    File.write!(path, "#!/bin/sh\nprintf '#{String.trim(version_output)}\\n'\n")
    File.chmod!(path, 0o700)

    on_exit(fn -> File.rm(path) end)
    path
  end
end
