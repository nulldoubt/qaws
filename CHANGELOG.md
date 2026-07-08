# Changelog

### 0.2.6

- Bumped qaws version metadata, Docker tags, and documentation to 0.2.6.

### 0.2.5

- Documented automatic event backend selection and high-concurrency benchmark guidance.
- Added automatic event-worker backends using `epoll` on Linux/Android and `kqueue` on macOS/FreeBSD with the worker pool kept as fallback.
- Bumped qaws version metadata, Docker tags, and documentation to 0.2.5.

### 0.2.4

- Documented sendfile defaults, fallback behavior, and large-file benchmark commands.
- Added platform sendfile transfer for uncached static `GET` bodies with buffered fallback.
- Added `--sendfile`/`--no-sendfile` and strict JSON `http.sendfile` configuration.
- Bumped qaws version metadata, Docker tags, and documentation to 0.2.4.

### 0.2.3

- Kept async access-log drop accounting portable across 32-bit release targets.
- Documented worker-pool defaults, async logging, pipelining behavior, and the next performance roadmap.
- Added ordered HTTP/1.1 pipelining coverage for sequential keep-alive requests.
- Added async log writing with non-blocking access-log drops under queue pressure.
- Replaced per-connection thread spawning with a bounded fixed worker pool.
- Added worker-count CLI and JSON configuration with a higher default connection cap.
- Bumped qaws version metadata, Docker tags, and documentation to 0.2.3.

### 0.2.2

- Documented static cache defaults and HTTP connection tuning flags.
- Added a small-file static cache with prebuilt response headers and TTL revalidation.
- Removed per-request request-buffer allocation and added fast normalization for simple safe paths.
- Added strict JSON cache settings and CLI overrides for HTTP connection limits.
- Bumped qaws version metadata, Docker tags, and documentation to 0.2.2.

### 0.2.1

- Added Docker image packaging and a Buildx publish script for amd64/arm64 images.
- Documented keep-alive defaults, CLI override pairs, and local benchmark commands.
- Added bounded per-connection worker threads and thread-safe logging.
- Added HTTP keep-alive response handling with defensive close behavior for bad requests.
- Added keep-alive configuration and HTTP `Connection` parsing rules.
- Bumped qaws version metadata and documentation to 0.2.1.

### 0.2.0

- Updated release documentation and generated SHA256 checksums for release artifacts.
- Added PID-file daemon management with `status`, `stop`, `restart`, stale detection, and `stop --force`.
- Added safer static serving with dotfile protection, custom headers, nosniff, Last-Modified/304, and slash redirects.
- Added explicit strict JSON configuration with CLI overrides and a `qaws check` command.
- Added plain and JSON-lines logging with default access logs and log-file support.
- Bumped qaws version metadata and documentation to 0.2.0.

### 0.1.0

- Initial dependency-free Zig static file server with GET/HEAD, path normalization, daemon mode, and release builds.
