"""One-request loopback TLS origin for isolated H100 qualification tests."""

import os
import pathlib
import shutil
import socket
import ssl
import subprocess
import tempfile
import threading
import time
import argparse
import base64
import hashlib
import json
import sys
import signal

MAX_HEADER_BYTES = 16 * 1024
MAX_BODY_BYTES = 64 * 1024
SAFE_ERROR_CLASSES = {
    "BrokenPipeError", "ConnectionAbortedError", "ConnectionResetError", "OSError",
    "SSLEOFError", "SSLError", "SSLSyscallError", "SSLZeroReturnError", "TimeoutError",
    "ValueError",
}
SAFE_FAILURE_STAGES = {
    "accept", "request_read", "response_write", "tls_handshake", "tls_setup", "unknown", "watchdog",
}


def _safe_error_class(error):
    name = type(error).__name__
    return name if name in SAFE_ERROR_CLASSES else "other"


class LocalTLSFixture:
    """Generate a private CA and serve one bounded PATCH request over loopback."""

    def __init__(self, timeout=10, wrong_hostname=False, tls11_only=False,
                 expected_authorization=None, directory=None, expected_path=None):
        if not 0 < timeout <= 60:
            raise ValueError("timeout must be between 0 and 60 seconds")
        self.timeout = timeout
        self.wrong_hostname = bool(wrong_hostname)
        self.tls11_only = bool(tls11_only)
        self.expected_authorization = expected_authorization
        if expected_authorization is not None and expected_authorization != "Bearer local-qualification-only":
            raise ValueError("fixture authorization must use the local qualification sentinel")
        if (expected_path is not None and
                (not isinstance(expected_path, str) or not expected_path.startswith("/") or
                 len(expected_path.encode("ascii", errors="ignore")) != len(expected_path) or
                 len(expected_path.encode("ascii", errors="ignore")) > 2048 or
                 any(ord(character) < 33 or ord(character) == 127 for character in expected_path))):
            raise ValueError("fixture path must be a bounded ASCII origin path")
        self.expected_path = expected_path
        self._requested_directory = pathlib.Path(directory) if directory is not None else None
        self.host = "127.0.0.1"
        self.server_hostname = self.host
        self.port = None
        self.directory = None
        self.ca_pem = None
        self.ca_der = None
        self._listener = None
        self._active_connection = None
        self._thread = None
        self._result = None
        self._error = None
        self._failure_stage = None
        self._done = threading.Event()
        self._closed = False
        self._deadline = None
        self._expires_at = None

    def __enter__(self):
        return self.start()

    def __exit__(self, exc_type, exc, traceback):
        self.close()

    def start(self):
        if self._listener is not None or self._closed:
            raise RuntimeError("fixture cannot be started in its current state")
        if self._requested_directory is None:
            self.directory = pathlib.Path(tempfile.mkdtemp(prefix="h100-tls-"))
        else:
            self.directory = self._requested_directory
            self.directory.mkdir(mode=0o700, parents=False, exist_ok=False)
        os.chmod(self.directory, 0o700)
        try:
            self._generate_certificates()
            self._listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            self._listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 0)
            self._listener.bind((self.host, 0))
            self._listener.listen(1)
            self._listener.settimeout(self.timeout)
            self.port = self._listener.getsockname()[1]
            self._expires_at = time.monotonic() + self.timeout
            self._deadline = threading.Timer(self.timeout, self._expire)
            self._deadline.daemon = True
            self._deadline.start()
            self._thread = threading.Thread(target=self._serve_one, name="h100-tls-origin", daemon=True)
            self._thread.start()
            return self
        except BaseException:
            self.close()
            raise

    def _run_openssl(self, *args):
        subprocess.run(["openssl", *map(str, args)], check=True, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, timeout=self.timeout)

    def _generate_certificates(self):
        root = self.directory
        ca_key = root / "ca.key"
        ca_cert = root / "ca.pem"
        server_key = root / "server.key"
        csr = root / "server.csr"
        server_cert = root / "server.pem"
        extensions = root / "server.ext"
        san_dns = "wrong.invalid" if self.wrong_hostname else "localhost"
        san = f"DNS:{san_dns}" if self.wrong_hostname else f"DNS:{san_dns},IP:127.0.0.1"
        extensions.write_text(
            "basicConstraints=critical,CA:FALSE\n"
            "keyUsage=critical,digitalSignature,keyEncipherment\n"
            "extendedKeyUsage=serverAuth\n"
            f"subjectAltName={san}\n",
            encoding="ascii",
        )
        os.chmod(extensions, 0o600)
        self._run_openssl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", ca_key,
                          "-out", ca_cert, "-days", "1", "-subj", "/CN=H100 Local Test CA",
                          "-addext", "basicConstraints=critical,CA:TRUE",
                          "-addext", "keyUsage=critical,keyCertSign,cRLSign")
        self._run_openssl("req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", server_key,
                          "-out", csr, "-subj", "/CN=localhost")
        self._run_openssl("x509", "-req", "-in", csr, "-CA", ca_cert, "-CAkey", ca_key,
                          "-CAcreateserial", "-out", server_cert, "-days", "1", "-extfile", extensions)
        der = subprocess.run(["openssl", "x509", "-in", str(ca_cert), "-outform", "DER"],
                             check=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             timeout=self.timeout).stdout
        self.ca_der = der
        self.ca_pem = ca_cert.read_text(encoding="ascii")
        for path in (ca_key, server_key):
            os.chmod(path, 0o600)
        for path in (ca_cert, csr, server_cert, extensions, root / "ca.srl"):
            if path.exists():
                os.chmod(path, 0o600)

    @property
    def authority(self):
        if self.port is None:
            raise RuntimeError("fixture has not started")
        return f"{self.host}:{self.port}"

    def _serve_one(self):
        stage = "accept"
        try:
            self._listener.settimeout(max(0.001, self._deadline_at() - time.monotonic()))
            connection, _ = self._listener.accept()
            self._active_connection = connection
            with connection:
                connection.settimeout(max(0.001, self._deadline_at() - time.monotonic()))
                stage = "tls_setup"
                context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
                if self.tls11_only:
                    context.minimum_version = ssl.TLSVersion.TLSv1_1
                    context.maximum_version = ssl.TLSVersion.TLSv1_1
                    context.set_ciphers("DEFAULT:@SECLEVEL=0")
                else:
                    context.minimum_version = ssl.TLSVersion.TLSv1_2
                    context.maximum_version = ssl.TLSVersion.TLSv1_2
                context.load_cert_chain(str(self.directory / "server.pem"), str(self.directory / "server.key"))
                stage = "tls_handshake"
                with context.wrap_socket(connection, server_side=True) as tls:
                    stage = "request_read"
                    self._result = self._read_patch(
                        tls, self._deadline_at, self.expected_authorization, self.expected_path, self.authority
                    )
                    self._result["tls_version"] = tls.version()
                    self._result["evidence"] = {
                        "request_count": 1,
                        "method": "PATCH",
                        "tls_version": tls.version(),
                    }
                    stage = "response_write"
                    self._send_response(tls)
        except (OSError, ssl.SSLError, ValueError) as exc:
            self._error = _safe_error_class(exc)
            self._failure_stage = stage
        finally:
            self._done.set()
            if self._deadline is not None:
                self._deadline.cancel()
            listener = self._listener
            self._listener = None
            if listener is not None:
                listener.close()
            self._active_connection = None

    def _deadline_at(self):
        return self._expires_at

    @staticmethod
    def _send_response(connection):
        try:
            connection.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            return True
        except (OSError, ssl.SSLError):
            return False

    def _expire(self):
        connection = self._active_connection
        if connection is not None:
            try:
                connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                connection.close()
            except OSError:
                pass
        listener = self._listener
        if listener is not None:
            try:
                listener.close()
            except OSError:
                pass

    @staticmethod
    def _read_patch(connection, deadline_at, expected_authorization=None, expected_path=None,
                    expected_host=None):
        request = bytearray()
        while b"\r\n\r\n" not in request:
            if len(request) >= MAX_HEADER_BYTES:
                raise ValueError("request headers exceed limit")
            connection.settimeout(max(0.001, deadline_at() - time.monotonic()))
            part = connection.recv(min(2048, MAX_HEADER_BYTES - len(request)))
            if not part:
                raise ValueError("truncated request headers")
            request.extend(part)
        split = request.index(b"\r\n\r\n") + 4
        head, body = bytes(request[:split]), bytearray(request[split:])
        lines = head[:-4].decode("ascii").split("\r\n")
        if not lines:
            raise ValueError("missing request line")
        request_parts = lines[0].split(" ")
        if (len(request_parts) != 3 or request_parts[0] != "PATCH" or request_parts[2] != "HTTP/1.1" or
                not request_parts[1].startswith("/") or
                (expected_path is not None and request_parts[1] != expected_path)):
            raise ValueError("request line does not match the bounded PATCH contract")
        headers = {}
        for line in lines[1:]:
            if ":" not in line:
                raise ValueError("malformed request header")
            name, value = line.split(":", 1)
            headers.setdefault(name.lower(), []).append(value.strip())
        lengths = headers.get("content-length", [])
        if len(lengths) != 1 or not lengths[0].isdigit():
            raise ValueError("request must have one content length")
        authorization = headers.get("authorization", [])
        hosts = headers.get("host", [])
        if len(hosts) != 1 or (expected_host is not None and hosts[0] != expected_host):
            raise ValueError("request Host does not match the local TLS listener")
        authorization_valid = (expected_authorization is None or
                               len(authorization) == 1 and authorization[0] == expected_authorization)
        if not authorization_valid:
            raise ValueError("local authorization sentinel mismatch")
        length = int(lengths[0])
        if length > MAX_BODY_BYTES:
            raise ValueError("request body exceeds limit")
        while len(body) < length:
            connection.settimeout(max(0.001, deadline_at() - time.monotonic()))
            part = connection.recv(min(4096, length - len(body)))
            if not part:
                raise ValueError("truncated request body")
            body.extend(part)
        if len(body) != length:
            raise ValueError("unexpected bytes after request body")
        return {"request_count": 1, "method": "PATCH", "request_body": bytes(body),
                "path": request_parts[1], "body_bytes": length,
                "authorization_valid": authorization_valid}

    def result(self, timeout=None):
        """Return the bounded origin result; only this in-process value contains the body."""
        wait_for = self.timeout if timeout is None else min(timeout, self.timeout)
        if not self._done.wait(wait_for):
            self._failure_stage = "watchdog"
            raise TimeoutError("local TLS origin did not finish within its watchdog")
        if self._error:
            raise RuntimeError(f"local TLS origin failed: {self._error}")
        if self._result is None:
            raise RuntimeError("local TLS origin received no complete request")
        return dict(self._result)

    def close(self):
        if self._closed:
            return
        self._closed = True
        listener = self._listener
        self._listener = None
        if listener is not None:
            try:
                listener.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            listener.close()
        if self._thread is not None and self._thread is not threading.current_thread():
            self._thread.join(self.timeout + 0.5)
        if self._deadline is not None:
            self._deadline.cancel()
        if self.directory is not None:
            shutil.rmtree(self.directory, ignore_errors=True)
        self.ca_pem = None
        self.ca_der = None


def _serve_cli(argv=None):
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--serve", action="store_true")
    parser.add_argument("--directory", required=True)
    parser.add_argument("--expected-authorization", required=True)
    parser.add_argument("--expected-path")
    parser.add_argument("--timeout", type=float, default=15)
    args = parser.parse_args(argv)
    if not args.serve or args.expected_authorization != "Bearer local-qualification-only":
        parser.error("local-only fixture sentinel and serve mode are required")

    fixture = LocalTLSFixture(timeout=args.timeout, expected_authorization=args.expected_authorization,
                              directory=args.directory, expected_path=args.expected_path)

    def stop_on_sigterm(signum, _frame):
        raise SystemExit(128 + signum)

    previous_sigterm = signal.signal(signal.SIGTERM, stop_on_sigterm)
    try:
        fixture.start()
        ready = {
            "type": "LOCAL_TLS_READY",
            "host": fixture.host,
            "port": fixture.port,
            "authority": fixture.authority,
            "server_hostname": fixture.server_hostname,
            "ca_der_base64": base64.b64encode(fixture.ca_der).decode("ascii"),
        }
        sys.stdout.write(json.dumps(ready, sort_keys=True, separators=(",", ":")) + "\n")
        sys.stdout.flush()
        result = fixture.result()
        summary = {
            "type": "LOCAL_TLS_RESULT",
            "request_count": result["request_count"],
            "complete_request": True,
            "method": result["method"],
            "path": result["path"],
            "body_bytes": result["body_bytes"],
            "body_sha256": hashlib.sha256(result["request_body"]).hexdigest(),
            "authorization_valid": result["authorization_valid"],
            "tls_version": result["tls_version"],
        }
        sys.stdout.write(json.dumps(summary, sort_keys=True, separators=(",", ":")) + "\n")
        sys.stdout.flush()
        return 0
    except (OSError, RuntimeError, TimeoutError, ValueError, ssl.SSLError) as exc:
        stage = fixture._failure_stage
        if stage not in SAFE_FAILURE_STAGES:
            stage = "unknown"
        error_class = fixture._error or _safe_error_class(exc)
        if error_class not in SAFE_ERROR_CLASSES:
            error_class = "other"
        error = {
            "type": "LOCAL_TLS_ERROR",
            "reason": "origin_failed",
            "stage": stage,
            "error_class": error_class,
        }
        sys.stdout.write(json.dumps(error, sort_keys=True, separators=(",", ":")) + "\n")
        sys.stdout.flush()
        return 1
    finally:
        fixture.close()
        signal.signal(signal.SIGTERM, previous_sigterm)


if __name__ == "__main__":
    raise SystemExit(_serve_cli())
