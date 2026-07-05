# qaws

qaws is the Quick Arm Webserver: a tiny static file server written in Zig with no runtime dependencies.
It is built for the simple case where a directory already contains finished static files and the server should do only one job: bind a TCP port and serve those files.

The default behavior is intentionally plain:

```sh
qaws
```

That serves `./public` on `0.0.0.0:80`.

## Status

qaws is currently `0.2.1`.

It supports HTTP/1.1 `GET` and `HEAD`, serves static files, maps directory requests to `index.html`, rejects path traversal, logs requests by default, supports explicit JSON config, and can manage Unix-style daemons with PID files. It does not do TLS, authentication, runtime compression, directory listings, reverse proxying, upload handling, or SPA fallback.

## Usage

```sh
qaws [--host <addr>] [--port <port>] [--serve <directory>] [-d]
qaws check --config <file>
qaws status [--config <file>] [--pid-file <path>]
qaws stop [--config <file>] [--pid-file <path>] [--force]
qaws restart [--config <file>] [--pid-file <path>] [--force]
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
| `--config <path>` | none | Load strict JSON config. Config is never auto-discovered. |
| `--log-format <format>` | `plain` | `plain` or `jsonl`. |
| `--log-file <path>` | stderr, or derived in daemon mode | Log output path. |
| `--access-log` / `--no-access-log` | access logs on | Enable or disable per-request access logs. |
| `--pid-file <path>` | derived in daemon mode | PID file for daemon start/status/stop/restart. |

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

# Use explicit config.
qaws --config qaws.json

# Validate config and serve directory without starting.
qaws check --config qaws.json

# Manage a daemon.
qaws status --pid-file /tmp/qaws.pid
qaws stop --pid-file /tmp/qaws.pid
qaws restart --config qaws.json
```

The utility commands are:

```sh
qaws help
qaws version
```

`qaws version` prints:

```text
qaws 0.2.1
```

## Serving Rules

- `GET` returns headers and a file body.
- `HEAD` returns the same headers as `GET` without the body.
- `/` resolves to `index.html`.
- `/docs/` resolves to `docs/index.html`.
- `/docs` redirects to `/docs/` with `308 Permanent Redirect` when `docs/` is a directory.
- Missing files return `404`.
- Unsupported methods return `405` with `Allow: GET, HEAD`.
- Directory listings are never generated.
- There is no SPA fallback. A missing route stays missing.
- `..`, encoded traversal, NUL bytes, encoded slashes, and backslashes in request paths are rejected.
- Dotfile path segments are blocked by default, except `.well-known`.
- Static responses include `X-Content-Type-Options: nosniff`.
- `Last-Modified` and `If-Modified-Since` are supported, including `304 Not Modified`.
- Custom configured headers can be added, but protected runtime headers are rejected.

Common MIME types are detected for HTML, CSS, JavaScript, JSON, text, SVG, PNG, JPEG, GIF, WebP, ICO, WASM, PDF, XML, WOFF, and WOFF2. Unknown extensions use `application/octet-stream`.

## Security Limits

qaws is deliberately small. Put it behind the right outer layer for anything public or sensitive.

- No TLS: terminate HTTPS with Cloudflare Tunnel, Caddy, nginx, Traefik, a load balancer, or another frontend.
- No authentication or authorization.
- No rate limiting.
- Request logging exists, but there is no log rotation.
- Cache headers are configurable, but qaws does not invent a full caching policy for you.
- No hardening beyond static path normalization, dotfile blocking, and `resolve_beneath` file opens.

## JSON Config

Config is explicit. qaws does not auto-load `qaws.json`; pass it with `--config`.

```json
{
  "listen": { "host": "127.0.0.1", "port": 18086 },
  "serve": "./public",
  "daemon": { "enabled": false, "pid_file": null, "log_file": null },
  "logging": { "format": "plain", "access": true },
  "security": { "dotfiles": "deny_except_well_known" },
  "headers": { "Cache-Control": "public, max-age=3600" },
  "http": { "last_modified": true, "trailing_slash_redirect": true }
}
```

Unknown keys and invalid types are rejected. CLI flags override config values:

```sh
qaws --config qaws.json --port 8080 --no-access-log
```

Validate config and the serve directory:

```sh
qaws check --config qaws.json
```

## Logging

Foreground logs go to stderr unless `--log-file` is set. Daemon logs use `--log-file` or a derived runtime log path.

Plain logs are human-readable:

```text
2026-07-05T10:20:30Z access remote=127.0.0.1:50000 method=GET target="/" status=200 bytes=268 duration_us=500 user_agent="curl/8.7.1"
```

JSON-lines logs are useful for machines:

```sh
qaws --log-format jsonl --log-file qaws.log
```

Access logs are on by default and can be disabled:

```sh
qaws --no-access-log
```

## Daemon Control

Daemon control is Unix/Termux-first. Windows foreground serving still works, but `-d`, `status`, `stop`, and `restart` report unsupported.

```sh
qaws -d --host 127.0.0.1 --port 18086 --serve ./public
qaws status --host 127.0.0.1 --port 18086
qaws stop --host 127.0.0.1 --port 18086
qaws restart --host 127.0.0.1 --port 18086 --serve ./public
```

You can make daemon identity explicit:

```sh
qaws -d --pid-file /tmp/qaws.pid --log-file /tmp/qaws.log --port 18086
qaws status --pid-file /tmp/qaws.pid
qaws stop --pid-file /tmp/qaws.pid --force
```

If no PID or log file is configured, qaws derives paths from the bind host and port under `$XDG_RUNTIME_DIR/qaws`, then `$PREFIX/var/run/qaws` on Termux, then `/tmp/qaws-$UID`.

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

Release artifacts are written as named binaries under `dist/`, with `dist/SHA256SUMS` for verification.

Current practical server targets:

| Target | Artifact |
| --- | --- |
| `x86_64-linux-musl` | `dist/qaws-0.2.1-x86_64-linux-musl` |
| `x86_64-linux-gnu` | `dist/qaws-0.2.1-x86_64-linux-gnu` |
| `aarch64-linux-musl` | `dist/qaws-0.2.1-aarch64-linux-musl` |
| `aarch64-linux-gnu` | `dist/qaws-0.2.1-aarch64-linux-gnu` |
| `arm-linux-musleabihf` | `dist/qaws-0.2.1-arm-linux-musleabihf` |
| `riscv64-linux-musl` | `dist/qaws-0.2.1-riscv64-linux-musl` |
| `aarch64-linux-android` | `dist/qaws-0.2.1-aarch64-linux-android` |
| `aarch64-macos` | `dist/qaws-0.2.1-aarch64-macos` |
| `x86_64-macos` | `dist/qaws-0.2.1-x86_64-macos` |
| `x86_64-windows-gnu` | `dist/qaws-0.2.1-x86_64-windows-gnu.exe` |
| `aarch64-windows-gnu` | `dist/qaws-0.2.1-aarch64-windows-gnu.exe` |
| `x86_64-freebsd` | `dist/qaws-0.2.1-x86_64-freebsd` |

The release matrix intentionally excludes targets that are not practical qaws server artifacts, including WASI, iOS, tvOS, watchOS, UEFI, GPU, console, freestanding, and similar non-server environments.

`dist/` is ignored by git. Release binaries and checksums are generated artifacts, not source.

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
curl --path-as-is -i http://127.0.0.1:18086/../build.zig
```

Expected results:

- `/` returns `200` and serves `public/index.html`.
- `HEAD /` returns headers without a body.
- Missing paths return `404`.
- Traversal attempts return `403`.
- Access logs appear by default.

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

`qaws -d` says the daemon is already running:

Use `qaws status`, `qaws stop`, or `qaws restart` with the same `--pid-file` or host/port-derived identity.
