# qaws

qaws is the Quick Arm Webserver: a tiny static file server written in Zig with no runtime dependencies.
It is built for the simple case where a directory already contains finished static files and the server should do only one job: bind a TCP port and serve those files.

The default behavior is intentionally plain:

```sh
qaws
```

That serves `./public` on `0.0.0.0:80`.

## Status

qaws is currently `0.1.0`.

It supports HTTP/1.1 `GET` and `HEAD`, serves static files, maps directory requests to `index.html`, and rejects path traversal. It does not do TLS, compression, caching policy, access logs, directory listings, reverse proxying, upload handling, or SPA fallback.

## Usage

```sh
qaws [--host <addr>] [--port <port>] [--serve <directory>] [-d]
qaws help
qaws version
```

Defaults:

| Option | Default | Meaning |
| --- | --- | --- |
| `--host <addr>` | `0.0.0.0` | Address to bind. Use `127.0.0.1` when only local clients or a tunnel should reach it. |
| `--port <port>` | `80` | TCP port to listen on. Ports below `1024` usually require root or a capability on Unix-like systems. |
| `--serve <directory>` | `./public` | Directory to serve. Requests are resolved inside this root. |
| `-d` | off | Daemonize with POSIX fork/session detach behavior where supported. |

Examples:

```sh
# Serve ./public on port 8080 for local development.
qaws --port 8080

# Bind only localhost, useful behind Cloudflare Tunnel or another local proxy.
qaws --host 127.0.0.1 --port 18086 --serve ./public

# Serve another directory.
qaws --port 8080 --serve /srv/site

# Run in daemon mode.
qaws --host 0.0.0.0 --port 8080 --serve /srv/site -d
```

The utility commands are:

```sh
qaws help
qaws version
```

`qaws version` prints:

```text
qaws 0.1.0
```

## Serving Rules

- `GET` returns headers and a file body.
- `HEAD` returns the same headers as `GET` without the body.
- `/` resolves to `index.html`.
- `/docs/` resolves to `docs/index.html`.
- Missing files return `404`.
- Unsupported methods return `405` with `Allow: GET, HEAD`.
- Directory listings are never generated.
- There is no SPA fallback. A missing route stays missing.
- `..`, encoded traversal, NUL bytes, encoded slashes, and backslashes in request paths are rejected.

Common MIME types are detected for HTML, CSS, JavaScript, JSON, text, SVG, PNG, JPEG, GIF, WebP, ICO, WASM, PDF, XML, WOFF, and WOFF2. Unknown extensions use `application/octet-stream`.

## Security Limits

qaws is deliberately small. Put it behind the right outer layer for anything public or sensitive.

- No TLS: terminate HTTPS with Cloudflare Tunnel, Caddy, nginx, Traefik, a load balancer, or another frontend.
- No authentication or authorization.
- No rate limiting.
- No request logging.
- No cache headers.
- No hardening beyond static path normalization and `resolve_beneath` file opens.

For a private tunnel, prefer:

```sh
qaws --host 127.0.0.1 --port 18086 --serve ./public
cloudflared tunnel --url http://localhost:18086
```

For a LAN server, bind `0.0.0.0` only when other machines should be able to connect:

```sh
qaws --host 0.0.0.0 --port 8080 --serve ./public
```

## Termux Notes

Termux uses Android's Bionic environment, not glibc. The Termux release target is:

```text
aarch64-linux-android
```

That artifact is built as Android PIE/static-PIE so it avoids the `unexpected e_type: 2` loader error caused by normal Linux `ET_EXEC` binaries on Android. qaws also keeps the current argv workaround for static Termux startup behavior by reading `/proc/self/cmdline` on Linux and ignoring duplicated argv0 forms.

Install a downloaded Termux binary like this:

```sh
chmod +x ./qaws
install -m 755 ./qaws "$PREFIX/bin/qaws"
qaws version
```

Use a high port on Termux unless the device is rooted or otherwise configured to allow privileged binds:

```sh
qaws --host 0.0.0.0 --port 8080 --serve "$HOME/website/public"
```

If you serve through Cloudflare Tunnel from Termux, bind qaws locally and point the tunnel at that local port:

```sh
qaws --host 127.0.0.1 --port 18086 --serve "$HOME/website/public"
cloudflared tunnel --url http://localhost:18086
```

Tunnel latency and phone CPU scheduling can dominate perceived speed. Benchmark direct loopback first before blaming qaws:

```sh
curl -o /dev/null -s -w 'time_total=%{time_total} size=%{size_download}\n' http://127.0.0.1:18086/
```

## Build

qaws is a Zig `0.16.0` project and has no package dependencies.

Native build:

```sh
zig build
```

Run unit tests:

```sh
zig test src/main.zig
zig build test
```

Run from the build system:

```sh
zig build run -- --host 127.0.0.1 --port 8080 --serve ./public
```

Build one target manually:

```sh
zig build -Dtarget=aarch64-linux-gnu -Doptimize=ReleaseFast
```

Build the Termux target manually:

```sh
zig build -Dtarget=aarch64-linux-android -Doptimize=ReleaseFast --prefix zig-out/termux-aarch64
```

The normal install output is `zig-out/bin/qaws` unless `--prefix` is changed.

## Release Builds

The repeatable release command is:

```sh
./scripts/build-release.sh
```

The script removes `dist/`, then runs:

```sh
zig build release --prefix .
```

Release artifacts are written as named binaries under `dist/`.

Current practical server targets:

| Target | Artifact |
| --- | --- |
| `x86_64-linux-musl` | `dist/qaws-0.1.0-x86_64-linux-musl` |
| `x86_64-linux-gnu` | `dist/qaws-0.1.0-x86_64-linux-gnu` |
| `aarch64-linux-musl` | `dist/qaws-0.1.0-aarch64-linux-musl` |
| `aarch64-linux-gnu` | `dist/qaws-0.1.0-aarch64-linux-gnu` |
| `arm-linux-musleabihf` | `dist/qaws-0.1.0-arm-linux-musleabihf` |
| `riscv64-linux-musl` | `dist/qaws-0.1.0-riscv64-linux-musl` |
| `aarch64-linux-android` | `dist/qaws-0.1.0-aarch64-linux-android` |
| `aarch64-macos` | `dist/qaws-0.1.0-aarch64-macos` |
| `x86_64-macos` | `dist/qaws-0.1.0-x86_64-macos` |
| `x86_64-windows-gnu` | `dist/qaws-0.1.0-x86_64-windows-gnu.exe` |
| `aarch64-windows-gnu` | `dist/qaws-0.1.0-aarch64-windows-gnu.exe` |
| `x86_64-freebsd` | `dist/qaws-0.1.0-x86_64-freebsd` |

The release matrix intentionally excludes targets that are not practical qaws server artifacts, including WASI, iOS, tvOS, watchOS, UEFI, GPU, console, freestanding, and similar non-server environments.

`dist/` is ignored by git. Release binaries are generated artifacts, not source.

## Smoke Test

Use a high port locally:

```sh
zig build
./zig-out/bin/qaws --host 127.0.0.1 --port 18086 --serve ./public
```

In another shell:

```sh
curl -i http://127.0.0.1:18086/
curl -I http://127.0.0.1:18086/
curl -i http://127.0.0.1:18086/nope
curl -i http://127.0.0.1:18086/../build.zig
```

Expected results:

- `/` returns `200` and serves `public/index.html`.
- `HEAD /` returns headers without a body.
- Missing paths return `404`.
- Traversal attempts return `403`.

## Troubleshooting

`Permission denied` or bind failure on port `80`:

Use a higher port, run with the needed privileges, or give the binary the appropriate OS capability. For local testing, prefer `--port 8080`.

`unexpected e_type: 2` on Termux:

You are running a normal Linux binary instead of the Android/Termux artifact. Use the `aarch64-linux-android` build.

`qaws: unknown argument` for `help` or `version` on Termux:

Use a current Termux build. The code includes a Linux `/proc/self/cmdline` argv workaround and tests for duplicated argv0 behavior.

Cloudflare Tunnel feels slow:

Measure direct qaws loopback first with `curl` and compare it with the tunnel URL. Quick tunnels add extra network hops and can be slower than the local server.

`-d` returns immediately but the site is not reachable:

Check that the serve directory exists before daemonizing and that the selected port is not already in use. For daemon mode, qaws resolves the serve directory before detaching so relative paths do not break after the process changes directory.
