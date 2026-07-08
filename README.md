# qaws

qaws is the Quick Arm Webserver: a tiny static file server written in Zig with no runtime dependencies.
It is built for the simple case where a directory already contains finished static files and the server should do only one job: bind a TCP port and serve those files.

The default behavior is intentionally plain:

```sh
qaws
```

That serves `./public` on `0.0.0.0:80`.

## Status

qaws is currently `0.2.6`.

It supports HTTP/1.1 `GET` and `HEAD`, HTTP keep-alive, ordered pipelining, event-worker backends on supported Unix platforms, a fixed worker fallback, a cached event-worker fast path for small files, async log writing, platform sendfile for uncached static files, directory `index.html` resolution, path traversal rejection, default request logging, explicit JSON config, and Unix-style daemon management with PID files. It does not do TLS, authentication, runtime compression, directory listings, reverse proxying, upload handling, or SPA fallback.

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
| `--keep-alive` / `--no-keep-alive` | keep-alive on | Enable or disable HTTP persistent connections. |
| `--sendfile` / `--no-sendfile` | sendfile on | Enable or disable platform sendfile for uncached static `GET` bodies. |
| `--keep-alive-timeout-ms <n>` | `5000` | Idle timeout for persistent connections. |
| `--max-requests-per-connection <n>` | `1000` | Maximum requests before recycling one persistent connection. |
| `--max-connections <n>` | `1024` | Maximum active plus queued connections. |
| `--workers <n>` | logical CPU count | Event-worker count on supported platforms, or fallback worker thread count elsewhere. |
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
qaws 0.2.6
```

## Serving Rules

- `GET` returns headers and a file body.
- `HEAD` returns the same headers as `GET` without the body.
- `/` resolves to `index.html`.
- `/docs/` resolves to `docs/index.html`.
- `/docs` redirects to `/docs/` with `308 Permanent Redirect` when `docs/` is a directory.
- Missing files return `404`.
- Unsupported methods return `405` with `Allow: GET, HEAD`.
- HTTP/1.1 keeps connections alive by default.
- HTTP/1.0 closes by default unless the client sends `Connection: keep-alive`.
- `Connection: close` always closes after the response.
- HTTP/1.1 pipelined requests are processed sequentially and responses are sent in request order.
- Requests with bodies are rejected because qaws only serves static files.
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
  "cache": {
    "enabled": true,
    "max_file_bytes": 262144,
    "max_total_bytes": 16777216,
    "revalidate_ms": 1000
  },
  "headers": { "Cache-Control": "public, max-age=3600" },
  "http": {
    "last_modified": true,
    "trailing_slash_redirect": true,
    "keep_alive": true,
    "sendfile": true,
    "keep_alive_timeout_ms": 5000,
    "max_requests_per_connection": 1000,
    "max_connections": 1024,
    "workers": 4
  }
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

Boolean flags are available as pairs when a config file may need to be overridden from the command line. For example, `--no-access-log` disables the default access log, while `--access-log` re-enables it when a config file sets `"access": false`. The same pattern applies to `--keep-alive` and `--no-keep-alive`.

## Static Cache

qaws caches small static files by default. The cache stores file bodies up to `256 KiB`, keeps at most `16 MiB` of active cached bodies, prebuilds common response headers, and revalidates cached files after `1000` ms. When the total cache limit is reached, additional files are served through the normal uncached path instead of evicting existing entries.

On evented platforms, cached safe-path `GET`, `HEAD`, and `304` responses use a nonblocking event-worker fast path. The worker writes prebuilt headers and cached bodies from pending output state, then continues with the next pipelined request only after the current response is fully sent. Complex paths, redirects, errors, uncached files, and large sendfile responses keep using the normal response path.

Cache settings are JSON-only in `0.2.6`:

```json
{
  "cache": {
    "enabled": true,
    "max_file_bytes": 262144,
    "max_total_bytes": 16777216,
    "revalidate_ms": 1000
  }
}
```

Disable the cache for comparisons or development checks:

```json
{ "cache": { "enabled": false } }
```

## Keep-Alive And Concurrency

qaws uses persistent HTTP connections by default:

- Keep-alive is enabled unless `--no-keep-alive` or `"keep_alive": false` is set.
- Idle keep-alive connections time out after `5000` ms by default.
- A single connection is recycled after `1000` requests by default.
- On Linux and Android, qaws uses `epoll` event workers.
- On macOS and FreeBSD, qaws uses `kqueue` event workers.
- Unsupported targets keep the fixed blocking worker-pool backend.
- `--workers` controls the event-worker count on evented platforms, or the fallback worker count elsewhere. The default is the detected logical CPU count, falling back to `1`.
- Cached event-worker responses are written without switching the socket into the blocking response path.
- Each event tick processes a small bounded batch of ready cached requests internally, so pipelined clients cannot monopolize a worker indefinitely.
- The server accepts up to `1024` active plus queued connections by default.
- When the connection cap is reached, qaws returns `503 Service Unavailable` with `Connection: close`.
- HTTP/1.1 pipelined requests on one connection are served sequentially in request order.

These defaults stay usable on Termux and small VPS machines while avoiding per-connection thread creation overhead. Startup logs include the selected backend, such as `using kqueue`, `using epoll`, or `using worker`.

## Sendfile

qaws uses platform sendfile by default for uncached regular-file `GET` responses on supported Unix targets. Headers are still written through the normal response writer, then qaws flushes those headers and sends the file body through the platform file-transfer path. Cached small files keep using the in-memory cache, and `HEAD`, `304`, redirects, and errors do not use sendfile.

Disable sendfile for comparison or troubleshooting:

```sh
qaws --no-sendfile --port 8080
```

Or in JSON:

```json
{ "http": { "sendfile": false } }
```

Unsupported platforms and early sendfile failures fall back to the normal buffered streaming path.

## Logging

Foreground logs go to stderr unless `--log-file` is set. Daemon logs use `--log-file` or a derived runtime log path. Log writes are handled by one background logger thread. Event logs are preserved and drained on shutdown; access logs are non-blocking and may be dropped if the internal queue is full.

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

## Docker Images

qaws publishes multi-architecture Docker images for `linux/amd64` and `linux/arm64`.

Registries:

```text
code.alkhatib.online/alkhatib/qaws
ghcr.io/nulldoubt/qaws
```

Tags:

```text
0.2.6
latest
```

Run the sample image:

```sh
docker run --rm -p 8080:80 code.alkhatib.online/alkhatib/qaws:0.2.6
curl -i http://127.0.0.1:8080/
```

Run with your own static files:

```sh
docker run --rm -p 8080:80 -v "$PWD/public:/public:ro" ghcr.io/nulldoubt/qaws:0.2.6
```

The container keeps the normal qaws defaults: it serves `./public` from `0.0.0.0:80`. The image uses `/` as its working directory and includes the sample `public/` directory, so it also works without a bind mount.

Log in before publishing:

```sh
docker login code.alkhatib.online
echo "$GHCR_TOKEN" | docker login ghcr.io -u nulldoubt --password-stdin
```

`GHCR_TOKEN` needs permission to write packages for `ghcr.io/nulldoubt/qaws`.

Publish both registries with Buildx:

```sh
./scripts/docker-build-push.sh
```

Inspect the published manifests:

```sh
docker buildx imagetools inspect code.alkhatib.online/alkhatib/qaws:0.2.6
docker buildx imagetools inspect ghcr.io/nulldoubt/qaws:0.2.6
```

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
| `x86_64-linux-musl` | `dist/qaws-0.2.6-x86_64-linux-musl` |
| `x86_64-linux-gnu` | `dist/qaws-0.2.6-x86_64-linux-gnu` |
| `aarch64-linux-musl` | `dist/qaws-0.2.6-aarch64-linux-musl` |
| `aarch64-linux-gnu` | `dist/qaws-0.2.6-aarch64-linux-gnu` |
| `arm-linux-musleabihf` | `dist/qaws-0.2.6-arm-linux-musleabihf` |
| `riscv64-linux-musl` | `dist/qaws-0.2.6-riscv64-linux-musl` |
| `aarch64-linux-android` | `dist/qaws-0.2.6-aarch64-linux-android` |
| `aarch64-macos` | `dist/qaws-0.2.6-aarch64-macos` |
| `x86_64-macos` | `dist/qaws-0.2.6-x86_64-macos` |
| `x86_64-windows-gnu` | `dist/qaws-0.2.6-x86_64-windows-gnu.exe` |
| `aarch64-windows-gnu` | `dist/qaws-0.2.6-aarch64-windows-gnu.exe` |
| `x86_64-freebsd` | `dist/qaws-0.2.6-x86_64-freebsd` |

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
- HTTP/1.1 responses include `Connection: keep-alive` by default.

## Benchmarking

For local performance checks, disable access logs and raise the file descriptor limit first:

```sh
ulimit -n 65536
./zig-out/bin/qaws --host 127.0.0.1 --port 18086 --serve ./public --no-access-log
```

Then run the same matrix when comparing builds:

```sh
wrk -t1 -c1 -d30s http://127.0.0.1:18086/
wrk -t1 -c10 -d30s http://127.0.0.1:18086/
wrk -t8 -c25 -d30s http://127.0.0.1:18086/
wrk -t8 -c100 -d30s http://127.0.0.1:18086/
wrk -t8 -c1000 -d30s http://127.0.0.1:18086/
```

To compare old one-request-per-connection behavior, disable keep-alive:

```sh
./zig-out/bin/qaws --host 127.0.0.1 --port 18086 --serve ./public --no-access-log --no-keep-alive
wrk -t8 -c100 -d30s http://127.0.0.1:18086/
```

To compare cached and uncached static serving, run once with the default cache and once with:

```json
{ "cache": { "enabled": false } }
```

For the small-file event fast path, compare `0.2.5` and `0.2.6` with access logs disabled and the same static file:

```sh
wrk -t1 -c1 -d10s http://127.0.0.1:18086/
wrk -t1 -c10 -d10s http://127.0.0.1:18086/
wrk -t8 -c100 -d10s http://127.0.0.1:18086/
wrk -t8 -c1000 -d10s http://127.0.0.1:18086/
```

To compare sendfile with buffered streaming for larger files, use files outside the small-file cache limit and run the same benchmark once normally and once with `--no-sendfile`:

```sh
truncate -s 1m public/one-mib.bin
truncate -s 64m public/sixty-four-mib.bin
wrk -t4 -c16 -d30s http://127.0.0.1:18086/one-mib.bin
wrk -t4 -c16 -d30s http://127.0.0.1:18086/sixty-four-mib.bin
```

To stress idle keep-alive handling, hold many sockets open while running an active benchmark. The event backend should continue serving active requests while idle clients wait for `keep_alive_timeout_ms`.

## Roadmap

Future performance releases may make large response bodies fully resumable in nonblocking event workers, add io_uring or IOCP where practical, and improve cache behavior with eviction, full-response blobs, file descriptor caching, and watcher-based invalidation.

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
