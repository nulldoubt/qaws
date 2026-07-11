const std = @import("std");

const Allocator = std.mem.Allocator;

pub const default_keep_alive_timeout_ms: u32 = 5000;
pub const default_max_requests_per_connection: u32 = 1000;
pub const default_max_connections: u32 = 1024;
pub const default_cache_max_file_bytes: usize = 256 * 1024;
pub const default_cache_max_total_bytes: usize = 16 * 1024 * 1024;
pub const default_cache_revalidate_ms: u32 = 1000;

pub const LogFormat = enum {
    plain,
    jsonl,
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const DotfilePolicy = enum {
    deny_except_well_known,
    deny_all,
    allow,
};

pub const Config = struct {
    host: []const u8 = "0.0.0.0",
    port: u16 = 80,
    serve_dir: []const u8 = "./public",
    daemon: bool = false,
    log_format: LogFormat = .plain,
    log_file: ?[]const u8 = null,
    access_log: bool = true,
    pid_file: ?[]const u8 = null,
    dotfiles: DotfilePolicy = .deny_except_well_known,
    last_modified: bool = true,
    trailing_slash_redirect: bool = true,
    keep_alive: bool = true,
    sendfile: bool = true,
    etag: bool = true,
    range_requests: bool = true,
    precompressed: bool = true,
    keep_alive_timeout_ms: u32 = default_keep_alive_timeout_ms,
    max_requests_per_connection: u32 = default_max_requests_per_connection,
    max_connections: u32 = default_max_connections,
    workers: u32 = 0,
    cache_enabled: bool = true,
    cache_max_file_bytes: usize = default_cache_max_file_bytes,
    cache_max_total_bytes: usize = default_cache_max_total_bytes,
    cache_revalidate_ms: u32 = default_cache_revalidate_ms,
    headers: []const Header = &.{},
};

pub const FileConfig = struct {
    listen: ?ListenConfig = null,
    serve: ?[]const u8 = null,
    daemon: ?DaemonConfig = null,
    logging: ?LoggingConfig = null,
    security: ?SecurityConfig = null,
    cache: ?CacheConfig = null,
    headers: ?std.json.Value = null,
    http: ?HttpConfig = null,
};

pub const ListenConfig = struct {
    host: ?[]const u8 = null,
    port: ?u16 = null,
};

pub const DaemonConfig = struct {
    enabled: ?bool = null,
    pid_file: ?[]const u8 = null,
    log_file: ?[]const u8 = null,
};

pub const LoggingConfig = struct {
    format: ?LogFormat = null,
    access: ?bool = null,
};

pub const SecurityConfig = struct {
    dotfiles: ?DotfilePolicy = null,
};

pub const CacheConfig = struct {
    enabled: ?bool = null,
    max_file_bytes: ?usize = null,
    max_total_bytes: ?usize = null,
    revalidate_ms: ?u32 = null,
};

pub const HttpConfig = struct {
    last_modified: ?bool = null,
    trailing_slash_redirect: ?bool = null,
    keep_alive: ?bool = null,
    sendfile: ?bool = null,
    etag: ?bool = null,
    range_requests: ?bool = null,
    precompressed: ?bool = null,
    keep_alive_timeout_ms: ?u32 = null,
    max_requests_per_connection: ?u32 = null,
    max_connections: ?u32 = null,
    workers: ?u32 = null,
};

pub fn applyFileConfig(allocator: Allocator, file_config: FileConfig, config: *Config) !void {
    if (file_config.listen) |listen| {
        if (listen.host) |host| config.host = try allocator.dupe(u8, host);
        if (listen.port) |port| {
            if (port == 0) return error.InvalidPort;
            config.port = port;
        }
    }

    if (file_config.serve) |serve_dir| config.serve_dir = try allocator.dupe(u8, serve_dir);

    if (file_config.daemon) |daemon_config| {
        if (daemon_config.enabled) |enabled| config.daemon = enabled;
        if (daemon_config.pid_file) |pid_file| config.pid_file = try allocator.dupe(u8, pid_file);
        if (daemon_config.log_file) |log_file| config.log_file = try allocator.dupe(u8, log_file);
    }

    if (file_config.logging) |logging| {
        if (logging.format) |format| config.log_format = format;
        if (logging.access) |access| config.access_log = access;
    }

    if (file_config.security) |security| {
        if (security.dotfiles) |dotfiles| config.dotfiles = dotfiles;
    }

    if (file_config.cache) |cache| {
        if (cache.enabled) |enabled| config.cache_enabled = enabled;
        if (cache.max_file_bytes) |max_file_bytes| {
            if (max_file_bytes == 0) return error.InvalidCacheConfig;
            config.cache_max_file_bytes = max_file_bytes;
        }
        if (cache.max_total_bytes) |max_total_bytes| {
            if (max_total_bytes == 0) return error.InvalidCacheConfig;
            config.cache_max_total_bytes = max_total_bytes;
        }
        if (cache.revalidate_ms) |revalidate_ms| {
            if (revalidate_ms == 0) return error.InvalidCacheConfig;
            config.cache_revalidate_ms = revalidate_ms;
        }
    }

    if (file_config.http) |http| {
        if (http.last_modified) |last_modified| config.last_modified = last_modified;
        if (http.trailing_slash_redirect) |trailing_slash_redirect| config.trailing_slash_redirect = trailing_slash_redirect;
        if (http.keep_alive) |keep_alive| config.keep_alive = keep_alive;
        if (http.sendfile) |sendfile| config.sendfile = sendfile;
        if (http.etag) |etag| config.etag = etag;
        if (http.range_requests) |range_requests| config.range_requests = range_requests;
        if (http.precompressed) |precompressed| config.precompressed = precompressed;
        if (http.keep_alive_timeout_ms) |timeout_ms| {
            if (timeout_ms == 0) return error.InvalidHttpConfig;
            config.keep_alive_timeout_ms = timeout_ms;
        }
        if (http.max_requests_per_connection) |max_requests| {
            if (max_requests == 0) return error.InvalidHttpConfig;
            config.max_requests_per_connection = max_requests;
        }
        if (http.max_connections) |max_connections| {
            if (max_connections == 0) return error.InvalidHttpConfig;
            config.max_connections = max_connections;
        }
        if (http.workers) |workers| {
            if (workers == 0) return error.InvalidHttpConfig;
            config.workers = workers;
        }
    }

    if (file_config.headers) |headers| {
        if (headers != .object) return error.InvalidHeaderConfig;
        var header_list: std.ArrayList(Header) = .empty;
        errdefer header_list.deinit(allocator);

        var it = headers.object.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* != .string) return error.InvalidHeaderConfig;
            const name = entry.key_ptr.*;
            if (isProtectedHeader(name)) return error.ProtectedHeader;
            try header_list.append(allocator, .{
                .name = try allocator.dupe(u8, name),
                .value = try allocator.dupe(u8, entry.value_ptr.string),
            });
        }
        config.headers = try header_list.toOwnedSlice(allocator);
    }
}

pub fn isProtectedHeader(name: []const u8) bool {
    const protected = [_][]const u8{
        "Content-Length",
        "Content-Type",
        "Connection",
        "Server",
        "Allow",
        "Location",
        "ETag",
        "Accept-Ranges",
        "Content-Range",
        "Content-Encoding",
        "Vary",
    };
    for (protected) |candidate| {
        if (std.ascii.eqlIgnoreCase(name, candidate)) return true;
    }
    return false;
}
