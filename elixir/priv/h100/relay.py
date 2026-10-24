#!/usr/bin/env python3
"""Single-use, payload-blind CONNECT relay for local H100 qualification."""

import argparse
import errno
import hashlib
import json
import os
import queue
import select
import socket
import sys
import threading
import time
import re
from dataclasses import dataclass, field

MAX_CONNECT_BYTES = 8192
MAX_RECORD_LENGTH = 18432
MAX_REQUEST_ID_BYTES = 128
MAX_AUTHORITY_BYTES = 259
MAX_EVIDENCE_BYTES = 2048


class ProtocolError(Exception):
    pass


def valid_identity_values(request_id, authority):
    try:
        request_id_bytes = request_id.encode("ascii")
        authority_bytes = authority.encode("ascii")
    except (AttributeError, UnicodeEncodeError):
        return False
    return (0 < len(request_id_bytes) <= MAX_REQUEST_ID_BYTES and
            all(32 <= byte < 127 for byte in request_id_bytes) and
            0 < len(authority_bytes) <= MAX_AUTHORITY_BYTES and
            all(33 <= byte < 127 for byte in authority_bytes))


def serialize_evidence(evidence):
    encoded = json.dumps(evidence, sort_keys=True, separators=(",", ":")).encode("ascii") + b"\n"
    if len(encoded) > MAX_EVIDENCE_BYTES:
        raise ValueError("relay evidence exceeds fixed size limit")
    return encoded


@dataclass(frozen=True)
class Connect:
    request_id: str
    authority: str


@dataclass(frozen=True)
class Record:
    content_type: int
    version: bytes
    length: int
    wire: bytes


@dataclass(frozen=True)
class Decision:
    forward: bool
    close: bool = False
    evidence: dict = field(default_factory=dict)


def parse_connect(data, expected_request_id, expected_authority):
    if not isinstance(data, bytes) or len(data) > MAX_CONNECT_BYTES or not data.endswith(b"\r\n\r\n"):
        raise ProtocolError("invalid CONNECT framing")
    try:
        lines = data[:-4].decode("ascii").split("\r\n")
    except UnicodeDecodeError as exc:
        raise ProtocolError("non-ASCII CONNECT") from exc
    if not lines or lines[0] != f"CONNECT {expected_authority} HTTP/1.1":
        raise ProtocolError("wrong CONNECT request line")
    headers = {}
    for line in lines[1:]:
        if not line or line[0] in " \t" or ":" not in line:
            raise ProtocolError("malformed CONNECT header")
        name, value = line.split(":", 1)
        key = name.lower()
        if not name or any(c not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-" for c in name):
            raise ProtocolError("malformed header name")
        if any(ord(char) < 32 and char != "\t" or ord(char) == 127 for char in value):
            raise ProtocolError("control byte in CONNECT header value")
        headers.setdefault(key, []).append(value.strip())
    ids = headers.get("x-symphony-provider-request-id", [])
    hosts = headers.get("host", [])
    if len(ids) != 1 or ids[0] != expected_request_id:
        raise ProtocolError("request ID mismatch")
    if len(hosts) != 1 or hosts[0] != expected_authority:
        raise ProtocolError("authority mismatch")
    if any(k not in ("host", "x-symphony-provider-request-id", "user-agent", "proxy-connection") for k in headers):
        raise ProtocolError("unexpected CONNECT header")
    return Connect(ids[0], expected_authority)


def parse_record(data, max_length=MAX_RECORD_LENGTH):
    if not isinstance(data, bytes) or len(data) < 5:
        raise ProtocolError("truncated TLS record header")
    content_type, major, minor = data[0], data[1], data[2]
    length = int.from_bytes(data[3:5], "big")
    if content_type not in (20, 21, 22, 23) or major != 3 or minor not in (1, 2, 3, 4):
        raise ProtocolError("invalid TLS record header")
    if length > min(max_length, MAX_RECORD_LENGTH):
        raise ProtocolError("TLS record too large")
    if len(data) != length + 5:
        raise ProtocolError("truncated TLS record payload")
    return Record(content_type, data[1:3], length, data)


class RecordGate:
    def __init__(self, max_client_app_records=1):
        if max_client_app_records != 1:
            raise ValueError("the qualification gate permits exactly one client application record")
        self.client_app_records = 0
        self.server_app_seen = False

    def client(self, wire):
        record = parse_record(wire)
        if record.content_type == 23:
            self.client_app_records += 1
            if self.client_app_records > 1:
                raise ProtocolError("second client application-data record")
        return Decision(True, evidence={"client_record_type": record.content_type, "client_record_length": record.length})

    def server(self, wire):
        record = parse_record(wire)
        if record.content_type == 23:
            self.server_app_seen = True
            return Decision(False, True, {"server_app_record_length": record.length,
                                          "server_app_fragment_sha256": hashlib.sha256(wire[5:]).hexdigest()})
        return Decision(True, evidence={"server_record_type": record.content_type, "server_record_length": record.length})


def watchdog_expired(start, seconds, now=None):
    return (time.monotonic() if now is None else now) - start >= seconds


def _recv_exact(sock, count, deadline):
    chunks = bytearray()
    while len(chunks) < count:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise ProtocolError("watchdog expired")
        sock.settimeout(remaining)
        try:
            part = sock.recv(count - len(chunks))
        except socket.timeout as exc:
            raise ProtocolError("watchdog expired") from exc
        if not part:
            raise ProtocolError("truncated stream")
        chunks.extend(part)
    return bytes(chunks)


def _record_from_socket(sock, deadline, prefix=b""):
    def take(count):
        nonlocal prefix
        part = prefix[:count]
        prefix = prefix[len(part):]
        if len(part) < count:
            part += _recv_exact(sock, count - len(part), deadline)
        return part

    header = take(5)
    length = int.from_bytes(header[3:5], "big")
    if length > MAX_RECORD_LENGTH or header[0] not in (20, 21, 22, 23) or header[1] != 3 or header[2] not in (1, 2, 3, 4):
        raise ProtocolError("invalid TLS record")
    wire = header + take(length)
    return wire, prefix


def _read_connect(sock, deadline):
    data = bytearray()
    while b"\r\n\r\n" not in data:
        remaining = deadline - time.monotonic()
        if remaining <= 0 or len(data) >= MAX_CONNECT_BYTES:
            raise ProtocolError("CONNECT timeout or oversized headers")
        sock.settimeout(remaining)
        try:
            piece = sock.recv(min(1024, MAX_CONNECT_BYTES - len(data)))
        except socket.timeout as exc:
            raise ProtocolError("CONNECT timeout") from exc
        if not piece:
            raise ProtocolError("truncated CONNECT")
        data.extend(piece)
    end = data.index(b"\r\n\r\n") + 4
    return bytes(data[:end]), bytes(data[end:])


def _send_all(sock, data, deadline):
    sock.setblocking(False)
    view = memoryview(data)
    while view:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise ProtocolError("watchdog expired during write")
        _, writable, _ = select.select([], [sock], [], remaining)
        if not writable:
            raise ProtocolError("watchdog expired during write")
        try:
            sent = sock.send(view)
        except (BlockingIOError, InterruptedError):
            continue
        if sent <= 0:
            raise ProtocolError("socket closed during write")
        view = view[sent:]


def _send_record(sock, wire, deadline):
    _send_all(sock, wire, deadline)


def accept_one(listener, deadline):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise ProtocolError("watchdog expired before CONNECT")
    listener.settimeout(remaining)
    try:
        client, _ = listener.accept()
        return client
    except socket.timeout as exc:
        raise ProtocolError("watchdog expired before CONNECT") from exc


def connect_once(authority, deadline):
    host, separator, service = authority.rpartition(":")
    if not separator or not service.isdigit():
        raise ProtocolError("invalid configured authority")
    port = int(service)
    if time.monotonic() >= deadline:
        raise ProtocolError("watchdog expired before name resolution")
    resolved = queue.Queue(maxsize=1)

    def resolve():
        try:
            resolved.put((True, socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)))
        except OSError:
            resolved.put((False, None))

    threading.Thread(target=resolve, daemon=True).start()
    try:
        ok, addresses = resolved.get(timeout=max(0, deadline - time.monotonic()))
    except queue.Empty as exc:
        raise ProtocolError("watchdog expired during name resolution") from exc
    if not ok or not addresses:
        raise ProtocolError("configured authority resolution failed")

    family, socktype, proto, _, sockaddr = addresses[0]
    upstream = socket.socket(family, socktype, proto)
    try:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise ProtocolError("watchdog expired before upstream connect")
        upstream.setblocking(False)
        result = upstream.connect_ex(sockaddr)
        pending = (errno.EINPROGRESS, errno.EWOULDBLOCK, errno.EALREADY, errno.EINTR)
        if result and result not in pending:
            raise OSError(result, "upstream connect failed")
        if result:
            _, writable, _ = select.select([], [upstream], [], remaining)
            if not writable:
                raise ProtocolError("watchdog expired during upstream connect")
            error = upstream.getsockopt(socket.SOL_SOCKET, socket.SO_ERROR)
            if error:
                raise OSError(error, "upstream connect failed")
        return upstream
    except (OSError, ProtocolError):
        upstream.close()
        raise


def handle_client(client, upstream_factory, expected_request_id, expected_authority, watchdog=10,
                  evidence_sink=None, deadline=None):
    """Authorize one CONNECT before dialing; then forward complete TLS records only."""
    evidence = _new_evidence(expected_request_id, expected_authority)
    evidence["connect_count"] = 1
    upstream = None
    started = time.monotonic()
    deadline = started + watchdog if deadline is None else deadline
    stage = "connect"
    evidence["close_reason"] = "CONNECT_REJECTED"
    try:
        raw, pending = _read_connect(client, deadline)
        parsed = parse_connect(raw, expected_request_id, expected_authority)
        stage = "upstream"
        evidence["close_reason"] = "TRANSPORT_ERROR"
        upstream = upstream_factory(parsed.authority, deadline)
        evidence["upstream_connections"] = 1
        _send_all(client, b"HTTP/1.1 200 Connection Established\r\n\r\n", deadline)
        stage = "tunnel"
        evidence["close_reason"] = "WATCHDOG_EXPIRED"
        gate = RecordGate(1)
        client_prefix = pending
        while True:
            if client_prefix:
                source = client
            else:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise ProtocolError("watchdog expired")
                ready, _, _ = select.select([client, upstream], [], [], remaining)
                if not ready:
                    raise ProtocolError("watchdog expired")
                source = ready[0]
            prefix = client_prefix if source is client else b""
            wire, remainder = _record_from_socket(source, deadline, prefix)
            if source is client:
                client_prefix = remainder
            if source is client:
                decision = gate.client(wire)
                evidence["client_app_records"] += int(wire[0] == 23)
                _send_record(upstream, wire, deadline)
            else:
                decision = gate.server(wire)
                if decision.forward:
                    _send_record(client, wire, deadline)
                else:
                    evidence["server_app_suppressed"] = True
                    evidence["server_app_observed"] = True
                    evidence["server_app_forwarded"] = False
                    evidence["server_app_record_length"] = decision.evidence["server_app_record_length"]
                    evidence["server_app_fragment_sha256"] = decision.evidence["server_app_fragment_sha256"]
                    evidence["close_reason"] = "SERVER_APP_SUPPRESSED"
                    break
    except ProtocolError as exc:
        if "watchdog" in str(exc) or "timeout" in str(exc):
            evidence["close_reason"] = "WATCHDOG_EXPIRED"
        elif stage == "tunnel":
            evidence["close_reason"] = "PROTOCOL_ERROR"
        evidence["failed_closed"] = True
    except OSError:
        evidence["close_reason"] = "TRANSPORT_ERROR"
        evidence["failed_closed"] = True
    finally:
        for sock in (client, upstream):
            if sock is not None:
                try:
                    sock.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                try:
                    sock.close()
                except OSError:
                    pass
        if evidence_sink is not None:
            evidence_sink(evidence)
    return evidence


def _new_evidence(request_id, authority):
    return {"provider_request_id": request_id, "authority": authority,
            "connect_count": 0, "upstream_connections": 0, "client_app_records": 0,
            "server_app_suppressed": False, "server_app_observed": False,
            "server_app_forwarded": False, "close_reason": "WATCHDOG_EXPIRED"}


def _evidence_file(path, evidence):
    with open(path, "wb") as out:
        out.write(serialize_evidence(evidence))


def _environment_names():
    forbidden = re.compile(r"(_TOKEN|_SECRET|_API_KEY|PASSWORD)", re.IGNORECASE)
    names = []
    for name in sorted(os.environ):
        try:
            encoded = name.encode("ascii")
        except UnicodeEncodeError:
            continue
        if (not 1 <= len(encoded) <= 128 or forbidden.search(name) or
                name.upper() in {"SSH_AUTH_SOCK", "SSH_AGENT_PID", "GIT_ASKPASS"}):
            continue
        names.append(name)
        if len(names) == 64:
            break
    return names


def _ready_line(request_id, port):
    with open(__file__, "rb") as script:
        script_hash = hashlib.sha256(script.read()).hexdigest()
    ready = {"type": "READY", "provider_request_id": request_id,
             "listen_host": "127.0.0.1", "bound_port": port,
             "python_version": sys.version.split()[0],
             "script_blob_sha256": script_hash,
             "environment_names": _environment_names()}
    return json.dumps(ready, sort_keys=True, separators=(",", ":"))


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--bind", required=True)
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--request-id", required=True)
    parser.add_argument("--authority", required=True)
    parser.add_argument("--record-limit", required=True, type=int, choices=(1,))
    parser.add_argument("--watchdog", required=True, type=float)
    parser.add_argument("--evidence", required=True)
    args = parser.parse_args(argv)
    if args.bind != "127.0.0.1" or not (0 <= args.port <= 65535) or args.watchdog <= 0:
        parser.error("bind must be 127.0.0.1, port valid, and watchdog positive")
    if not valid_identity_values(args.request_id, args.authority):
        parser.error("request ID or authority exceeds its byte limit or contains invalid bytes")
    host, sep, port = args.authority.rpartition(":")
    if not sep or not host or not port.isdigit() or not 1 <= int(port) <= 65535:
        parser.error("authority must be a host:port")
    listener = socket.socket()
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 0)
    listener.bind((args.bind, args.port))
    listener.listen(1)
    deadline = time.monotonic() + args.watchdog
    print(_ready_line(args.request_id, listener.getsockname()[1]), flush=True)
    evidence = _new_evidence(args.request_id, args.authority)
    try:
        client = accept_one(listener, deadline)
    except ProtocolError:
        evidence["failed_closed"] = True
        evidence["close_reason"] = "WATCHDOG_EXPIRED"
        _evidence_file(args.evidence, evidence)
        return 1
    except OSError:
        evidence["failed_closed"] = True
        evidence["close_reason"] = "TRANSPORT_ERROR"
        _evidence_file(args.evidence, evidence)
        return 1
    finally:
        listener.close()
    def upstream_factory(authority, upstream_deadline):
        return connect_once(authority, upstream_deadline)
    result = handle_client(client, upstream_factory, args.request_id, args.authority, args.watchdog,
                           lambda ev: _evidence_file(args.evidence, ev), deadline=deadline)
    return 1 if result.get("failed_closed") else 0


if __name__ == "__main__":
    sys.exit(main())
