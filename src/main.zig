const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const IpAddress = Io.net.IpAddress;

const version = "0.1.0";
const server_name = "qaws/" ++ version;
const max_request_bytes = 16 * 1024;

const Config = struct {
    host: []const u8 = "0.0.0.0",
    port: u16 = 80,
    serve_dir: []const u8 = "./public",
    daemon: bool = false,
};

const ParsedCommand = union(enum) {
    serve: Config,
    help,
    version,
};

const Request = struct {
    method: []const u8,
    target: []const u8,
};

const ResponseStatus = struct {
    code: u16,
    reason: []const u8,
};

const CliError = error{
    MissingValue,
    InvalidPort,
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

    const command = parseArgs(loaded_args.args) catch |err| {
        try printCliError(err);
        std.process.exit(2);
    };

    switch (command) {
        .help => try printHelp(),
        .version => try printVersion(),
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
            try serve(allocator, config);
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
    var config = Config{};
    var i: usize = initialArgIndex(args);

    while (i < args.len) : (i += 1) {
        const arg = normalizeArg(args[i]);
        if (std.mem.eql(u8, arg, "--port")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            const value = normalizeArg(args[i]);
            const parsed = std.fmt.parseInt(u16, value, 10) catch return error.InvalidPort;
            if (parsed == 0) return error.InvalidPort;
            config.port = parsed;
        } else if (std.mem.eql(u8, arg, "--host")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            config.host = normalizeArg(args[i]);
        } else if (std.mem.eql(u8, arg, "--serve")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            config.serve_dir = normalizeArg(args[i]);
        } else if (std.mem.eql(u8, arg, "-d")) {
            config.daemon = true;
        } else if (std.mem.eql(u8, arg, "help") or std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return .help;
        } else if (std.mem.eql(u8, arg, "version") or std.mem.eql(u8, arg, "--version")) {
            return .version;
        } else {
            return error.UnknownArgument;
        }
    }

    return .{ .serve = config };
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
        error.UnknownArgument => try out.writeAll("qaws: unknown argument\n"),
    }
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
        \\  qaws help
        \\  qaws version
        \\
        \\Defaults:
        \\  --host  0.0.0.0
        \\  --port  80
        \\  --serve ./public
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

fn serve(allocator: Allocator, config: Config) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var root = try Io.Dir.cwd().openDir(io, config.serve_dir, .{});
    defer root.close(io);

    var address = try IpAddress.parse(config.host, config.port);
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    while (true) {
        const stream = server.accept(io) catch |err| switch (err) {
            error.ConnectionAborted => continue,
            else => return err,
        };
        handleConnection(allocator, io, root, stream) catch {};
    }
}

fn handleConnection(allocator: Allocator, io: Io, root: Io.Dir, stream: Io.net.Stream) !void {
    defer stream.close(io);

    var reader_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io, &reader_buffer);
    var writer_buffer: [8192]u8 = undefined;
    var writer = stream.writer(io, &writer_buffer);
    const out = &writer.interface;

    const request_bytes = readHttpRequest(allocator, &reader) catch |err| {
        switch (err) {
            error.RequestTooLarge => try sendSimple(out, &writer, .{ .code = 413, .reason = "Payload Too Large" }, "Request too large\n"),
            else => try sendSimple(out, &writer, .{ .code = 400, .reason = "Bad Request" }, "Bad request\n"),
        }
        return;
    };
    defer allocator.free(request_bytes);

    const request = parseRequest(request_bytes) catch {
        try sendSimple(out, &writer, .{ .code = 400, .reason = "Bad Request" }, "Bad request\n");
        return;
    };

    const is_head = std.mem.eql(u8, request.method, "HEAD");
    if (!is_head and !std.mem.eql(u8, request.method, "GET")) {
        try sendHeaders(out, .{ .code = 405, .reason = "Method Not Allowed" }, "text/plain; charset=utf-8", 19, "close", "GET, HEAD");
        if (!is_head) try out.writeAll("Method not allowed\n");
        try writer.interface.flush();
        return;
    }

    const relative_path = normalizeTarget(allocator, request.target) catch {
        try sendSimple(out, &writer, .{ .code = 403, .reason = "Forbidden" }, "Forbidden\n");
        return;
    };
    defer allocator.free(relative_path);

    try servePath(allocator, io, root, out, &writer, relative_path, is_head);
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

    return .{ .method = method, .target = target };
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
) !void {
    var file = root.openFile(io, relative_path, .{
        .mode = .read_only,
        .allow_directory = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => {
            try sendSimple(out, stream_writer, .{ .code = 404, .reason = "Not Found" }, "Not found\n");
            return;
        },
        error.IsDir => {
            const index_path = try std.fs.path.join(allocator, &.{ relative_path, "index.html" });
            defer allocator.free(index_path);
            return servePath(allocator, io, root, out, stream_writer, index_path, is_head);
        },
        error.AccessDenied => {
            try sendSimple(out, stream_writer, .{ .code = 403, .reason = "Forbidden" }, "Forbidden\n");
            return;
        },
        else => return err,
    };
    defer file.close(io);

    const stat = try file.stat(io);
    if (stat.kind != .file) {
        try sendSimple(out, stream_writer, .{ .code = 404, .reason = "Not Found" }, "Not found\n");
        return;
    }

    const content_type = mimeType(relative_path);
    try sendHeaders(out, .{ .code = 200, .reason = "OK" }, content_type, stat.size, "close", null);
    if (!is_head) {
        try streamFile(io, out, file);
    }
    try stream_writer.interface.flush();
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

fn sendSimple(out: *Io.Writer, stream_writer: *Io.net.Stream.Writer, status: ResponseStatus, body: []const u8) !void {
    try sendHeaders(out, status, "text/plain; charset=utf-8", body.len, "close", null);
    try out.writeAll(body);
    try stream_writer.interface.flush();
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
}

test "parse cli serve options" {
    const args: []const [:0]const u8 = &.{ "qaws", "--host", "127.0.0.1", "--port", "8080", "--serve", "site", "-d" };
    const command = try parseArgs(args);
    switch (command) {
        .serve => |config| {
            try std.testing.expectEqualStrings("127.0.0.1", config.host);
            try std.testing.expectEqual(@as(u16, 8080), config.port);
            try std.testing.expectEqualStrings("site", config.serve_dir);
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
