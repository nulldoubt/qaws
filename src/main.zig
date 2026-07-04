const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const IpAddress = Io.net.IpAddress;

const version = "0.2.0";
const server_name = "qaws/" ++ version;
const max_request_bytes = 16 * 1024;

const LogFormat = enum {
    plain,
    jsonl,
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
};

const ParsedCommand = union(enum) {
    serve: Config,
    check: Config,
    help,
    version,
};

const CliCommand = enum {
    serve,
    check,
    help,
    version,
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
        .serve => |raw_config| {
            var config = raw_config;
            var owned_serve_dir: ?[:0]u8 = null;
            defer if (owned_serve_dir) |path| allocator.free(path);

            if (config.daemon) {
                owned_serve_dir = try Io.Dir.cwd().realPathFileAlloc(
                    std.Io.Threaded.global_single_threaded.io(),
                    config.serve_dir,
                    allocator,
                );
                config.serve_dir = owned_serve_dir.?;
                try daemonize();
            }

            var logger = try Logger.init(allocator, io, config);
            defer logger.deinit();
            try serve(allocator, config, &logger);
        },
    }
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
        var it = headers.object.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* != .string) return error.InvalidHeaderConfig;
        }
    }
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

    while (true) {
        const stream = server.accept(io) catch |err| switch (err) {
            error.ConnectionAborted => continue,
            else => return err,
        };
        handleConnection(allocator, io, root, stream, logger) catch |err| {
            logger.event("error", "connection failed: {s}", .{@errorName(err)}) catch {};
        };
    }
}

fn handleConnection(allocator: Allocator, io: Io, root: Io.Dir, stream: Io.net.Stream, logger: *Logger) !void {
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
        try sendHeaders(out, .{ .code = 405, .reason = "Method Not Allowed" }, "text/plain; charset=utf-8", 19, "close", "GET, HEAD");
        if (!is_head) try out.writeAll("Method not allowed\n");
        try writer.interface.flush();
        access_record.status = 405;
        access_record.bytes = 19;
        return;
    }

    const relative_path = normalizeTarget(allocator, request.target) catch {
        const result = try sendSimple(out, &writer, .{ .code = 403, .reason = "Forbidden" }, "Forbidden\n");
        access_record.status = result.status;
        access_record.bytes = result.bytes;
        return;
    };
    defer allocator.free(relative_path);

    const result = try servePath(allocator, io, root, out, &writer, relative_path, is_head);
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
            }
        }
        header_start = header_end + 2;
    }

    return .{ .method = method, .target = target, .user_agent = user_agent };
}

fn normalizeTarget(allocator: Allocator, target: []const u8) ![]u8 {
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
    is_head: bool,
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
            const index_path = try std.fs.path.join(allocator, &.{ relative_path, "index.html" });
            defer allocator.free(index_path);
            return servePath(allocator, io, root, out, stream_writer, index_path, is_head);
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
    try sendHeaders(out, .{ .code = 200, .reason = "OK" }, content_type, stat.size, "close", null);
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
    try sendHeaders(out, status, "text/plain; charset=utf-8", body.len, "close", null);
    try out.writeAll(body);
    try stream_writer.interface.flush();
    return .{ .status = status.code, .bytes = body.len };
}

fn sendHeaders(
    out: *Io.Writer,
    status: ResponseStatus,
    content_type: []const u8,
    content_length: u64,
    connection: []const u8,
    allow: ?[]const u8,
) !void {
    try out.print("HTTP/1.1 {d} {s}\r\n", .{ status.code, status.reason });
    try out.print("Server: {s}\r\n", .{server_name});
    try out.print("Content-Type: {s}\r\n", .{content_type});
    try out.print("Content-Length: {d}\r\n", .{content_length});
    try out.print("Connection: {s}\r\n", .{connection});
    if (allow) |value| try out.print("Allow: {s}\r\n", .{value});
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
    const root = try normalizeTarget(allocator, "/");
    defer allocator.free(root);
    try std.testing.expectEqualStrings("index.html", root);

    const nested = try normalizeTarget(allocator, "/docs/");
    defer allocator.free(nested);
    try std.testing.expectEqualStrings("docs/index.html", nested);
}

test "normalize rejects traversal" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.Forbidden, normalizeTarget(allocator, "/../build.zig"));
    try std.testing.expectError(error.Forbidden, normalizeTarget(allocator, "/%2e%2e/build.zig"));
    try std.testing.expectError(error.Forbidden, normalizeTarget(allocator, "/a%2fb"));
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
}
