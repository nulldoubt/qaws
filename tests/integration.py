#!/usr/bin/env python3

import gzip
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import tempfile
import time
import traceback


ROOT = Path(__file__).resolve().parents[1]
BINARY = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / "zig-out/bin/qaws").resolve()


class Failure(RuntimeError):
    pass


def expect(condition, message):
    if not condition:
        raise Failure(message)


def run_qaws(*args, expected=0, timeout=10):
    result = subprocess.run(
        [str(BINARY), *map(str, args)],
        cwd=ROOT,
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    if result.returncode != expected:
        raise Failure(
            f"qaws {' '.join(map(str, args))} returned {result.returncode}, "
            f"expected {expected}\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )
    return result


def unused_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def wait_for_port(port, timeout=5):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return
        except OSError:
            time.sleep(0.02)
    raise Failure(f"server did not listen on port {port}")


def wait_for_port_closed(port, timeout=5):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                time.sleep(0.02)
        except OSError:
            return
    raise Failure(f"server still listens on port {port}")


def read_all(sock):
    chunks = []
    while True:
        try:
            chunk = sock.recv(65536)
        except ConnectionResetError:
            return b"".join(chunks)
        if not chunk:
            return b"".join(chunks)
        chunks.append(chunk)


def parse_head(raw):
    head, marker, body = raw.partition(b"\r\n\r\n")
    expect(marker != b"", "response has no header terminator")
    lines = head.split(b"\r\n")
    status_parts = lines[0].split(b" ", 2)
    expect(len(status_parts) == 3, "response has malformed status line")
    headers = {}
    for line in lines[1:]:
        name, separator, value = line.partition(b":")
        expect(separator != b"", f"response has malformed header: {line!r}")
        headers[name.decode("ascii").lower()] = value.strip().decode("ascii")
    return int(status_parts[1]), headers, body


def request(port, method, target, headers=None, body=b""):
    fields = {"Host": "localhost", "Connection": "close"}
    if headers:
        fields.update(headers)
    request_bytes = f"{method} {target} HTTP/1.1\r\n".encode("ascii")
    request_bytes += b"".join(f"{name}: {value}\r\n".encode("ascii") for name, value in fields.items())
    request_bytes += b"\r\n" + body
    with socket.create_connection(("127.0.0.1", port), timeout=5) as sock:
        sock.settimeout(10)
        sock.sendall(request_bytes)
        raw = read_all(sock)
    return parse_head(raw)


def raw_request(port, payload):
    with socket.create_connection(("127.0.0.1", port), timeout=5) as sock:
        sock.settimeout(10)
        sock.sendall(payload)
        return parse_head(read_all(sock))


def parse_pipeline(raw, methods):
    responses = []
    remaining = raw
    for method in methods:
        head, marker, tail = remaining.partition(b"\r\n\r\n")
        expect(marker != b"", f"pipeline ended after {len(responses)} responses")
        status, headers, _ = parse_head(head + marker)
        content_length = int(headers.get("content-length", "0"))
        body_length = 0 if method == "HEAD" or status in (204, 304) else content_length
        expect(len(tail) >= body_length, f"pipeline response {len(responses)} has a short body")
        responses.append((status, headers, tail[:body_length]))
        remaining = tail[body_length:]
    expect(remaining == b"", f"pipeline has {len(remaining)} unexpected trailing bytes")
    return responses


def pipeline(port, requests, pause_before_read=0, receive_buffer=None):
    payload = bytearray()
    methods = []
    for index, (method, target, headers) in enumerate(requests):
        methods.append(method)
        connection = "close" if index == len(requests) - 1 else "keep-alive"
        fields = {"Host": "localhost", "Connection": connection, **headers}
        payload.extend(f"{method} {target} HTTP/1.1\r\n".encode("ascii"))
        for name, value in fields.items():
            payload.extend(f"{name}: {value}\r\n".encode("ascii"))
        payload.extend(b"\r\n")

    with socket.create_connection(("127.0.0.1", port), timeout=5) as sock:
        sock.settimeout(20)
        if receive_buffer:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, receive_buffer)
        sock.sendall(payload)
        if pause_before_read:
            time.sleep(pause_before_read)
        raw = read_all(sock)
    return parse_pipeline(raw, methods)


def write_config(path, serve, port, *, cache=True, sendfile=True, precompressed=True, daemon=False, max_connections=64):
    config = {
        "listen": {"host": "127.0.0.1", "port": port},
        "serve": str(serve),
        "daemon": {
            "enabled": daemon,
            "pid_file": str(path.with_suffix(".pid")) if daemon else None,
            "log_file": str(path.with_suffix(".log")) if daemon else None,
        },
        "logging": {"format": "plain", "access": False},
        "security": {"dotfiles": "deny_except_well_known"},
        "cache": {
            "enabled": cache,
            "max_file_bytes": 262144,
            "max_total_bytes": 16777216,
            "revalidate_ms": 1000,
        },
        "headers": {"Cache-Control": "public, max-age=60"},
        "http": {
            "last_modified": True,
            "trailing_slash_redirect": True,
            "keep_alive": True,
            "sendfile": sendfile,
            "etag": True,
            "range_requests": True,
            "precompressed": precompressed,
            "keep_alive_timeout_ms": 1000,
            "max_requests_per_connection": 1000,
            "max_connections": max_connections,
            "workers": 2,
        },
    }
    path.write_text(json.dumps(config), encoding="utf-8")


class Server:
    def __init__(self, config, port):
        self.config = config
        self.port = port
        self.process = None
        self.log = config.with_suffix(".foreground.log")
        self.log_file = None

    def __enter__(self):
        self.log_file = self.log.open("wb")
        self.process = subprocess.Popen(
            [str(BINARY), "--config", str(self.config)],
            cwd=ROOT,
            stdout=subprocess.DEVNULL,
            stderr=self.log_file,
        )
        try:
            wait_for_port(self.port)
        except Exception:
            self.stop()
            raise
        return self

    def stop(self):
        if self.process and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
        if self.log_file:
            self.log_file.close()
            self.log_file = None

    def __exit__(self, exc_type, exc, traceback):
        self.stop()
        if exc and self.log.exists():
            sys.stderr.write(self.log.read_text(encoding="utf-8", errors="replace"))


def expect_response(port, method, target, status, body=None, headers=None):
    actual_status, actual_headers, actual_body = request(port, method, target, headers)
    expect(actual_status == status, f"{method} {target} returned {actual_status}, expected {status}")
    if body is not None:
        expect(actual_body == body, f"{method} {target} returned unexpected body")
    return actual_headers, actual_body


def test_protocol(root, config, port):
    with Server(config, port):
        expect_response(port, "GET", "/", 200, b"integration-index\n")
        headers, _ = expect_response(port, "HEAD", "/", 200, b"")
        expect(headers["content-length"] == str(len(b"integration-index\n")), "HEAD has wrong content length")
        expect_response(port, "GET", "/missing", 404, b"Not found\n")
        expect_response(port, "HEAD", "/missing", 404, b"")
        expect_response(port, "GET", "/../outside", 403, b"Forbidden\n")
        expect_response(port, "GET", "/.env", 403, b"Forbidden\n")
        expect_response(port, "GET", "/.well-known/security.txt", 200, b"security\n")
        redirect_headers, _ = expect_response(port, "HEAD", "/docs", 308, b"")
        expect(redirect_headers["location"] == "/docs/", "directory redirect has wrong location")
        expect_response(port, "GET", "/docs/", 200, b"docs-index\n")

        status, _, _ = raw_request(port, b"GET / HTTP/1.1\r\nConnection: close\r\n\r\n")
        expect(status == 400, "HTTP/1.1 without Host was not rejected")
        status, _, _ = raw_request(
            port,
            b"GET / HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: identity\r\nConnection: close\r\n\r\n",
        )
        expect(status == 400, "Transfer-Encoding was not rejected")
        status, _, _ = raw_request(
            port,
            b"GET / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\nContent-Length: 1\r\nConnection: close\r\n\r\n",
        )
        expect(status == 400, "conflicting Content-Length was not rejected")

        identity_headers, _ = expect_response(port, "GET", "/app.js", 200, b"identity-javascript\n")
        expect(identity_headers["content-type"].startswith("application/javascript"), "identity MIME is wrong")
        expect("content-encoding" not in identity_headers, "identity response is encoded")
        identity_etag = identity_headers["etag"]

        br_headers, br_body = expect_response(
            port,
            "GET",
            "/app.js",
            200,
            b"brotli-sidecar-bytes",
            {"Accept-Encoding": "gzip, br"},
        )
        expect(br_headers["content-encoding"] == "br", "Brotli was not preferred on a tie")
        expect(br_headers["vary"] == "Accept-Encoding", "encoded response lacks Vary")
        expect(br_headers["etag"] != identity_etag, "representation ETags are not distinct")

        gzip_headers, gzip_body = expect_response(
            port,
            "GET",
            "/app.js",
            200,
            gzip.compress(b"identity-javascript\n"),
            {"Accept-Encoding": "br;q=0.2, gzip;q=1, identity;q=0.1"},
        )
        expect(gzip_headers["content-encoding"] == "gzip", "gzip q-value was not honored")
        expect(gzip_body != br_body, "gzip and Brotli fixtures unexpectedly match")

        not_modified_headers, _ = expect_response(
            port,
            "GET",
            "/app.js",
            304,
            b"",
            {"Accept-Encoding": "br", "If-None-Match": br_headers["etag"]},
        )
        expect(not_modified_headers["content-encoding"] == "br", "encoded 304 lacks Content-Encoding")
        expect_response(
            port,
            "GET",
            "/app.js",
            200,
            b"brotli-sidecar-bytes",
            {"Accept-Encoding": "br", "If-None-Match": identity_etag},
        )

        range_headers, range_body = expect_response(
            port,
            "GET",
            "/app.js",
            206,
            b"rotli",
            {"Accept-Encoding": "br", "Range": "bytes=1-5"},
        )
        expect(range_headers["content-range"] == "bytes 1-5/20", "encoded range metadata is wrong")
        expect(range_body == b"rotli", "encoded range addresses wrong bytes")
        expect_response(port, "GET", "/app.js", 206, b"ipt\n", {"Range": "bytes=-4"})
        unsatisfied_headers, _ = expect_response(port, "GET", "/app.js", 416, b"Range not satisfiable\n", {"Range": "bytes=999-"})
        expect(unsatisfied_headers["content-range"] == "bytes */20", "416 has wrong complete length")
        expect_response(port, "GET", "/app.js", 200, b"identity-javascript\n", {"Range": "bytes=0-1, 4-5"})
        expect_response(
            port,
            "GET",
            "/app.js",
            200,
            b"brotli-sidecar-bytes",
            {"Accept-Encoding": "br", "Range": "bytes=0-3", "If-Range": br_headers["etag"]},
        )

        not_acceptable_headers, _ = expect_response(
            port,
            "GET",
            "/app.js",
            406,
            b"Not acceptable\n",
            {"Accept-Encoding": "br;q=0, gzip;q=0, identity;q=0"},
        )
        expect(not_acceptable_headers["vary"] == "Accept-Encoding", "406 lacks Vary")
        direct_headers, direct_body = expect_response(port, "GET", "/app.js.gz", 200, gzip.compress(b"identity-javascript\n"), {"Accept-Encoding": "br"})
        expect("content-encoding" not in direct_headers, "direct sidecar request was recursively negotiated")
        expect(direct_body == gzip_body, "direct gzip sidecar bytes changed")

        mutable_headers, _ = expect_response(port, "GET", "/mutable.txt", 200, b"before\n")
        (root / "mutable.txt").write_bytes(b"after-refresh\n")
        time.sleep(1.1)
        refreshed_headers, _ = expect_response(port, "GET", "/mutable.txt", 200, b"after-refresh\n")
        expect(refreshed_headers["etag"] != mutable_headers["etag"], "cache refresh retained stale ETag")

        large = (root / "large.bin").read_bytes()
        expect_response(port, "GET", "/large.bin", 200, large)
        expect_response(port, "GET", "/large.bin", 206, large[104857:209715], {"Range": "bytes=104857-209714"})

        for index in range(64):
            expect_response(port, "GET", f"/order/{index:02d}.txt", 200, f"order-{index:02d}\n".encode())
        ordered = pipeline(port, [("GET", f"/order/{index:02d}.txt", {}) for index in range(64)])
        for index, (status, _, response_body) in enumerate(ordered):
            expect(status == 200, f"ordered pipeline response {index} returned {status}")
            expect(response_body == f"order-{index:02d}\n".encode(), f"ordered pipeline response {index} is out of order")

        partial_body = (root / "partial.bin").read_bytes()
        expect_response(port, "GET", "/partial.bin", 200, partial_body)
        partial = pipeline(
            port,
            [("GET", "/partial.bin", {}) for _ in range(64)],
            pause_before_read=0.2,
            receive_buffer=4096,
        )
        expect(len(partial) == 64, "partial-write pipeline did not return 64 responses")
        for index, (status, _, response_body) in enumerate(partial):
            expect(status == 200 and response_body == partial_body, f"partial-write pipeline response {index} is corrupt")

        idle = []
        try:
            for _ in range(2):
                sock = socket.create_connection(("127.0.0.1", port), timeout=5)
                sock.sendall(b"GET / HTTP/1.1\r\nHost: localhost\r\n")
                idle.append(sock)
            time.sleep(0.1)
            expect_response(port, "GET", "/", 503, b"Server busy\n")
        finally:
            for sock in idle:
                sock.close()


def test_buffered_fallback(root, config, port):
    with Server(config, port):
        identity = (root / "app.js").read_bytes()
        headers, _ = expect_response(port, "GET", "/app.js", 200, identity, {"Accept-Encoding": "br"})
        expect("content-encoding" not in headers, "disabled precompression still selected a sidecar")
        expect_response(port, "GET", "/large.bin", 200, (root / "large.bin").read_bytes())


def test_daemon(root, config, port):
    _ = root
    if os.name == "nt":
        return
    pid_file = config.with_suffix(".pid")
    try:
        run_qaws("--config", config)
        wait_for_port(port)
        run_qaws("status", "--config", config)
        expect_response(port, "GET", "/", 200, b"integration-index\n")
        run_qaws("restart", "--config", config)
        wait_for_port(port)
        expect_response(port, "GET", "/", 200, b"integration-index\n")
        run_qaws("stop", "--config", config, "--force")
        wait_for_port_closed(port)
        expect(not pid_file.exists(), "daemon PID file remained after stop")
    finally:
        if pid_file.exists():
            try:
                run_qaws("stop", "--config", config, "--force", timeout=5)
            except Exception:
                pass


def main():
    expect(BINARY.is_file(), f"qaws binary not found: {BINARY}")
    version_source = (ROOT / "src/version.zig").read_text(encoding="utf-8")
    version_match = re.search(r'pub const string = "([0-9.]+)";', version_source)
    expect(version_match is not None, "could not read source version")
    version = version_match.group(1)
    expect(run_qaws("version").stdout.strip() == f"qaws {version}", "version output is inconsistent")
    run_qaws("help")
    run_qaws("check", "--config", ROOT / "qaws.example.json")

    with tempfile.TemporaryDirectory(prefix="qaws-integration.") as temporary:
        root = Path(temporary) / "public"
        root.mkdir()
        (root / "index.html").write_bytes(b"integration-index\n")
        (root / ".env").write_bytes(b"secret\n")
        (root / ".well-known").mkdir()
        (root / ".well-known/security.txt").write_bytes(b"security\n")
        (root / "docs").mkdir()
        (root / "docs/index.html").write_bytes(b"docs-index\n")
        (root / "app.js").write_bytes(b"identity-javascript\n")
        (root / "app.js.gz").write_bytes(gzip.compress(b"identity-javascript\n"))
        (root / "app.js.br").write_bytes(b"brotli-sidecar-bytes")
        (root / "mutable.txt").write_bytes(b"before\n")
        (root / "large.bin").write_bytes(os.urandom(1024 * 1024))
        (root / "partial.bin").write_bytes((b"partial-response-" * 8192)[:128 * 1024])
        (root / "order").mkdir()
        for index in range(64):
            (root / "order" / f"{index:02d}.txt").write_bytes(f"order-{index:02d}\n".encode())

        primary_port = unused_port()
        primary_config = Path(temporary) / "primary.json"
        write_config(primary_config, root, primary_port, max_connections=2)
        run_qaws("check", "--config", primary_config)
        print("integration: protocol, cache, pipeline, and overload")
        test_protocol(root, primary_config, primary_port)

        fallback_port = unused_port()
        fallback_config = Path(temporary) / "fallback.json"
        write_config(fallback_config, root, fallback_port, cache=False, sendfile=False, precompressed=False)
        print("integration: cache-disabled buffered fallback")
        test_buffered_fallback(root, fallback_config, fallback_port)

        invalid_config = Path(temporary) / "invalid.json"
        invalid_config.write_text('{"http":{"unknown":true}}', encoding="utf-8")
        invalid = subprocess.run(
            [str(BINARY), "check", "--config", str(invalid_config)],
            cwd=ROOT,
            capture_output=True,
            text=True,
        )
        expect(invalid.returncode != 0, "strict JSON accepted an unknown key")
        expect("UnknownField" in invalid.stderr, "strict JSON returned the wrong validation error")

        daemon_port = unused_port()
        daemon_config = Path(temporary) / "daemon.json"
        write_config(daemon_config, root, daemon_port, daemon=True)
        print("integration: daemon start, status, restart, and forced stop")
        test_daemon(root, daemon_config, daemon_port)

    print("integration: all checks passed")


if __name__ == "__main__":
    try:
        main()
    except (Failure, OSError, subprocess.SubprocessError) as error:
        print(f"integration failure: {error}", file=sys.stderr)
        traceback.print_exc()
        raise SystemExit(1)
