import importlib.util
import pathlib
import socket
import ssl
import unittest

MODULE = pathlib.Path(__file__).parents[2] / "priv/h100/local_tls_fixture.py"
spec = importlib.util.spec_from_file_location("h100_local_tls_fixture", MODULE)
fixture_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture_module)


class LocalTLSFixtureTests(unittest.TestCase):
    def request(self, fixture, context):
        with socket.create_connection((fixture.host, fixture.port), timeout=2) as raw:
            with context.wrap_socket(raw, server_hostname=fixture.server_hostname) as connection:
                connection.sendall(b"PATCH /local HTTP/1.1\r\nHost: localhost\r\nContent-Length: 7\r\nConnection: close\r\n\r\nbody-01")
                return connection.recv(1024)

    def verified_context(self, fixture):
        context = ssl.create_default_context(cadata=fixture.ca_pem)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.maximum_version = ssl.TLSVersion.TLSv1_2
        return context

    def test_tls12_serves_one_patch_and_exposes_body_only_in_process_result(self):
        with fixture_module.LocalTLSFixture(timeout=2) as fixture:
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

    def test_wrong_hostname_certificate_fails_peer_verification(self):
        with fixture_module.LocalTLSFixture(timeout=2, wrong_hostname=True) as fixture:
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


if __name__ == "__main__":
    unittest.main()
