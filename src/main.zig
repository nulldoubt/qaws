const std = @import("std");
const builtin = @import("builtin");
const cache_mod = @import("cache.zig");
const config_mod = @import("config.zig");
const http = @import("http.zig");
const logging = @import("logging.zig");
const platform = @import("platform.zig");
const qaws_version = @import("version.zig");
const server = @import("server.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const IpAddress = Io.net.IpAddress;

const version = qaws_version.string;
const server_name = "qaws/" ++ version;
const max_request_bytes = 16 * 1024;
const default_keep_alive_timeout_ms = config_mod.default_keep_alive_timeout_ms;
const default_max_requests_per_connection = config_mod.default_max_requests_per_connection;
const default_max_connections = config_mod.default_max_connections;
const default_cache_max_file_bytes = config_mod.default_cache_max_file_bytes;
const default_cache_max_total_bytes = config_mod.default_cache_max_total_bytes;
const default_cache_revalidate_ms = config_mod.default_cache_revalidate_ms;
const worker_stack_size = 512 * 1024;
const event_request_batch_limit = server.event_request_batch_limit;

const LogFormat = config_mod.LogFormat;
const Header = config_mod.Header;
const Config = config_mod.Config;

const ParsedCommand = union(enum) {
    serve: Config,
    check: Config,
    status: Config,
    stop: StopCommand,
    restart: StopCommand,
    help,
    version,
};

const CliCommand = enum {
    serve,
    check,
    status,
    stop,
    restart,
    help,
    version,
};

const StopCommand = struct {
    config: Config,
    force: bool = false,
};

const StopSignal = enum {
    term,
    kill,
};

const CliOptions = struct {
    command: CliCommand = .serve,
    config_path: ?[]const u8 = null,
    host: ?[]const u8 = null,
    port: ?u16 = null,
    serve_dir: ?[]const u8 = null,
    daemon: ?bool = null,
    log_format: ?LogFormat = null,
    log_file: ?[]const u8 = null,
    access_log: ?bool = null,
    pid_file: ?[]const u8 = null,
    keep_alive: ?bool = null,
    sendfile: ?bool = null,
    keep_alive_timeout_ms: ?u32 = null,
    max_requests_per_connection: ?u32 = null,
    max_connections: ?u32 = null,
    workers: ?u32 = null,
    force: bool = false,
};

const FileConfig = config_mod.FileConfig;
const DotfilePolicy = config_mod.DotfilePolicy;
const applyFileConfig = config_mod.applyFileConfig;
const isProtectedHeader = config_mod.isProtectedHeader;
const AccessRecord = logging.AccessRecord;
const LogQueue = logging.LogQueue;
const Logger = logging.Logger;
const appendRfc3339Timestamp = logging.appendRfc3339Timestamp;
const appendJsonString = logging.appendJsonString;
const HttpVersion = http.HttpVersion;
const ConnectionDirective = http.ConnectionDirective;
const Request = http.Request;
const ResponseStatus = http.ResponseStatus;
const ResponseResult = http.ResponseResult;
const parseRequest = http.parseRequest;
const parseConnectionHeader = http.parseConnectionHeader;
const requestWantsKeepAlive = http.requestWantsKeepAlive;
const normalizeTarget = http.normalizeTarget;
const normalizeTargetFast = http.normalizeTargetFast;
const targetPathHasTrailingSlash = http.targetPathHasTrailingSlash;
const slashRedirectLocation = http.slashRedirectLocation;
const formatHttpDate = http.formatHttpDate;
const parseHttpDate = http.parseHttpDate;
const sendHeaders = http.sendHeaders;
const buildHeaderAlloc = http.buildHeaderAlloc;
const mimeType = http.mimeType;
const CachedEventResponse = cache_mod.CachedEventResponse;
const CachedFileSnapshot = cache_mod.CachedFileSnapshot;
const StaticCache = cache_mod.StaticCache;
const cachedEventResponseFromSnapshot = cache_mod.cachedEventResponseFromSnapshot;
const SendfileResult = platform.SendfileResult;
const RuntimeBackend = platform.RuntimeBackend;
const WakePipe = platform.WakePipe;
const selectRuntimeBackend = platform.selectRuntimeBackend;
const runtimeBackendName = platform.runtimeBackendName;
const createWakePipe = platform.createWakePipe;
const closeWakePipe = platform.closeWakePipe;
const wakeFd = platform.wakeFd;
const drainWakeFd = platform.drainWakeFd;
const readFd = platform.readFd;
const writeFd = platform.writeFd;
const writevFd = platform.writevFd;
const isNormalDisconnect = platform.isNormalDisconnect;
const closeFd = platform.closeFd;
const setFdNonblocking = platform.setFdNonblocking;
const setFdCloseOnExec = platform.setFdCloseOnExec;
const epollCreate = platform.epollCreate;
const epollAdd = platform.epollAdd;
const epollSetWriteInterest = platform.epollSetWriteInterest;
const epollWait = platform.epollWait;
const kqueueCreate = platform.kqueueCreate;
const kqueueAdd = platform.kqueueAdd;
const kqueueSetWriteInterest = platform.kqueueSetWriteInterest;
const kqueueWait = platform.kqueueWait;
const sendfileSupportedForOs = platform.sendfileSupportedForOs;
const trySendfile = platform.trySendfile;
const FileTransferPath = server.FileTransferPath;
const EventConnection = server.EventConnection;
const PendingEventWrite = server.PendingEventWrite;
const WorkerQueue = server.WorkerQueue;
const ConnectionReader = server.ConnectionReader;
const serve = server.serve;
const resolveWorkerCount = server.resolveWorkerCount;
const tryAcquireConnection = server.tryAcquireConnection;
const releaseConnection = server.releaseConnection;
const eventConnectionExpired = server.eventConnectionExpired;
const pendingWriteSlice = server.pendingWriteSlice;
const advancePendingWrite = server.advancePendingWrite;
const eventWaitTimeoutMs = server.eventWaitTimeoutMs;
const keepAliveTimeout = server.keepAliveTimeout;
const readHttpRequest = server.readHttpRequest;
const appendRequestChunk = server.appendRequestChunk;
const selectFileTransferPath = server.selectFileTransferPath;

const CliError = error{
    MissingValue,
    InvalidPort,
    InvalidHttpLimit,
    InvalidLogFormat,
    UnknownArgument,
};

const LoadedArgs = struct {
    bytes: ?[]u8 = null,
    arg_copies: bool = false,
    args: []const []const u8,

    fn deinit(self: LoadedArgs, allocator: Allocator) void {
        if (self.arg_copies) {
            for (self.args) |arg| allocator.free(arg);
        }
        if (self.bytes) |bytes| allocator.free(bytes);
        allocator.free(self.args);
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const loaded_args = try loadArgs(allocator, io, init.minimal.args);
    defer loaded_args.deinit(allocator);

    const cli = parseCli(loaded_args.args) catch |err| {
        try printCliError(err);
        std.process.exit(2);
    };

    var config_arena = std.heap.ArenaAllocator.init(allocator);
    defer config_arena.deinit();
    const command = resolveCommand(config_arena.allocator(), io, cli) catch |err| {
        try printConfigError(err);
        std.process.exit(2);
    };

    switch (command) {
        .help => try printHelp(),
        .version => try printVersion(),
        .check => |config| try checkConfig(io, config),
        .status => |config| daemonStatus(config_arena.allocator(), io, init.environ_map.*, config) catch |err| {
            if (err != error.NotRunning) try printRuntimeError(err);
            std.process.exit(1);
        },
        .stop => |command_config| daemonStop(config_arena.allocator(), io, init.environ_map.*, command_config.config, command_config.force) catch |err| {
            try printRuntimeError(err);
            std.process.exit(1);
        },
        .restart => |command_config| {
            daemonStop(config_arena.allocator(), io, init.environ_map.*, command_config.config, command_config.force) catch |err| switch (err) {
                error.NotRunning => {},
                else => {
                    try printRuntimeError(err);
                    std.process.exit(1);
                },
            };
            var config = command_config.config;
            config.daemon = true;
            runServeCommand(allocator, config_arena.allocator(), io, init.environ_map.*, config) catch |err| {
                try printRuntimeError(err);
                std.process.exit(2);
            };
        },
        .serve => |config| {
            runServeCommand(allocator, config_arena.allocator(), io, init.environ_map.*, config) catch |err| {
                try printRuntimeError(err);
                std.process.exit(2);
            };
        },
    }
}

const PidFile = struct {
    path: []const u8,
    file: Io.File,
    io: Io,

    fn writeCurrentPid(self: *PidFile) !void {
        var buffer: [64]u8 = undefined;
        var writer: Io.Writer = .fixed(&buffer);
        try writer.print("{d}\n", .{currentPid()});
        const bytes = writer.buffered();
        try self.file.setLength(self.io, 0);
        try self.file.writePositionalAll(self.io, bytes, 0);
    }

    fn deinit(self: *PidFile) void {
        self.file.unlock(self.io);
        self.file.close(self.io);
        deletePath(self.io, self.path) catch {};
    }
};

fn runServeCommand(
    allocator: Allocator,
    config_allocator: Allocator,
    io: Io,
    env_map: std.process.Environ.Map,
    raw_config: Config,
) !void {
    var config = raw_config;
    var owned_serve_dir: ?[:0]u8 = null;
    defer if (owned_serve_dir) |path| allocator.free(path);

    var pid_file: ?PidFile = null;
    defer if (pid_file) |*pid| pid.deinit();

    if (config.daemon) {
        try ensureDaemonSupported();
        owned_serve_dir = try Io.Dir.cwd().realPathFileAlloc(io, config.serve_dir, allocator);
        config.serve_dir = owned_serve_dir.?;
        config.pid_file = try resolvePidPath(config_allocator, io, env_map, config);
        if (config.log_file == null) {
            config.log_file = try defaultRuntimeFilePath(config_allocator, io, env_map, config, "log");
        } else if (config.log_file) |path| {
            config.log_file = try absolutePath(config_allocator, io, path);
        }
        pid_file = try acquirePidFile(config_allocator, io, config.pid_file.?);
        try daemonize();
        try pid_file.?.writeCurrentPid();
    }

    installShutdownHandlers();
    var logger = try Logger.init(allocator, io, config);
    defer logger.deinit();
    try logger.start();
    var cache = StaticCache.init(std.heap.smp_allocator, config);
    defer cache.deinit();
    try serve(std.heap.smp_allocator, io, config, &logger, &cache);
}

fn loadArgs(allocator: Allocator, io: Io, init_args: std.process.Args) !LoadedArgs {
    if (builtin.os.tag == .linux) {
        return readProcSelfCmdline(allocator, io) catch try copyInitArgs(allocator, init_args);
    }
    return copyInitArgs(allocator, init_args);
}

fn readProcSelfCmdline(allocator: Allocator, io: Io) !LoadedArgs {
    var file = try Io.Dir.openFileAbsolute(io, "/proc/self/cmdline", .{});
    defer file.close(io);

    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);

    var file_buffer: [1024]u8 = undefined;
    var reader = file.reader(io, &.{});
    while (true) {
        const n = reader.interface.readSliceShort(&file_buffer) catch |err| switch (err) {
            error.ReadFailed => return reader.err orelse err,
        };
        if (n == 0) break;
        try bytes.appendSlice(allocator, file_buffer[0..n]);
        if (bytes.items.len > max_request_bytes) return error.StreamTooLong;
    }

    if (bytes.items.len == 0) return error.EndOfStream;
    const owned_bytes = try bytes.toOwnedSlice(allocator);
    errdefer allocator.free(owned_bytes);

    var args: std.ArrayList([]const u8) = .empty;
    errdefer args.deinit(allocator);

    var parts = std.mem.splitScalar(u8, owned_bytes, 0);
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        try args.append(allocator, part);
    }
    if (args.items.len == 0) return error.EndOfStream;

    return .{
        .bytes = owned_bytes,
        .args = try args.toOwnedSlice(allocator),
    };
}

fn copyInitArgs(allocator: Allocator, init_args: std.process.Args) !LoadedArgs {
    var it = try init_args.iterateAllocator(allocator);
    defer it.deinit();

    var args: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (args.items) |arg| allocator.free(arg);
        args.deinit(allocator);
    }

    while (it.next()) |arg| {
        try args.append(allocator, try allocator.dupe(u8, arg));
    }

    return .{
        .arg_copies = true,
        .args = try args.toOwnedSlice(allocator),
    };
}

fn parseArgs(args: []const []const u8) CliError!ParsedCommand {
    const cli = try parseCli(args);
    var config = Config{};
    applyCliOverrides(&config, cli);

    return switch (cli.command) {
        .serve => .{ .serve = config },
        .check => .{ .check = config },
        .status => .{ .status = config },
        .stop => .{ .stop = .{ .config = config, .force = cli.force } },
        .restart => .{ .restart = .{ .config = config, .force = cli.force } },
        .help => .help,
        .version => .version,
    };
}

fn parseCli(args: []const []const u8) CliError!CliOptions {
    var cli = CliOptions{};
    var i: usize = initialArgIndex(args);

    while (i < args.len) : (i += 1) {
        const arg = normalizeArg(args[i]);
        if (std.mem.eql(u8, arg, "--port")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            const value = normalizeArg(args[i]);
            const parsed = std.fmt.parseInt(u16, value, 10) catch return error.InvalidPort;
            if (parsed == 0) return error.InvalidPort;
            cli.port = parsed;
        } else if (std.mem.eql(u8, arg, "--log-format")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            const value = normalizeArg(args[i]);
            if (std.mem.eql(u8, value, "plain")) {
                cli.log_format = .plain;
            } else if (std.mem.eql(u8, value, "jsonl")) {
                cli.log_format = .jsonl;
            } else {
                return error.InvalidLogFormat;
            }
        } else if (std.mem.eql(u8, arg, "--host")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            cli.host = normalizeArg(args[i]);
        } else if (std.mem.eql(u8, arg, "--serve")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            cli.serve_dir = normalizeArg(args[i]);
        } else if (std.mem.eql(u8, arg, "--config")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            cli.config_path = normalizeArg(args[i]);
        } else if (std.mem.eql(u8, arg, "--log-file")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            cli.log_file = normalizeArg(args[i]);
        } else if (std.mem.eql(u8, arg, "--pid-file")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            cli.pid_file = normalizeArg(args[i]);
        } else if (std.mem.eql(u8, arg, "--access-log")) {
            cli.access_log = true;
        } else if (std.mem.eql(u8, arg, "--no-access-log")) {
            cli.access_log = false;
        } else if (std.mem.eql(u8, arg, "--keep-alive")) {
            cli.keep_alive = true;
        } else if (std.mem.eql(u8, arg, "--no-keep-alive")) {
            cli.keep_alive = false;
        } else if (std.mem.eql(u8, arg, "--sendfile")) {
            cli.sendfile = true;
        } else if (std.mem.eql(u8, arg, "--no-sendfile")) {
            cli.sendfile = false;
        } else if (std.mem.eql(u8, arg, "--keep-alive-timeout-ms")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            cli.keep_alive_timeout_ms = parseU32Limit(normalizeArg(args[i])) catch return error.InvalidHttpLimit;
        } else if (std.mem.eql(u8, arg, "--max-requests-per-connection")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            cli.max_requests_per_connection = parseU32Limit(normalizeArg(args[i])) catch return error.InvalidHttpLimit;
        } else if (std.mem.eql(u8, arg, "--max-connections")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            cli.max_connections = parseU32Limit(normalizeArg(args[i])) catch return error.InvalidHttpLimit;
        } else if (std.mem.eql(u8, arg, "--workers")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            cli.workers = parseU32Limit(normalizeArg(args[i])) catch return error.InvalidHttpLimit;
        } else if (std.mem.eql(u8, arg, "-d")) {
            cli.daemon = true;
        } else if (std.mem.eql(u8, arg, "check")) {
            cli.command = .check;
        } else if (std.mem.eql(u8, arg, "status")) {
            cli.command = .status;
        } else if (std.mem.eql(u8, arg, "stop")) {
            cli.command = .stop;
        } else if (std.mem.eql(u8, arg, "restart")) {
            cli.command = .restart;
        } else if (std.mem.eql(u8, arg, "--force")) {
            cli.force = true;
        } else if (std.mem.eql(u8, arg, "help") or std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            cli.command = .help;
        } else if (std.mem.eql(u8, arg, "version") or std.mem.eql(u8, arg, "--version")) {
            cli.command = .version;
        } else {
            return error.UnknownArgument;
        }
    }

    return cli;
}

fn parseU32Limit(value: []const u8) !u32 {
    const parsed = std.fmt.parseInt(u32, value, 10) catch return error.InvalidHttpLimit;
    if (parsed == 0) return error.InvalidHttpLimit;
    return parsed;
}

fn resolveCommand(allocator: Allocator, io: Io, cli: CliOptions) !ParsedCommand {
    var config = Config{};
    if (cli.config_path) |path| {
        try loadConfigFile(allocator, io, path, &config);
    }
    applyCliOverrides(&config, cli);

    return switch (cli.command) {
        .serve => .{ .serve = config },
        .check => .{ .check = config },
        .status => .{ .status = config },
        .stop => .{ .stop = .{ .config = config, .force = cli.force } },
        .restart => .{ .restart = .{ .config = config, .force = cli.force } },
        .help => .help,
        .version => .version,
    };
}

fn applyCliOverrides(config: *Config, cli: CliOptions) void {
    if (cli.host) |value| config.host = value;
    if (cli.port) |value| config.port = value;
    if (cli.serve_dir) |value| config.serve_dir = value;
    if (cli.daemon) |value| config.daemon = value;
    if (cli.log_format) |value| config.log_format = value;
    if (cli.log_file) |value| config.log_file = value;
    if (cli.access_log) |value| config.access_log = value;
    if (cli.pid_file) |value| config.pid_file = value;
    if (cli.keep_alive) |value| config.keep_alive = value;
    if (cli.sendfile) |value| config.sendfile = value;
    if (cli.keep_alive_timeout_ms) |value| config.keep_alive_timeout_ms = value;
    if (cli.max_requests_per_connection) |value| config.max_requests_per_connection = value;
    if (cli.max_connections) |value| config.max_connections = value;
    if (cli.workers) |value| config.workers = value;
}

fn loadConfigFile(allocator: Allocator, io: Io, path: []const u8, config: *Config) !void {
    const bytes = try readFileAlloc(allocator, io, path, 1024 * 1024);
    defer allocator.free(bytes);

    var parsed = try std.json.parseFromSlice(FileConfig, allocator, bytes, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    try applyFileConfig(allocator, parsed.value, config);
}

fn readFileAlloc(allocator: Allocator, io: Io, path: []const u8, max_bytes: usize) ![]u8 {
    var file = try Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    defer file.close(io);

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &.{});
    while (true) {
        const n = reader.interface.readSliceShort(&buffer) catch |err| switch (err) {
            error.ReadFailed => return reader.err orelse err,
        };
        if (n == 0) break;
        if (output.items.len + n > max_bytes) return error.FileTooBig;
        try output.appendSlice(allocator, buffer[0..n]);
    }
    return try output.toOwnedSlice(allocator);
}

fn ensureDaemonSupported() !void {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        return error.UnsupportedOperatingSystem;
    }
}

fn resolvePidPath(allocator: Allocator, io: Io, env_map: std.process.Environ.Map, config: Config) ![]const u8 {
    if (config.pid_file) |path| return absolutePath(allocator, io, path);
    return defaultRuntimeFilePath(allocator, io, env_map, config, "pid");
}

fn defaultRuntimeFilePath(
    allocator: Allocator,
    io: Io,
    env_map: std.process.Environ.Map,
    config: Config,
    extension: []const u8,
) ![]const u8 {
    const runtime_dir = try defaultRuntimeDir(allocator, env_map);
    try ensureDirPath(io, runtime_dir);

    const safe_host = try sanitizePathComponent(allocator, config.host);
    return std.fmt.allocPrint(allocator, "{s}/qaws-{s}-{d}.{s}", .{ runtime_dir, safe_host, config.port, extension });
}

fn defaultRuntimeDir(allocator: Allocator, env_map: std.process.Environ.Map) ![]const u8 {
    if (env_map.get("XDG_RUNTIME_DIR")) |path| {
        if (path.len != 0) return std.fmt.allocPrint(allocator, "{s}/qaws", .{path});
    }
    if (env_map.get("PREFIX")) |path| {
        if (path.len != 0) return std.fmt.allocPrint(allocator, "{s}/var/run/qaws", .{path});
    }
    return std.fmt.allocPrint(allocator, "/tmp/qaws-{d}", .{currentUid()});
}

fn sanitizePathComponent(allocator: Allocator, value: []const u8) ![]const u8 {
    var output = try std.ArrayList(u8).initCapacity(allocator, value.len);
    errdefer output.deinit(allocator);
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '-' or byte == '_') {
            try output.append(allocator, byte);
        } else {
            try output.append(allocator, '_');
        }
    }
    return try output.toOwnedSlice(allocator);
}

fn absolutePath(allocator: Allocator, io: Io, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buffer);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ cwd_buffer[0..cwd_len], path });
}

fn ensureParentDir(io: Io, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        try ensureDirPath(io, parent);
    }
}

fn ensureDirPath(io: Io, path: []const u8) !void {
    if (std.fs.path.isAbsolute(path)) {
        var dir = Io.Dir.openDirAbsolute(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                if (std.mem.eql(u8, path, "/")) return;
                var root = try Io.Dir.openDirAbsolute(io, "/", .{});
                defer root.close(io);
                _ = try root.createDirPathStatus(io, path[1..], .default_dir);
                return;
            },
            else => return err,
        };
        dir.close(io);
    } else {
        _ = try Io.Dir.cwd().createDirPathStatus(io, path, .default_dir);
    }
}

fn acquirePidFile(allocator: Allocator, io: Io, path: []const u8) !PidFile {
    _ = allocator;
    try ensureParentDir(io, path);
    var file = Io.Dir.cwd().createFile(io, path, .{
        .read = true,
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
    }) catch |err| switch (err) {
        error.WouldBlock => return error.DaemonAlreadyRunning,
        else => return err,
    };
    errdefer file.close(io);
    return .{ .path = path, .file = file, .io = io };
}

fn readPidFile(allocator: Allocator, io: Io, path: []const u8) !i64 {
    const bytes = try readFileAlloc(allocator, io, path, 128);
    defer allocator.free(bytes);
    const trimmed = std.mem.trim(u8, bytes, &std.ascii.whitespace);
    if (trimmed.len == 0) return error.InvalidPidFile;
    return std.fmt.parseInt(i64, trimmed, 10) catch error.InvalidPidFile;
}

fn daemonStatus(allocator: Allocator, io: Io, env_map: std.process.Environ.Map, config: Config) !void {
    try ensureDaemonSupported();
    const pid_path = try resolvePidPath(allocator, io, env_map, config);
    const stdout = std.Io.File.stdout();
    var buffer: [512]u8 = undefined;
    var writer = stdout.writer(io, &buffer);

    const pid = readPidFile(allocator, io, pid_path) catch |err| switch (err) {
        error.FileNotFound => {
            try writer.interface.print("qaws: not running ({s})\n", .{pid_path});
            try writer.flush();
            return error.NotRunning;
        },
        else => return err,
    };
    if (processAlive(pid)) {
        try writer.interface.print("qaws: running pid={d} ({s})\n", .{ pid, pid_path });
    } else {
        try writer.interface.print("qaws: stale pid file pid={d} ({s})\n", .{ pid, pid_path });
        try writer.flush();
        return error.NotRunning;
    }
    try writer.flush();
}

fn daemonStop(allocator: Allocator, io: Io, env_map: std.process.Environ.Map, config: Config, force: bool) !void {
    try ensureDaemonSupported();
    const pid_path = try resolvePidPath(allocator, io, env_map, config);
    const pid = readPidFile(allocator, io, pid_path) catch |err| switch (err) {
        error.FileNotFound => return error.NotRunning,
        else => return err,
    };
    if (!processAlive(pid)) {
        deletePath(io, pid_path) catch {};
        return error.NotRunning;
    }

    try sendSignal(pid, .term);
    if (waitForExit(io, pid, 30)) {
        deletePath(io, pid_path) catch {};
        return;
    }
    if (force) {
        try sendSignal(pid, .kill);
        if (waitForExit(io, pid, 30)) {
            deletePath(io, pid_path) catch {};
            return;
        }
    }
    return error.ProcessStillRunning;
}

fn waitForExit(io: Io, pid: i64, attempts: usize) bool {
    var i: usize = 0;
    while (i < attempts) : (i += 1) {
        if (!processAlive(pid)) return true;
        Io.sleep(io, Io.Duration.fromMilliseconds(100), .awake) catch {};
    }
    return !processAlive(pid);
}

fn deletePath(io: Io, path: []const u8) !void {
    if (std.fs.path.isAbsolute(path)) {
        return Io.Dir.deleteFileAbsolute(io, path);
    }
    return Io.Dir.cwd().deleteFile(io, path);
}

fn currentPid() i64 {
    return switch (builtin.os.tag) {
        .linux => @intCast(std.os.linux.getpid()),
        .windows, .wasi => 0,
        else => @intCast(std.c.getpid()),
    };
}

fn currentUid() u32 {
    return switch (builtin.os.tag) {
        .linux => @intCast(std.os.linux.getuid()),
        .windows, .wasi => 0,
        else => @intCast(std.c.getuid()),
    };
}

fn processAlive(pid: i64) bool {
    if (pid <= 0) return false;
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return false;
    const zero_signal: std.posix.SIG = @enumFromInt(0);
    std.posix.kill(@intCast(pid), zero_signal) catch |err| switch (err) {
        error.ProcessNotFound => return false,
        error.PermissionDenied => return true,
        else => return false,
    };
    return true;
}

fn sendSignal(pid: i64, signal: StopSignal) !void {
    if (pid <= 0) return error.InvalidPidFile;
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.UnsupportedOperatingSystem;
    const posix_signal: std.posix.SIG = switch (signal) {
        .term => .TERM,
        .kill => .KILL,
    };
    return std.posix.kill(@intCast(pid), posix_signal);
}

fn installShutdownHandlers() void {
    server.resetShutdown();
    if (builtin.os.tag != .linux) return;

    const action = std.os.linux.Sigaction{
        .handler = .{ .handler = linuxShutdownSignalHandler },
        .mask = std.os.linux.sigemptyset(),
        .flags = 0,
    };
    _ = std.os.linux.sigaction(.TERM, &action, null);
    _ = std.os.linux.sigaction(.INT, &action, null);
}

fn linuxShutdownSignalHandler(signal: std.os.linux.SIG) callconv(.c) void {
    _ = signal;
    server.requestShutdown();
}

fn normalizeArg(arg: []const u8) []const u8 {
    return std.mem.trim(u8, arg, &std.ascii.whitespace);
}

fn initialArgIndex(args: []const []const u8) usize {
    if (args.len <= 1) return 1;
    if (std.mem.eql(u8, args[0], args[1])) return 2;
    if (std.mem.eql(u8, basename(args[0]), basename(args[1]))) return 2;
    return 1;
}

fn basename(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[slash + 1 ..];
}

fn printCliError(err: CliError) !void {
    const stderr = std.Io.File.stderr();
    var buffer: [512]u8 = undefined;
    var writer = stderr.writer(std.Io.Threaded.global_single_threaded.io(), &buffer);
    const out = &writer.interface;

    switch (err) {
        error.MissingValue => try out.writeAll("qaws: missing value for option\n"),
        error.InvalidPort => try out.writeAll("qaws: port must be a number from 1 to 65535\n"),
        error.InvalidHttpLimit => try out.writeAll("qaws: HTTP limits must be positive numbers\n"),
        error.InvalidLogFormat => try out.writeAll("qaws: log format must be plain or jsonl\n"),
        error.UnknownArgument => try out.writeAll("qaws: unknown argument\n"),
    }
    try out.writeAll("Run `qaws help` for usage.\n");
    try writer.flush();
}

fn printConfigError(err: anyerror) !void {
    const stderr = std.Io.File.stderr();
    var buffer: [512]u8 = undefined;
    var writer = stderr.writer(std.Io.Threaded.global_single_threaded.io(), &buffer);
    const out = &writer.interface;

    try out.print("qaws: configuration error: {s}\n", .{@errorName(err)});
    try out.writeAll("Run `qaws help` for usage.\n");
    try writer.flush();
}

fn printRuntimeError(err: anyerror) !void {
    const stderr = std.Io.File.stderr();
    var buffer: [512]u8 = undefined;
    var writer = stderr.writer(std.Io.Threaded.global_single_threaded.io(), &buffer);
    const out = &writer.interface;

    switch (err) {
        error.DaemonAlreadyRunning => try out.writeAll("qaws: daemon already running; use `qaws status`, `qaws stop`, or `qaws restart`\n"),
        error.NotRunning => try out.writeAll("qaws: not running\n"),
        error.ProcessStillRunning => try out.writeAll("qaws: process is still running; retry with `qaws stop --force`\n"),
        error.UnsupportedOperatingSystem => try out.writeAll("qaws: daemon control is not supported on this operating system\n"),
        else => try out.print("qaws: runtime error: {s}\n", .{@errorName(err)}),
    }
    try writer.flush();
}

fn printHelp() !void {
    const stdout = std.Io.File.stdout();
    var buffer: [1024]u8 = undefined;
    var writer = stdout.writer(std.Io.Threaded.global_single_threaded.io(), &buffer);
    const out = &writer.interface;

    try out.writeAll(
        \\qaws - Quick Arm Webserver
        \\
        \\Usage:
        \\  qaws [--host <addr>] [--port <port>] [--serve <directory>] [-d]
        \\  qaws check --config <file>
        \\  qaws status [--config <file>] [--pid-file <path>]
        \\  qaws stop [--config <file>] [--pid-file <path>] [--force]
        \\  qaws restart [--config <file>] [--pid-file <path>] [--force]
        \\  qaws help
        \\  qaws version
        \\
        \\Defaults:
        \\  --host  0.0.0.0
        \\  --port  80
        \\  --serve ./public
        \\
        \\Options:
        \\  --config <path>
        \\  --log-format plain|jsonl
        \\  --log-file <path>
        \\  --pid-file <path>
        \\  --keep-alive
        \\  --no-keep-alive
        \\  --sendfile
        \\  --no-sendfile
        \\  --keep-alive-timeout-ms <n>
        \\  --max-requests-per-connection <n>
        \\  --max-connections <n>
        \\  --workers <n>
        \\  --access-log
        \\  --no-access-log
        \\
    );
    try writer.flush();
}

fn printVersion() !void {
    const stdout = std.Io.File.stdout();
    var buffer: [64]u8 = undefined;
    var writer = stdout.writer(std.Io.Threaded.global_single_threaded.io(), &buffer);
    const out = &writer.interface;

    try out.print("qaws {s}\n", .{version});
    try writer.flush();
}

fn checkConfig(io: Io, config: Config) !void {
    var root = try Io.Dir.cwd().openDir(io, config.serve_dir, .{});
    root.close(io);

    const stdout = std.Io.File.stdout();
    var buffer: [256]u8 = undefined;
    var writer = stdout.writer(io, &buffer);
    try writer.interface.print("qaws: configuration ok ({s} on {s}:{d})\n", .{
        config.serve_dir,
        config.host,
        config.port,
    });
    try writer.flush();
}

fn daemonize() !void {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        return error.UnsupportedOperatingSystem;
    }

    const first_pid = try forkProcess();
    if (first_pid > 0) {
        std.process.exit(0);
    }

    try createSession();

    const second_pid = try forkProcess();
    if (second_pid > 0) {
        std.process.exit(0);
    }

    try changeToRoot();
    try redirectStandardFiles();
}

fn forkProcess() !i64 {
    return switch (builtin.os.tag) {
        .linux => {
            const rc = std.os.linux.fork();
            const err = std.os.linux.errno(rc);
            if (err != .SUCCESS) return error.Unexpected;
            return @intCast(rc);
        },
        else => {
            const rc = std.c.fork();
            if (rc < 0) return error.Unexpected;
            return @intCast(rc);
        },
    };
}

fn createSession() !void {
    switch (builtin.os.tag) {
        .linux => {
            const rc = std.os.linux.setsid();
            const err = std.os.linux.errno(rc);
            if (err != .SUCCESS) return error.Unexpected;
        },
        else => {
            if (std.c.setsid() < 0) return error.Unexpected;
        },
    }
}

fn changeToRoot() !void {
    switch (builtin.os.tag) {
        .linux => {
            const path: [*:0]const u8 = "/";
            const rc = std.os.linux.chdir(path);
            const err = std.os.linux.errno(rc);
            if (err != .SUCCESS) return error.Unexpected;
        },
        else => {
            if (std.c.chdir("/") < 0) return error.Unexpected;
        },
    }
}

fn redirectStandardFiles() !void {
    switch (builtin.os.tag) {
        .linux => {
            const open_rc = std.os.linux.open("/dev/null", .{ .ACCMODE = .RDWR }, 0);
            if (std.os.linux.errno(open_rc) != .SUCCESS) return error.Unexpected;
            const fd: i32 = @intCast(open_rc);
            defer _ = std.os.linux.close(fd);

            const stdin_rc = std.os.linux.dup2(fd, std.posix.STDIN_FILENO);
            if (std.os.linux.errno(stdin_rc) != .SUCCESS) return error.Unexpected;
            const stdout_rc = std.os.linux.dup2(fd, std.posix.STDOUT_FILENO);
            if (std.os.linux.errno(stdout_rc) != .SUCCESS) return error.Unexpected;
            const stderr_rc = std.os.linux.dup2(fd, std.posix.STDERR_FILENO);
            if (std.os.linux.errno(stderr_rc) != .SUCCESS) return error.Unexpected;
        },
        else => {
            const fd = std.c.open("/dev/null", .{ .ACCMODE = .RDWR });
            if (fd < 0) return error.Unexpected;
            defer _ = std.c.close(fd);
            if (std.c.dup2(fd, std.posix.STDIN_FILENO) < 0) return error.Unexpected;
            if (std.c.dup2(fd, std.posix.STDOUT_FILENO) < 0) return error.Unexpected;
            if (std.c.dup2(fd, std.posix.STDERR_FILENO) < 0) return error.Unexpected;
        },
    }
}

test "normalize root and directory paths" {
    const allocator = std.testing.allocator;
    const root = try normalizeTarget(allocator, "/", .deny_except_well_known);
    defer allocator.free(root);
    try std.testing.expectEqualStrings("index.html", root);

    const nested = try normalizeTarget(allocator, "/docs/", .deny_except_well_known);
    defer allocator.free(nested);
    try std.testing.expectEqualStrings("docs/index.html", nested);
}

test "fast normalize handles common safe targets" {
    try std.testing.expectEqualStrings("index.html", normalizeTargetFast("/", .deny_except_well_known).?);
    try std.testing.expectEqualStrings("index.html", normalizeTargetFast("/index.html", .deny_except_well_known).?);
    try std.testing.expectEqualStrings("assets/app.css", normalizeTargetFast("/assets/app.css", .deny_except_well_known).?);
    try std.testing.expectEqualStrings(".well-known/security.txt", normalizeTargetFast("/.well-known/security.txt", .deny_except_well_known).?);

    try std.testing.expect(normalizeTargetFast("/docs/", .deny_except_well_known) == null);
    try std.testing.expect(normalizeTargetFast("/a%2fb", .deny_except_well_known) == null);
    try std.testing.expect(normalizeTargetFast("/../build.zig", .deny_except_well_known) == null);
    try std.testing.expect(normalizeTargetFast("/.env", .deny_except_well_known) == null);
    try std.testing.expect(normalizeTargetFast("/.well-known/security.txt", .deny_all) == null);
}

test "request chunk appender preserves keep-alive leftovers" {
    var buffer: [max_request_bytes]u8 = undefined;
    var len: usize = 0;
    const first = "GET / HTTP/1.1\r\nHost: x\r\n";
    var step = try appendRequestChunk(&buffer, &len, first);
    try std.testing.expect(!step.complete);
    try std.testing.expectEqual(first.len, step.consumed);

    const second = "\r\nGET /next HTTP/1.1\r\nHost: x\r\n\r\n";
    step = try appendRequestChunk(&buffer, &len, second);
    try std.testing.expect(step.complete);
    try std.testing.expectEqualStrings("GET / HTTP/1.1\r\nHost: x\r\n\r\n", buffer[0..step.request_len]);
    try std.testing.expectEqual(@as(usize, 2), step.consumed);
}

test "request chunk appender rejects oversized headers" {
    var buffer: [8]u8 = undefined;
    var len: usize = 0;
    try std.testing.expectError(error.RequestTooLarge, appendRequestChunk(&buffer, &len, "123456789"));
}

test "request reader handles pipelined requests in order" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const fake_stream = Io.net.Stream{
        .socket = .{
            .handle = -1,
            .address = .{ .ip4 = Io.net.Ip4Address.loopback(0) },
        },
    };
    const pipelined = "GET /first HTTP/1.1\r\nHost: x\r\n\r\nHEAD /second HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
    var reader_buffer: [pipelined.len]u8 = undefined;
    @memcpy(&reader_buffer, pipelined);
    var reader = ConnectionReader{
        .io = io,
        .stream = fake_stream,
        .buffer = &reader_buffer,
        .start = 0,
        .end = reader_buffer.len,
    };
    var request_buffer: [max_request_bytes]u8 = undefined;

    const first_bytes = try readHttpRequest(&reader, keepAliveTimeout(.{}), &request_buffer);
    const first = try parseRequest(first_bytes);
    try std.testing.expectEqualStrings("GET", first.method);
    try std.testing.expectEqualStrings("/first", first.target);

    const second_bytes = try readHttpRequest(&reader, keepAliveTimeout(.{}), &request_buffer);
    const second = try parseRequest(second_bytes);
    try std.testing.expectEqualStrings("HEAD", second.method);
    try std.testing.expectEqualStrings("/second", second.target);
    try std.testing.expectEqual(ConnectionDirective.close, second.connection);
}

test "pipelined malformed request is rejected after prior request" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const fake_stream = Io.net.Stream{
        .socket = .{
            .handle = -1,
            .address = .{ .ip4 = Io.net.Ip4Address.loopback(0) },
        },
    };
    const pipelined = "GET / HTTP/1.1\r\nHost: x\r\n\r\nBAD\r\n\r\n";
    var reader_buffer: [pipelined.len]u8 = undefined;
    @memcpy(&reader_buffer, pipelined);
    var reader = ConnectionReader{
        .io = io,
        .stream = fake_stream,
        .buffer = &reader_buffer,
        .start = 0,
        .end = reader_buffer.len,
    };
    var request_buffer: [max_request_bytes]u8 = undefined;

    _ = try parseRequest(try readHttpRequest(&reader, keepAliveTimeout(.{}), &request_buffer));
    try std.testing.expectError(error.BadRequest, parseRequest(try readHttpRequest(&reader, keepAliveTimeout(.{}), &request_buffer)));
}

test "worker count resolves explicit and automatic defaults" {
    try std.testing.expectEqual(@as(usize, 3), resolveWorkerCount(.{ .workers = 3 }));
    try std.testing.expect(resolveWorkerCount(.{}) >= 1);
}

test "runtime backend selection follows supported platforms" {
    try std.testing.expectEqual(RuntimeBackend.epoll, selectRuntimeBackend(.linux));
    try std.testing.expectEqual(RuntimeBackend.kqueue, selectRuntimeBackend(.macos));
    try std.testing.expectEqual(RuntimeBackend.kqueue, selectRuntimeBackend(.freebsd));
    try std.testing.expectEqual(RuntimeBackend.worker, selectRuntimeBackend(.windows));
    try std.testing.expectEqualStrings("epoll", runtimeBackendName(.epoll));
    try std.testing.expectEqualStrings("kqueue", runtimeBackendName(.kqueue));
    try std.testing.expectEqualStrings("worker", runtimeBackendName(.worker));
}

test "worker queue push pop and close behavior" {
    var queue = try WorkerQueue.init(std.testing.allocator, std.Io.Threaded.global_single_threaded.io(), 1);
    defer queue.deinit();

    const fake_stream = Io.net.Stream{
        .socket = .{
            .handle = -1,
            .address = .{ .ip4 = Io.net.Ip4Address.loopback(0) },
        },
    };
    try std.testing.expect(queue.push(fake_stream));
    try std.testing.expect(!queue.push(fake_stream));
    try std.testing.expect(queue.popAvailable() != null);
    try std.testing.expect(queue.popAvailable() == null);
    try std.testing.expect(queue.push(fake_stream));
    try std.testing.expect(queue.pop() != null);
    queue.close();
    try std.testing.expect(!queue.push(fake_stream));
    try std.testing.expect(queue.pop() == null);
}

test "wake pipe supports event worker notifications" {
    if (selectRuntimeBackend(builtin.os.tag) == .worker) return;

    const pipe = try createWakePipe();
    defer closeWakePipe(pipe);

    try wakeFd(pipe.write);
    var buffer: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try readFd(pipe.read, &buffer));

    try wakeFd(pipe.write);
    drainWakeFd(pipe.read);
    try std.testing.expectError(error.WouldBlock, readFd(pipe.read, &buffer));
}

test "event backend timeout helpers cap wait and detect fresh connections" {
    try std.testing.expectEqual(@as(i32, 1000), eventWaitTimeoutMs(.{ .keep_alive_timeout_ms = 5000 }));
    try std.testing.expectEqual(@as(i32, 25), eventWaitTimeoutMs(.{ .keep_alive_timeout_ms = 25 }));

    const io = std.Io.Threaded.global_single_threaded.io();
    const now = Io.Timestamp.now(io, .awake);
    const fake_stream = Io.net.Stream{
        .socket = .{
            .handle = -1,
            .address = .{ .ip4 = Io.net.Ip4Address.loopback(0) },
        },
    };
    const conn = EventConnection{
        .stream = fake_stream,
        .last_active = now,
    };
    try std.testing.expect(!eventConnectionExpired(&conn, now, .{ .keep_alive_timeout_ms = 1 }));

    var pending_conn = conn;
    pending_conn.pending = .{
        .header = "HTTP/1.1 200 OK\r\n\r\n",
        .request_end = 1,
    };
    try std.testing.expect(!eventConnectionExpired(&pending_conn, now.addDuration(Io.Duration.fromMilliseconds(5000)), .{ .keep_alive_timeout_ms = 1 }));
}

test "cached event response selection handles GET HEAD and 304" {
    const cached = CachedFileSnapshot{
        .body = "Bismillah.",
        .size = 10,
        .mtime_sec = 0,
        .header_200 = "HTTP/1.1 200 OK\r\nConnection: keep-alive\r\n\r\n",
        .header_304 = "HTTP/1.1 304 Not Modified\r\nConnection: keep-alive\r\n\r\n",
        .response_200 = "HTTP/1.1 200 OK\r\nConnection: keep-alive\r\n\r\nBismillah.",
    };

    const get = cachedEventResponseFromSnapshot(true, cached, null, false);
    try std.testing.expectEqual(@as(u16, 200), get.status);
    try std.testing.expectEqual(@as(u64, 10), get.bytes);
    try std.testing.expectEqualStrings(cached.response_200, get.header);
    try std.testing.expectEqual(@as(usize, 0), get.body.len);

    const head = cachedEventResponseFromSnapshot(true, cached, null, true);
    try std.testing.expectEqual(@as(u16, 200), head.status);
    try std.testing.expectEqual(@as(u64, 0), head.bytes);
    try std.testing.expectEqualStrings(cached.header_200, head.header);
    try std.testing.expectEqual(@as(usize, 0), head.body.len);

    const not_modified = cachedEventResponseFromSnapshot(true, cached, "Thu, 01 Jan 1970 00:00:00 GMT", false);
    try std.testing.expectEqual(@as(u16, 304), not_modified.status);
    try std.testing.expectEqual(@as(u64, 0), not_modified.bytes);
    try std.testing.expectEqualStrings(cached.header_304, not_modified.header);
    try std.testing.expectEqual(@as(usize, 0), not_modified.body.len);
}

test "pending event write tracks partial header and body progress" {
    var pending = PendingEventWrite{
        .header = "header",
        .body = "body",
        .request_end = 1,
    };
    try std.testing.expect(pending.active());
    try std.testing.expectEqualStrings("header", pendingWriteSlice(&pending).?);

    advancePendingWrite(&pending, 2);
    try std.testing.expectEqual(@as(usize, 2), pending.header_offset);
    try std.testing.expectEqualStrings("ader", pendingWriteSlice(&pending).?);

    advancePendingWrite(&pending, 4);
    try std.testing.expectEqual(@as(usize, 6), pending.header_offset);
    try std.testing.expectEqual(@as(usize, 0), pending.body_offset);
    try std.testing.expectEqualStrings("body", pendingWriteSlice(&pending).?);

    advancePendingWrite(&pending, 3);
    try std.testing.expectEqual(@as(usize, 3), pending.body_offset);
    try std.testing.expectEqualStrings("y", pendingWriteSlice(&pending).?);

    advancePendingWrite(&pending, 1);
    try std.testing.expect(pending.complete());
    try std.testing.expect(pendingWriteSlice(&pending) == null);
}

test "event batch limit remains internal and bounded" {
    try std.testing.expectEqual(@as(usize, 16), event_request_batch_limit);
}

test "normal disconnect classifier covers quiet body transfer closes" {
    try std.testing.expect(isNormalDisconnect(error.BrokenPipe));
    try std.testing.expect(isNormalDisconnect(error.ConnectionResetByPeer));
    try std.testing.expect(isNormalDisconnect(error.SocketUnconnected));
    try std.testing.expect(isNormalDisconnect(error.ConnectionAborted));
    try std.testing.expect(!isNormalDisconnect(error.SendfileFailed));
}

test "log queue preserves events and reports full access queue" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var queue = try LogQueue.init(allocator, io, 1);
    defer queue.deinit();

    const first = try allocator.dupe(u8, "event\n");
    try std.testing.expect(queue.pushBlocking(first));
    const second = try allocator.dupe(u8, "access\n");
    try std.testing.expect(!queue.tryPush(second));
    allocator.free(second);

    const popped = queue.pop().?;
    try std.testing.expectEqualStrings("event\n", popped);
    allocator.free(popped);
    queue.close();
    try std.testing.expect(queue.pop() == null);
}

test "async access logger drops when queue is full" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var logger = Logger{
        .allocator = allocator,
        .io = io,
        .file = std.Io.File.stderr(),
        .owns_file = false,
        .format = .plain,
        .access_enabled = true,
        .queue = try LogQueue.init(allocator, io, 1),
    };
    defer {
        logger.queue.close();
        logger.queue.deinit();
    }

    const record = AccessRecord{
        .remote = "127.0.0.1:1",
        .method = "GET",
        .target = "/",
        .status = 200,
        .bytes = 5,
        .duration_us = 10,
        .user_agent = "test",
    };
    logger.access(record);
    logger.access(record);
    try std.testing.expectEqual(@as(u32, 1), logger.dropped_access.load(.monotonic));
}

test "connection accounting enforces configured cap" {
    var active = std.atomic.Value(u32).init(0);
    try std.testing.expect(tryAcquireConnection(&active, 1));
    try std.testing.expect(!tryAcquireConnection(&active, 1));
    releaseConnection(&active);
    try std.testing.expectEqual(@as(u32, 0), active.load(.seq_cst));
}

test "normalize rejects traversal" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.Forbidden, normalizeTarget(allocator, "/../build.zig", .deny_except_well_known));
    try std.testing.expectError(error.Forbidden, normalizeTarget(allocator, "/%2e%2e/build.zig", .deny_except_well_known));
    try std.testing.expectError(error.Forbidden, normalizeTarget(allocator, "/a%2fb", .deny_except_well_known));
}

test "normalize enforces dotfile policy" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.Forbidden, normalizeTarget(allocator, "/.env", .deny_except_well_known));
    try std.testing.expectError(error.Forbidden, normalizeTarget(allocator, "/.well-known/security.txt", .deny_all));

    const well_known = try normalizeTarget(allocator, "/.well-known/security.txt", .deny_except_well_known);
    defer allocator.free(well_known);
    try std.testing.expectEqualStrings(".well-known/security.txt", well_known);
}

test "parse cli commands" {
    const version_args: []const [:0]const u8 = &.{ "qaws", "version" };
    try std.testing.expectEqual(ParsedCommand.version, try parseArgs(version_args));

    const help_args: []const [:0]const u8 = &.{ "qaws", "help" };
    try std.testing.expectEqual(ParsedCommand.help, try parseArgs(help_args));

    const dash_help_args: []const [:0]const u8 = &.{ "qaws", "--help" };
    try std.testing.expectEqual(ParsedCommand.help, try parseArgs(dash_help_args));

    const check_args: []const [:0]const u8 = &.{ "qaws", "check", "--config", "qaws.json" };
    const cli = try parseCli(check_args);
    try std.testing.expectEqual(CliCommand.check, cli.command);
    try std.testing.expectEqualStrings("qaws.json", cli.config_path.?);

    const stop_args: []const [:0]const u8 = &.{ "qaws", "stop", "--pid-file", "/tmp/qaws.pid", "--force" };
    const stop_cli = try parseCli(stop_args);
    try std.testing.expectEqual(CliCommand.stop, stop_cli.command);
    try std.testing.expectEqualStrings("/tmp/qaws.pid", stop_cli.pid_file.?);
    try std.testing.expect(stop_cli.force);
}

test "parse cli serve options" {
    const args: []const [:0]const u8 = &.{
        "qaws",
        "--host",
        "127.0.0.1",
        "--port",
        "8080",
        "--serve",
        "site",
        "--log-format",
        "jsonl",
        "--log-file",
        "qaws.log",
        "--no-access-log",
        "--no-keep-alive",
        "--no-sendfile",
        "--keep-alive-timeout-ms",
        "1500",
        "--max-requests-per-connection",
        "500",
        "--max-connections",
        "256",
        "--workers",
        "3",
        "-d",
    };
    const command = try parseArgs(args);
    switch (command) {
        .serve => |config| {
            try std.testing.expectEqualStrings("127.0.0.1", config.host);
            try std.testing.expectEqual(@as(u16, 8080), config.port);
            try std.testing.expectEqualStrings("site", config.serve_dir);
            try std.testing.expectEqual(LogFormat.jsonl, config.log_format);
            try std.testing.expectEqualStrings("qaws.log", config.log_file.?);
            try std.testing.expect(!config.access_log);
            try std.testing.expect(!config.keep_alive);
            try std.testing.expect(!config.sendfile);
            try std.testing.expectEqual(@as(u32, 1500), config.keep_alive_timeout_ms);
            try std.testing.expectEqual(@as(u32, 500), config.max_requests_per_connection);
            try std.testing.expectEqual(@as(u32, 256), config.max_connections);
            try std.testing.expectEqual(@as(u32, 3), config.workers);
            try std.testing.expect(config.daemon);
        },
        else => return error.TestExpectedEqual,
    }
}

test "parse cli trims argument whitespace" {
    const args: []const [:0]const u8 = &.{ "qaws", "version\r" };
    try std.testing.expectEqual(ParsedCommand.version, try parseArgs(args));
}

test "parse cli skips duplicated argv0" {
    const args: []const [:0]const u8 = &.{ "/data/data/com.termux/files/usr/bin/qaws", "/data/data/com.termux/files/usr/bin/qaws", "version" };
    try std.testing.expectEqual(ParsedCommand.version, try parseArgs(args));
}

test "parse cli skips argv0 basename duplicate" {
    const args: []const [:0]const u8 = &.{ "qaws", "/data/data/com.termux/files/usr/bin/qaws", "version" };
    try std.testing.expectEqual(ParsedCommand.version, try parseArgs(args));
}

test "json log string escaping" {
    const allocator = std.testing.allocator;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    try appendJsonString(&output, allocator, "a\"b\\c\n");
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\n\"", output.items);
}

test "prebuilt cached headers preserve response fields" {
    const allocator = std.testing.allocator;
    const extra_headers = [_]Header{.{ .name = "Cache-Control", .value = "public, max-age=60" }};
    const header = try buildHeaderAlloc(
        allocator,
        .{ .code = 200, .reason = "OK" },
        "text/html; charset=utf-8",
        123,
        "keep-alive",
        null,
        &extra_headers,
        "Thu, 01 Jan 1970 00:00:00 GMT",
        null,
    );
    defer allocator.free(header);

    try std.testing.expect(std.mem.indexOf(u8, header, "HTTP/1.1 200 OK\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "Content-Length: 123\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "Connection: keep-alive\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "X-Content-Type-Options: nosniff\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "Last-Modified: Thu, 01 Jan 1970 00:00:00 GMT\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "Cache-Control: public, max-age=60\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, header, "\r\n\r\n"));
}

test "file transfer path selects sendfile only for uncached GET bodies" {
    try std.testing.expectEqual(FileTransferPath.none, selectFileTransferPath(.{}, true, false));
    try std.testing.expectEqual(FileTransferPath.none, selectFileTransferPath(.{}, false, true));
    try std.testing.expectEqual(FileTransferPath.buffered, selectFileTransferPath(.{ .sendfile = false }, false, false));
    const expected: FileTransferPath = if (sendfileSupportedForOs(builtin.os.tag)) .sendfile else .buffered;
    try std.testing.expectEqual(expected, selectFileTransferPath(.{}, false, false));
    try std.testing.expect(sendfileSupportedForOs(.linux));
    try std.testing.expect(sendfileSupportedForOs(.macos));
    try std.testing.expect(sendfileSupportedForOs(.freebsd));
    try std.testing.expect(!sendfileSupportedForOs(.windows));
}

test "json config applies values and cli overrides" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "listen": { "host": "127.0.0.1", "port": 8080 },
        \\  "serve": "site",
        \\  "daemon": { "enabled": true, "pid_file": "qaws.pid", "log_file": "qaws.log" },
        \\  "logging": { "format": "jsonl", "access": false },
        \\  "security": { "dotfiles": "deny_all" },
        \\  "cache": { "enabled": false, "max_file_bytes": 1024, "max_total_bytes": 4096, "revalidate_ms": 250 },
        \\  "headers": { "Cache-Control": "public, max-age=60" },
        \\  "http": {
        \\    "last_modified": false,
        \\    "trailing_slash_redirect": false,
        \\    "keep_alive": false,
        \\    "sendfile": false,
        \\    "keep_alive_timeout_ms": 2000,
        \\    "max_requests_per_connection": 100,
        \\    "max_connections": 64,
        \\    "workers": 2
        \\  }
        \\}
    ;

    var parsed = try std.json.parseFromSlice(FileConfig, allocator, json, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var config = Config{};
    try applyFileConfig(arena.allocator(), parsed.value, &config);
    try std.testing.expectEqualStrings("127.0.0.1", config.host);
    try std.testing.expectEqual(@as(u16, 8080), config.port);
    try std.testing.expectEqualStrings("site", config.serve_dir);
    try std.testing.expect(config.daemon);
    try std.testing.expectEqualStrings("qaws.pid", config.pid_file.?);
    try std.testing.expectEqualStrings("qaws.log", config.log_file.?);
    try std.testing.expectEqual(LogFormat.jsonl, config.log_format);
    try std.testing.expect(!config.access_log);
    try std.testing.expectEqual(DotfilePolicy.deny_all, config.dotfiles);
    try std.testing.expect(!config.last_modified);
    try std.testing.expect(!config.trailing_slash_redirect);
    try std.testing.expect(!config.keep_alive);
    try std.testing.expect(!config.sendfile);
    try std.testing.expectEqual(@as(u32, 2000), config.keep_alive_timeout_ms);
    try std.testing.expectEqual(@as(u32, 100), config.max_requests_per_connection);
    try std.testing.expectEqual(@as(u32, 64), config.max_connections);
    try std.testing.expectEqual(@as(u32, 2), config.workers);
    try std.testing.expect(!config.cache_enabled);
    try std.testing.expectEqual(@as(usize, 1024), config.cache_max_file_bytes);
    try std.testing.expectEqual(@as(usize, 4096), config.cache_max_total_bytes);
    try std.testing.expectEqual(@as(u32, 250), config.cache_revalidate_ms);

    applyCliOverrides(&config, .{
        .host = "0.0.0.0",
        .port = 9090,
        .serve_dir = "public",
        .access_log = true,
        .keep_alive = true,
        .sendfile = true,
        .keep_alive_timeout_ms = 3000,
        .max_requests_per_connection = 600,
        .max_connections = 128,
        .workers = 4,
    });
    try std.testing.expectEqualStrings("0.0.0.0", config.host);
    try std.testing.expectEqual(@as(u16, 9090), config.port);
    try std.testing.expectEqualStrings("public", config.serve_dir);
    try std.testing.expect(config.access_log);
    try std.testing.expect(config.keep_alive);
    try std.testing.expect(config.sendfile);
    try std.testing.expectEqual(@as(u32, 3000), config.keep_alive_timeout_ms);
    try std.testing.expectEqual(@as(u32, 600), config.max_requests_per_connection);
    try std.testing.expectEqual(@as(u32, 128), config.max_connections);
    try std.testing.expectEqual(@as(u32, 4), config.workers);
}

test "json config rejects unknown keys and invalid headers" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.UnknownField,
        std.json.parseFromSlice(FileConfig, allocator, "{ \"unknown\": true }", .{
            .ignore_unknown_fields = false,
        }),
    );

    var parsed = try std.json.parseFromSlice(FileConfig, allocator, "{ \"headers\": { \"X-Test\": 123 } }", .{
        .ignore_unknown_fields = false,
    });
    defer parsed.deinit();

    var config = Config{};
    try std.testing.expectError(error.InvalidHeaderConfig, applyFileConfig(allocator, parsed.value, &config));

    var protected = try std.json.parseFromSlice(FileConfig, allocator, "{ \"headers\": { \"Content-Length\": \"12\" } }", .{
        .ignore_unknown_fields = false,
    });
    defer protected.deinit();
    try std.testing.expectError(error.ProtectedHeader, applyFileConfig(allocator, protected.value, &config));
}

test "json config rejects invalid http limits" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(FileConfig, allocator, "{ \"http\": { \"keep_alive_timeout_ms\": 0 } }", .{
        .ignore_unknown_fields = false,
    });
    defer parsed.deinit();

    var config = Config{};
    try std.testing.expectError(error.InvalidHttpConfig, applyFileConfig(allocator, parsed.value, &config));

    var parsed_workers = try std.json.parseFromSlice(FileConfig, allocator, "{ \"http\": { \"workers\": 0 } }", .{
        .ignore_unknown_fields = false,
    });
    defer parsed_workers.deinit();
    try std.testing.expectError(error.InvalidHttpConfig, applyFileConfig(allocator, parsed_workers.value, &config));
}

test "json config rejects invalid cache limits" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(FileConfig, allocator, "{ \"cache\": { \"max_file_bytes\": 0 } }", .{
        .ignore_unknown_fields = false,
    });
    defer parsed.deinit();

    var config = Config{};
    try std.testing.expectError(error.InvalidCacheConfig, applyFileConfig(allocator, parsed.value, &config));

    try std.testing.expectError(
        error.UnknownField,
        std.json.parseFromSlice(FileConfig, allocator, "{ \"cache\": { \"unknown\": true } }", .{
            .ignore_unknown_fields = false,
        }),
    );
}

test "http keep-alive decisions follow protocol defaults" {
    const http11 = try parseRequest("GET / HTTP/1.1\r\nHost: example\r\n\r\n");
    try std.testing.expectEqual(HttpVersion.http_1_1, http11.version);
    try std.testing.expect(requestWantsKeepAlive(http11, .{}, 1));

    const http11_close = try parseRequest("GET / HTTP/1.1\r\nConnection: close\r\n\r\n");
    try std.testing.expectEqual(ConnectionDirective.close, http11_close.connection);
    try std.testing.expect(!requestWantsKeepAlive(http11_close, .{}, 1));

    const http10 = try parseRequest("GET / HTTP/1.0\r\n\r\n");
    try std.testing.expectEqual(HttpVersion.http_1_0, http10.version);
    try std.testing.expect(!requestWantsKeepAlive(http10, .{}, 1));

    const http10_keep_alive = try parseRequest("GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n");
    try std.testing.expectEqual(ConnectionDirective.keep_alive, http10_keep_alive.connection);
    try std.testing.expect(requestWantsKeepAlive(http10_keep_alive, .{}, 1));
}

test "connection header parsing is tokenized and close wins" {
    const request = try parseRequest("GET / HTTP/1.1\r\nConnection: Upgrade, Keep-Alive\r\nConnection: close\r\n\r\n");
    try std.testing.expectEqual(ConnectionDirective.close, request.connection);

    const body = try parseRequest("GET / HTTP/1.1\r\nContent-Length: 10\r\n\r\n");
    try std.testing.expect(body.has_request_body);

    const disabled = Config{ .keep_alive = false };
    try std.testing.expect(!requestWantsKeepAlive(try parseRequest("GET / HTTP/1.1\r\n\r\n"), disabled, 1));

    const capped = Config{ .max_requests_per_connection = 1 };
    try std.testing.expect(!requestWantsKeepAlive(try parseRequest("GET / HTTP/1.1\r\n\r\n"), capped, 1));
}

test "http date parsing and slash redirect locations" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqual(@as(?i64, 0), parseHttpDate("Thu, 01 Jan 1970 00:00:00 GMT"));
    try std.testing.expect(parseHttpDate("bad") == null);

    const redirected = try slashRedirectLocation(allocator, "/docs?x=1");
    defer allocator.free(redirected);
    try std.testing.expectEqualStrings("/docs/?x=1", redirected);
    try std.testing.expect(!targetPathHasTrailingSlash("/docs?x=1"));
    try std.testing.expect(targetPathHasTrailingSlash("/docs/?x=1"));
}

test "runtime path component sanitization" {
    const allocator = std.testing.allocator;
    const sanitized = try sanitizePathComponent(allocator, "127.0.0.1:8080/[::1]");
    defer allocator.free(sanitized);
    try std.testing.expectEqualStrings("127.0.0.1_8080____1_", sanitized);
}
