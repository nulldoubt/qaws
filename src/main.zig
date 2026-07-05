const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const IpAddress = Io.net.IpAddress;

const version = "0.2.1";
const server_name = "qaws/" ++ version;
const max_request_bytes = 16 * 1024;

var shutdown_requested = std.atomic.Value(bool).init(false);

const LogFormat = enum {
    plain,
    jsonl,
};

const Header = struct {
    name: []const u8,
    value: []const u8,
};

const Config = struct {
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
    headers: []const Header = &.{},
};

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
    force: bool = false,
};

const FileConfig = struct {
    listen: ?ListenConfig = null,
    serve: ?[]const u8 = null,
    daemon: ?DaemonConfig = null,
    logging: ?LoggingConfig = null,
    security: ?SecurityConfig = null,
    headers: ?std.json.Value = null,
    http: ?HttpConfig = null,
};

const ListenConfig = struct {
    host: ?[]const u8 = null,
    port: ?u16 = null,
};

const DaemonConfig = struct {
    enabled: ?bool = null,
    pid_file: ?[]const u8 = null,
    log_file: ?[]const u8 = null,
};

const LoggingConfig = struct {
    format: ?LogFormat = null,
    access: ?bool = null,
};

const DotfilePolicy = enum {
    deny_except_well_known,
    deny_all,
    allow,
};

const SecurityConfig = struct {
    dotfiles: ?DotfilePolicy = null,
};

const HttpConfig = struct {
    last_modified: ?bool = null,
    trailing_slash_redirect: ?bool = null,
};

const Request = struct {
    method: []const u8,
    target: []const u8,
    user_agent: ?[]const u8 = null,
    if_modified_since: ?[]const u8 = null,
};

const ResponseStatus = struct {
    code: u16,
    reason: []const u8,
};

const ResponseResult = struct {
    status: u16,
    bytes: u64,
};

const AccessRecord = struct {
    remote: []const u8,
    method: []const u8,
    target: []const u8,
    status: u16,
    bytes: u64,
    duration_us: i64,
    user_agent: ?[]const u8,
};

const CliError = error{
    MissingValue,
    InvalidPort,
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

const Logger = struct {
    allocator: Allocator,
    io: Io,
    file: Io.File,
    owns_file: bool,
    offset: u64 = 0,
    format: LogFormat,
    access_enabled: bool,

    fn init(allocator: Allocator, io: Io, config: Config) !Logger {
        if (config.log_file) |path| {
            var file = try Io.Dir.cwd().createFile(io, path, .{
                .truncate = false,
            });
            const stat = try file.stat(io);
            return .{
                .allocator = allocator,
                .io = io,
                .file = file,
                .owns_file = true,
                .offset = stat.size,
                .format = config.log_format,
                .access_enabled = config.access_log,
            };
        }

        return .{
            .allocator = allocator,
            .io = io,
            .file = std.Io.File.stderr(),
            .owns_file = false,
            .format = config.log_format,
            .access_enabled = config.access_log,
        };
    }

    fn deinit(self: *Logger) void {
        if (self.owns_file) {
            self.file.close(self.io);
        }
    }

    fn event(self: *Logger, level: []const u8, comptime fmt: []const u8, args: anytype) !void {
        var message: std.ArrayList(u8) = .empty;
        defer message.deinit(self.allocator);
        try message.print(self.allocator, fmt, args);

        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(self.allocator);

        switch (self.format) {
            .plain => {
                try appendRfc3339Timestamp(&line, self.allocator, self.io);
                try line.print(self.allocator, " {s} {s}\n", .{ level, message.items });
            },
            .jsonl => {
                try line.append(self.allocator, '{');
                try line.appendSlice(self.allocator, "\"ts\":\"");
                try appendRfc3339Timestamp(&line, self.allocator, self.io);
                try line.appendSlice(self.allocator, "\",\"level\":");
                try appendJsonString(&line, self.allocator, level);
                try line.appendSlice(self.allocator, ",\"message\":");
                try appendJsonString(&line, self.allocator, message.items);
                try line.appendSlice(self.allocator, "}\n");
            },
        }

        try self.writeLine(line.items);
    }

    fn access(self: *Logger, record: AccessRecord) void {
        if (!self.access_enabled) return;

        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(self.allocator);

        switch (self.format) {
            .plain => {
                appendRfc3339Timestamp(&line, self.allocator, self.io) catch return;
                line.print(
                    self.allocator,
                    " access remote={s} method={s} target=\"{s}\" status={d} bytes={d} duration_us={d}",
                    .{ record.remote, record.method, record.target, record.status, record.bytes, record.duration_us },
                ) catch return;
                if (record.user_agent) |ua| {
                    line.print(self.allocator, " user_agent=\"{s}\"", .{ua}) catch return;
                }
                line.append(self.allocator, '\n') catch return;
            },
            .jsonl => {
                line.append(self.allocator, '{') catch return;
                line.appendSlice(self.allocator, "\"ts\":\"") catch return;
                appendRfc3339Timestamp(&line, self.allocator, self.io) catch return;
                line.appendSlice(self.allocator, "\",\"level\":\"access\",\"remote\":") catch return;
                appendJsonString(&line, self.allocator, record.remote) catch return;
                line.appendSlice(self.allocator, ",\"method\":") catch return;
                appendJsonString(&line, self.allocator, record.method) catch return;
                line.appendSlice(self.allocator, ",\"target\":") catch return;
                appendJsonString(&line, self.allocator, record.target) catch return;
                line.print(self.allocator, ",\"status\":{d},\"bytes\":{d},\"duration_us\":{d}", .{
                    record.status,
                    record.bytes,
                    record.duration_us,
                }) catch return;
                if (record.user_agent) |ua| {
                    line.appendSlice(self.allocator, ",\"user_agent\":") catch return;
                    appendJsonString(&line, self.allocator, ua) catch return;
                }
                line.appendSlice(self.allocator, "}\n") catch return;
            },
        }

        self.writeLine(line.items) catch {};
    }

    fn writeLine(self: *Logger, line: []const u8) !void {
        if (self.owns_file) {
            try self.file.writePositionalAll(self.io, line, self.offset);
            self.offset += line.len;
            return;
        }

        var buffer: [2048]u8 = undefined;
        var writer = self.file.writer(self.io, &buffer);
        try writer.interface.writeAll(line);
        try writer.flush();
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
    try serve(allocator, config, &logger);
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

fn applyFileConfig(allocator: Allocator, file_config: FileConfig, config: *Config) !void {
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

    if (file_config.http) |http| {
        if (http.last_modified) |last_modified| config.last_modified = last_modified;
        if (http.trailing_slash_redirect) |trailing_slash_redirect| config.trailing_slash_redirect = trailing_slash_redirect;
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

fn isProtectedHeader(name: []const u8) bool {
    const protected = [_][]const u8{
        "Content-Length",
        "Content-Type",
        "Connection",
        "Server",
        "Allow",
        "Location",
    };
    for (protected) |candidate| {
        if (std.ascii.eqlIgnoreCase(name, candidate)) return true;
    }
    return false;
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
    shutdown_requested.store(false, .seq_cst);
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
    shutdown_requested.store(true, .seq_cst);
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

fn formatRemoteAddress(address: IpAddress, buffer: []u8) []const u8 {
    var writer: Io.Writer = .fixed(buffer);
    address.format(&writer) catch return "-";
    return writer.buffered();
}

fn appendRfc3339Timestamp(output: *std.ArrayList(u8), allocator: Allocator, io: Io) !void {
    const now = Io.Timestamp.now(io, .real);
    const seconds_i = now.toSeconds();
    const seconds: u64 = if (seconds_i < 0) 0 else @intCast(seconds_i);
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = seconds };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();

    try output.print(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
        .{
            year_day.year,
            @intFromEnum(month_day.month),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        },
    );
}

fn appendJsonString(output: *std.ArrayList(u8), allocator: Allocator, value: []const u8) !void {
    try output.append(allocator, '"');
    for (value) |byte| {
        switch (byte) {
            '"' => try output.appendSlice(allocator, "\\\""),
            '\\' => try output.appendSlice(allocator, "\\\\"),
            '\n' => try output.appendSlice(allocator, "\\n"),
            '\r' => try output.appendSlice(allocator, "\\r"),
            '\t' => try output.appendSlice(allocator, "\\t"),
            else => {
                if (byte < 0x20) {
                    try output.print(allocator, "\\u{X:0>4}", .{byte});
                } else {
                    try output.append(allocator, byte);
                }
            },
        }
    }
    try output.append(allocator, '"');
}

fn printCliError(err: CliError) !void {
    const stderr = std.Io.File.stderr();
    var buffer: [512]u8 = undefined;
    var writer = stderr.writer(std.Io.Threaded.global_single_threaded.io(), &buffer);
    const out = &writer.interface;

    switch (err) {
        error.MissingValue => try out.writeAll("qaws: missing value for option\n"),
        error.InvalidPort => try out.writeAll("qaws: port must be a number from 1 to 65535\n"),
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

fn serve(allocator: Allocator, config: Config, logger: *Logger) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var root = try Io.Dir.cwd().openDir(io, config.serve_dir, .{});
    defer root.close(io);

    var address = try IpAddress.parse(config.host, config.port);
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    try logger.event("info", "serving {s} on {s}:{d}", .{ config.serve_dir, config.host, config.port });

    accept_loop: while (!shutdown_requested.load(.seq_cst)) {
        const stream = server.accept(io) catch |err| switch (err) {
            error.ConnectionAborted => continue,
            else => {
                if (shutdown_requested.load(.seq_cst)) break :accept_loop;
                return err;
            },
        };
        handleConnection(allocator, io, root, stream, config, logger) catch |err| {
            logger.event("error", "connection failed: {s}", .{@errorName(err)}) catch {};
        };
    }

    logger.event("info", "shutdown", .{}) catch {};
}

fn handleConnection(allocator: Allocator, io: Io, root: Io.Dir, stream: Io.net.Stream, config: Config, logger: *Logger) !void {
    defer stream.close(io);

    const start = Io.Timestamp.now(io, .awake);
    var remote_buffer: [128]u8 = undefined;
    const remote = formatRemoteAddress(stream.socket.address, &remote_buffer);
    var access_record = AccessRecord{
        .remote = remote,
        .method = "-",
        .target = "-",
        .status = 500,
        .bytes = 0,
        .duration_us = 0,
        .user_agent = null,
    };

    var reader_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io, &reader_buffer);
    var writer_buffer: [8192]u8 = undefined;
    var writer = stream.writer(io, &writer_buffer);
    const out = &writer.interface;

    const request_bytes = readHttpRequest(allocator, &reader) catch |err| {
        const result = switch (err) {
            error.RequestTooLarge => try sendSimple(out, &writer, .{ .code = 413, .reason = "Payload Too Large" }, "Request too large\n"),
            else => try sendSimple(out, &writer, .{ .code = 400, .reason = "Bad Request" }, "Bad request\n"),
        };
        access_record.status = result.status;
        access_record.bytes = result.bytes;
        finishAccessLog(logger, io, start, &access_record);
        return;
    };
    defer allocator.free(request_bytes);
    defer finishAccessLog(logger, io, start, &access_record);

    const request = parseRequest(request_bytes) catch {
        const result = try sendSimple(out, &writer, .{ .code = 400, .reason = "Bad Request" }, "Bad request\n");
        access_record.status = result.status;
        access_record.bytes = result.bytes;
        return;
    };
    access_record.method = request.method;
    access_record.target = request.target;
    access_record.user_agent = request.user_agent;

    const is_head = std.mem.eql(u8, request.method, "HEAD");
    if (!is_head and !std.mem.eql(u8, request.method, "GET")) {
        try sendHeaders(out, .{ .code = 405, .reason = "Method Not Allowed" }, "text/plain; charset=utf-8", 19, "close", "GET, HEAD", &.{}, null, null);
        if (!is_head) try out.writeAll("Method not allowed\n");
        try writer.interface.flush();
        access_record.status = 405;
        access_record.bytes = 19;
        return;
    }

    const relative_path = normalizeTarget(allocator, request.target, config.dotfiles) catch {
        const result = try sendSimple(out, &writer, .{ .code = 403, .reason = "Forbidden" }, "Forbidden\n");
        access_record.status = result.status;
        access_record.bytes = result.bytes;
        return;
    };
    defer allocator.free(relative_path);

    const result = try servePath(
        allocator,
        io,
        root,
        out,
        &writer,
        relative_path,
        request.target,
        request.if_modified_since,
        is_head,
        config,
    );
    access_record.status = result.status;
    access_record.bytes = result.bytes;
}

fn finishAccessLog(logger: *Logger, io: Io, start: Io.Timestamp, record: *AccessRecord) void {
    const end = Io.Timestamp.now(io, .awake);
    record.duration_us = start.durationTo(end).toMicroseconds();
    logger.access(record.*);
}

fn readHttpRequest(allocator: Allocator, reader: *Io.net.Stream.Reader) ![]u8 {
    var data = try std.ArrayList(u8).initCapacity(allocator, 1024);
    errdefer data.deinit(allocator);

    while (data.items.len < max_request_bytes) {
        const byte = reader.interface.takeByte() catch |err| switch (err) {
            error.ReadFailed => return reader.err orelse err,
            error.EndOfStream => return error.BadRequest,
        };
        try data.append(allocator, byte);
        if (std.mem.indexOf(u8, data.items, "\r\n\r\n") != null) {
            return try data.toOwnedSlice(allocator);
        }
    }

    return error.RequestTooLarge;
}

fn parseRequest(bytes: []const u8) !Request {
    const line_end = std.mem.indexOf(u8, bytes, "\r\n") orelse return error.BadRequest;
    const line = bytes[0..line_end];

    var parts = std.mem.splitScalar(u8, line, ' ');
    const method = parts.next() orelse return error.BadRequest;
    const target = parts.next() orelse return error.BadRequest;
    const version_text = parts.next() orelse return error.BadRequest;
    if (parts.next() != null) return error.BadRequest;
    if (!std.mem.startsWith(u8, version_text, "HTTP/1.")) return error.BadRequest;
    if (target.len == 0 or target[0] != '/') return error.BadRequest;

    var user_agent: ?[]const u8 = null;
    var if_modified_since: ?[]const u8 = null;
    var header_start = line_end + 2;
    while (header_start < bytes.len) {
        const header_end_rel = std.mem.indexOf(u8, bytes[header_start..], "\r\n") orelse break;
        const header_end = header_start + header_end_rel;
        if (header_end == header_start) break;
        const header = bytes[header_start..header_end];
        if (std.mem.indexOfScalar(u8, header, ':')) |colon| {
            const name = std.mem.trim(u8, header[0..colon], &std.ascii.whitespace);
            const value = std.mem.trim(u8, header[colon + 1 ..], &std.ascii.whitespace);
            if (std.ascii.eqlIgnoreCase(name, "User-Agent")) {
                user_agent = value;
            } else if (std.ascii.eqlIgnoreCase(name, "If-Modified-Since")) {
                if_modified_since = value;
            }
        }
        header_start = header_end + 2;
    }

    return .{
        .method = method,
        .target = target,
        .user_agent = user_agent,
        .if_modified_since = if_modified_since,
    };
}

fn normalizeTarget(allocator: Allocator, target: []const u8, dotfiles: DotfilePolicy) ![]u8 {
    const path_part = blk: {
        const q = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
        const f = std.mem.indexOfScalar(u8, target[0..q], '#') orelse q;
        break :blk target[0..f];
    };

    var output = try std.ArrayList(u8).initCapacity(allocator, path_part.len + "index.html".len);
    errdefer output.deinit(allocator);

    var segments = std.mem.splitScalar(u8, path_part, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0) continue;
        if (std.mem.eql(u8, segment, "..")) return error.Forbidden;
        if (std.mem.indexOfScalar(u8, segment, '\\') != null) return error.Forbidden;

        var decoded = try std.ArrayList(u8).initCapacity(allocator, segment.len);
        defer decoded.deinit(allocator);
        try appendPercentDecoded(&decoded, allocator, segment);

        if (decoded.items.len == 0 or std.mem.eql(u8, decoded.items, ".")) continue;
        if (std.mem.eql(u8, decoded.items, "..")) return error.Forbidden;
        if (isDotfileSegment(decoded.items, dotfiles)) return error.Forbidden;

        if (output.items.len != 0) try output.append(allocator, '/');
        try output.appendSlice(allocator, decoded.items);
    }

    if (path_part.len == 0 or path_part[path_part.len - 1] == '/') {
        if (output.items.len != 0) try output.append(allocator, '/');
        try output.appendSlice(allocator, "index.html");
    }

    if (output.items.len == 0) {
        try output.appendSlice(allocator, "index.html");
    }

    return try output.toOwnedSlice(allocator);
}

fn isDotfileSegment(segment: []const u8, dotfiles: DotfilePolicy) bool {
    if (segment.len == 0 or segment[0] != '.') return false;
    return switch (dotfiles) {
        .allow => false,
        .deny_all => true,
        .deny_except_well_known => !std.mem.eql(u8, segment, ".well-known"),
    };
}

fn targetPathHasTrailingSlash(target: []const u8) bool {
    const q = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    if (q == 0) return false;
    return target[q - 1] == '/';
}

fn slashRedirectLocation(allocator: Allocator, target: []const u8) ![]u8 {
    const q = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    if (q > 0 and target[q - 1] == '/') return allocator.dupe(u8, target);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ target[0..q], target[q..] });
}

fn formatHttpDate(timestamp: Io.Timestamp, buffer: []u8) []const u8 {
    const seconds_i = timestamp.toSeconds();
    const seconds: u64 = if (seconds_i < 0) 0 else @intCast(seconds_i);
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = seconds };
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    const weekday_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    const weekday_index: usize = @intCast((epoch_day.day + 4) % 7);

    var writer: Io.Writer = .fixed(buffer);
    writer.print(
        "{s}, {d:0>2} {s} {d:0>4} {d:0>2}:{d:0>2}:{d:0>2} GMT",
        .{
            weekday_names[weekday_index],
            month_day.day_index + 1,
            month_names[@intFromEnum(month_day.month) - 1],
            year_day.year,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        },
    ) catch return "";
    return writer.buffered();
}

fn parseHttpDate(value: []const u8) ?i64 {
    if (value.len != 29) return null;
    if (value[3] != ',' or value[4] != ' ' or value[7] != ' ' or value[11] != ' ' or
        value[16] != ' ' or value[19] != ':' or value[22] != ':' or value[25] != ' ')
    {
        return null;
    }
    if (!std.mem.eql(u8, value[26..29], "GMT")) return null;

    const day = std.fmt.parseInt(u8, value[5..7], 10) catch return null;
    const month = parseHttpMonth(value[8..11]) orelse return null;
    const year = std.fmt.parseInt(u16, value[12..16], 10) catch return null;
    const hour = std.fmt.parseInt(u8, value[17..19], 10) catch return null;
    const minute = std.fmt.parseInt(u8, value[20..22], 10) catch return null;
    const second = std.fmt.parseInt(u8, value[23..25], 10) catch return null;

    if (year < 1970 or day == 0 or day > std.time.epoch.getDaysInMonth(year, @enumFromInt(month))) return null;
    if (hour > 23 or minute > 59 or second > 59) return null;

    var days: u64 = 0;
    var y: u16 = 1970;
    while (y < year) : (y += 1) {
        days += std.time.epoch.getDaysInYear(y);
    }
    var m: u8 = 1;
    while (m < month) : (m += 1) {
        days += std.time.epoch.getDaysInMonth(year, @enumFromInt(m));
    }
    days += day - 1;

    const total: u64 = days * std.time.s_per_day + @as(u64, hour) * std.time.s_per_hour + @as(u64, minute) * std.time.s_per_min + second;
    return @intCast(total);
}

fn parseHttpMonth(value: []const u8) ?u8 {
    const names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    for (names, 1..) |name, month| {
        if (std.mem.eql(u8, value, name)) return @intCast(month);
    }
    return null;
}

fn appendPercentDecoded(output: *std.ArrayList(u8), allocator: Allocator, input: []const u8) !void {
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '%') {
            if (i + 2 >= input.len) return error.Forbidden;
            const byte = std.fmt.parseInt(u8, input[i + 1 .. i + 3], 16) catch return error.Forbidden;
            if (byte == 0 or byte == '/' or byte == '\\') return error.Forbidden;
            try output.append(allocator, byte);
            i += 3;
        } else {
            if (input[i] == 0 or input[i] == '\\') return error.Forbidden;
            try output.append(allocator, input[i]);
            i += 1;
        }
    }
}

fn servePath(
    allocator: Allocator,
    io: Io,
    root: Io.Dir,
    out: *Io.Writer,
    stream_writer: *Io.net.Stream.Writer,
    relative_path: []const u8,
    request_target: []const u8,
    if_modified_since: ?[]const u8,
    is_head: bool,
    config: Config,
) !ResponseResult {
    var file = root.openFile(io, relative_path, .{
        .mode = .read_only,
        .allow_directory = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => {
            return sendSimple(out, stream_writer, .{ .code = 404, .reason = "Not Found" }, "Not found\n");
        },
        error.IsDir => {
            if (config.trailing_slash_redirect and !targetPathHasTrailingSlash(request_target)) {
                return sendRedirect(allocator, out, stream_writer, request_target, is_head, config.headers);
            }
            const index_path = try std.fs.path.join(allocator, &.{ relative_path, "index.html" });
            defer allocator.free(index_path);
            return servePath(allocator, io, root, out, stream_writer, index_path, request_target, if_modified_since, is_head, config);
        },
        error.AccessDenied => {
            return sendSimple(out, stream_writer, .{ .code = 403, .reason = "Forbidden" }, "Forbidden\n");
        },
        else => return err,
    };
    defer file.close(io);

    const stat = try file.stat(io);
    if (stat.kind != .file) {
        return sendSimple(out, stream_writer, .{ .code = 404, .reason = "Not Found" }, "Not found\n");
    }

    const content_type = mimeType(relative_path);
    var last_modified_buffer: [64]u8 = undefined;
    const last_modified = if (config.last_modified) formatHttpDate(stat.mtime, &last_modified_buffer) else null;
    if (config.last_modified) {
        if (if_modified_since) |value| {
            if (parseHttpDate(value)) |since| {
                if (since >= stat.mtime.toSeconds()) {
                    try sendHeaders(
                        out,
                        .{ .code = 304, .reason = "Not Modified" },
                        content_type,
                        0,
                        "close",
                        null,
                        config.headers,
                        last_modified,
                        null,
                    );
                    try stream_writer.interface.flush();
                    return .{ .status = 304, .bytes = 0 };
                }
            }
        }
    }

    try sendHeaders(out, .{ .code = 200, .reason = "OK" }, content_type, stat.size, "close", null, config.headers, last_modified, null);
    if (!is_head) {
        try streamFile(io, out, file);
    }
    try stream_writer.interface.flush();
    return .{ .status = 200, .bytes = if (is_head) 0 else stat.size };
}

fn streamFile(io: Io, out: *Io.Writer, file: Io.File) !void {
    var file_buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &.{});

    while (true) {
        const n = reader.interface.readSliceShort(&file_buffer) catch |err| switch (err) {
            error.ReadFailed => return reader.err orelse err,
        };
        if (n == 0) break;
        try out.writeAll(file_buffer[0..n]);
    }
}

fn sendSimple(out: *Io.Writer, stream_writer: *Io.net.Stream.Writer, status: ResponseStatus, body: []const u8) !ResponseResult {
    try sendHeaders(out, status, "text/plain; charset=utf-8", body.len, "close", null, &.{}, null, null);
    try out.writeAll(body);
    try stream_writer.interface.flush();
    return .{ .status = status.code, .bytes = body.len };
}

fn sendRedirect(
    allocator: Allocator,
    out: *Io.Writer,
    stream_writer: *Io.net.Stream.Writer,
    request_target: []const u8,
    is_head: bool,
    extra_headers: []const Header,
) !ResponseResult {
    const location = try slashRedirectLocation(allocator, request_target);
    defer allocator.free(location);

    const body = "Redirecting\n";
    try sendHeaders(
        out,
        .{ .code = 308, .reason = "Permanent Redirect" },
        "text/plain; charset=utf-8",
        body.len,
        "close",
        null,
        extra_headers,
        null,
        location,
    );
    if (!is_head) try out.writeAll(body);
    try stream_writer.interface.flush();
    return .{ .status = 308, .bytes = if (is_head) 0 else body.len };
}

fn sendHeaders(
    out: *Io.Writer,
    status: ResponseStatus,
    content_type: []const u8,
    content_length: u64,
    connection: []const u8,
    allow: ?[]const u8,
    extra_headers: []const Header,
    last_modified: ?[]const u8,
    location: ?[]const u8,
) !void {
    try out.print("HTTP/1.1 {d} {s}\r\n", .{ status.code, status.reason });
    try out.print("Server: {s}\r\n", .{server_name});
    try out.print("Content-Type: {s}\r\n", .{content_type});
    try out.print("Content-Length: {d}\r\n", .{content_length});
    try out.print("Connection: {s}\r\n", .{connection});
    try out.writeAll("X-Content-Type-Options: nosniff\r\n");
    if (allow) |value| try out.print("Allow: {s}\r\n", .{value});
    if (last_modified) |value| try out.print("Last-Modified: {s}\r\n", .{value});
    if (location) |value| try out.print("Location: {s}\r\n", .{value});
    for (extra_headers) |header| {
        try out.print("{s}: {s}\r\n", .{ header.name, header.value });
    }
    try out.writeAll("\r\n");
}

fn mimeType(path: []const u8) []const u8 {
    if (endsWith(path, ".html") or endsWith(path, ".htm")) return "text/html; charset=utf-8";
    if (endsWith(path, ".css")) return "text/css; charset=utf-8";
    if (endsWith(path, ".js") or endsWith(path, ".mjs")) return "application/javascript; charset=utf-8";
    if (endsWith(path, ".json")) return "application/json; charset=utf-8";
    if (endsWith(path, ".txt")) return "text/plain; charset=utf-8";
    if (endsWith(path, ".svg")) return "image/svg+xml";
    if (endsWith(path, ".png")) return "image/png";
    if (endsWith(path, ".jpg") or endsWith(path, ".jpeg")) return "image/jpeg";
    if (endsWith(path, ".gif")) return "image/gif";
    if (endsWith(path, ".webp")) return "image/webp";
    if (endsWith(path, ".ico")) return "image/x-icon";
    if (endsWith(path, ".wasm")) return "application/wasm";
    if (endsWith(path, ".pdf")) return "application/pdf";
    if (endsWith(path, ".xml")) return "application/xml; charset=utf-8";
    if (endsWith(path, ".woff")) return "font/woff";
    if (endsWith(path, ".woff2")) return "font/woff2";
    return "application/octet-stream";
}

fn endsWith(path: []const u8, suffix: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(path, suffix);
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

test "json config applies values and cli overrides" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "listen": { "host": "127.0.0.1", "port": 8080 },
        \\  "serve": "site",
        \\  "daemon": { "enabled": true, "pid_file": "qaws.pid", "log_file": "qaws.log" },
        \\  "logging": { "format": "jsonl", "access": false },
        \\  "security": { "dotfiles": "deny_all" },
        \\  "headers": { "Cache-Control": "public, max-age=60" },
        \\  "http": { "last_modified": false, "trailing_slash_redirect": false }
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

    applyCliOverrides(&config, .{
        .host = "0.0.0.0",
        .port = 9090,
        .serve_dir = "public",
        .access_log = true,
    });
    try std.testing.expectEqualStrings("0.0.0.0", config.host);
    try std.testing.expectEqual(@as(u16, 9090), config.port);
    try std.testing.expectEqualStrings("public", config.serve_dir);
    try std.testing.expect(config.access_log);
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
