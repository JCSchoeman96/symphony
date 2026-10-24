"""Rootless Linux integration tests for the disposable-netns nft policy."""

import json
import os
import pathlib
import signal
import shutil
import socket
import subprocess
import tempfile
import threading
import unittest


ROOT = pathlib.Path(__file__).parents[2] / "priv/h100"
INNER = r'''
import json, pathlib, socket, subprocess, sys, threading
sys.path.insert(0, sys.argv[1])
import host_qualification as host
host.POLICY_VERIFIER = pathlib.Path(sys.argv[2])

subprocess.run(["ip", "link", "set", "lo", "up"], check=True,
               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def listener(family, address):
    sock = socket.socket(family, socket.SOCK_STREAM)
    if family == socket.AF_INET6:
        sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
    sock.bind((address, 0))
    sock.listen(8)
    return sock, sock.getsockname()[1]

fixture, fixture_port = listener(socket.AF_INET, "127.0.0.1")
other, other_port = listener(socket.AF_INET, "127.0.0.1")
v6, v6_port = listener(socket.AF_INET6, "::1")
relay_server_code = r"""import json, os, socket
server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.bind(("127.0.0.1", 0))
server.listen(1)
print(json.dumps({"pid": os.getpid(), "uid": os.geteuid(), "port": server.getsockname()[1]}), flush=True)
connection, _ = server.accept()
with connection:
    if connection.recv(64) == b"relay-probe":
        connection.sendall(b"relay-response")
server.close()
"""
relay_service = subprocess.Popen(["setpriv", "--bounding-set=-all", "--inh-caps=-all",
                                  "--ambient-caps=-all", "--reuid=1202", "--regid=1202",
                                  "--clear-groups", "python3", "-I", "-u", "-c", relay_server_code],
                                 stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                 stderr=subprocess.DEVNULL, text=True, bufsize=1)
relay_ready = json.loads(relay_service.stdout.readline())
assert relay_ready["uid"] == 1202 and relay_ready["pid"] > 0

host.install_stage_a(proof_uid=1201, relay_uid=1202, fixture_port=fixture_port)
stage_a = host._run_verifier(["--stage-a", "--proof-uid", "1201", "--relay-uid", "1202",
                              "--fixture-port", str(fixture_port)])
assert stage_a["stage"] == "A" and stage_a["proof_drop"] is True
assert stage_a["verifier_uid"] == 1201 and stage_a["verifier_cap_eff"] == 0
print(json.dumps({"type": "POLICY_ACTIVE"}), flush=True)

worker = r"""import json, os, socket, sys
print(json.dumps({"pid": os.getpid(), "uid": os.geteuid()}), flush=True)
for line in sys.stdin:
    request = json.loads(line)
    client = socket.socket(socket.AF_INET6 if ":" in request["host"] else socket.AF_INET,
                           socket.SOCK_STREAM)
    client.settimeout(0.35)
    try:
        client.connect((request["host"], request["port"]))
        if request.get("exchange"):
            client.sendall(b"relay-probe")
            result = "connected" if client.recv(64) == b"relay-response" else "blocked"
        else:
            result = "connected"
    except OSError:
        result = "blocked"
    finally:
        client.close()
    print(json.dumps({"result": result}), flush=True)
"""

def start_worker(uid):
    proc = subprocess.Popen(["setpriv", "--bounding-set=-all", "--inh-caps=-all",
                             "--ambient-caps=-all", f"--reuid={uid}", f"--regid={uid}",
                             "--clear-groups", "python3", "-u", "-c", worker],
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, text=True, bufsize=1)
    identity = json.loads(proc.stdout.readline())
    assert identity["uid"] == uid
    return proc, identity["pid"]

def probe(proc, host_name, port, *, exchange=False):
    proc.stdin.write(json.dumps({"host": host_name, "port": port, "exchange": exchange}) + "\n")
    proc.stdin.flush()
    return json.loads(proc.stdout.readline())["result"]

def accept_once(sock):
    conn, _ = sock.accept()
    conn.close()

proof, proof_pid = start_worker(1201)
relay, relay_pid = start_worker(1202)
identity = pathlib.Path(f"/proc/{proof_pid}/status").read_text()
cap_eff = next(line.split()[1] for line in identity.splitlines() if line.startswith("CapEff:"))
assert int(cap_eff, 16) == 0

assert probe(proof, "127.0.0.1", fixture_port) == "blocked"
assert probe(proof, "::1", v6_port) == "blocked"
stage_a_after = host._run_verifier(["--stage-a", "--proof-uid", "1201", "--relay-uid", "1202",
                                    "--fixture-port", str(fixture_port)])
assert stage_a_after["proof_drop_packets"] >= 2

host.install_stage_b(proof_uid=1201, proof_port=relay_ready["port"])
stage_b = host._run_verifier(["--stage-b", "--proof-uid", "1201", "--proof-pid", str(proof_pid),
                              "--proof-port", str(relay_ready["port"]), "--relay-uid", "1202",
                              "--fixture-port", str(fixture_port)])
assert stage_b["stage"] == "B" and stage_b["netns_inode"] > 0
assert stage_b["userns_inode"] > 0 and stage_b["cgroup"]
assert stage_b["proof_allow"]["rule_handle"] > 0 and stage_b["proof_drop_rule_handle"] > 0
assert stage_b["verifier_uid"] == 1201 and stage_b["verifier_cap_eff"] == 0

assert probe(proof, "127.0.0.1", relay_ready["port"], exchange=True) == "connected"
assert probe(proof, "127.0.0.1", other_port) == "blocked"
assert probe(proof, "::1", v6_port) == "blocked"

relay_server = threading.Thread(target=accept_once, args=(fixture,), daemon=True)
relay_server.start()
assert probe(relay, "127.0.0.1", fixture_port) == "connected"
relay_server.join(2)
assert not relay_server.is_alive()
assert probe(relay, "127.0.0.1", other_port) == "blocked"

stage_b_after = host._run_verifier(["--stage-b", "--proof-uid", "1201", "--proof-pid", str(proof_pid),
                                    "--proof-port", str(relay_ready["port"]), "--relay-uid", "1202",
                                    "--fixture-port", str(fixture_port)])
assert stage_b_after["proof_allow"]["packets"] >= 1
assert stage_b_after["proof_drop_packets"] >= 4
assert stage_b_after["relay_allow"]["packets"] >= 1
assert stage_b_after["relay_drop_packets"] >= 1

host.revoke_stage_b(proof_uid=1201, proof_port=relay_ready["port"])
restored = host._run_verifier(["--deny-all", "--proof-uid", "1201", "--relay-uid", "1202"])
assert restored["proof_allow"] is None
assert probe(proof, "127.0.0.1", relay_ready["port"]) == "blocked"
assert probe(relay, "127.0.0.1", fixture_port) == "blocked"
restored = host._run_verifier(["--deny-all", "--proof-uid", "1201", "--relay-uid", "1202"])
assert restored["proof_allow"] is None

for proc in (proof, relay):
    proc.stdin.close()
    proc.terminate()
    proc.wait(timeout=2)
relay_service.terminate()
relay_service.wait(timeout=2)
relay_service.stdout.close()
for sock in (fixture, other, v6):
    sock.close()
host._nft_script("delete table inet symphony_h100\n")
removed = host._run_verifier(["--table-absent"])
assert removed["stage"] == "REMOVED" and removed["policy_table_absent"] is True
print(json.dumps({"stage_a": stage_a_after["proof_drop_packets"],
                  "stage_b": stage_b_after["proof_allow"]["packets"],
                  "proof_drop": stage_b_after["proof_drop_packets"],
                  "relay_drop": stage_b_after["relay_drop_packets"],
                  "restored_drop": restored["proof_drop_packets"],
                  "proof_pid": proof_pid, "proof_uid": 1201,
                  "netns_inode": stage_b["netns_inode"],
                  "userns_inode": stage_b["userns_inode"],
                  "policy_table_absent": removed["policy_table_absent"]}, sort_keys=True))
'''


class LocalPolicyIntegrationTests(unittest.TestCase):
    def test_rootless_namespace_enforces_stage_a_and_exact_stage_b_scopes(self):
        required = ("unshare", "nft", "ip", "setpriv", "newuidmap", "newgidmap")
        missing = [binary for binary in required if shutil.which(binary) is None]
        self.assertEqual(missing, [], f"rootless namespace tools unavailable: {missing}")

        host_listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        verifier_directory = tempfile.TemporaryDirectory(prefix="h100-policy-verifier-")
        os.chmod(verifier_directory.name, 0o755)
        verifier_path = pathlib.Path(verifier_directory.name) / "policy_verify.py"
        shutil.copyfile(ROOT / "policy_verify.py", verifier_path)
        os.chmod(verifier_path, 0o644)
        try:
            host_listener.bind(("127.0.0.1", 0))
            host_listener.listen(1)
            host_port = host_listener.getsockname()[1]

            process = subprocess.Popen(
                ["unshare", "--user", "--map-auto", "--map-root-user", "--net",
                 "--", "python3", "-c", INNER, str(ROOT), str(verifier_path)],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1,
                start_new_session=True,
            )
            try:
                active = json.loads(process.stdout.readline())
                self.assertEqual(active, {"type": "POLICY_ACTIVE"})
                control = subprocess.run(
                    ["python3", "-I", "-c",
                     "import socket,sys; s=socket.create_connection(('127.0.0.1',int(sys.argv[1])),2); s.sendall(b'outside-control-ok'); s.close()",
                     str(host_port)],
                    check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                    timeout=5, env={"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8"},
                )
                self.assertEqual(control.returncode, 0, control.stderr)
                accepted, _ = host_listener.accept()
                self.assertEqual(accepted.recv(64), b"outside-control-ok")
                accepted.close()
                rest, stderr = process.communicate(timeout=30)
                self.assertEqual(process.returncode, 0, stderr)
                evidence = json.loads(rest.strip().splitlines()[-1])
            finally:
                if process.poll() is None:
                    try:
                        os.killpg(process.pid, signal.SIGTERM)
                        process.wait(timeout=5)
                    except (OSError, subprocess.TimeoutExpired):
                        try:
                            os.killpg(process.pid, signal.SIGKILL)
                        except OSError:
                            pass
                        process.wait(timeout=3)
                if process.stdout is not None:
                    process.stdout.close()
                if process.stderr is not None:
                    process.stderr.close()
            self.assertGreaterEqual(evidence["stage_a"], 2)
            self.assertGreaterEqual(evidence["stage_b"], 1)
            self.assertGreaterEqual(evidence["proof_drop"], 4)
            self.assertGreaterEqual(evidence["relay_drop"], 1)
            self.assertGreater(evidence["restored_drop"], evidence["proof_drop"])
            self.assertEqual(evidence["proof_uid"], 1201)
            self.assertGreater(evidence["proof_pid"], 0)
            self.assertGreater(evidence["netns_inode"], 0)
            self.assertGreater(evidence["userns_inode"], 0)
            self.assertTrue(evidence["policy_table_absent"])

        finally:
            verifier_directory.cleanup()
            host_listener.close()


if __name__ == "__main__":
    unittest.main()
