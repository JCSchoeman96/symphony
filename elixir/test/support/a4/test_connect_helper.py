import json
import select
import socket
import subprocess
import sys
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("connect_helper.py")


def launch(port, request_id="preq_test", **overrides):
    process = subprocess.Popen([sys.executable, "-I", str(SCRIPT)], stdin=subprocess.PIPE,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1,
                              env={"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8"})
    manifest = {"provider_request_id": request_id, "origin_authority": f"127.0.0.1:{port}",
                "origin_kind": "local_qualification", "connect_watchdog_seconds": 2}
    manifest.update(overrides)
    if manifest.get("connect_watchdog_seconds") is None:
        manifest.pop("connect_watchdog_seconds")
    process.stdin.write(json.dumps(manifest) + "\n")
    process.stdin.flush()
    process.stdin.close()
    ready = json.loads(process.stdout.readline())
    return process, ready


class ConnectHelperTests(unittest.TestCase):
    def test_rejects_bad_manifest_without_starting_listener(self):
        process = subprocess.Popen([sys.executable, "-I", str(SCRIPT)], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        out, _ = process.communicate("{}", timeout=2)
        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(out, "")

    def test_manifest_defaults_watchdog_and_rejects_unbounded_json(self):
        origin = socket.socket()
        origin.bind(("127.0.0.1", 0))
        origin.listen(1)
        process, ready = launch(origin.getsockname()[1], connect_watchdog_seconds=None)
        self.assertEqual(ready["type"], "READY")
        self.assertEqual(process.poll(), None)
        client = socket.create_connection((ready["listen_host"], ready["bound_port"]))
        client.close()
        process.wait(timeout=2)
        process.stdin.close()
        process.stdout.close()
        process.stderr.close()
        origin.close()

        oversized = subprocess.Popen([sys.executable, "-I", str(SCRIPT)], stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                     env={"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8"})
        oversized.communicate(b"{" + b" " * (64 * 1024 + 1), timeout=2)
        self.assertNotEqual(oversized.returncode, 0)

    def test_manifest_rejects_non_ascii_request_id_before_ready(self):
        origin = socket.socket()
        origin.bind(("127.0.0.1", 0))
        manifest = {"provider_request_id": "preq_é", "origin_authority": f"127.0.0.1:{origin.getsockname()[1]}",
                    "origin_kind": "local_qualification"}
        process = subprocess.Popen([sys.executable, "-I", str(SCRIPT)], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                   env={"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8"})
        process.stdin.write(json.dumps(manifest) + "\n")
        process.stdin.flush()
        process.stdin.close()
        self.assertTrue(select.select([process.stdout], [], [], 2)[0])
        self.assertEqual(process.stdout.readline(), "")
        self.assertEqual(process.wait(timeout=2), 2)
        process.stdout.close()
        process.stderr.close()
        origin.close()

    def test_non_ascii_connect_id_is_rejected_without_upstream_connection(self):
        origin = socket.socket()
        origin.bind(("127.0.0.1", 0))
        origin.listen(1)
        process, ready = launch(origin.getsockname()[1])
        client = socket.create_connection((ready["listen_host"], ready["bound_port"]))
        client.sendall((f"CONNECT 127.0.0.1:{origin.getsockname()[1]} HTTP/1.1\r\n".encode()
                        + b"x-symphony-provider-request-id: preq_\xfftest\r\n\r\n"))
        rejection = json.loads(process.stdout.readline())
        self.assertEqual(rejection, {"type": "REJECTED", "reason": "REQUEST_ID_MISMATCH"})
        self.assertEqual(process.wait(timeout=2), 2)
        client.close()
        process.stdin.close()
        process.stdout.close()
        process.stderr.close()
        origin.settimeout(0.1)
        with self.assertRaises(TimeoutError):
            origin.accept()
        origin.close()

    def test_wrong_authority_is_rejected_without_upstream_connection(self):
        origin = socket.socket()
        origin.bind(("127.0.0.1", 0))
        origin.listen(1)
        process, ready = launch(origin.getsockname()[1])
        client = socket.create_connection((ready["listen_host"], ready["bound_port"]))
        client.sendall(b"CONNECT other.example:443 HTTP/1.1\r\nx-symphony-provider-request-id: preq_test\r\n\r\n")
        rejection = json.loads(process.stdout.readline())
        self.assertEqual(rejection, {"type": "REJECTED", "reason": "WRONG_AUTHORITY"})
        self.assertEqual(process.wait(timeout=2), 2)
        client.close()
        process.stdin.close()
        process.stdout.close()
        process.stderr.close()
        origin.settimeout(0.1)
        with self.assertRaises(TimeoutError):
            origin.accept()
        origin.close()

    def test_listener_closes_immediately_after_first_accept(self):
        origin = socket.socket()
        origin.bind(("127.0.0.1", 0))
        origin.listen(1)
        process, ready = launch(origin.getsockname()[1])
        first = socket.create_connection((ready["listen_host"], ready["bound_port"]))
        first.sendall((f"CONNECT 127.0.0.1:{origin.getsockname()[1]} HTTP/1.1\r\n"
                       "x-symphony-provider-request-id: preq_test\r\n\r\n").encode())
        first.settimeout(2)
        self.assertIn(b"200 Connection Established", first.recv(128))
        with self.assertRaises(ConnectionRefusedError):
            socket.create_connection((ready["listen_host"], ready["bound_port"]), timeout=0.5)
        first.close()
        process.kill()
        process.wait(timeout=2)
        process.stdin.close()
        process.stdout.close()
        process.stderr.close()
        origin.close()

    def test_first_client_application_record_closes_immediately(self):
        origin = socket.socket()
        origin.bind(("127.0.0.1", 0))
        origin.listen(1)
        accepted = []
        def serve():
            upstream, _ = origin.accept()
            upstream.settimeout(1)
            upstream.settimeout(2)
            try:
                while True:
                    data = upstream.recv(64)
                    if not data:
                        break
                    accepted.append(data)
            except OSError:
                pass
            upstream.close()
        import threading
        worker = threading.Thread(target=serve, daemon=True)
        worker.start()
        process, ready = launch(origin.getsockname()[1])
        client = socket.create_connection((ready["listen_host"], ready["bound_port"]))
        client.settimeout(2)
        client.sendall((f"CONNECT 127.0.0.1:{origin.getsockname()[1]} HTTP/1.1\r\n"
                        "x-symphony-provider-request-id: preq_test\r\n\r\n").encode())
        client.recv(128)
        client.sendall(b"\x17\x03\x03\x00\x01x")
        self.assertEqual(client.recv(1), b"")
        evidence = json.loads(process.stdout.readline())
        self.assertEqual(evidence["close_reason"], "UNEXPECTED_FIRST_TLS_RECORD")
        self.assertEqual(process.wait(timeout=2), 2)
        worker.join(timeout=2)
        self.assertEqual(accepted, [])
        client.close()
        origin.close()
        process.stdin.close()
        process.stdout.close()
        process.stderr.close()

    def test_server_handshake_control_after_dispatch_fails_closed(self):
        origin = socket.socket()
        origin.bind(("127.0.0.1", 0))
        origin.listen(1)
        import threading
        def serve():
            upstream, _ = origin.accept()
            request = bytearray()
            while len(request) < 12:
                request.extend(upstream.recv(64))
            upstream.sendall(b"\x16\x03\x03\x00\x01x")
            upstream.settimeout(2)
            try:
                upstream.recv(1)
            except OSError:
                pass
            upstream.close()
        worker = threading.Thread(target=serve, daemon=True)
        worker.start()
        process, ready = launch(origin.getsockname()[1])
        client = socket.create_connection((ready["listen_host"], ready["bound_port"]))
        client.settimeout(2)
        client.sendall((f"CONNECT 127.0.0.1:{origin.getsockname()[1]} HTTP/1.1\r\n"
                        "x-symphony-provider-request-id: preq_test\r\n\r\n").encode())
        client.recv(128)
        client.sendall(b"\x16\x03\x03\x00\x01c\x17\x03\x03\x00\x01d")
        self.assertEqual(client.recv(1), b"")
        evidence = json.loads(process.stdout.readline())
        self.assertEqual(evidence["close_reason"], "UNEXPECTED_SERVER_CONTROL")
        self.assertEqual(process.wait(timeout=2), 2)
        worker.join(timeout=2)
        client.close()
        origin.close()
        process.stdin.close()
        process.stdout.close()
        process.stderr.close()

    def test_tls_record_parser_reassembles_split_and_coalesced_records(self):
        sys.path.insert(0, str(SCRIPT.parent))
        import connect_helper
        one = b"\x16\x03\x03\x00\x02ab"
        two = b"\x17\x03\x03\x00\x01z"
        self.assertEqual(connect_helper.take_records(one[:3]), ([], one[:3]))
        self.assertEqual(connect_helper.take_records(one[:-1]), ([], one[:-1]))
        records, remainder = connect_helper.take_records(one + two + b"\x17\x03")
        self.assertEqual(records, [one, two])
        self.assertEqual(remainder, b"\x17\x03")

    def test_wrong_id_consumes_the_single_connection_opportunity(self):
        origin = socket.socket()
        origin.bind(("127.0.0.1", 0))
        origin.listen(1)
        process, ready = launch(origin.getsockname()[1])
        client = socket.create_connection((ready["listen_host"], ready["bound_port"]))
        client.sendall((f"CONNECT 127.0.0.1:{origin.getsockname()[1]} HTTP/1.1\r\n"
                        "x-symphony-provider-request-id: wrong\r\n\r\n").encode())
        self.assertTrue(select.select([process.stdout], [], [], 3)[0])
        result = json.loads(process.stdout.readline())
        self.assertEqual(result, {"type": "REJECTED", "reason": "REQUEST_ID_MISMATCH"})
        self.assertEqual(process.wait(timeout=2), 2)
        client.close()
        process.stdin.close()
        process.stdout.close()
        process.stderr.close()
        with self.assertRaises(OSError):
            socket.create_connection((ready["listen_host"], ready["bound_port"]), timeout=0.2)
        origin.close()

    def test_second_client_application_record_is_not_forwarded(self):
        origin = socket.socket()
        origin.bind(("127.0.0.1", 0))
        origin.listen(1)
        received = []
        import threading
        def serve():
            upstream, _ = origin.accept()
            upstream.settimeout(2)
            try:
                while True:
                    data = upstream.recv(64)
                    if not data:
                        break
                    received.append(data)
            except OSError:
                pass
            upstream.close()
        worker = threading.Thread(target=serve, daemon=True)
        worker.start()
        process, ready = launch(origin.getsockname()[1])
        client = socket.create_connection((ready["listen_host"], ready["bound_port"]))
        client.settimeout(2)
        client.sendall((f"CONNECT 127.0.0.1:{origin.getsockname()[1]} HTTP/1.1\r\n"
                        "x-symphony-provider-request-id: preq_test\r\n\r\n").encode())
        client.recv(128)
        client.sendall(b"\x16\x03\x03\x00\x01c\x17\x03\x03\x00\x01d\x17\x03\x03\x00\x01e")
        self.assertEqual(client.recv(1), b"")
        evidence = json.loads(process.stdout.readline())
        self.assertEqual(evidence["close_reason"], "INVALID_MULTI_RECORD_REQUEST")
        self.assertEqual(evidence["client_application_data_record_count"], 2)
        self.assertEqual(process.wait(timeout=2), 2)
        worker.join(timeout=2)
        self.assertEqual(b"".join(received), b"\x16\x03\x03\x00\x01c\x17\x03\x03\x00\x01d")
        client.close()
        origin.close()
        process.stdin.close()
        process.stdout.close()
        process.stderr.close()

    def test_first_server_application_record_is_withheld_and_closes_both_sides(self):
        origin = socket.socket()
        origin.bind(("127.0.0.1", 0))
        origin.listen(1)
        received = []

        def serve():
            upstream, _ = origin.accept()
            upstream.sendall(b"\x16\x03\x03\x00\x01h")
            request = bytearray()
            while len(request) < 7:
                request.extend(upstream.recv(64))
            received.append(bytes(request))
            app = b"\x17\x03\x03\x00\x03xyz"
            upstream.sendall(app + b"\x16\x03\x03\x00\x01q")
            upstream.settimeout(2)
            try:
                upstream.recv(1)
            except OSError:
                pass
            upstream.close()

        thread = __import__("threading").Thread(target=serve, daemon=True)
        thread.start()
        process, ready = launch(origin.getsockname()[1])
        client = socket.create_connection((ready["listen_host"], ready["bound_port"]))
        client.settimeout(2)
        client.sendall((f"CONNECT 127.0.0.1:{origin.getsockname()[1]} HTTP/1.1\r\n"
                        "x-symphony-provider-request-id: preq_test\r\n\r\n").encode())
        self.assertIn(b"200 Connection Established", client.recv(128))
        self.assertEqual(client.recv(64), b"\x16\x03\x03\x00\x01h")
        client.sendall(b"\x16\x03\x03\x00\x01c\x17\x03\x03\x00\x01d")
        self.assertEqual(client.recv(64), b"")
        evidence = json.loads(process.stdout.readline())
        self.assertEqual(evidence["close_reason"], "RESPONSE_SUPPRESSED")
        self.assertTrue(evidence["server_application_data_observed"])
        self.assertFalse(evidence["server_application_data_forwarded"])
        self.assertEqual(evidence["client_application_data_record_count"], 1)
        self.assertEqual(process.wait(timeout=2), 0)
        self.assertEqual(received[0], b"\x16\x03\x03\x00\x01c\x17\x03\x03\x00\x01d")
        client.close()
        process.stdin.close()
        process.stdout.close()
        process.stderr.close()
        origin.close()

    def test_forward_control_mode_forwards_server_application_data_locally(self):
        origin = socket.socket()
        origin.bind(("127.0.0.1", 0))
        origin.listen(1)
        import threading
        def serve():
            upstream, _ = origin.accept()
            upstream.sendall(b"\x16\x03\x03\x00\x01h")
            request = bytearray()
            while len(request) < 7:
                request.extend(upstream.recv(64))
            upstream.sendall(b"\x17\x03\x03\x00\x03xyz")
            upstream.settimeout(2)
            try:
                upstream.recv(1)
            except OSError:
                pass
            upstream.close()
        worker = threading.Thread(target=serve, daemon=True)
        worker.start()
        process, ready = launch(origin.getsockname()[1], relay_mode="forward_control")
        client = socket.create_connection((ready["listen_host"], ready["bound_port"]))
        client.settimeout(2)
        client.sendall((f"CONNECT 127.0.0.1:{origin.getsockname()[1]} HTTP/1.1\r\n"
                        "x-symphony-provider-request-id: preq_test\r\n\r\n").encode())
        self.assertIn(b"200 Connection Established", client.recv(128))
        self.assertEqual(client.recv(64), b"\x16\x03\x03\x00\x01h")
        client.sendall(b"\x16\x03\x03\x00\x01c\x17\x03\x03\x00\x01d")
        self.assertEqual(client.recv(64), b"\x17\x03\x03\x00\x03xyz")
        client.close()
        evidence = json.loads(process.stdout.readline())
        self.assertEqual(evidence["close_reason"], "CLIENT_CLOSED")
        self.assertTrue(evidence["server_application_data_observed"])
        self.assertTrue(evidence["server_application_data_forwarded"])
        self.assertEqual(process.wait(timeout=2), 0)
        worker.join(timeout=2)
        origin.close()
        process.stdin.close()
        process.stdout.close()
        process.stderr.close()

    def test_server_alert_after_dispatch_fails_closed(self):
        origin = socket.socket()
        origin.bind(("127.0.0.1", 0))
        origin.listen(1)
        import threading
        def serve():
            upstream, _ = origin.accept()
            request = bytearray()
            while len(request) < 12:
                request.extend(upstream.recv(64))
            upstream.sendall(b"\x15\x03\x03\x00\x01x")
            upstream.settimeout(2)
            try:
                upstream.recv(1)
            except OSError:
                pass
            upstream.close()
        worker = threading.Thread(target=serve, daemon=True)
        worker.start()
        process, ready = launch(origin.getsockname()[1])
        client = socket.create_connection((ready["listen_host"], ready["bound_port"]))
        client.settimeout(2)
        client.sendall((f"CONNECT 127.0.0.1:{origin.getsockname()[1]} HTTP/1.1\r\n"
                        "x-symphony-provider-request-id: preq_test\r\n\r\n").encode())
        self.assertIn(b"200 Connection Established", client.recv(128))
        client.sendall(b"\x16\x03\x03\x00\x01c\x17\x03\x03\x00\x01d")
        self.assertEqual(client.recv(1), b"")
        evidence = json.loads(process.stdout.readline())
        self.assertEqual(evidence["close_reason"], "UNEXPECTED_SERVER_CONTROL")
        self.assertEqual(process.wait(timeout=2), 2)
        client.close()
        worker.join(timeout=2)
        origin.close()
        process.stdin.close()
        process.stdout.close()
        process.stderr.close()

    def test_ready_has_required_fields_and_only_environment_names(self):
        self.assertTrue(SCRIPT.exists())
        for field in (b"provider_request_id", b"listen_host", b"bound_port", b"python_version",
                      b"script_blob_sha256", b"environment_names", b"x-symphony-provider-request-id"):
            self.assertIn(field, SCRIPT.read_bytes())

    def test_ready_reports_hash_and_safe_environment_names(self):
        origin = socket.socket()
        origin.bind(("127.0.0.1", 0))
        origin.listen(1)
        process, ready = launch(origin.getsockname()[1])
        import hashlib
        self.assertEqual(ready["script_blob_sha256"], hashlib.sha256(SCRIPT.read_bytes()).hexdigest())
        self.assertEqual(ready["environment_names"], ["LANG", "PATH"])
        client = socket.create_connection((ready["listen_host"], ready["bound_port"]))
        client.close()
        process.wait(timeout=2)
        process.stdin.close()
        process.stdout.close()
        process.stderr.close()
        origin.close()


if __name__ == "__main__":
    unittest.main()
