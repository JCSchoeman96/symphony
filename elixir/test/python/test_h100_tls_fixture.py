import importlib.util
import base64
import json
import pathlib
import socket
import ssl
import subprocess
import tempfile
import unittest

MODULE = pathlib.Path(__file__).parents[2] / "priv/h100/local_tls_fixture.py"
spec = importlib.util.spec_from_file_location("h100_local_tls_fixture", MODULE)
fixture_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture_module)


class LocalTLSFixtureTests(unittest.TestCase):
    def test_client_api_key_sentinel_is_accepted_without_entering_evidence(self):
        sentinel = "local-qualification-only"
        with fixture_module.LocalTLSFixture(timeout=2, expected_api_key=sentinel) as fixture:
            with socket.create_connection((fixture.host, fixture.port), timeout=2) as raw:
                with self.verified_context(fixture).wrap_socket(
                    raw, server_hostname=fixture.server_hostname
                ) as connection:
                    connection.sendall(
                        f"PATCH /local HTTP/1.1\r\nHost: {fixture.authority}\r\n"
                        f"X-API-Key: {sentinel}\r\nContent-Length: 7\r\n"
                        "Connection: close\r\n\r\nbody-01".encode("ascii")
                    )
                    self.assertIn(b"200 OK", connection.recv(1024))
            result = fixture.result()
            self.assertTrue(result["credential_valid"])
            self.assertNotIn("api_key", result["evidence"])
            self.assertNotIn(sentinel, repr(result["evidence"]))

    def test_response_write_failure_after_complete_request_is_tolerated(self):
        class ClosedTLSConnection:
            def sendall(self, _data):
                raise ssl.SSLEOFError("peer closed after request capture")

        self.assertFalse(fixture_module.LocalTLSFixture._send_response(ClosedTLSConnection()))

    def request(self, fixture, context, api_key=None):
        with socket.create_connection((fixture.host, fixture.port), timeout=2) as raw:
            with context.wrap_socket(raw, server_hostname=fixture.server_hostname) as connection:
                key_header = "" if api_key is None else f"X-API-Key: {api_key}\r\n"
                connection.sendall(f"PATCH /local HTTP/1.1\r\nHost: {fixture.authority}\r\n{key_header}Content-Length: 7\r\nConnection: close\r\n\r\n".encode("ascii") + b"body-01")
                return connection.recv(1024)

    def verified_context(self, fixture):
        context = ssl.create_default_context(cadata=fixture.ca_pem)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.maximum_version = ssl.TLSVersion.TLSv1_2
        return context

    def test_tls12_serves_one_patch_and_exposes_body_only_in_process_result(self):
        with fixture_module.LocalTLSFixture(timeout=2) as fixture:
            self.assertTrue(fixture.authority.startswith("127.0.0.1:"))
            self.assertEqual(fixture.server_hostname, "127.0.0.1")
            response = self.request(fixture, self.verified_context(fixture))
            self.assertIn(b"200 OK", response)
            result = fixture.result()
            self.assertEqual(result["request_count"], 1)
            self.assertEqual(result["method"], "PATCH")
            self.assertEqual(result["request_body"], b"body-01")
            self.assertEqual(result["tls_version"], "TLSv1.2")
            self.assertEqual(result["evidence"]["request_count"], 1)
            self.assertNotIn("request_body", result["evidence"])
            self.assertNotIn(b"body-01", repr(result["evidence"]).encode())
            self.assertEqual(fixture.ca_der[:1], b"0")

    def test_wrong_ip_certificate_fails_peer_verification(self):
        with fixture_module.LocalTLSFixture(timeout=2, wrong_hostname=True) as fixture:
            self.assertEqual(fixture.server_hostname, "127.0.0.1")
            with self.assertRaises(ssl.SSLCertVerificationError):
                self.request(fixture, self.verified_context(fixture))

    def test_tls11_only_origin_rejects_tls12_client(self):
        with fixture_module.LocalTLSFixture(timeout=2, tls11_only=True) as fixture:
            with self.assertRaises((ssl.SSLError, OSError)):
                self.request(fixture, self.verified_context(fixture))

    def test_close_removes_private_directory_and_material(self):
        fixture = fixture_module.LocalTLSFixture(timeout=2)
        fixture.start()
        directory = fixture.directory
        self.assertTrue(directory.is_dir())
        self.assertEqual(directory.stat().st_mode & 0o777, 0o700)
        fixture.close()
        self.assertFalse(directory.exists())

    def test_local_sentinel_is_checked_without_entering_evidence(self):
        sentinel = "local-qualification-only"
        with fixture_module.LocalTLSFixture(timeout=2, expected_api_key=sentinel) as fixture:
            self.request(fixture, self.verified_context(fixture), api_key=sentinel)
            result = fixture.result()
            self.assertTrue(result["credential_valid"])
            self.assertNotIn("api_key", result["evidence"])
            self.assertNotIn(sentinel, repr(result["evidence"]))
            self.assertNotIn(b"body-01", repr(result["evidence"]).encode())

    def test_fixture_accepts_configured_work_item_path_and_checks_host(self):
        expected_path = "/api/v1/workspaces/workspace/projects/project-1/work-items/work-1/"
        with fixture_module.LocalTLSFixture(timeout=2, expected_path=expected_path) as fixture:
            with socket.create_connection((fixture.host, fixture.port), timeout=2) as raw:
                with self.verified_context(fixture).wrap_socket(
                    raw, server_hostname=fixture.server_hostname
                ) as connection:
                    connection.sendall(
                        f"PATCH {expected_path} HTTP/1.1\r\nHost: {fixture.authority}\r\n"
                        "X-API-Key: local-qualification-only\r\n"
                        "Content-Length: 2\r\nConnection: close\r\n\r\nok".encode("ascii")
                    )
                    self.assertIn(b"200 OK", connection.recv(1024))
            self.assertEqual(fixture.result()["path"], expected_path)

    def test_unprivileged_origin_command_keeps_payload_out_of_its_output(self):
        directory = pathlib.Path(tempfile.mkdtemp(prefix="h100-origin-test-")) / "origin"
        command = [
            "python3", "-I", str(MODULE), "--serve",
            "--directory", str(directory),
            "--expected-api-key", "local-qualification-only",
            "--timeout", "4",
        ]
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True, env={"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8"})
        try:
            ready = json.loads(process.stdout.readline())
            self.assertEqual(ready["type"], "LOCAL_TLS_READY")
            context = ssl.create_default_context(cadata=base64.b64decode(ready["ca_der_base64"]))
            context.minimum_version = ssl.TLSVersion.TLSv1_2
            context.maximum_version = ssl.TLSVersion.TLSv1_2
            with socket.create_connection((ready["host"], ready["port"]), timeout=2) as raw:
                with context.wrap_socket(raw, server_hostname=ready["server_hostname"]) as connection:
                    connection.sendall(
                        f"PATCH /local HTTP/1.1\r\nHost: {ready['authority']}\r\n"
                        "X-API-Key: local-qualification-only\r\n"
                        "Content-Length: 7\r\nConnection: close\r\n\r\nbody-01".encode("ascii")
                    )
                    self.assertIn(b"200 OK", connection.recv(1024))
            summary = json.loads(process.stdout.readline())
            self.assertEqual(summary["type"], "LOCAL_TLS_RESULT")
            self.assertEqual(summary["request_count"], 1)
            self.assertTrue(summary["complete_request"])
            self.assertTrue(summary["credential_valid"])
            self.assertEqual(summary["tls_version"], "TLSv1.2")
            self.assertNotIn("request_body", summary)
            self.assertNotIn("api_key", summary)
            self.assertNotIn("local-qualification-only", repr(summary))
            self.assertNotIn("body-01", repr(summary))
            self.assertEqual(process.wait(timeout=2), 0)
            self.assertFalse(directory.exists())
        finally:
            if process.poll() is None:
                process.send_signal(2)
                process.wait(timeout=3)
            process.stdout.close()
            process.stderr.close()
            if directory.parent.exists():
                import shutil
                shutil.rmtree(directory.parent, ignore_errors=True)

    def test_origin_signal_cleanup_removes_generated_private_keys(self):
        root = pathlib.Path(tempfile.mkdtemp(prefix="h100-origin-signal-test-"))
        origin_home = root / "origin"
        origin_home.mkdir(mode=0o700)
        directory = origin_home / "generated-certs"
        command = [
            "python3", "-I", str(MODULE), "--serve",
            "--directory", str(directory),
            "--expected-api-key", "local-qualification-only",
            "--expected-path", "/local",
            "--timeout", "20",
        ]
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True, env={"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8"})
        try:
            ready = json.loads(process.stdout.readline())
            self.assertEqual(ready["type"], "LOCAL_TLS_READY")
            process.send_signal(15)
            self.assertNotEqual(process.wait(timeout=3), 0)
            self.assertFalse(directory.exists())
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=3)
            process.stdout.close()
            process.stderr.close()
            import shutil
            shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
