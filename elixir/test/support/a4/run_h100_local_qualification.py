#!/usr/bin/env python3
"""Run the H100 proof only inside a disposable rootless network namespace."""

import argparse
import base64
import datetime
import hashlib
import importlib.util
import json
import os
import pathlib
import select
import signal
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import uuid
import re


MAX_IPC_BYTES = 16_384
EVIDENCE_SCHEMA_VERSION = 1
SYSTEM_PATH = "/usr/local/bin:/usr/bin:/bin"
PROOF_UID = 1201
RELAY_UID = 1202
ORIGIN_UID = 1203
SPEC_COMMIT = "5b3ecadeafa3c43ece8fe43099be56892d11d410"
IMPLEMENTATION_BASE = SPEC_COMMIT
EXPECTED_PATH = "/api/v1/workspaces/workspace/projects/project-1/work-items/work-1/"
LOCAL_SENTINEL = "local-qualification-only"
AUTHORIZATION_SENTINEL = "Bearer " + LOCAL_SENTINEL
POLICY_PATH_OVERRIDE = None


class QualificationFailure(RuntimeError):
    """A local qualification assertion failed."""


def _safe_failure_reason(value):
    if not isinstance(value, str):
        return None
    try:
        encoded = value.encode("ascii")
    except UnicodeEncodeError:
        return None
    if not 0 < len(encoded) <= 160 or any(byte < 32 or byte > 126 for byte in encoded):
        return None
    return value


def _safe_manifest_failure(reason):
    if reason == "manifest_request_shape":
        return reason
    prefix = "manifest_request_mismatch:"
    if isinstance(reason, str) and reason.startswith(prefix):
        fields = reason[len(prefix):].split(",")
        allowed = {
            "provider_request_id", "transition_attempt_id", "work_item_id", "workspace_id",
            "project_id", "target_state_id", "candidate_sha", "candidate_tree",
            "origin_base_url", "origin_authority", "method", "body_bytes", "path_bytes",
        }
        if fields and all(field in allowed for field in fields):
            return prefix + ",".join(fields)
    return "manifest_handler_failed"


def proof_stderr_category(stderr):
    """Classify startup diagnostics without returning their text or paths."""
    if not isinstance(stderr, bytes) or not stderr:
        return "no_stderr"
    value = stderr[:8192].lower()
    if b"failed to create scheduler thread" in value or b"could not start vm" in value:
        return "erlang_startup_error"
    if b"permission denied" in value:
        if b"_build" in value:
            return "permission_build_output"
        if b"proof-result" in value or b"proof_state" in value:
            return "permission_proof_result"
        if b"controller.sock" in value:
            return "permission_controller_socket"
        if b".mix" in value or b".hex" in value:
            return "permission_proof_home"
        if b"mix.exs" in value or b"/repo/" in value or b".exs" in value:
            return "permission_project_source"
        return "permission_error"
    if b"no such file or directory" in value:
        return "file_missing"
    if b"compileerror" in value or b"syntaxerror" in value:
        return "compile_error"
    if b"** (mix)" in value:
        if b"could not load" in value:
            return "mix_load_error"
        if b"could not compile" in value:
            return "mix_compile_error"
        if b"mix.project" in value or b"mix.exs" in value:
            return "mix_project_error"
        if b"dependency" in value or b"deps" in value:
            return "mix_dependency_error"
        if b"could not find" in value or b"no mix.project" in value:
            return "mix_component_not_found"
        return "mix_error"
    return "unclassified_stderr"


def proof_failure_detail(status_code, result, stderr=b""):
    """Summarize only allowlisted proof failures; never surface exception text."""
    if not isinstance(status_code, int) or isinstance(status_code, bool) or status_code == 0:
        return "unprivileged proof BEAM failed without a bounded result"
    if not isinstance(result, dict):
        category = proof_stderr_category(stderr)
        return (f"unprivileged proof BEAM exited with status {status_code} without a bounded result: "
                + category)

    if (set(result) == {"type", "reason", "error_class", "failure_code", "failure_site"} and
            result.get("type") == "PROOF_ERROR" and result.get("reason") == "proof_process_failed"):
        error_class = result.get("error_class")
        failure_code = result.get("failure_code")
        failure_site = result.get("failure_site")
        allowed_failure_codes = {
            "not_available", "a4_rejected", "invalid_proof_preflight",
            "controller_manifest_ipc_failed", "controller_manifest_response_invalid",
            "controller_ready_ipc_failed", "controller_ready_response_invalid",
            "invalid_proof_controller_capability", "remote_proof_controller",
            "proof_controller_unavailable", "proof_already_active",
            "persisted_attempt_envelope_mismatch", "mutation_not_persisted", "witness_required",
            "durable_proof_ledger_required", "invalid_origin", "proof_manifest_timeout",
            "proof_ready_timeout", "duplicate_or_unsolicited_controller_message",
            "proof_reply_receiver_failed", "wrong_controller_reference", "invalid_manifest_response",
            "manifest_schema", "manifest_experiment_scope", "manifest_provider_request_id",
            "manifest_transition_attempt_id", "manifest_work_item_id", "manifest_workspace_id",
            "manifest_project_id", "manifest_target_state_id", "manifest_method",
            "manifest_origin_base_url", "manifest_origin_authority", "manifest_candidate_sha",
            "manifest_candidate_tree", "manifest_relay_script_blob_sha256", "manifest_manifest_id",
            "manifest_operator_authorization_ref", "manifest_python_path", "manifest_python_version",
            "manifest_max_dispatch", "manifest_max_connect", "manifest_max_client_app_records",
            "manifest_tls_versions", "manifest_expires_at", "manifest_manifest_bytes",
            "manifest_shape", "manifest_canonical_or_hash", "manifest_canonical_json",
            "manifest_body_bytes", "manifest_path_bytes",
        }
        allowed_functions = {
            "run_proof", "capture_request", "patch_bounds", "ipc_ack", "attempt_persistence",
            "mutation_envelope", "controller_setup", "witness_gate", "canary_probe",
            "local_client_setup", "proof_result_check", "proof_runner",
        }
        if (not isinstance(failure_site, dict) or set(failure_site) != {"function", "line"} or
                failure_site.get("function") not in allowed_functions or
                not isinstance(failure_site.get("line"), int) or isinstance(failure_site.get("line"), bool) or
                not 0 <= failure_site["line"] <= 500 or failure_code not in allowed_failure_codes):
            return "proof BEAM failed with an invalid bounded result"
        location = f" at {failure_site['function']}:{failure_site['line']}"
        if failure_code != "not_available":
            return "proof BEAM failed " + failure_code + location
        if error_class in {"argument_error", "match_error", "function_clause", "case_clause",
                           "key_error", "runtime_error"}:
            return "proof BEAM raised " + error_class + location
        return "proof BEAM raised an unclassified exception" + location

    expected_fields = {
        "type", "failure_code", "provider_request_id", "manifest_finch_absent_before_ready",
        "finch_started_at_witness", "finch_stopped", "dispatch_witness_ack_count",
        "retry_count", "replay_count", "transport_result", "direct_ipv4_canary",
        "direct_ipv6_canary", "canary_policy_verified", "canary_drop_packets",
        "tls_verify_peer", "tls_hostname_verification", "shared_trust_unchanged",
    }
    if result.get("type") != "PROOF_RESULT" or set(result) != expected_fields:
        return "proof BEAM failed with an invalid bounded result"

    proof_failure_codes = {
        "unexpected_success", "transport_failure", "provider_unavailable", "dispatch_witness_failed",
        "controller_manifest_ipc_failed", "controller_manifest_response_invalid",
        "controller_ready_ipc_failed", "controller_ready_response_invalid",
        "witness_required", "request_fun_transport_not_supported", "invalid_proof_session",
        "proof_finch_start_failed", "proof_finch_already_started", "invalid_proof_tls_trust_context",
        "proof_ready_already_received",
        "proof_token_owner_mismatch",
        "proof_token_expired", "proof_controller_unavailable", "proof_ready_already_requested",
        "proof_token_consumed", "proof_token_binding_mismatch", "proof_token_not_ready",
        "proof_reply_receiver_failed", "duplicate_or_unsolicited_controller_message",
        "invalid_ready_response", "wrong_controller_reference", "proof_ready_timeout",
        "policy_not_verified", "controller_failed", "manifest_unavailable", "stage_b_not_verified",
        "request_identity_mismatch",
        "direct_egress_not_denied", "canary_probe_failed", "local_qualification_gate_failed",
        "sink_rejected", "sink_timeout", "sink_unavailable", "sink_exception",
        "econnrefused", "timeout", "closed",
    }
    manifest_failure_fields = {
        "schema", "experiment_scope", "provider_request_id", "transition_attempt_id", "work_item_id",
        "workspace_id", "project_id", "target_state_id", "method", "origin_base_url",
        "origin_authority", "candidate_sha", "candidate_tree", "relay_script_blob_sha256", "manifest_id",
        "operator_authorization_ref", "python_path", "python_version", "max_dispatch", "max_connect",
        "max_client_app_records", "tls_versions", "expires_at", "manifest_bytes", "shape",
        "canonical_or_hash", "canonical_json", "body_bytes", "path_bytes", "ready",
    }
    if not isinstance(result["failure_code"], str):
        return "proof BEAM failed with an invalid bounded result"
    if (result["failure_code"] not in proof_failure_codes and
            not any(result["failure_code"] == "proof_manifest_mismatch_" + field
                    for field in manifest_failure_fields)):
        return "proof BEAM failed with an invalid bounded result"
    if (not isinstance(result["dispatch_witness_ack_count"], int) or
            isinstance(result["dispatch_witness_ack_count"], bool) or
            result["dispatch_witness_ack_count"] not in (0, 1) or
            result["direct_ipv4_canary"] not in ("not_observed", "blocked", "reachable", "failed") or
            result["direct_ipv6_canary"] not in ("not_observed", "blocked", "reachable", "failed")):
        return "proof BEAM failed with an invalid bounded result"

    required = {
        "transport_result": "transport_failure",
        "finch_stopped": True,
        "dispatch_witness_ack_count": 1,
        "canary_policy_verified": True,
        "direct_ipv4_canary": "blocked",
        "direct_ipv6_canary": "blocked",
        "tls_verify_peer": True,
        "tls_hostname_verification": True,
        "shared_trust_unchanged": True,
    }
    failures = sorted(name for name, value in required.items() if result.get(name) != value)
    if failures:
        if result["failure_code"] not in {"transport_failure", "provider_unavailable"}:
            detail = "proof result rejected (" + result["failure_code"] + ")"
        else:
            detail = "proof result rejected: " + ",".join(failures)
        diagnostics = []
        if result["direct_ipv4_canary"] != "blocked":
            diagnostics.append("ipv4=" + result["direct_ipv4_canary"])
        if result["direct_ipv6_canary"] != "blocked":
            diagnostics.append("ipv6=" + result["direct_ipv6_canary"])
        if result["dispatch_witness_ack_count"] != 1:
            diagnostics.append("acks=" + str(result["dispatch_witness_ack_count"]))
        if diagnostics:
            detail += " [" + ",".join(diagnostics) + "]"
        return detail[:160]
    return "proof BEAM exited nonzero after an accepted bounded result"


def _read_bounded_proof_result(path):
    try:
        if path.stat().st_size > 4096:
            return None
        value = json.loads(path.read_text(encoding="ascii"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return None
    return value if isinstance(value, dict) else None


def runtime_path_for(*executables):
    """Return only the tool directories needed by the pinned Elixir runtime."""
    directories = []
    for executable in executables:
        if not isinstance(executable, str) or not executable.startswith("/") or "\x00" in executable:
            raise QualificationFailure("runtime executable path is invalid")
        directory = os.path.dirname(executable)
        if directory not in directories:
            directories.append(directory)
    runtime_path = os.pathsep.join(directories)
    if not runtime_path or len(runtime_path) > 2048:
        raise QualificationFailure("runtime executable path exceeds its bound")
    return runtime_path


def _valid_runtime_path(runtime_path):
    return (isinstance(runtime_path, str) and 0 < len(runtime_path) <= 2048 and
            all(part.startswith("/") and "\x00" not in part for part in runtime_path.split(os.pathsep)))


def runtime_mount_plan(mix_path, runtime_path, temp_root):
    """Map the exact Elixir and Erlang installs into namespace-readable paths."""
    if (not isinstance(mix_path, str) or not mix_path.startswith("/") or
            not _valid_runtime_path(runtime_path) or not isinstance(temp_root, str) or
            not temp_root.startswith("/")):
        raise QualificationFailure("runtime mount inputs are invalid")
    elixir_bin = pathlib.Path(mix_path).parent.resolve()
    if pathlib.Path(mix_path).name != "mix" or not (elixir_bin / "elixir").is_file():
        raise QualificationFailure("pinned Elixir runtime installation is incomplete")
    erlang_bins = [pathlib.Path(entry).resolve() for entry in runtime_path.split(os.pathsep)
                   if (pathlib.Path(entry) / "erl").is_file()]
    if len(erlang_bins) != 1:
        raise QualificationFailure("pinned Erlang runtime installation is ambiguous")

    mount_root = pathlib.Path(temp_root) / "runtime"
    elixir_destination = mount_root / "elixir"
    erlang_destination = mount_root / "erlang"
    return {
        "mounts": [
            {"source": str(elixir_bin.parent), "destination": str(elixir_destination)},
            {"source": str(erlang_bins[0].parent), "destination": str(erlang_destination)},
        ],
        "mix_path": str(elixir_destination / "bin/mix"),
        "elixir_path": str(elixir_destination / "bin/elixir"),
        "runtime_path": runtime_path_for(
            str(elixir_destination / "bin/mix"),
            str(elixir_destination / "bin/elixir"),
            str(erlang_destination / "bin/erl"),
        ),
    }


def proof_elixir_command(elixir_path, build_lib_path, script_path):
    """Launch the proof script with code paths pinned to this read-only build."""
    if any(not isinstance(value, str) or not value.startswith("/") or "\x00" in value
           for value in (elixir_path, build_lib_path, script_path)):
        raise QualificationFailure("proof BEAM command paths are invalid")
    build_lib = pathlib.Path(build_lib_path).resolve()
    try:
        code_paths = sorted(
            ebin.resolve()
            for app in build_lib.iterdir()
            if app.is_dir()
            for ebin in [app / "ebin"]
            if ebin.is_dir() and ebin.resolve().is_relative_to(build_lib)
        )
    except OSError as exc:
        raise QualificationFailure("proof build code paths are unavailable") from exc
    if (len(code_paths) > 128 or not any(path.parent.name == "symphony_elixir" for path in code_paths) or
            not any(path.parent.name == "finch" for path in code_paths)):
        raise QualificationFailure("proof build lacks the required pinned application paths")
    command = [elixir_path]
    for code_path in code_paths:
        command.extend(("-pa", str(code_path)))
    command.append(script_path)
    if sum(len(value) + 1 for value in command) > 65_536:
        raise QualificationFailure("proof BEAM command exceeds its fixed bound")
    return command


def child_environment(values, *, home, runtime_path=SYSTEM_PATH):
    """Build a clean child environment from fixed names and explicit values."""
    if (not isinstance(values, dict) or not isinstance(home, str) or not home.startswith("/") or
            not _valid_runtime_path(runtime_path)):
        raise QualificationFailure("invalid clean child environment")
    allowed = {
        "H100_QUAL_SOCKET", "H100_QUAL_CA_DER", "H100_QUAL_CANDIDATE_SHA",
        "H100_QUAL_CANDIDATE_TREE", "H100_QUAL_RELAY_SCRIPT", "H100_QUAL_ORIGIN_AUTHORITY",
        "H100_QUAL_ORIGIN_URL", "H100_QUAL_PROOF_STATE", "H100_QUAL_IPV4_CANARY_PORT",
        "H100_QUAL_IPV6_CANARY_PORT", "H100_QUAL_REQUEST_ID", "H100_QUAL_EXPECTED_PATH",
        "H100_QUAL_RESULT_FILE",
    }
    if set(values) - allowed:
        raise QualificationFailure("child environment contains an unapproved name")
    if any(not isinstance(name, str) or not isinstance(value, str) or "\x00" in value
           for name, value in values.items()):
        raise QualificationFailure("child environment contains an invalid value")
    return {"PATH": runtime_path + os.pathsep + SYSTEM_PATH,
            "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8", "HOME": home,
            "MIX_HOME": os.path.join(home, ".mix"), "HEX_HOME": os.path.join(home, ".hex"),
            "MIX_ENV": "test", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_TERMINAL_PROMPT": "0", **values}


def validate_origin_summary(raw, *, expected_path, expected_body_bytes, expected_body_sha256):
    """Validate the fixture's one complete PATCH and return payload-free fields."""
    if not isinstance(raw, str) or len(raw.encode("utf-8")) > MAX_IPC_BYTES:
        raise QualificationFailure("origin summary exceeds its fixed bound")
    try:
        summary = json.loads(raw)
    except (TypeError, json.JSONDecodeError) as exc:
        raise QualificationFailure("origin summary is malformed") from exc
    required = {"type", "request_count", "complete_request", "method", "path", "body_bytes",
                "body_sha256", "authorization_valid", "tls_version"}
    if not isinstance(summary, dict) or set(summary) != required:
        raise QualificationFailure("origin summary fields differ from the bounded fixture contract")
    if (summary["type"] != "LOCAL_TLS_RESULT" or summary["request_count"] != 1 or
            summary["complete_request"] is not True or summary["method"] != "PATCH" or
            summary["path"] != expected_path or summary["body_bytes"] != expected_body_bytes or
            summary["body_sha256"] != expected_body_sha256 or
            summary["authorization_valid"] is not True or summary["tls_version"] != "TLSv1.2"):
        raise QualificationFailure("local origin did not receive the exact bounded TLS 1.2 PATCH")
    return {"request_count": 1, "complete_request": True, "method": "PATCH",
            "tls_version": "TLSv1.2", "authorization_valid": True}


def peer_credentials(connection):
    """Read Linux SO_PEERCRED for an accepted local Unix-domain connection."""
    if not hasattr(socket, "SO_PEERCRED"):
        raise QualificationFailure("Linux Unix peer credentials are unavailable")
    raw = connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
    if len(raw) != struct.calcsize("3i"):
        raise QualificationFailure("Unix peer credentials are malformed")
    return struct.unpack("3i", raw)


def process_socket_inodes(pid):
    """Read the socket inode set owned by a live process from procfs."""
    result = set()
    try:
        entries = pathlib.Path(f"/proc/{pid}/fd").iterdir()
        for entry in entries:
            try:
                target = os.readlink(entry)
            except OSError:
                continue
            if target.startswith("socket:[") and target.endswith("]"):
                inode = target[8:-1]
                if inode.isdigit():
                    result.add(int(inode))
    except OSError as exc:
        raise QualificationFailure("cannot inspect relay socket ownership") from exc
    return result


def verify_relay_listener(tcp_table, tcp6_table, owned_inodes, expected_port):
    """Prove the relay owns exactly one IPv4 127.0.0.1 listening socket."""
    if not isinstance(owned_inodes, set) or not owned_inodes:
        raise QualificationFailure("relay has no inspectable socket descriptors")
    listeners = []
    for line in tcp_table.splitlines()[1:]:
        fields = line.split()
        if len(fields) < 10 or fields[3] != "0A":
            continue
        try:
            inode = int(fields[9])
            if inode not in owned_inodes:
                continue
            address_hex, port_hex = fields[1].split(":", 1)
            address = socket.inet_ntop(socket.AF_INET, struct.pack("<I", int(address_hex, 16)))
            port = int(port_hex, 16)
        except (ValueError, OSError, struct.error) as exc:
            raise QualificationFailure("relay IPv4 listener table is malformed") from exc
        listeners.append((address, port, inode))
    for line in tcp6_table.splitlines()[1:]:
        fields = line.split()
        if len(fields) >= 10 and fields[3] == "0A" and fields[9].isdigit() and int(fields[9]) in owned_inodes:
            raise QualificationFailure("relay owns an IPv6 listening socket")
    if len(listeners) != 1 or listeners[0][0] != "127.0.0.1" or listeners[0][1] != expected_port:
        raise QualificationFailure("relay listener is not exactly the verified loopback port")
    address, port, inode = listeners[0]
    return {"host": address, "port": port, "socket_inode": inode}


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise QualificationFailure("controller IPC contains duplicate fields")
        result[key] = value
    return result


def _safe_ipc_value(value):
    if isinstance(value, dict):
        for key, item in value.items():
            if not isinstance(key, str):
                return False
            lowered = key.lower()
            if (lowered in {"api_key", "authorization", "authorization_header", "body",
                            "request_body", "payload", "secret", "token", "tls_plaintext"} or
                    ("authorization" in lowered and lowered != "operator_authorization_ref")):
                return False
            if not _safe_ipc_value(item):
                return False
        return True
    if isinstance(value, list):
        return all(_safe_ipc_value(item) for item in value)
    return value is None or isinstance(value, (str, int, float, bool))


class ControllerIPCServer:
    """Serve bounded A4 launcher requests after binding them to one OS process."""

    def __init__(self, path, *, expected_uid, expected_pid, handler):
        self.path = pathlib.Path(path)
        self.expected_uid = expected_uid
        self.expected_pid = expected_pid
        self.handler = handler
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(str(self.path))
        os.chown(self.path, expected_uid, expected_uid)
        os.chmod(self.path, 0o600)
        self.listener.listen(8)
        self.listener.settimeout(0.2)
        self.stopping = threading.Event()
        self.identity_ready = threading.Event()
        if expected_pid > 0:
            self.identity_ready.set()
        self.thread = None
        self.last_error = None

    def start(self):
        if self.thread is not None:
            raise QualificationFailure("controller IPC server already started")
        self.thread = threading.Thread(target=self._serve, name="h100-controller-ipc", daemon=True)
        self.thread.start()

    def set_expected_pid(self, pid):
        if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0:
            raise QualificationFailure("proof PID binding is invalid")
        if self.identity_ready.is_set():
            if self.expected_pid != pid:
                raise QualificationFailure("proof PID binding cannot be changed")
            return
        self.expected_pid = pid
        self.identity_ready.set()

    def close(self):
        self.stopping.set()
        self.identity_ready.set()
        self.listener.close()
        if self.thread is not None:
            self.thread.join(2)
        self.path.unlink(missing_ok=True)
        if self.thread is not None and self.thread.is_alive():
            raise QualificationFailure("controller IPC server did not stop")

    def _serve(self):
        while not self.stopping.is_set():
            try:
                connection, _address = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                if self.stopping.is_set():
                    return
                self.last_error = "controller_listener_failed"
                return
            with connection:
                connection.settimeout(5)
                self._handle(connection)

    def _handle(self, connection):
        try:
            peer = peer_credentials(connection)
            if (not self.identity_ready.wait(3) or peer[0] != self.expected_pid or
                    peer[1] != self.expected_uid):
                response = {"error": "unauthorized_controller_peer"}
            else:
                raw = bytearray()
                while len(raw) <= MAX_IPC_BYTES:
                    part = connection.recv(min(4096, MAX_IPC_BYTES + 1 - len(raw)))
                    if not part:
                        raise QualificationFailure("controller IPC closed before a complete request")
                    raw.extend(part)
                    if b"\n" in part:
                        break
                if len(raw) > MAX_IPC_BYTES or not raw.endswith(b"\n") or raw.count(b"\n") != 1:
                    raise QualificationFailure("controller IPC request framing is invalid")
                request = json.loads(raw[:-1], object_pairs_hook=_unique_object)
                if (not isinstance(request, dict) or set(request) - {"op", "request"} or
                        not isinstance(request.get("op"), str) or not _safe_ipc_value(request)):
                    raise QualificationFailure("controller IPC request fields are invalid")
                response = self.handler(request, peer)
                if not isinstance(response, dict) or not _safe_ipc_value(response):
                    raise QualificationFailure("controller IPC response fields are invalid")
            encoded = json.dumps(response, sort_keys=True, separators=(",", ":")).encode("ascii") + b"\n"
            if len(encoded) > MAX_IPC_BYTES:
                raise QualificationFailure("controller IPC response exceeds its fixed bound")
            connection.sendall(encoded)
        except Exception:
            try:
                connection.sendall(b'{"error":"controller_operation_failed"}\n')
            except OSError:
                pass


class BoundedLineReader:
    """Read newline-delimited child status with a deadline and fixed bound."""

    def __init__(self, stream, maximum=MAX_IPC_BYTES):
        self.fd = stream.fileno()
        self.maximum = maximum
        self.buffer = bytearray()

    def read_line(self, timeout):
        deadline = time.monotonic() + timeout
        while b"\n" not in self.buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise QualificationFailure("qualification child status timed out")
            readable, _, _ = select.select([self.fd], [], [], remaining)
            if not readable:
                raise QualificationFailure("qualification child status timed out")
            chunk = os.read(self.fd, min(4096, self.maximum + 1 - len(self.buffer)))
            if not chunk:
                raise QualificationFailure("qualification child exited before status")
            self.buffer.extend(chunk)
            if len(self.buffer) > self.maximum:
                raise QualificationFailure("qualification child status exceeds its bound")
        index = self.buffer.index(b"\n")
        line = bytes(self.buffer[:index])
        del self.buffer[:index + 1]
        try:
            return line.decode("ascii")
        except UnicodeDecodeError as exc:
            raise QualificationFailure("qualification child status is not ASCII") from exc


def service_environment(home):
    """Return the minimal environment used by relay and TLS fixture processes."""
    if not isinstance(home, str) or not home.startswith("/"):
        raise QualificationFailure("service HOME must be an absolute path")
    return {"PATH": SYSTEM_PATH, "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8", "HOME": home}


def _run_bounded(command, *, env=None, timeout=5, input_data=None):
    try:
        result = subprocess.run(command, input=input_data, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, check=True, timeout=timeout, env=env)
        if len(result.stdout) > MAX_IPC_BYTES:
            raise QualificationFailure("local qualification command output exceeds its bound")
        return result.stdout
    except (OSError, subprocess.SubprocessError) as exc:
        raise QualificationFailure("local qualification command failed") from exc


def _process_identity(pid, expected_uid):
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        try:
            status = pathlib.Path(f"/proc/{pid}/status").read_text(encoding="ascii")
        except OSError:
            time.sleep(0.02)
            continue
        uid_line = next((line for line in status.splitlines() if line.startswith("Uid:")), None)
        cap_line = next((line for line in status.splitlines() if line.startswith("CapEff:")), None)
        if uid_line is None or cap_line is None:
            raise QualificationFailure("qualification process identity is incomplete")
        fields = uid_line.split()
        if len(fields) != 5:
            raise QualificationFailure("qualification process identity is incomplete")
        if int(fields[2]) != expected_uid:
            time.sleep(0.02)
            continue
        capabilities = int(cap_line.split()[1], 16)
        if capabilities != 0:
            time.sleep(0.02)
            continue
        try:
            identity = policy_module().read_process_identity(pid)
        except Exception:
            time.sleep(0.02)
            continue
        return {"pid": pid, "uid": expected_uid, "uid_map": identity["uid_map"],
                "netns_inode": identity["netns_inode"], "userns_inode": identity["userns_inode"],
                "cgroup": identity["cgroup"], "cap_eff": "0"}
    raise QualificationFailure("qualification process did not become inspectable")


def proof_process_identity(process):
    """Inspect the proof PID and report only its exit status if it exited early."""
    try:
        return _process_identity(process.pid, PROOF_UID)
    except QualificationFailure as exc:
        status = process.poll()
        if status is not None:
            raise QualificationFailure(f"proof BEAM exited before identity check with status {status}") from exc
        raise


def proof_launch_command(target):
    """Wait for the launcher gate, then exec the target without changing PID."""
    if (not isinstance(target, list) or not target or
            any(not isinstance(value, str) or not value or "\x00" in value for value in target) or
            not target[0].startswith("/")):
        raise QualificationFailure("proof launch target is invalid")
    gate = (
        "import os,sys\n"
        "target=sys.argv[1:]\n"
        "if not target or sys.stdin.buffer.readline(4) != b'GO\\n': sys.exit(1)\n"
        "os.execve(target[0], target, os.environ)\n"
    )
    return [sys.executable, "-I", "-c", gate, *target]


def _pid_socket_inodes(pid):
    return process_socket_inodes(pid)


def _relay_listener(pid, port):
    tcp = pathlib.Path("/proc/net/tcp").read_text(encoding="ascii")
    try:
        tcp6 = pathlib.Path("/proc/net/tcp6").read_text(encoding="ascii")
    except OSError:
        tcp6 = ""
    return verify_relay_listener(tcp, tcp6, _pid_socket_inodes(pid), port)


def _setpriv_command(uid, command):
    setpriv = shutil.which("setpriv")
    if setpriv is None:
        raise QualificationFailure("setpriv is required for unprivileged child identities")
    return [setpriv, "--bounding-set=-all", "--inh-caps=-all", "--ambient-caps=-all",
            f"--reuid={uid}", f"--regid={uid}", "--clear-groups", *command]


def _stop_process(process, *, timeout=3):
    if process is None or process.poll() is not None:
        return True
    if not isinstance(timeout, (int, float)) or timeout <= 0:
        raise QualificationFailure("process teardown timeout must be positive")
    try:
        os.killpg(process.pid, signal.SIGTERM)
        process.wait(timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        try:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=3)
        except (OSError, subprocess.TimeoutExpired):
            return False
    return process.poll() is not None


def _stop_failed_launch(process):
    try:
        if not _stop_process(process, timeout=10):
            raise QualificationFailure("child process did not stop after launcher setup failed")
    finally:
        if process.stdout is not None:
            process.stdout.close()


def _read_json_status(reader, timeout):
    try:
        value = json.loads(reader.read_line(timeout), object_pairs_hook=_unique_object)
    except (json.JSONDecodeError, QualificationFailure) as exc:
        raise QualificationFailure("qualification child status is invalid") from exc
    if not isinstance(value, dict):
        raise QualificationFailure("qualification child status is not an object")
    return value


def policy_module():
    """Load the independent policy verifier from the checked-out candidate."""
    path = POLICY_PATH_OVERRIDE or pathlib.Path(__file__).resolve().parents[3] / "priv/h100/policy_verify.py"
    spec = importlib.util.spec_from_file_location("h100_qualification_policy_verify", path)
    if spec is None or spec.loader is None:
        raise QualificationFailure("read-only policy verifier is unavailable")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _json_line(raw):
    try:
        value = json.loads(raw, object_pairs_hook=_unique_object)
    except (json.JSONDecodeError, QualificationFailure) as exc:
        raise QualificationFailure("local qualification status is malformed") from exc
    if not isinstance(value, dict):
        raise QualificationFailure("local qualification status is not an object")
    return value


def _canonical_json(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True)


def _valid_sha256(value):
    return isinstance(value, str) and len(value) == 64 and all(char in "0123456789abcdef" for char in value)


def _matches_schema_type(value, schema_type):
    if schema_type == "object":
        return isinstance(value, dict)
    if schema_type == "array":
        return isinstance(value, list)
    if schema_type == "string":
        return isinstance(value, str)
    if schema_type == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if schema_type == "boolean":
        return isinstance(value, bool)
    return False


def _validate_schema_value(value, schema, root):
    if not isinstance(schema, dict):
        raise QualificationFailure("qualification evidence schema is malformed")
    reference = schema.get("$ref")
    if reference is not None:
        prefix = "#/$defs/"
        if not isinstance(reference, str) or not reference.startswith(prefix):
            raise QualificationFailure("qualification evidence schema has an unsupported reference")
        definition = root.get("$defs", {}).get(reference[len(prefix):])
        if not isinstance(definition, dict):
            raise QualificationFailure("qualification evidence schema reference is missing")
        _validate_schema_value(value, definition, root)
        return
    if "const" in schema:
        constant = schema["const"]
        same_type = isinstance(value, bool) == isinstance(constant, bool)
        if not same_type or value != constant:
            raise QualificationFailure("qualification evidence does not match its versioned schema")
    schema_type = schema.get("type")
    if schema_type is not None and not _matches_schema_type(value, schema_type):
        raise QualificationFailure("qualification evidence does not match its versioned schema")
    if schema_type == "object":
        required = schema.get("required", [])
        properties = schema.get("properties", {})
        if (not isinstance(required, list) or not isinstance(properties, dict) or
                any(not isinstance(key, str) for key in required) or
                not set(required).issubset(value)):
            raise QualificationFailure("qualification evidence does not match its versioned schema")
        if schema.get("additionalProperties") is False and set(value) - set(properties):
            raise QualificationFailure("qualification evidence does not match its versioned schema")
        for key, item in value.items():
            if key in properties:
                _validate_schema_value(item, properties[key], root)
    elif schema_type == "array":
        if len(value) > schema.get("maxItems", len(value)):
            raise QualificationFailure("qualification evidence exceeds its schema bound")
        item_schema = schema.get("items")
        if item_schema is not None:
            for item in value:
                _validate_schema_value(item, item_schema, root)
    elif schema_type == "string":
        if len(value) < schema.get("minLength", 0) or len(value) > schema.get("maxLength", len(value)):
            raise QualificationFailure("qualification evidence exceeds its schema bound")
        pattern = schema.get("pattern")
        if pattern is not None and (not isinstance(pattern, str) or re.fullmatch(pattern, value) is None):
            raise QualificationFailure("qualification evidence does not match its versioned schema")
    elif schema_type == "integer":
        if ("minimum" in schema and value < schema["minimum"]) or (
                "maximum" in schema and value > schema["maximum"]):
            raise QualificationFailure("qualification evidence exceeds its schema bound")


def validate_qualification_result(result):
    """Validate final local evidence against its fixed, payload-free schema."""
    schema_path = pathlib.Path(__file__).resolve().parents[3] / "priv/h100/evidence_schema.json"
    try:
        schema = json.loads(schema_path.read_text(encoding="ascii"))
        _validate_schema_value(result, schema, schema)
        encoded = json.dumps(result, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode("ascii")
    except (OSError, UnicodeError, json.JSONDecodeError, TypeError, ValueError) as exc:
        raise QualificationFailure("qualification evidence is invalid") from exc
    if len(encoded) > MAX_IPC_BYTES:
        raise QualificationFailure("qualification evidence exceeds its fixed bound")
    return result


def _manifest_for(request, expected, *, head, tree, relay_hash, python_path, python_version):
    required = {
        "provider_request_id", "transition_attempt_id", "work_item_id", "workspace_id",
        "project_id", "target_state_id", "candidate_sha", "candidate_tree", "origin_base_url",
        "origin_authority", "method", "body_bytes", "path_bytes",
    }
    if not isinstance(request, dict) or set(request) != required:
        raise QualificationFailure("manifest_request_shape")
    checks = {
        "provider_request_id": request["provider_request_id"] == expected["provider_request_id"],
        "transition_attempt_id": request["transition_attempt_id"] == expected["transition_attempt_id"],
        "work_item_id": request["work_item_id"] == "work-1",
        "workspace_id": request["workspace_id"] == "workspace-1",
        "project_id": request["project_id"] == "project-1",
        "target_state_id": request["target_state_id"] == "state-1",
        "candidate_sha": request["candidate_sha"] == head,
        "candidate_tree": request["candidate_tree"] == tree,
        "origin_base_url": request["origin_base_url"] == expected["origin_url"],
        "origin_authority": request["origin_authority"] == expected["origin_authority"],
        "method": request["method"] == "PATCH",
        "body_bytes": request["body_bytes"] == expected["body_bytes"],
        "path_bytes": request["path_bytes"] == len(EXPECTED_PATH.encode()),
    }
    mismatches = sorted(name for name, matches in checks.items() if not matches)
    if mismatches:
        raise QualificationFailure("manifest_request_mismatch:" + ",".join(mismatches))
    manifest = {
        "schema": "a4-v2_1",
        "manifest_id": "local-qualification-" + request["provider_request_id"],
        "experiment_scope": "single_designated_state_patch",
        "provider_request_id": request["provider_request_id"],
        "transition_attempt_id": request["transition_attempt_id"],
        "work_item_id": "work-1",
        "workspace_id": "workspace-1",
        "project_id": "project-1",
        "target_state_id": "state-1",
        "method": "PATCH",
        "origin_kind": "local_qualification",
        "origin_authority": expected["origin_authority"],
        "origin_base_url": expected["origin_url"],
        "candidate_sha": head,
        "candidate_tree": tree,
        "relay_script_blob_sha256": relay_hash,
        "python_path": python_path,
        "python_version": python_version,
        "max_dispatch": 1,
        "max_connect": 1,
        "max_client_app_records": 1,
        "tls_versions": ["tlsv1.2"],
        "not_before": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "expires_at": (datetime.datetime.now(datetime.timezone.utc) +
                       datetime.timedelta(minutes=3)).isoformat(),
        "operator_authorization_ref": "local-test-only",
    }
    digest = hashlib.sha256(_canonical_json(manifest).encode("ascii")).hexdigest()
    full = {**manifest, "manifest_sha256": digest}
    return {"canonical_json": _canonical_json(full), "sha256": digest, "manifest": full}


def _read_status_line(stream, timeout=5):
    reader = BoundedLineReader(stream)
    return _read_json_status(reader, timeout)


def _nft_delete_if_present(policy):
    try:
        policy.remove_policy_table()
    except Exception:
        pass
    if policy.verify_policy_removed() is not True:
        raise QualificationFailure("temporary host policy could not be independently removed")


def _remove_generated_trust_material(ca_path, cert_directory):
    """Remove the per-qualification CA and fixture certificate/key directory."""
    if ca_path is not None:
        ca_path.unlink(missing_ok=True)
        if ca_path.exists() or ca_path.is_symlink():
            raise QualificationFailure("temporary trust file remains")

    if cert_directory is not None:
        if cert_directory.is_symlink():
            cert_directory.unlink()
        elif cert_directory.exists():
            shutil.rmtree(cert_directory)
        if cert_directory.exists() or cert_directory.is_symlink():
            raise QualificationFailure("generated certificate directory remains")

    return True


def _cleanup_preserving_failure(primary_failure, cleanup):
    try:
        cleanup()
    except QualificationFailure as cleanup_failure:
        if isinstance(primary_failure, QualificationFailure):
            primary_reason = _safe_failure_reason(str(primary_failure)) or "local_qualification_failed"
            cleanup_reason = _safe_failure_reason(str(cleanup_failure)) or "cleanup_failed"
            suffix = "; " + cleanup_reason
            primary_reason = primary_reason[:max(1, 160 - len(suffix))]
            raise QualificationFailure(primary_reason + suffix) from cleanup_failure
        if primary_failure is not None:
            raise cleanup_failure from primary_failure
        raise


def _cleanup_inside_resources(*, control_server, processes, canaries, ca_path,
                              cert_directory, policy, mount_path, mounted, temp_root,
                              runtime_mounts=()):
    """Attempt every teardown action and fail qualification if any cannot be verified."""
    failures = []

    def attempt(name, action):
        try:
            action()
        except Exception:
            failures.append(name)

    if control_server is not None:
        attempt("controller", control_server.close)

    for name, process in processes:
        if process is None:
            continue

        def stop_child(child=process):
            if not _stop_process(child, timeout=20):
                raise QualificationFailure("child process remained alive")

        attempt(name, stop_child)
        for stream_name in ("stdin", "stdout", "stderr"):
            stream = getattr(process, stream_name, None)
            if stream is not None and not stream.closed:
                attempt(name + "_pipe", stream.close)

    for index, canary in enumerate(canaries):
        if canary is not None:
            attempt("canary_" + str(index), canary.close)

    if ca_path is not None or cert_directory is not None:
        attempt("trust_material", lambda: _remove_generated_trust_material(ca_path, cert_directory))

    if policy is not None:
        attempt("policy", lambda: _nft_delete_if_present(policy))

    for index, runtime_mount in enumerate(reversed(runtime_mounts)):
        attempt("runtime_mount_" + str(index), lambda path=runtime_mount: _unmount_mount(path))

    if mounted:
        attempt("source_mount", lambda: _unmount_repo(mount_path))

    if temp_root is not None:
        def remove_temporary_root():
            if temp_root.is_symlink():
                temp_root.unlink()
            elif temp_root.exists():
                shutil.rmtree(temp_root)
            if temp_root.exists() or temp_root.is_symlink():
                raise QualificationFailure("qualification temporary root remains")

        attempt("temporary_root", remove_temporary_root)

    if failures:
        raise QualificationFailure("qualification cleanup failed: " + ",".join(failures))


def _set_owner(path, uid, mode):
    path.mkdir(parents=True, exist_ok=True)
    os.chown(path, uid, uid)
    os.chmod(path, mode)


def _bind_read_only_path(source_path, mount_path, *, unmount):
    source_path = pathlib.Path(source_path).resolve()
    mount_path = pathlib.Path(mount_path)
    mount_path.mkdir(parents=True, exist_ok=True)
    bound = False
    try:
        _run_bounded(["mount", "--bind", str(source_path), str(mount_path)], env=service_environment("/"))
        bound = True
        _run_bounded(["mount", "-o", "remount,bind,ro", str(mount_path)], env=service_environment("/"))
        mount_point = str(mount_path)
        for line in pathlib.Path("/proc/self/mountinfo").read_text(encoding="ascii").splitlines():
            fields = line.split()
            if len(fields) >= 6 and fields[4] == mount_point:
                if "ro" in fields[5].split(","):
                    return
                break
        raise QualificationFailure("qualification mount is not read-only")
    except BaseException:
        if bound:
            unmount(mount_path)
        raise


def _bind_repo_read_only(repo_root, mount_path):
    _bind_read_only_path(repo_root, mount_path, unmount=_unmount_repo)


def _bind_runtime_installations(plan):
    mounted = []
    try:
        for item in plan["mounts"]:
            destination = pathlib.Path(item["destination"])
            _bind_read_only_path(item["source"], destination, unmount=_unmount_mount)
            mounted.append(destination)
    except BaseException:
        for destination in reversed(mounted):
            _unmount_mount(destination)
        raise
    return mounted


def _start_canary(family, address):
    listener = socket.socket(family, socket.SOCK_STREAM)
    if family == socket.AF_INET6:
        listener.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
    listener.bind((address, 0))
    listener.listen(8)
    return listener, listener.getsockname()[1]


def _launch_origin(python_path, fixture_path, origin_home, expected_path):
    cert_directory = origin_home / "generated-certs"
    command = _setpriv_command(ORIGIN_UID, [python_path, "-I", str(fixture_path), "--serve",
                                            "--directory", str(cert_directory),
                                            "--expected-authorization", AUTHORIZATION_SENTINEL,
                                            "--expected-path", expected_path, "--timeout", "25"])
    process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, env=service_environment(str(origin_home)),
                               start_new_session=True, bufsize=0)
    try:
        identity = _process_identity(process.pid, ORIGIN_UID)
        reader = BoundedLineReader(process.stdout)
        ready = _read_json_status(reader, 8)
        if (ready.get("type") != "LOCAL_TLS_READY" or ready.get("host") != "127.0.0.1" or
                ready.get("server_hostname") != "127.0.0.1" or
                ready.get("authority") != f"127.0.0.1:{ready.get('port')}" or
                not isinstance(ready.get("port"), int) or not 1 <= ready["port"] <= 65535):
            raise QualificationFailure("local TLS origin did not bind its loopback listener")
        ca_der = base64.b64decode(ready["ca_der_base64"], validate=True)
    except (KeyError, ValueError) as exc:
        _stop_failed_launch(process)
        raise QualificationFailure("local TLS origin trust certificate is malformed") from exc
    except BaseException:
        _stop_failed_launch(process)
        raise
    if not 1 <= len(ca_der) <= 16_384:
        _stop_failed_launch(process)
        raise QualificationFailure("local TLS origin CA exceeds its fixed bound")
    return process, reader, identity, ready, ca_der, cert_directory


def _launch_relay(python_path, relay_path, relay_home, evidence_path, request_id, authority):
    command = _setpriv_command(RELAY_UID, [python_path, "-I", str(relay_path),
                                           "--bind", "127.0.0.1", "--port", "0",
                                           "--request-id", request_id, "--authority", authority,
                                           "--record-limit", "1", "--watchdog", "20",
                                           "--evidence", str(evidence_path)])
    process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, env=service_environment(str(relay_home)),
                               start_new_session=True, bufsize=0)
    try:
        identity = _process_identity(process.pid, RELAY_UID)
        ready = _read_status_line(process.stdout, 5)
        script_hash = hashlib.sha256(relay_path.read_bytes()).hexdigest()
        if (ready.get("type") != "READY" or ready.get("provider_request_id") != request_id or
                ready.get("listen_host") != "127.0.0.1" or ready.get("script_blob_sha256") != script_hash or
                not isinstance(ready.get("bound_port"), int) or not 1 <= ready["bound_port"] <= 65535):
            raise QualificationFailure("relay READY did not match the accepted one-use contract")
        listener = _relay_listener(process.pid, ready["bound_port"])
    except BaseException:
        _stop_failed_launch(process)
        raise
    return process, identity, {"host": listener["host"], "port": listener["port"], "ready": ready}, listener


def _outer_listener():
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 0)
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    port = listener.getsockname()[1]
    result = {"complete": False}

    def accept_control():
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            listener.settimeout(min(0.25, deadline - time.monotonic()))
            try:
                connection, _address = listener.accept()
                with connection:
                    message = connection.recv(128)
                    result["complete"] = message == b"h100-non-proof-control"
                    connection.sendall(b"ok" if result["complete"] else b"no")
                return
            except socket.timeout:
                continue
            except OSError:
                result["complete"] = False
                return

    thread = threading.Thread(target=accept_control, name="h100-outside-control", daemon=True)
    thread.start()
    return listener, port, result, thread


def _outside_control_exchange(port):
    code = ("import socket,sys; s=socket.create_connection(('127.0.0.1',int(sys.argv[1])),3); "
            "s.sendall(b'h100-non-proof-control'); result=s.recv(16); s.close(); "
            "raise SystemExit(0 if result==b'ok' else 1)")
    completed = subprocess.run([sys.executable, "-I", "-c", code, str(port)], check=False,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5,
                               env={"PATH": SYSTEM_PATH, "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8"})
    return completed.returncode == 0


def outer_main(repo_root):
    repo_root = pathlib.Path(repo_root).resolve()
    if not repo_root.is_dir():
        raise QualificationFailure("implementation repository is unavailable")
    status = _run_bounded(["git", "-C", str(repo_root), "status", "--porcelain"],
                          env={"PATH": SYSTEM_PATH, "LANG": "C.UTF-8", "GIT_CONFIG_GLOBAL": "/dev/null",
                               "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0"})
    if status.strip():
        raise QualificationFailure("local qualification requires a clean implementation worktree")
    head = _run_bounded(["git", "-C", str(repo_root), "rev-parse", "HEAD"],
                        env={"PATH": SYSTEM_PATH, "LANG": "C.UTF-8", "GIT_CONFIG_GLOBAL": "/dev/null",
                             "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0"}).decode().strip()
    tree = _run_bounded(["git", "-C", str(repo_root), "rev-parse", "HEAD^{tree}"],
                        env={"PATH": SYSTEM_PATH, "LANG": "C.UTF-8", "GIT_CONFIG_GLOBAL": "/dev/null",
                             "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0"}).decode().strip()
    base = _run_bounded(["git", "-C", str(repo_root), "merge-base", IMPLEMENTATION_BASE, "HEAD"],
                        env={"PATH": SYSTEM_PATH, "LANG": "C.UTF-8", "GIT_CONFIG_GLOBAL": "/dev/null",
                             "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0"}).decode().strip()
    if base != IMPLEMENTATION_BASE or len(head) != 40 or len(tree) != 40:
        raise QualificationFailure("candidate is not based on the accepted implementation base")
    unshare = shutil.which("unshare")
    if unshare is None:
        raise QualificationFailure("rootless user, network, and mount namespaces are required")
    mix_path = shutil.which("mix")
    elixir_path = shutil.which("elixir")
    erlang_path = shutil.which("erl")
    if mix_path is None or elixir_path is None or erlang_path is None:
        raise QualificationFailure("Mix and the Elixir/Erlang runtime are required")
    runtime_path = runtime_path_for(mix_path, elixir_path, erlang_path)

    temp_root = pathlib.Path(tempfile.mkdtemp(prefix="h100-local-qualification-"))
    listener, outside_port, outside_result, outside_thread = _outer_listener()
    process = None
    clean_env = {"PATH": SYSTEM_PATH, "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8",
                 "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
                 "GIT_TERMINAL_PROMPT": "0"}
    command = [unshare, "--user", "--map-auto", "--map-root-user", "--net", "--mount",
               "--propagation", "private", "--", sys.executable, "-I", str(pathlib.Path(__file__).resolve()),
               "--inside", "--repo-root", str(repo_root), "--temp-root", str(temp_root),
               "--head", head, "--tree", tree, "--request-id", "preq_" + str(uuid.uuid4()),
               "--mix-path", mix_path, "--runtime-path", runtime_path,
               "--outside-control-port", str(outside_port)]
    try:
        process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL, env=clean_env, start_new_session=True,
                                   bufsize=0)
        reader = BoundedLineReader(process.stdout, maximum=65_536)
        active_seen = False
        result = None
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            status_line = _read_json_status(reader, max(0.1, deadline - time.monotonic()))
            if status_line.get("type") == "STAGE_B_VERIFIED":
                if active_seen:
                    raise QualificationFailure("outside control window was requested more than once")
                active_seen = True
                outside_ok = _outside_control_exchange(outside_port)
                outside_thread.join(3)
                if not outside_ok or not outside_result["complete"]:
                    raise QualificationFailure("unrelated outside-namespace control exchange failed")
                process.stdin.write(b"CONTROL_OK\n")
                process.stdin.flush()
            elif status_line.get("type") == "QUALIFICATION_RESULT":
                result = status_line
                break
            elif status_line.get("type") == "QUALIFICATION_ERROR":
                reason = _safe_failure_reason(status_line.get("reason"))
                raise QualificationFailure(reason or "inner qualification failed")
            else:
                raise QualificationFailure("local qualification emitted an unexpected status")
        if result is None:
            raise QualificationFailure("local qualification exceeded its watchdog")
        status_code = process.wait(timeout=10)
        if status_code != 0 or result.get("qualified") is not True or not active_seen:
            raise QualificationFailure("local host relay qualification failed")
        result["evidence"]["non_proof_control_exchange"] = "passed"
        result["evidence"]["implementation_head_sha"] = head
        result["evidence"]["implementation_head_tree"] = tree
        result["evidence"]["implementation_base"] = IMPLEMENTATION_BASE
        result["evidence"]["spec_commit"] = SPEC_COMMIT
        result["schema_version"] = EVIDENCE_SCHEMA_VERSION
        return validate_qualification_result(result)
    finally:
        listener.close()
        cleanup_failures = []
        if process is not None:
            if process.poll() is None:
                if not _stop_process(process, timeout=20):
                    cleanup_failures.append("namespace_process")
            for stream in (process.stdin, process.stdout):
                if stream is not None:
                    try:
                        stream.close()
                    except OSError:
                        cleanup_failures.append("namespace_pipe")
        outside_thread.join(1)
        if outside_thread.is_alive():
            cleanup_failures.append("outside_control_listener")
        try:
            if temp_root.is_symlink():
                temp_root.unlink()
            elif temp_root.exists():
                shutil.rmtree(temp_root)
        except OSError:
            cleanup_failures.append("temporary_root")
        if temp_root.exists() or temp_root.is_symlink():
            cleanup_failures.append("temporary_root")
        if cleanup_failures:
            raise QualificationFailure("outer qualification cleanup failed: " + ",".join(cleanup_failures))


def _inside_main(repo_root, temp_root, head, tree, request_id, outside_control_port,
                 mix_path, runtime_path):
    global POLICY_PATH_OVERRIDE
    repo_root = pathlib.Path(repo_root).resolve()
    temp_root = pathlib.Path(temp_root).resolve()
    temp_root.mkdir(parents=True, exist_ok=True)
    os.chmod(temp_root, 0o711)
    mount_path = temp_root / "repo"
    mounted = False
    runtime_mounts = []
    policy = None
    session = None
    proof_process = None
    proof_stderr_file = None
    relay_process = None
    origin_process = None
    control_server = None
    canary4 = None
    canary6 = None
    ca_path = None
    cert_directory = None
    relay_home = temp_root / "relay"
    origin_home = temp_root / "origin"
    proof_home = temp_root / "proof-home"
    proof_state = temp_root / "proof-state"
    relay_evidence_path = temp_root / "relay-evidence" / "relay.json"
    result_path = proof_state / "proof-result.json"
    try:
        _bind_repo_read_only(repo_root, mount_path)
        mounted = True
        source_elixir = mount_path / "elixir"
        h100_directory = source_elixir / "priv/h100"
        fixture_path = h100_directory / "local_tls_fixture.py"
        relay_path = h100_directory / "relay.py"
        proof_runner_path = source_elixir / "test/support/a4/host_qualification_runner.exs"
        policy_path = h100_directory / "policy_verify.py"
        if not all(path.is_file() for path in (fixture_path, relay_path, proof_runner_path, policy_path)):
            raise QualificationFailure("local qualification source files are incomplete")
        POLICY_PATH_OVERRIDE = policy_path
        sys.path.insert(0, str(h100_directory))
        import host_qualification as host

        runtime_plan = runtime_mount_plan(mix_path, runtime_path, str(temp_root))
        runtime_mounts = _bind_runtime_installations(runtime_plan)

        _set_owner(relay_home, RELAY_UID, 0o700)
        _set_owner(origin_home, ORIGIN_UID, 0o700)
        _set_owner(proof_home, PROOF_UID, 0o700)
        _set_owner(proof_state, PROOF_UID, 0o700)
        relay_evidence_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chown(relay_evidence_path.parent, RELAY_UID, RELAY_UID)
        os.chmod(relay_evidence_path.parent, 0o700)
        if shutil.which("ip") is None:
            raise QualificationFailure("iproute2 is required for loopback qualification")
        _run_bounded(["ip", "link", "set", "lo", "up"], env=service_environment("/"))

        python_path = os.path.realpath(sys.executable)
        cert_directory = origin_home / "generated-certs"
        origin_process, origin_reader, origin_identity, origin_ready, ca_der, cert_directory = _launch_origin(
            python_path, fixture_path, origin_home, EXPECTED_PATH
        )
        origin_authority = origin_ready["authority"]
        origin_url = "https://" + origin_authority
        ca_path = proof_home / "fixture-ca.der"
        ca_path.write_bytes(ca_der)
        os.chown(ca_path, PROOF_UID, PROOF_UID)
        os.chmod(ca_path, 0o400)

        canary4, ipv4_port = _start_canary(socket.AF_INET, "127.0.0.1")
        canary6, ipv6_port = _start_canary(socket.AF_INET6, "::1")
        relay_identity = {}
        relay_ready = {}
        relay_listener = {}

        def start_relay():
            nonlocal relay_process, relay_identity, relay_ready, relay_listener
            relay_process, relay_identity, relay_ready, relay_listener = _launch_relay(
                python_path, relay_path, relay_home, relay_evidence_path, request_id, origin_authority
            )
            return relay_ready

        def stop_relay():
            return _stop_process(relay_process)

        policy = host.LinuxPolicyBackend(proof_uid=PROOF_UID, relay_uid=RELAY_UID,
                                         fixture_port=origin_ready["port"],
                                         relay_start=start_relay, relay_stop=stop_relay)
        session = host.preflight(policy)
        stage_a = policy.last_stage_a_evidence
        if (not isinstance(stage_a, dict) or stage_a.get("stage") != "A" or
                stage_a.get("proof_drop") is not True or stage_a.get("proof_allow") is not None):
            raise QualificationFailure("pre-spawn deny-all policy was not independently verified")

        socket_path = temp_root / "controller.sock"
        expected = {"provider_request_id": request_id, "origin_authority": origin_authority,
                    "origin_url": origin_url, "transition_attempt_id": None,
                    "path": None, "body_bytes": None, "body_sha256": None}
        state = {"manifest": None, "manifest_seen": False, "manifest_failure": None, "ready": None,
                 "egress": None, "control_passed": False}

        def handler(message, peer):
            operation = message["op"]
            if operation == "stage_a":
                return {"verified": stage_a.get("stage") == "A" and stage_a.get("proof_drop") is True}
            if operation == "origin_expect":
                request = message.get("request")
                required = {"provider_request_id", "transition_attempt_id", "method", "path",
                            "body_bytes", "body_sha256"}
                if (not isinstance(request, dict) or set(request) != required or
                        request.get("provider_request_id") != request_id or request.get("method") != "PATCH" or
                        request.get("path") != EXPECTED_PATH or
                        not isinstance(request.get("transition_attempt_id"), str) or
                        not 1 <= request.get("body_bytes", 0) <= 512 or
                        not _valid_sha256(request.get("body_sha256"))):
                    raise QualificationFailure("captured local request does not match the fixed PATCH contract")
                expected.update({"transition_attempt_id": request["transition_attempt_id"],
                                 "path": request["path"], "body_bytes": request["body_bytes"],
                                 "body_sha256": request["body_sha256"]})
                return {"verified": True}
            if operation == "manifest":
                state["manifest_seen"] = True
                if expected["path"] is None:
                    state["manifest_failure"] = "manifest_before_capture"
                    raise QualificationFailure("manifest arrived before the captured request")
                payload = message.get("request")
                try:
                    response = _manifest_for(payload, expected, head=head, tree=tree,
                                             relay_hash=hashlib.sha256(relay_path.read_bytes()).hexdigest(),
                                             python_path=python_path, python_version=sys.version.split()[0])
                except QualificationFailure as error:
                    state["manifest_failure"] = _safe_manifest_failure(str(error))
                    raise
                except Exception:
                    state["manifest_failure"] = "manifest_handler_failed"
                    raise
                state["manifest"] = response
                return response
            if operation == "ready":
                request = message.get("request")
                if (state["manifest"] is None or not isinstance(request, dict) or
                        set(request) != {"provider_request_id", "relay_script_blob_sha256"} or
                        request.get("provider_request_id") != request_id or
                        request.get("relay_script_blob_sha256") != state["manifest"]["manifest"]["relay_script_blob_sha256"]):
                    raise QualificationFailure("A4 READY request differs from the accepted manifest")
                ready = session.ready(pid=peer[0], uid=peer[1], request_id=request_id)
                if policy.last_stage_b_evidence is None:
                    raise QualificationFailure("Stage B verifier did not produce live evidence")
                state["ready"] = ready
                _write_status({"type": "STAGE_B_VERIFIED", "proof_pid": peer[0], "relay_port": ready["bound_port"]})
                if sys.stdin.readline(64) != "CONTROL_OK\n":
                    raise QualificationFailure("outside control exchange was not acknowledged")
                state["control_passed"] = True
                return {"verified": True, "ready": ready}
            if operation == "canaries":
                request = message.get("request")
                if (state["ready"] is None or not isinstance(request, dict) or
                        request.get("provider_request_id") != request_id or
                        request.get("ipv4") != "blocked" or request.get("ipv6") != "blocked"):
                    raise QualificationFailure("direct egress canaries were reachable or malformed")
                if policy.verify_stage_b(peer[0], peer[1], state["ready"]["bound_port"]) is not True:
                    raise QualificationFailure("exact-port policy no longer matches the live proof process")
                evidence = policy.last_stage_b_evidence
                if evidence.get("proof_drop_packets", 0) < 2:
                    raise QualificationFailure("IPv4 and IPv6 canary drops lack effective rule counters")
                state["egress"] = evidence
                return {"verified": True, "proof_drop_packets": evidence["proof_drop_packets"],
                        "proof_drop_rule_handle": evidence["proof_drop_rule_handle"]}
            raise QualificationFailure("controller IPC operation is not recognized")

        control_server = ControllerIPCServer(socket_path, expected_uid=PROOF_UID, expected_pid=0,
                                             handler=handler)
        result_values = {
            "H100_QUAL_SOCKET": str(socket_path),
            "H100_QUAL_CA_DER": str(ca_path),
            "H100_QUAL_CANDIDATE_SHA": head,
            "H100_QUAL_CANDIDATE_TREE": tree,
            "H100_QUAL_RELAY_SCRIPT": str(relay_path),
            "H100_QUAL_ORIGIN_AUTHORITY": origin_authority,
            "H100_QUAL_ORIGIN_URL": origin_url,
            "H100_QUAL_PROOF_STATE": str(proof_state),
            "H100_QUAL_IPV4_CANARY_PORT": str(ipv4_port),
            "H100_QUAL_IPV6_CANARY_PORT": str(ipv6_port),
            "H100_QUAL_REQUEST_ID": request_id,
            "H100_QUAL_EXPECTED_PATH": EXPECTED_PATH,
            "H100_QUAL_RESULT_FILE": str(result_path),
        }
        proof_environment = child_environment(
            result_values, home=str(proof_home), runtime_path=runtime_plan["runtime_path"]
        )
        target = proof_elixir_command(
            runtime_plan["elixir_path"], str(source_elixir / "_build/test/lib"), str(proof_runner_path)
        )
        proof_command = _setpriv_command(PROOF_UID, proof_launch_command(target))
        control_server.start()
        proof_stderr_file = tempfile.TemporaryFile()
        proof_process = subprocess.Popen(proof_command, cwd=str(source_elixir), stdin=subprocess.PIPE,
                                         stdout=subprocess.DEVNULL, stderr=proof_stderr_file,
                                         env=proof_environment, start_new_session=True)
        control_server.set_expected_pid(proof_process.pid)
        proof_identity = proof_process_identity(proof_process)
        proof_process.stdin.write(b"GO\n")
        proof_process.stdin.flush()
        proof_process.stdin.close()
        status_code = proof_process.wait(timeout=55)
        proof_result = _read_bounded_proof_result(result_path)
        if status_code != 0 or proof_result is None:
            proof_stderr_file.seek(0)
            failure_detail = proof_failure_detail(status_code, proof_result, proof_stderr_file.read(8192))
            if state["manifest_failure"] is not None:
                failure_detail += ": " + state["manifest_failure"]
            elif proof_result and proof_result.get("failure_code", "").startswith("controller_manifest_"):
                if state["manifest"] is not None:
                    failure_detail += ": manifest_built_by_host"
                elif state["manifest_seen"]:
                    failure_detail += ": manifest_handler_did_not_complete"
                else:
                    failure_detail += ": manifest_handler_not_reached"
            raise QualificationFailure(
                failure_detail
            )
        if proof_result.get("type") != "PROOF_RESULT":
            raise QualificationFailure("proof BEAM did not produce a bounded result")
        origin_summary = _read_json_status(origin_reader, 8)
        origin_status = origin_process.wait(timeout=5)
        origin_safe = validate_origin_summary(json.dumps(origin_summary, separators=(",", ":")),
                                              expected_path=expected["path"],
                                              expected_body_bytes=expected["body_bytes"],
                                              expected_body_sha256=expected["body_sha256"])
        if origin_status != 0 or not origin_safe["complete_request"]:
            raise QualificationFailure("local TLS origin did not receive one complete request")
        relay_status = relay_process.wait(timeout=10)
        relay_raw = relay_evidence_path.read_bytes()
        if len(relay_raw) > 2048:
            raise QualificationFailure("relay evidence exceeds its fixed bound")
        relay_evidence = _json_line(relay_raw.decode("ascii"))
        if (relay_status != 0 or relay_evidence.get("provider_request_id") != request_id or
                relay_evidence.get("authority") != origin_authority or relay_evidence.get("connect_count") != 1 or
                relay_evidence.get("upstream_connections") != 1 or relay_evidence.get("client_app_records") != 1 or
                relay_evidence.get("server_app_observed") is not True or
                relay_evidence.get("server_app_forwarded") is not False or
                relay_evidence.get("server_app_suppressed") is not True or
                relay_evidence.get("close_reason") != "SERVER_APP_SUPPRESSED" or
                not _valid_sha256(relay_evidence.get("server_app_fragment_sha256"))):
            raise QualificationFailure("relay evidence does not prove the exact one-use suppression")
        if (proof_result.get("provider_request_id") != request_id or
                proof_result.get("transport_result") != "transport_failure" or
                proof_result.get("dispatch_witness_ack_count") != 1 or
                proof_result.get("retry_count") != 0 or proof_result.get("replay_count") != 0 or
                proof_result.get("finch_started_at_witness") is not True or
                proof_result.get("finch_stopped") is not True or not state["control_passed"] or
                not isinstance(state["egress"], dict)):
            raise QualificationFailure("proof BEAM result does not match the witnessed transport outcome")

        if control_server is not None:
            control_server.close()
            control_server = None
        if proof_process.poll() is None:
            raise QualificationFailure("proof BEAM process did not stop after the one-use request")
        if not _stop_process(relay_process) or not _stop_process(origin_process):
            raise QualificationFailure("local relay or TLS origin did not stop")

        policy.revoke_stage_b(PROOF_UID, state["ready"]["bound_port"])
        deny_all = policy.verify_deny_all()
        if deny_all is not True:
            raise QualificationFailure("deny-all policy was not restored after qualification")
        relay_stopped = policy.stop_relay()
        if relay_stopped is not True:
            raise QualificationFailure("relay teardown failed")
        _nft_delete_if_present(policy)

        trust_material_removed = _remove_generated_trust_material(ca_path, cert_directory)
        if not trust_material_removed:
            raise QualificationFailure("generated local TLS trust material remains on disk")
        canary4.close()
        canary6.close()
        canary4 = canary6 = None
        if control_server is not None:
            raise QualificationFailure("controller IPC socket remains open")

        ready = state["ready"]
        stage_b = policy.last_stage_b_evidence
        evidence = {
            "policy_mechanism": "temporary nftables table in disposable rootless user/network/mount namespaces",
            "policy_scope": {"proof_uid": PROOF_UID, "relay_uid": RELAY_UID, "origin_uid": ORIGIN_UID,
                             "netns_inode": stage_b["netns_inode"], "userns_inode": stage_b["userns_inode"],
                             "proof_cgroup": stage_b["cgroup"], "proof_uid_map": stage_b["proof_uid_map"]},
            "pre_spawn_deny_all_verified": stage_a["proof_drop"],
            "pre_spawn_deny_rule_handle": stage_a["proof_drop_rule_handle"],
            "proof_identity": proof_identity,
            "relay_identity": relay_identity,
            "relay_bound_host": relay_listener["host"],
            "relay_bound_port": relay_listener["port"],
            "relay_listener_socket_inode": relay_listener["socket_inode"],
            "second_exact_port_policy_verified": stage_b["proof_allow"]["port"] == ready["bound_port"],
            "stage_b_allow_rule_handle": stage_b["proof_allow"]["rule_handle"],
            "stage_b_deny_rule_handle": stage_b["proof_drop_rule_handle"],
            "manifest_sha256": state["manifest"]["sha256"],
            "relay_script_sha256": ready["script_blob_sha256"],
            "provider_request_id": request_id,
            "connect_count": relay_evidence["connect_count"],
            "upstream_connection_count": relay_evidence["upstream_connections"],
            "client_application_data_record_count": relay_evidence["client_app_records"],
            "origin_request_count": origin_safe["request_count"],
            "complete_request": origin_safe["complete_request"],
            "server_application_data_observed": relay_evidence["server_app_observed"],
            "server_application_data_forwarded": relay_evidence["server_app_forwarded"],
            "suppressed_encrypted_record_length": relay_evidence["server_app_record_length"],
            "suppressed_encrypted_record_sha256": relay_evidence["server_app_fragment_sha256"],
            "finch_result": proof_result["transport_result"],
            "retry_count": proof_result["retry_count"],
            "replay_count": proof_result["replay_count"],
            "ipv4_egress_canary": proof_result["direct_ipv4_canary"],
            "ipv6_egress_canary": proof_result["direct_ipv6_canary"],
            "proof_drop_packets_after_canaries": proof_result["canary_drop_packets"],
            "unrelated_control_exchange": "passed",
            "tls_version": origin_safe["tls_version"],
            "tls_verify_peer": proof_result["tls_verify_peer"],
            "tls_hostname_verification": proof_result["tls_hostname_verification"],
            "shared_trust_unchanged": proof_result["shared_trust_unchanged"],
            "trust_material_removed": trust_material_removed,
            "policy_deny_all_restored": deny_all,
            "policy_table_removed_and_verified": True,
            "proof_process_stopped": proof_process.poll() is not None,
            "relay_process_stopped": relay_process.poll() is not None,
            "origin_process_stopped": origin_process.poll() is not None,
            "controller_socket_removed": not socket_path.exists(),
            "manifest_finch_absent_before_ready": proof_result["manifest_finch_absent_before_ready"],
            "finch_started_after_ready_validation": proof_result["finch_started_at_witness"],
            "ready_withheld_until_stage_b_verified": state["control_passed"] and
                stage_b["pid"] == proof_identity["pid"] and stage_b["proof_allow"]["port"] == ready["bound_port"],
        }
        _unmount_repo(mount_path)
        mounted = False
        return {"type": "QUALIFICATION_RESULT", "qualified": True, "evidence": evidence}
    finally:
        primary_failure = sys.exception()
        try:
            _cleanup_preserving_failure(
                primary_failure,
                lambda: _cleanup_inside_resources(
                    control_server=control_server,
                    processes=(("proof_process", proof_process), ("relay_process", relay_process),
                               ("origin_process", origin_process)),
                    canaries=(canary4, canary6), ca_path=ca_path,
                    cert_directory=cert_directory, policy=policy,
                    mount_path=mount_path, mounted=mounted, temp_root=temp_root,
                    runtime_mounts=runtime_mounts,
                ),
            )
        finally:
            if proof_stderr_file is not None:
                proof_stderr_file.close()


def _unmount_mount(mount_path):
    completed = subprocess.run(["umount", str(mount_path)], check=False,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                               timeout=3, env=service_environment("/"))
    if completed.returncode != 0:
        raise QualificationFailure("read-only qualification mount could not be removed")


def _unmount_repo(mount_path):
    _unmount_mount(mount_path)


def _write_status(value):
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":"))
    if len(encoded.encode("ascii")) > MAX_IPC_BYTES:
        raise QualificationFailure("launcher status exceeds its fixed bound")
    sys.stdout.write(encoded + "\n")
    sys.stdout.flush()


def _interrupt_local_qualification(signum, _frame):
    if signum == signal.SIGTERM:
        raise QualificationFailure("local qualification was asked to stop")


def main(argv=None):
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--inside", action="store_true")
    parser.add_argument("--repo-root", required=True)
    parser.add_argument("--temp-root")
    parser.add_argument("--head")
    parser.add_argument("--tree")
    parser.add_argument("--request-id")
    parser.add_argument("--mix-path")
    parser.add_argument("--runtime-path")
    parser.add_argument("--outside-control-port", type=int)
    args = parser.parse_args(argv)
    try:
        if not args.inside:
            result = outer_main(args.repo_root)
            _write_status(result)
            return 0
        if (not _valid_sha(args.head) or not _valid_sha(args.tree) or
                not isinstance(args.temp_root, str) or not args.temp_root.startswith("/") or
                "\x00" in args.temp_root or
                not isinstance(args.mix_path, str) or not args.mix_path.startswith("/") or
                "\x00" in args.mix_path or not _valid_runtime_path(args.runtime_path) or
                not isinstance(args.request_id, str) or not args.request_id.startswith("preq_") or
                not 1 <= len(args.request_id) <= 128 or
                not isinstance(args.outside_control_port, int) or not 1 <= args.outside_control_port <= 65535):
            raise QualificationFailure("inner namespace launch parameters are invalid")
        previous_sigterm = signal.signal(signal.SIGTERM, _interrupt_local_qualification)
        try:
            result = _inside_main(args.repo_root, args.temp_root, args.head, args.tree,
                                  args.request_id, args.outside_control_port,
                                  args.mix_path, args.runtime_path)
        finally:
            signal.signal(signal.SIGTERM, previous_sigterm)
        _write_status(result)
        return 0
    except QualificationFailure as exc:
        reason = _safe_failure_reason(str(exc)) or "local_qualification_failed"
        _write_status({"type": "QUALIFICATION_ERROR", "reason": reason})
        return 1
    except Exception:
        _write_status({"type": "QUALIFICATION_ERROR", "reason": "local_qualification_failed"})
        return 1


def _valid_sha(value):
    return isinstance(value, str) and len(value) == 40 and all(char in "0123456789abcdef" for char in value)


if __name__ == "__main__":
    raise SystemExit(main())
