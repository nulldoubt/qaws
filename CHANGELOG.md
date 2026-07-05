# Changelog

### 0.2.3

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
