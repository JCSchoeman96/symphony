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

MAX_HEADER_BYTES = 16 * 1024
MAX_BODY_BYTES = 64 * 1024


class LocalTLSFixture:
    """Generate a private CA and serve one bounded PATCH request over loopback."""

    def __init__(self, timeout=10, wrong_hostname=False, tls11_only=False):
        if not 0 < timeout <= 60:
            raise ValueError("timeout must be between 0 and 60 seconds")
        self.timeout = timeout
        self.wrong_hostname = bool(wrong_hostname)
        self.tls11_only = bool(tls11_only)
        self.host = "127.0.0.1"
        self.server_hostname = "localhost"
        self.port = None
        self.directory = None
        self.ca_pem = None
        self.ca_der = None
        self._listener = None
        self._active_connection = None
        self._thread = None
        self._result = None
        self._error = None
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
        self.directory = pathlib.Path(tempfile.mkdtemp(prefix="h100-tls-"))
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
        extensions.write_text(
            "basicConstraints=critical,CA:FALSE\n"
            "keyUsage=critical,digitalSignature,keyEncipherment\n"
            "extendedKeyUsage=serverAuth\n"
            f"subjectAltName=DNS:{san_dns},IP:127.0.0.1\n",
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
        return f"localhost:{self.port}"

    def _serve_one(self):
        try:
            self._listener.settimeout(max(0.001, self._deadline_at() - time.monotonic()))
            connection, _ = self._listener.accept()
            self._active_connection = connection
            with connection:
                connection.settimeout(max(0.001, self._deadline_at() - time.monotonic()))
                context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
                if self.tls11_only:
                    context.minimum_version = ssl.TLSVersion.TLSv1_1
                    context.maximum_version = ssl.TLSVersion.TLSv1_1
                    context.set_ciphers("DEFAULT:@SECLEVEL=0")
                else:
                    context.minimum_version = ssl.TLSVersion.TLSv1_2
                    context.maximum_version = ssl.TLSVersion.TLSv1_2
                context.load_cert_chain(str(self.directory / "server.pem"), str(self.directory / "server.key"))
                with context.wrap_socket(connection, server_side=True) as tls:
                    self._result = self._read_patch(tls, self._deadline_at)
                    self._result["tls_version"] = tls.version()
                    self._result["evidence"] = {
                        "request_count": 1,
                        "method": "PATCH",
                        "tls_version": tls.version(),
                    }
                    tls.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        except (OSError, ssl.SSLError, ValueError) as exc:
            self._error = type(exc).__name__
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
    def _read_patch(connection, deadline_at):
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
        if not lines or lines[0] != "PATCH /local HTTP/1.1":
            raise ValueError("expected one PATCH /local HTTP/1.1 request")
        lengths = [line.split(":", 1)[1].strip() for line in lines[1:] if line.lower().startswith("content-length:")]
        if len(lengths) != 1 or not lengths[0].isdigit():
            raise ValueError("request must have one content length")
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
        return {"request_count": 1, "method": "PATCH", "request_body": bytes(body)}

    def result(self, timeout=None):
        """Return the bounded origin result; only this in-process value contains the body."""
        wait_for = self.timeout if timeout is None else min(timeout, self.timeout)
        if not self._done.wait(wait_for):
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
