defmodule SymphonyElixir.A4LoopbackProbe do
  alias SymphonyElixir.Codex.IsolationProfile

  def run! do
    root = Path.join(System.tmp_dir!(), "a4-loopback-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)
    executable = System.find_executable("codex") || raise "codex is required"
    {:ok, command} = IsolationProfile.resolve_codex_executable(executable <> " app-server")
    {:ok, session} = IsolationProfile.prepare_session_home(workspace, "implementation", command.native_executable)
    helper = Path.expand("connect_helper.py", __DIR__)
    manifest_path = Path.join(root, "manifest.json")
    File.write!(manifest_path, Jason.encode!(%{provider_request_id: "preq_q12", origin_kind: "local_qualification", origin_authority: "127.0.0.1:9", connect_watchdog_seconds: 3}))
    python = System.find_executable("python3") || raise "python3 is required"
    shell = "exec /usr/bin/env -i PATH=/usr/bin:/bin LANG=C.UTF-8 \"$2\" -I \"$3\" < \"$1\""
    port = Port.open({:spawn_executable, ~c"/bin/sh"}, [:binary, :exit_status, {:line, 65_536}, {:args, ["-c", shell, "a4-loopback", manifest_path, python, helper]}])

    try do
      ready =
        receive do
          {^port, {:data, {:eol, line}}} -> Jason.decode!(line)
        after
          5000 -> raise "helper READY timeout"
        end

      true = ready["type"] == "READY"

      child_script = """
      import json,socket,sys
      reachable=False
      try:
          s=socket.socket()
          s.settimeout(1)
          reachable=s.connect_ex(('127.0.0.1',int(sys.argv[1])))==0
          s.close()
      except OSError:
          pass
      print(json.dumps({'reachable':reachable}))
      """

      args =
        ["sandbox", "--permission-profile", session.permission_profile, "--sandbox-state-disable-network", "--cd", workspace] ++
          [python, "-c", child_script, Integer.to_string(ready["bound_port"])]

      removed = System.get_env() |> Map.keys() |> Enum.map(&{&1, nil})

      env =
        removed ++
          [
            {"PATH", "/usr/bin:/bin"},
            {"HOME", session.home},
            {"CODEX_HOME", session.codex_home},
            {"XDG_CONFIG_HOME", session.xdg_config_home},
            {"XDG_STATE_HOME", session.xdg_state_home},
            {"XDG_CACHE_HOME", session.xdg_cache_home},
            {"LANG", "C.UTF-8"}
          ]

      {output, 0} = System.cmd(executable, args, env: env, cd: workspace, stderr_to_stdout: true)
      child = output |> String.split("\n", trim: true) |> Enum.find(&String.starts_with?(&1, "{")) |> Jason.decode!()

      closed =
        receive do
          {^port, {:data, {:eol, line}}} -> Jason.decode!(line)
        after
          5000 -> raise "helper closure timeout"
        end

      status =
        receive do
          {^port, {:exit_status, status}} -> status
        after
          5000 -> raise "helper exit timeout"
        end

      %{
        child_loopback_relay_reachable: child["reachable"],
        helper_connect_count: closed["connect_count"],
        helper_terminated: status == 2,
        codex_version: "codex-cli 0.162.1",
        helper_sha256: ready["script_blob_sha256"]
      }
    after
      if Port.info(port), do: Port.close(port)
      :ok = IsolationProfile.cleanup_session_home(session)
      File.rm_rf!(root)
    end
  end
end
