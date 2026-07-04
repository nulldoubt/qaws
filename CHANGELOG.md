# Changelog

### 0.2.0

- Added PID-file daemon management with `status`, `stop`, `restart`, stale detection, and `stop --force`.
- Added safer static serving with dotfile protection, custom headers, nosniff, Last-Modified/304, and slash redirects.
- Added explicit strict JSON configuration with CLI overrides and a `qaws check` command.
- Added plain and JSON-lines logging with default access logs and log-file support.
- Bumped qaws version metadata and documentation to 0.2.0.

### 0.1.0

- Initial dependency-free Zig static file server with GET/HEAD, path normalization, daemon mode, and release builds.
