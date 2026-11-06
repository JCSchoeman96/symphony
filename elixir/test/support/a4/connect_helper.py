#!/usr/bin/env python3
"""Single-use loopback CONNECT relay for local TLS qualification fixtures."""

import hashlib
import json
import os
import select
import socket
import sys
import time

HEADER_LIMIT = 16384
RECORD_LIMIT = 18432
CONNECT_HEADER = b"x-symphony-provider-request-id"


def take_records(data):
    records = []
    offset = 0
    while len(data) - offset >= 5:
        content_type = data[offset]
        major, minor = data[offset + 1:offset + 3]
        size = int.from_bytes(data[offset + 3:offset + 5], "big")
        if content_type not in (20, 21, 22, 23) or major != 3 or minor not in (1, 2, 3) or size > RECORD_LIMIT:
            raise ValueError("UNEXPECTED_TLS_FRAMING")
        end = offset + 5 + size
        if len(data) < end:
            break
        records.append(data[offset:end])
        offset = end
    return records, data[offset:]


def emit(value):
    sys.stdout.write(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def manifest_read():
    raw_manifest = sys.stdin.buffer.read(65537)
    if len(raw_manifest) > 65536:
        raise ValueError("MANIFEST_TOO_LARGE")
    manifest = json.loads(raw_manifest)
    required = ("provider_request_id", "origin_authority", "origin_kind")
    if any(not isinstance(manifest.get(k), str) or not manifest[k] for k in required[:3]):
        raise ValueError("INVALID_MANIFEST")
    try:
        manifest["provider_request_id"].encode("ascii")
    except UnicodeEncodeError as exc:
        raise ValueError("INVALID_PROVIDER_REQUEST_ID") from exc
    origin_kind = manifest["origin_kind"]
    if origin_kind == "local_qualification":
        if not manifest["origin_authority"].startswith("127.0.0.1:"):
            raise ValueError("LIVE_ORIGIN_FORBIDDEN")
    elif origin_kind == "live_plane":
        if manifest["origin_authority"] != "api.plane.so:443":
            raise ValueError("LIVE_ORIGIN_FORBIDDEN")
    else:
        raise ValueError("INVALID_ORIGIN_KIND")
    mode = manifest.get("relay_mode", "suppression")
    if mode not in ("suppression", "forward_control") or (mode == "forward_control" and origin_kind != "local_qualification"):
        raise ValueError("INVALID_RELAY_MODE")
    watchdog = manifest.get("connect_watchdog_seconds", 30)
    if not isinstance(watchdog, (int, float)) or watchdog <= 0 or watchdog > 300:
        raise ValueError("INVALID_WATCHDOG")
    authority = manifest["origin_authority"]
    if ":" not in authority or authority.count(":") != 1:
        raise ValueError("INVALID_AUTHORITY")
    host, port_text = authority.rsplit(":", 1)
    try:
        port = int(port_text)
    except ValueError as exc:
        raise ValueError("INVALID_AUTHORITY") from exc
    if manifest["origin_kind"] == "local_qualification":
        if host != "127.0.0.1" or not 1 <= port <= 65535:
            raise ValueError("LIVE_ORIGIN_FORBIDDEN")
    elif host != "api.plane.so" or port != 443:
        raise ValueError("LIVE_ORIGIN_FORBIDDEN")
    return manifest, host, port


def read_connect(client, expected_id, authority):
    buf = bytearray()
    while b"\r\n\r\n" not in buf and len(buf) < HEADER_LIMIT:
        chunk = client.recv(min(4096, HEADER_LIMIT - len(buf)))
        if not chunk:
            raise ValueError("MALFORMED_CONNECT")
        buf.extend(chunk)
    if b"\r\n\r\n" not in buf:
        raise ValueError("MALFORMED_CONNECT")
    header, remainder = bytes(buf).split(b"\r\n\r\n", 1)
    lines = header.split(b"\r\n")
    if not lines or lines[0] != b"CONNECT " + authority.encode("ascii") + b" HTTP/1.1":
        raise ValueError("WRONG_AUTHORITY")
    vals = []
    for line in lines[1:]:
        if b":" not in line:
            raise ValueError("MALFORMED_CONNECT")
        name, value = line.split(b":", 1)
        if name.strip().lower() == CONNECT_HEADER:
            vals.append(value.strip())
    if len(vals) != 1 or vals[0] != expected_id.encode("ascii"):
        raise ValueError("REQUEST_ID_MISMATCH")
    return remainder


def close_quietly(sock):
    if sock is not None:
        try:
            sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            sock.close()
        except OSError:
            pass


def run():
    try:
        manifest, upstream_host, upstream_port = manifest_read()
    except Exception:
        return 2

    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    listener.settimeout(float(manifest.get("connect_watchdog_seconds", 30)))
    ready = {
        "type": "READY", "provider_request_id": manifest["provider_request_id"],
        "listen_host": "127.0.0.1", "bound_port": listener.getsockname()[1],
        "python_version": sys.version.split()[0],
        "script_blob_sha256": hashlib.sha256(open(__file__, "rb").read()).hexdigest(),
        "environment_names": sorted(os.environ.keys()),
    }
    emit(ready)
    client = upstream = None
    evidence = {"type": "CLOSED", "connect_count": 0, "upstream_connection_count": 0,
                "client_application_data_record_count": 0, "server_application_data_observed": False,
                "server_application_data_forwarded": False, "withheld_record_length": 0,
                "withheld_record_sha256": None, "close_reason": "WATCHDOG_EXPIRED"}
    try:
        try:
            client, _ = listener.accept()
        except socket.timeout:
            return 2
        evidence["connect_count"] = 1
        close_quietly(listener)
        listener = None
        client.settimeout(float(manifest.get("connect_watchdog_seconds", 30)))
        try:
            pending = read_connect(client, manifest["provider_request_id"], manifest["origin_authority"])
        except ValueError as exc:
            close_quietly(client)
            client = None
            close_quietly(listener)
            listener = None
            emit({"type": "REJECTED", "reason": str(exc)})
            return 2
        upstream = socket.create_connection((upstream_host, upstream_port), timeout=float(manifest.get("connect_watchdog_seconds", 30)))
        evidence["upstream_connection_count"] = 1
        client.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
        client.setblocking(False)
        upstream.setblocking(False)
        client_buf = bytearray(pending)
        server_buf = bytearray()
        client_app_count = 0
        dispatched = False
        client_record_seen = False
        while True:
            readable, _, _ = select.select([client, upstream], [], [], float(manifest.get("connect_watchdog_seconds", 30)))
            if not readable:
                evidence["close_reason"] = "TUNNEL_WATCHDOG_EXPIRED"
                break
            if client in readable:
                try:
                    chunk = client.recv(65536)
                except OSError:
                    chunk = b""
                if not chunk:
                    evidence["close_reason"] = "CLIENT_CLOSED"
                    break
                client_buf.extend(chunk)
                try:
                    records, remain = take_records(bytes(client_buf))
                except ValueError:
                    evidence["close_reason"] = "UNEXPECTED_TLS_FRAMING"
                    break
                client_buf = bytearray(remain)
                for record in records:
                    kind = record[0]
                    if not client_record_seen and kind not in (20, 22):
                        evidence["close_reason"] = "UNEXPECTED_FIRST_TLS_RECORD"
                        break
                    client_record_seen = True
                    if kind == 23:
                        client_app_count += 1
                        evidence["client_application_data_record_count"] = client_app_count
                        if client_app_count > 1:
                            evidence["close_reason"] = "INVALID_MULTI_RECORD_REQUEST"
                            break
                        dispatched = True
                    upstream.sendall(record)
                if evidence["close_reason"] in ("INVALID_MULTI_RECORD_REQUEST", "UNEXPECTED_FIRST_TLS_RECORD"):
                    break
            if upstream in readable:
                try:
                    chunk = upstream.recv(65536)
                except OSError:
                    chunk = b""
                if not chunk:
                    evidence["close_reason"] = "UPSTREAM_CLOSED"
                    break
                server_buf.extend(chunk)
                try:
                    records, remain = take_records(bytes(server_buf))
                except ValueError:
                    evidence["close_reason"] = "UNEXPECTED_TLS_FRAMING"
                    break
                server_buf = bytearray(remain)
                for record in records:
                    kind = record[0]
                    if kind == 23:
                        if client_app_count == 0:
                            evidence["close_reason"] = "SERVER_APP_DATA_BEFORE_DISPATCH"
                            break
                        evidence["server_application_data_observed"] = True
                        if manifest.get("relay_mode", "suppression") == "forward_control":
                            client.sendall(record)
                            evidence["server_application_data_forwarded"] = True
                            continue
                        evidence["withheld_record_length"] = len(record) - 5
                        evidence["withheld_record_sha256"] = hashlib.sha256(record[5:]).hexdigest()
                        evidence["close_reason"] = "RESPONSE_SUPPRESSED"
                        return_code = 0
                        break
                    if dispatched and kind in (21, 22):
                        evidence["close_reason"] = "UNEXPECTED_SERVER_CONTROL"
                        break
                    client.sendall(record)
                if evidence["close_reason"] in ("SERVER_APP_DATA_BEFORE_DISPATCH", "UNEXPECTED_SERVER_CONTROL", "RESPONSE_SUPPRESSED"):
                    break
            if evidence["close_reason"] == "RESPONSE_SUPPRESSED":
                break
    except (OSError, ValueError):
        evidence["close_reason"] = "TUNNEL_ERROR"
        return_code = 2
    else:
        return_code = 0 if evidence["close_reason"] in ("CLIENT_CLOSED", "RESPONSE_SUPPRESSED") else 2
    finally:
        close_quietly(client)
        close_quietly(upstream)
        close_quietly(listener)
        if evidence["type"] == "CLOSED":
            emit(evidence)
    return return_code


if __name__ == "__main__":
    raise SystemExit(run())
