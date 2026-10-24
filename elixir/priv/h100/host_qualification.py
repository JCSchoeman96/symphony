"""Install disposable-netns policy and gate A4 READY on independent checks."""

import json
from pathlib import Path
import subprocess
import sys
import threading


TABLE = "symphony_h100"
SYSTEM_PATH = "/usr/sbin:/usr/bin:/sbin:/bin"
READY_FIELDS = {"type", "provider_request_id", "listen_host", "bound_port",
                "python_version", "script_blob_sha256", "environment_names"}
POLICY_VERIFIER = Path(__file__).with_name("policy_verify.py")


class QualificationError(RuntimeError):
    """A required effective policy or relay step failed."""


def _valid_uid(uid):
    return isinstance(uid, int) and not isinstance(uid, bool) and 0 <= uid <= 4_294_967_295


def _valid_port(port):
    return isinstance(port, int) and not isinstance(port, bool) and 1 <= port <= 65535


def _nft_script(script):
    try:
        subprocess.run(["nft", "-f", "-"], input=script.encode("ascii"), check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       timeout=3, env={"PATH": SYSTEM_PATH})
    except (OSError, subprocess.SubprocessError, UnicodeEncodeError) as exc:
        raise QualificationError("nftables policy command failed") from exc


def install_stage_a(*, proof_uid, relay_uid=None, fixture_port=None):
    """Install output-chain proof deny and optional exact relay scope."""
    if not _valid_uid(proof_uid):
        raise QualificationError("invalid proof UID")
    if relay_uid is not None and (not _valid_uid(relay_uid) or relay_uid == proof_uid or
                                  not _valid_port(fixture_port)):
        raise QualificationError("invalid relay UID or fixture port")
    commands = [
        f"add table inet {TABLE}",
        f"add chain inet {TABLE} output {{ type filter hook output priority 0; policy accept; }}",
        f"add rule inet {TABLE} output meta skuid {proof_uid} counter drop",
    ]
    if relay_uid is not None:
        commands.extend([
            f"add rule inet {TABLE} output meta skuid {relay_uid} ip daddr 127.0.0.1 tcp dport {fixture_port} counter accept",
            f"add rule inet {TABLE} output meta skuid {relay_uid} ct state established ip daddr 127.0.0.1 meta l4proto tcp counter accept",
            f"add rule inet {TABLE} output meta skuid {relay_uid} counter drop",
        ])
    _nft_script("\n".join(commands) + "\n")


def install_stage_b(*, proof_uid, proof_port):
    """Prepend one exact proof-UID IPv4 loopback TCP exception."""
    if not _valid_uid(proof_uid) or not _valid_port(proof_port):
        raise QualificationError("invalid Stage B policy scope")
    _nft_script(
        f"insert rule inet {TABLE} output meta skuid {proof_uid} ip daddr 127.0.0.1 "
        f"tcp dport {proof_port} counter accept\n"
    )


def revoke_stage_b(*, proof_uid, proof_port):
    """Delete all dedicated-table accept rules so cleanup leaves full deny-all."""
    if not _valid_uid(proof_uid) or not _valid_port(proof_port):
        raise QualificationError("invalid Stage B rollback scope")
    try:
        result = subprocess.run(["nft", "-a", "-j", "list", "ruleset"], check=True,
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                timeout=3, env={"PATH": SYSTEM_PATH})
        if len(result.stdout) > 1_048_576:
            raise QualificationError("nftables state exceeds rollback bound")
        ruleset = json.loads(result.stdout)
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError) as exc:
        raise QualificationError("cannot inspect Stage B rollback rule") from exc
    handles = []
    for row in ruleset.get("nftables", []):
        rule = row.get("rule") if isinstance(row, dict) else None
        if not isinstance(rule, dict) or rule.get("family") != "inet" or \
                rule.get("table") != TABLE or rule.get("chain") != "output":
            continue
        expressions = rule.get("expr", [])
        verdict_accept = any(isinstance(expr, dict) and "accept" in expr for expr in expressions)
        if verdict_accept:
            handle = rule.get("handle")
            if not isinstance(handle, int) or handle <= 0:
                raise QualificationError("Stage B accept rule has no nft handle")
            handles.append(handle)
    if not handles:
        return
    commands = "\n".join(f"delete rule inet {TABLE} output handle {handle}" for handle in handles)
    _nft_script(commands + "\n")


def _run_verifier(args):
    try:
        result = subprocess.run([sys.executable, str(POLICY_VERIFIER), *args], check=True,
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                timeout=4, env={"PATH": SYSTEM_PATH})
        if len(result.stdout) > 8192:
            raise QualificationError("independent verifier response exceeds bound")
        response = json.loads(result.stdout)
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError) as exc:
        raise QualificationError("independent policy verifier failed") from exc
    if not isinstance(response, dict) or response.get("verified") is not True:
        raise QualificationError("independent policy verifier rejected effective state")
    return response


class LinuxPolicyBackend:
    """Nft installer and separate verifier for the current disposable netns."""

    def __init__(self, *, proof_uid, relay_start, relay_stop, relay_uid=None, fixture_port=None):
        if not callable(relay_start) or not callable(relay_stop):
            raise TypeError("relay start and stop callbacks are required")
        self.proof_uid = proof_uid
        self.relay_uid = relay_uid
        self.fixture_port = fixture_port
        self._relay_start = relay_start
        self._relay_stop = relay_stop
        self.last_stage_a_evidence = None
        self.last_stage_b_evidence = None

    def install_stage_a(self):
        install_stage_a(proof_uid=self.proof_uid, relay_uid=self.relay_uid,
                        fixture_port=self.fixture_port)

    def verify_stage_a(self):
        args = ["--stage-a", "--proof-uid", str(self.proof_uid)]
        if self.relay_uid is not None:
            args.extend(["--relay-uid", str(self.relay_uid), "--fixture-port", str(self.fixture_port)])
        result = _run_verifier(args)
        self.last_stage_a_evidence = result
        relay_allow = result.get("relay_allow")
        relay_return = result.get("relay_established_return")
        if self.relay_uid is None:
            relay_ok = relay_allow is None and relay_return is None and result.get("relay_drop") is False
        else:
            relay_ok = (isinstance(relay_allow, dict) and relay_allow.get("uid") == self.relay_uid and
                        relay_allow.get("port") == self.fixture_port and
                        isinstance(relay_return, dict) and relay_return.get("uid") == self.relay_uid and
                        relay_return.get("destination") == "127.0.0.1" and
                        relay_return.get("flow") == "established" and result.get("relay_drop") is True)
        return (result.get("stage") == "A" and result.get("proof_drop") is True and
                result.get("proof_allow") is None and result.get("netns_inode", 0) > 0 and relay_ok)

    def verify_deny_all(self):
        args = ["--deny-all", "--proof-uid", str(self.proof_uid)]
        if self.relay_uid is not None:
            args.extend(["--relay-uid", str(self.relay_uid)])
        result = _run_verifier(args)
        return (result.get("stage") == "DENY_ALL" and result.get("proof_drop") is True and
                result.get("proof_allow") is None and result.get("relay_allow") is None and
                result.get("relay_established_return") is None and
                result.get("relay_drop") is (self.relay_uid is not None) and
                result.get("netns_inode", 0) > 0)

    def start_relay(self):
        return self._relay_start()

    def install_stage_b(self, pid, uid, port):
        if pid <= 0 or uid != self.proof_uid:
            raise QualificationError("Stage B identity differs from the selected proof scope")
        install_stage_b(proof_uid=uid, proof_port=port)

    def verify_stage_b(self, pid, uid, port):
        if uid != self.proof_uid:
            return False
        args = ["--stage-b", "--proof-uid", str(uid), "--proof-pid", str(pid),
                "--proof-port", str(port)]
        if self.relay_uid is not None:
            args.extend(["--relay-uid", str(self.relay_uid), "--fixture-port", str(self.fixture_port)])
        result = _run_verifier(args)
        self.last_stage_b_evidence = result
        allow = result.get("proof_allow")
        relay_allow = result.get("relay_allow")
        relay_return = result.get("relay_established_return")
        relay_ok = (self.relay_uid is None and relay_allow is None and relay_return is None) or (
            self.relay_uid is not None and isinstance(relay_allow, dict) and
            relay_allow.get("uid") == self.relay_uid and relay_allow.get("port") == self.fixture_port and
            isinstance(relay_return, dict) and relay_return.get("uid") == self.relay_uid and
            relay_return.get("destination") == "127.0.0.1" and relay_return.get("flow") == "established" and
            result.get("relay_drop") is True
        )
        return (result.get("stage") == "B" and result.get("pid") == pid and result.get("uid") == uid and
                result.get("proof_drop") is True and isinstance(allow, dict) and
                allow.get("uid") == uid and allow.get("port") == port and relay_ok and
                result.get("netns_inode", 0) > 0)

    def revoke_stage_b(self, uid, port):
        revoke_stage_b(proof_uid=uid, proof_port=port)

    def stop_relay(self):
        return self._relay_stop()

    def remove_policy_table(self):
        _nft_script(f"delete table inet {TABLE}\n")

    def verify_policy_removed(self):
        result = _run_verifier(["--table-absent"])
        return result.get("stage") == "REMOVED" and result.get("policy_table_absent") is True


class HostQualificationSession:
    """A Stage A lease whose READY method performs the Stage B lifecycle."""

    def __init__(self, backend):
        self.backend = backend
        self.used = False
        self._claim_lock = threading.Lock()

    def _claim_ready(self):
        """Atomically reserve the one READY attempt."""
        with self._claim_lock:
            if self.used:
                return False
            self.used = True
            return True

    def ready(self, *, pid, uid, request_id):
        """Start relay and return READY only after independently verified Stage B."""
        if not self._claim_ready():
            raise QualificationError("qualification session is already used")
        if (not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0 or
                not _valid_uid(uid) or not isinstance(request_id, str) or
                not request_id or len(request_id.encode("utf-8")) > 128):
            raise QualificationError("invalid proof identity or request binding")
        relay_started = False
        stage_b_attempted = False
        relay = None
        try:
            relay_started = True
            relay = self.backend.start_relay()
            if (not isinstance(relay, dict) or set(relay) != {"host", "port", "ready"} or
                    relay["host"] != "127.0.0.1" or not _valid_port(relay["port"])):
                raise QualificationError("relay did not bind an allowed loopback listener")
            ready = relay["ready"]
            if (not isinstance(ready, dict) or set(ready) != READY_FIELDS or
                    ready.get("type") != "READY" or ready.get("provider_request_id") != request_id or
                    ready.get("listen_host") != "127.0.0.1" or ready.get("bound_port") != relay["port"]):
                raise QualificationError("relay READY does not match the frozen listener contract")
            try:
                stage_b_attempted = True
                self.backend.install_stage_b(pid, uid, relay["port"])
            except Exception:
                # Effective state, rather than installer status, decides whether Stage B succeeded.
                pass
            if self.backend.verify_stage_b(pid, uid, relay["port"]) is not True:
                raise QualificationError("Stage B effective policy verification failed")
            return ready
        except Exception as exc:
            cleanup_error = None
            if stage_b_attempted and isinstance(relay, dict) and _valid_port(relay.get("port")):
                try:
                    self.backend.revoke_stage_b(uid, relay["port"])
                except Exception as revoke_exc:
                    cleanup_error = revoke_exc
                try:
                    if self.backend.verify_deny_all() is not True:
                        cleanup_error = QualificationError("deny-all policy was not restored")
                except Exception as verify_exc:
                    cleanup_error = verify_exc
            elif relay_started:
                try:
                    if self.backend.verify_stage_a() is not True:
                        cleanup_error = QualificationError("Stage A deny policy was not verified")
                except Exception as verify_exc:
                    cleanup_error = verify_exc
            if relay_started:
                try:
                    self.backend.stop_relay()
                except Exception as stop_exc:
                    cleanup_error = stop_exc
            if cleanup_error is not None:
                raise QualificationError("Stage B failed and deny-all cleanup could not be verified") from cleanup_error
            if isinstance(exc, QualificationError):
                raise
            raise QualificationError("host qualification failed closed") from exc


def preflight(backend):
    """Install and independently verify Stage A before starting the BEAM."""
    for method in ("install_stage_a", "verify_stage_a", "start_relay", "install_stage_b",
                   "verify_stage_b", "revoke_stage_b", "verify_deny_all", "stop_relay"):
        if not callable(getattr(backend, method, None)):
            raise TypeError("backend does not implement the qualification lifecycle")
    try:
        backend.install_stage_a()
    except Exception:
        # The independent read below is authoritative even if the command status is ambiguous.
        pass
    if backend.verify_stage_a() is not True:
        raise QualificationError("Stage A effective deny policy verification failed")
    return HostQualificationSession(backend)
