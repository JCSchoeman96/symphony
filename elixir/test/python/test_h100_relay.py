import importlib.util
import hashlib
import errno
import json
import os
import pathlib
import select
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

MODULE = pathlib.Path(__file__).parents[2] / "priv/h100/relay.py"
spec = importlib.util.spec_from_file_location("h100_relay", MODULE)
relay = importlib.util.module_from_spec(spec)
spec.loader.exec_module(relay)


class ConnectParserTests(unittest.TestCase):
    def parse(self, request):
        return relay.parse_connect(request, "req-123", "fixture.test:443")

    def test_accepts_exact_connect_and_single_request_id(self):
        parsed = self.parse(b"CONNECT fixture.test:443 HTTP/1.1\r\nHost: fixture.test:443\r\nx-symphony-provider-request-id: req-123\r\n\r\n")
        self.assertEqual(parsed.authority, "fixture.test:443")

    def test_control_bytes_in_allowed_header_values_reject_before_upstream(self):
        for control in (b"\n", b"\r", b"\x00", b"\x7f"):
            with self.subTest(control=control):
                client, relay_client = socket.socketpair()
                upstream_peer, relay_upstream = socket.socketpair()
                calls = []
                result = {}
                authority = "fixture.test:443"
                def factory(target, deadline):
                    calls.append(target)
                    return relay_upstream
                thread = threading.Thread(target=lambda: result.update(relay.handle_client(
                    relay_client, factory, "req-123", authority, 0.2)))
                thread.start()
                request = (b"CONNECT fixture.test:443 HTTP/1.1\r\nHost: fixture.test:443\r\n"
                           b"x-symphony-provider-request-id: req-123\r\nUser-Agent: ok" + control +
                           b"bad\r\n\r\n")
                client.sendall(request)
                thread.join(1)
                self.assertFalse(thread.is_alive())
                self.assertEqual(calls, [])
                self.assertTrue(result["failed_closed"])
                client.close()
                upstream_peer.close()
                relay_upstream.close()

    def test_horizontal_tab_in_header_value_is_permitted(self):
        parsed = relay.parse_connect(
            b"CONNECT fixture.test:443 HTTP/1.1\r\nHost: fixture.test:443\r\n"
            b"x-symphony-provider-request-id: req-123\r\nUser-Agent: left\tright\r\n\r\n",
            "req-123", "fixture.test:443")
        self.assertEqual(parsed.authority, "fixture.test:443")

    def test_rejects_invalid_connect_before_upstream(self):
        good = b"CONNECT fixture.test:443 HTTP/1.1\r\nHost: fixture.test:443\r\nx-symphony-provider-request-id: req-123\r\n\r\n"
        cases = [
            good.replace(b"x-symphony-provider-request-id: req-123\r\n", b""),
            good.replace(b"req-123", b"wrong"),
            good.replace(b"\r\n\r\n", b"\r\nx-symphony-provider-request-id: req-123\r\n\r\n"),
            good.replace(b"fixture.test:443", b"other.test:443"),
            b"garbage\r\n\r\n",
            good + b"CONNECT fixture.test:443 HTTP/1.1\r\n\r\n",
        ]
        for request in cases:
            with self.subTest(request=request):
                with self.assertRaises(relay.ProtocolError):
                    self.parse(request)


class RecordTests(unittest.TestCase):
    def test_record_parser_forwards_exact_tls_record(self):
        record = b"\x16\x03\x03\x00\x03abc"
        self.assertEqual(relay.parse_record(record, 1024).wire, record)

    def test_gate_closes_on_second_client_app_or_first_server_app(self):
        gate = relay.RecordGate(max_client_app_records=1)
        app = b"\x17\x03\x03\x00\x01x"
        self.assertTrue(gate.client(app).forward)
        with self.assertRaises(relay.ProtocolError):
            gate.client(app)
        gate = relay.RecordGate(max_client_app_records=1)
        decision = gate.server(app)
        self.assertFalse(decision.forward)
        self.assertTrue(decision.close)
        self.assertEqual(decision.evidence["server_app_record_length"], 1)
        self.assertNotIn(b"x", repr(decision.evidence).encode())

    def test_malformed_truncated_and_watchdog_fail_closed(self):
        for data in (b"\x16\x03", b"\x16\x03\x03\x00\x03x"):
            with self.subTest(data=data), self.assertRaises(relay.ProtocolError):
                relay.parse_record(data, 1024)
        self.assertFalse(relay.watchdog_expired(0, 1, now=0.5))
        self.assertTrue(relay.watchdog_expired(0, 1, now=1))

    def test_evidence_is_bounded_and_payload_free(self):
        gate = relay.RecordGate(1)
        app = b"\x17\x03\x03\x00\x06secret"
        decision = gate.server(app)
        evidence = decision.evidence
        self.assertLessEqual(len(repr(evidence)), 256)
        self.assertNotIn("secret", repr(evidence))
        self.assertEqual(set(evidence), {"server_app_record_length", "server_app_fragment_sha256"})

    def test_cli_identity_values_have_conservative_byte_limits(self):
        self.assertTrue(relay.valid_identity_values("a" * 128, "fixture.test:443"))
        self.assertFalse(relay.valid_identity_values("a" * 129, "fixture.test:443"))
        self.assertTrue(relay.valid_identity_values("req-123", "a" * 255 + ":443"))
        self.assertFalse(relay.valid_identity_values("req-123", "a" * 256 + ":443"))

    def test_cli_rejects_unbounded_request_id_before_listen(self):
        command = [sys.executable, str(MODULE), "--bind", "127.0.0.1", "--port", "0",
                   "--request-id", "i" * 129, "--authority", "fixture.test:443",
                   "--record-limit", "1", "--watchdog", "1", "--evidence", "unused.json"]
        result = subprocess.run(command, capture_output=True, text=True, timeout=1)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")

    def test_upstream_connect_uses_only_first_resolved_address(self):
        class FakeSocket:
            def __init__(self):
                self.attempts = []
            def setblocking(self, value):
                pass
            def connect_ex(self, address):
                self.attempts.append(address)
                return 0
            def close(self):
                pass
        fake = FakeSocket()
        addresses = [(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("192.0.2.1", 443)),
                     (socket.AF_INET6, socket.SOCK_STREAM, 6, "", ("2001:db8::1", 443, 0, 0))]
        with mock.patch.object(relay.socket, "getaddrinfo", return_value=addresses), \
             mock.patch.object(relay.socket, "socket", return_value=fake):
            result = relay.connect_once("fixture.test:443", time.monotonic() + 1)
        self.assertIs(result, fake)
        self.assertEqual(fake.attempts, [addresses[0][4]])

    def test_stalled_single_address_dial_expires_deadline(self):
        class FakeSocket:
            def __init__(self):
                self.attempts = []
                self.closed = False
            def setblocking(self, value):
                pass
            def connect_ex(self, address):
                self.attempts.append(address)
                return errno.EINPROGRESS
            def close(self):
                self.closed = True
        fake = FakeSocket()
        address = (socket.AF_INET, socket.SOCK_STREAM, 6, "", ("192.0.2.1", 443))
        with mock.patch.object(relay.socket, "getaddrinfo", return_value=[address]), \
             mock.patch.object(relay.socket, "socket", return_value=fake), \
             mock.patch.object(relay.select, "select", return_value=([], [], [])):
            with self.assertRaises(relay.ProtocolError):
                relay.connect_once("fixture.test:443", time.monotonic() + 0.02)
        self.assertEqual(fake.attempts, [address[4]])
        self.assertTrue(fake.closed)

    def test_stalled_name_resolution_expires_shared_deadline(self):
        started = threading.Event()
        release = threading.Event()
        def blocked_resolver(*args, **kwargs):
            started.set()
            release.wait(1)
            return []
        before = time.monotonic()
        with mock.patch.object(relay.socket, "getaddrinfo", side_effect=blocked_resolver):
            with self.assertRaises(relay.ProtocolError):
                relay.connect_once("fixture.test:443", before + 0.05)
        elapsed = time.monotonic() - before
        release.set()
        self.assertTrue(started.is_set())
        self.assertLess(elapsed, 0.2)

    def test_stalled_dial_fails_closed_without_upstream_count(self):
        class FakeSocket:
            def __init__(self):
                self.closed = False
            def setblocking(self, value):
                pass
            def connect_ex(self, address):
                return errno.EINPROGRESS
            def close(self):
                self.closed = True
        fake = FakeSocket()
        address = (socket.AF_INET, socket.SOCK_STREAM, 6, "", ("192.0.2.1", 443))
        client, relay_client = socket.socketpair()
        client.sendall(b"CONNECT fixture.test:443 HTTP/1.1\r\nHost: fixture.test:443\r\n"
                       b"x-symphony-provider-request-id: req-123\r\n\r\n")
        with mock.patch.object(relay.socket, "getaddrinfo", return_value=[address]), \
             mock.patch.object(relay.socket, "socket", return_value=fake), \
             mock.patch.object(relay.select, "select", return_value=([], [], [])):
            result = relay.handle_client(client=relay_client,
                                         upstream_factory=relay.connect_once,
                                         expected_request_id="req-123",
                                         expected_authority="fixture.test:443", watchdog=0.1)
        self.assertTrue(result["failed_closed"])
        self.assertEqual(result["close_reason"], "WATCHDOG_EXPIRED")
        self.assertEqual(result["upstream_connections"], 0)
        self.assertTrue(fake.closed)
        client.close()

    def test_serialized_evidence_has_fixed_upper_bound(self):
        evidence = {"provider_request_id": "i" * 128, "authority": "a" * 259,
                    "connect_count": 1, "upstream_connections": 1,
                    "close_reason": "WATCHDOG_EXPIRED", "client_app_records": 1,
                    "server_app_suppressed": False, "failed_closed": True}
        encoded = relay.serialize_evidence(evidence)
        self.assertLessEqual(len(encoded), relay.MAX_EVIDENCE_BYTES)

    def test_listener_accept_obeys_watchdog(self):
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        started = time.monotonic()
        with self.assertRaises(relay.ProtocolError):
            relay.accept_one(listener, started + 0.05)
        self.assertLess(time.monotonic() - started, 0.5)
        listener.close()


class SocketRelayTests(unittest.TestCase):
    def setUp(self):
        self.request = (b"CONNECT fixture.test:443 HTTP/1.1\r\nHost: fixture.test:443\r\n"
                        b"x-symphony-provider-request-id: req-123\r\n\r\n")

    def start(self, watchdog=1):
        client, relay_client = socket.socketpair()
        upstream_peer, relay_upstream = socket.socketpair()
        calls = []
        result = {}
        # The factory must return the relay end, while tests retain its peer.
        def factory(authority, deadline):
            calls.append(authority)
            return relay_upstream
        def run():
            result.update(relay.handle_client(relay_client, factory, "req-123", "fixture.test:443", watchdog))
            relay_upstream.close()
        thread = threading.Thread(target=run)
        thread.start()
        return client, thread, calls, result, upstream_peer

    def test_client_accepted_late_gets_only_remaining_watchdog_budget(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence_path = pathlib.Path(directory) / "evidence.json"
            command = [sys.executable, str(MODULE), "--bind", "127.0.0.1", "--port", "0",
                       "--request-id", "req-123", "--authority", "fixture.test:443",
                       "--record-limit", "1", "--watchdog", "0.8", "--evidence", str(evidence_path)]
            process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            client = None
            try:
                self.assertTrue(select.select([process.stdout], [], [], 1)[0])
                ready = json.loads(process.stdout.readline())
                time.sleep(0.55)
                accepted_at = time.monotonic()
                client = socket.create_connection((ready["listen_host"], ready["bound_port"]))
                self.assertEqual(process.wait(timeout=0.45), 1)
                self.assertLess(time.monotonic() - accepted_at, 0.45)
                evidence = json.loads(evidence_path.read_text())
                self.assertEqual(evidence["close_reason"], "WATCHDOG_EXPIRED")
            finally:
                if client is not None:
                    client.close()
                process.stdout.close()
                process.stderr.close()
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=2)

    def test_subprocess_emits_internal_ready_before_any_activity(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence_path = pathlib.Path(directory) / "evidence.json"
            upstream = socket.socket()
            upstream.bind(("127.0.0.1", 0))
            upstream.listen(1)
            upstream.setblocking(False)
            authority = f"127.0.0.1:{upstream.getsockname()[1]}"
            command = [sys.executable, str(MODULE), "--bind", "127.0.0.1", "--port", "0",
                       "--request-id", "req-123", "--authority", authority,
                       "--record-limit", "1", "--watchdog", "1", "--evidence", str(evidence_path)]
            process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                self.assertTrue(select.select([process.stdout], [], [], 1)[0], "no READY line")
                ready_line = process.stdout.readline()
                ready = json.loads(ready_line)
                self.assertEqual(set(ready), {"type", "provider_request_id", "listen_host", "bound_port",
                                              "python_version", "script_blob_sha256", "environment_names"})
                self.assertEqual(ready["type"], "READY")
                self.assertEqual(ready["provider_request_id"], "req-123")
                self.assertEqual(ready["listen_host"], "127.0.0.1")
                self.assertGreater(ready["bound_port"], 0)
                self.assertEqual(ready["script_blob_sha256"], hashlib.sha256(MODULE.read_bytes()).hexdigest())
                self.assertLessEqual(len(ready["environment_names"]), 64)
                self.assertFalse(evidence_path.exists())
                self.assertEqual(select.select([upstream], [], [], 0.1)[0], [])
            finally:
                process.terminate()
                process.wait(timeout=2)
                process.stdout.close()
                process.stderr.close()
                upstream.close()

    def test_invalid_connect_exits_nonzero_and_writes_payload_free_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence_path = pathlib.Path(directory) / "evidence.json"
            upstream = socket.socket()
            upstream.bind(("127.0.0.1", 0))
            upstream.listen(1)
            upstream.setblocking(False)
            authority = f"127.0.0.1:{upstream.getsockname()[1]}"
            command = [sys.executable, str(MODULE), "--bind", "127.0.0.1", "--port", "0",
                       "--request-id", "req-123", "--authority", authority,
                       "--record-limit", "1", "--watchdog", "1", "--evidence", str(evidence_path)]
            process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            client = None
            try:
                self.assertTrue(select.select([process.stdout], [], [], 1)[0])
                ready = json.loads(process.stdout.readline())
                client = socket.create_connection((ready["listen_host"], ready["bound_port"]))
                client.sendall(b"CONNECT wrong.test:443 HTTP/1.1\r\n\r\n")
                client.settimeout(1)
                self.assertEqual(client.recv(1), b"")
                self.assertEqual(process.wait(timeout=1), 1)
                evidence = json.loads(evidence_path.read_text())
                self.assertEqual(evidence["connect_count"], 1)
                self.assertEqual(evidence["upstream_connections"], 0)
                self.assertEqual(evidence["close_reason"], "CONNECT_REJECTED")
                self.assertNotIn("wrong.test", repr(evidence))
                self.assertLessEqual(evidence_path.stat().st_size, relay.MAX_EVIDENCE_BYTES)
                self.assertEqual(select.select([upstream], [], [], 0.05)[0], [])
            finally:
                if client is not None:
                    client.close()
                process.stdout.close()
                process.stderr.close()
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=2)
                upstream.close()

    def test_accept_watchdog_writes_failure_evidence_and_nonzero_status(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence_path = pathlib.Path(directory) / "evidence.json"
            command = [sys.executable, str(MODULE), "--bind", "127.0.0.1", "--port", "0",
                       "--request-id", "req-123", "--authority", "fixture.test:443",
                       "--record-limit", "1", "--watchdog", "0.05", "--evidence", str(evidence_path)]
            process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                self.assertTrue(select.select([process.stdout], [], [], 1)[0])
                ready = json.loads(process.stdout.readline())
                self.assertEqual(ready["type"], "READY")
                self.assertEqual(process.wait(timeout=1), 1)
                evidence = json.loads(evidence_path.read_text())
                self.assertEqual(evidence["connect_count"], 0)
                self.assertEqual(evidence["upstream_connections"], 0)
                self.assertEqual(evidence["close_reason"], "WATCHDOG_EXPIRED")
                self.assertTrue(evidence["failed_closed"])
                self.assertLessEqual(evidence_path.stat().st_size, relay.MAX_EVIDENCE_BYTES)
            finally:
                process.stdout.close()
                process.stderr.close()
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=2)

    def test_server_application_suppression_exits_successfully(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence_path = pathlib.Path(directory) / "evidence.json"
            upstream = socket.socket()
            upstream.bind(("127.0.0.1", 0))
            upstream.listen(1)
            upstream.settimeout(1)
            authority = f"127.0.0.1:{upstream.getsockname()[1]}"
            app = b"\x17\x03\x03\x00\x03xyz"
            fixture_result = {}
            def fixture():
                conn, _ = upstream.accept()
                with conn:
                    conn.settimeout(1)
                    fixture_result["request"] = conn.recv(64)
                    conn.sendall(app)
            fixture_thread = threading.Thread(target=fixture)
            fixture_thread.start()
            command = [sys.executable, str(MODULE), "--bind", "127.0.0.1", "--port", "0",
                       "--request-id", "req-123", "--authority", authority,
                       "--record-limit", "1", "--watchdog", "1", "--evidence", str(evidence_path)]
            process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            client = None
            try:
                self.assertTrue(select.select([process.stdout], [], [], 1)[0])
                ready = json.loads(process.stdout.readline())
                client = socket.create_connection((ready["listen_host"], ready["bound_port"]))
                client.sendall((f"CONNECT {authority} HTTP/1.1\r\nHost: {authority}\r\n"
                                "x-symphony-provider-request-id: req-123\r\n\r\n").encode())
                self.assertIn(b"200 Connection Established", client.recv(4096))
                handshake = b"\x16\x03\x03\x00\x03abc"
                client.sendall(handshake)
                client.settimeout(1)
                try:
                    received = client.recv(1)
                    self.assertEqual(received, b"")
                except ConnectionResetError:
                    pass
                self.assertEqual(process.wait(timeout=1), 0)
                fixture_thread.join(1)
                self.assertEqual(fixture_result["request"], handshake)
                evidence = json.loads(evidence_path.read_text())
                self.assertTrue(evidence["server_app_suppressed"])
                self.assertEqual(evidence["close_reason"], "SERVER_APP_SUPPRESSED")
                self.assertEqual(evidence["upstream_connections"], 1)
                self.assertLessEqual(evidence_path.stat().st_size, relay.MAX_EVIDENCE_BYTES)
            finally:
                if client is not None:
                    client.close()
                process.stdout.close()
                process.stderr.close()
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=2)
                fixture_thread.join(1)
                upstream.close()

    def test_authorization_precedes_dial_and_second_connect_is_rejected(self):
        client, peer = socket.socketpair()
        calls = []
        result = {}
        thread = threading.Thread(target=lambda: result.update(relay.handle_client(
            peer, lambda authority, deadline: calls.append(authority), "req-123", "fixture.test:443", 1)))
        thread.start()
        client.sendall(self.request.replace(b"req-123", b"bad"))
        thread.join(2)
        self.assertEqual(calls, [])
        self.assertTrue(result["failed_closed"])
        client.close()
        tunnel, thread, calls, result, upstream_peer = self.start()
        tunnel.sendall(self.request)
        response = tunnel.recv(4096)
        self.assertIn(b"200 Connection Established", response)
        tunnel.sendall(b"CONNECT fixture.test:443 HTTP/1.1\r\n\r\n")
        tunnel.settimeout(1)
        try:
            self.assertEqual(tunnel.recv(1), b"")
        except ConnectionResetError:
            pass
        thread.join(2)
        self.assertEqual(calls, ["fixture.test:443"])
        tunnel.close()
        upstream_peer.close()

    def test_tls_records_forward_unchanged_and_suppress_server_app(self):
        tunnel, thread, calls, result, upstream_peer = self.start()
        tunnel.sendall(self.request)
        self.assertIn(b"200 Connection Established", tunnel.recv(4096))
        handshake = b"\x16\x03\x03\x00\x03abc"
        # Two records in one read must retain the bytes after the first record.
        extra = b"\x16\x03\x03\x00\x02de"
        tunnel.sendall(handshake + extra)
        upstream_peer.settimeout(1)
        self.assertEqual(upstream_peer.recv(len(handshake)), handshake)
        self.assertEqual(upstream_peer.recv(len(extra)), extra)
        response = b"\x16\x03\x03\x00\x02ok"
        upstream_peer.sendall(response)
        self.assertEqual(tunnel.recv(len(response)), response)
        app = b"\x17\x03\x03\x00\x03xyz"
        upstream_peer.sendall(app)
        tunnel.settimeout(1)
        self.assertEqual(tunnel.recv(1), b"")
        thread.join(2)
        self.assertTrue(result["server_app_suppressed"])
        self.assertEqual(result["server_app_record_length"], 3)
        self.assertNotIn("xyz", repr(result))
        self.assertEqual(upstream_peer.recv(1), b"")
        tunnel.close()
        upstream_peer.close()

    def test_connect_and_buffered_tls_records_forward_without_new_readiness(self):
        tunnel, thread, calls, result, upstream_peer = self.start(watchdog=0.15)
        records = (b"\x16\x03\x03\x00\x03abc" +
                   b"\x16\x03\x03\x00\x02de")
        tunnel.sendall(self.request + records)
        self.assertIn(b"200 Connection Established", tunnel.recv(4096))
        upstream_peer.settimeout(0.5)
        received = bytearray()
        while len(received) < len(records):
            received.extend(upstream_peer.recv(len(records) - len(received)))
        self.assertEqual(received, records)
        thread.join(1)
        self.assertFalse(thread.is_alive())
        tunnel.close()
        upstream_peer.close()

    def test_blocked_upstream_write_closes_both_sides_at_watchdog(self):
        tunnel, relay_client = socket.socketpair()
        upstream_peer, relay_upstream = socket.socketpair()
        relay_upstream.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 1024)
        result = {}
        with mock.patch.object(relay.socket, "MSG_DONTWAIT", 0, create=True):
            thread = threading.Thread(target=lambda: result.update(relay.handle_client(
                relay_client, lambda authority, deadline: relay_upstream, "req-123", "fixture.test:443", 0.1)))
            thread.start()
            tunnel.sendall(self.request)
            self.assertIn(b"200 Connection Established", tunnel.recv(4096))
            payload = b"x" * 16000
            tunnel.sendall(b"\x16\x03\x03" + len(payload).to_bytes(2, "big") + payload)
            thread.join(0.5)
        finished = not thread.is_alive()
        if not finished:
            upstream_peer.close()
            thread.join(1)
        self.assertTrue(finished, "blocked write exceeded the relay watchdog")
        self.assertTrue(result.get("failed_closed"))
        self.assertEqual(tunnel.recv(1), b"")
        upstream_peer.settimeout(0.5)
        forwarded = bytearray()
        while True:
            part = upstream_peer.recv(4096)
            if not part:
                break
            forwarded.extend(part)
        self.assertLess(len(forwarded), len(payload) + 5)
        tunnel.close()
        upstream_peer.close()

    def test_second_client_app_record_and_truncated_record_fail_closed(self):
        tunnel, thread, calls, result, upstream_peer = self.start()
        tunnel.sendall(self.request)
        tunnel.recv(4096)
        app = b"\x17\x03\x03\x00\x01x"
        tunnel.sendall(app + app)
        upstream_peer.settimeout(1)
        self.assertEqual(upstream_peer.recv(6), app)
        self.assertEqual(upstream_peer.recv(1), b"")
        thread.join(2)
        self.assertTrue(result["failed_closed"])
        tunnel.close()
        upstream_peer.close()

        tunnel, thread, calls, result, upstream_peer = self.start(watchdog=0.1)
        tunnel.sendall(self.request + b"\x16\x03")
        thread.join(1)
        self.assertTrue(result["failed_closed"])
        tunnel.close()
        upstream_peer.close()

    def test_connect_header_watchdog_has_fixed_watchdog_reason(self):
        tunnel, thread, calls, result, upstream_peer = self.start(watchdog=0.05)
        thread.join(0.5)
        self.assertFalse(thread.is_alive())
        self.assertEqual(result["close_reason"], "WATCHDOG_EXPIRED")
        self.assertEqual(result["connect_count"], 1)
        self.assertEqual(calls, [])
        tunnel.close()
        upstream_peer.close()


if __name__ == "__main__":
    unittest.main()
