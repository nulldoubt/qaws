const std = @import("std");
const config_mod = @import("config.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const worker_stack_size = 512 * 1024;
const log_queue_capacity = 4096;

pub const AccessRecord = struct {
    remote: []const u8,
    method: []const u8,
    target: []const u8,
    status: u16,
    bytes: u64,
    duration_us: i64,
    user_agent: ?[]const u8,
};

pub const LogQueue = struct {
    allocator: Allocator,
    io: Io,
    buffer: [][]u8,
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,
    closed: bool = false,
    mutex: Io.Mutex = .init,
    not_empty: Io.Condition = .init,
    not_full: Io.Condition = .init,

    pub fn init(allocator: Allocator, io: Io, capacity: usize) !LogQueue {
        return .{
            .allocator = allocator,
            .io = io,
            .buffer = try allocator.alloc([]u8, capacity),
        };
    }

    pub fn deinit(self: *LogQueue) void {
        while (self.pop()) |line| self.allocator.free(line);
        self.allocator.free(self.buffer);
    }

    pub fn pushBlocking(self: *LogQueue, line: []u8) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        while (self.count == self.buffer.len and !self.closed) {
            self.not_full.waitUncancelable(self.io, &self.mutex);
        }
        if (self.closed) return false;
        self.pushLocked(line);
        return true;
    }

    pub fn tryPush(self: *LogQueue, line: []u8) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.closed or self.count == self.buffer.len) return false;
        self.pushLocked(line);
        return true;
    }

    pub fn pop(self: *LogQueue) ?[]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        while (self.count == 0 and !self.closed) {
            self.not_empty.waitUncancelable(self.io, &self.mutex);
        }
        if (self.count == 0) return null;

        const line = self.buffer[self.head];
        self.head = (self.head + 1) % self.buffer.len;
        self.count -= 1;
        self.not_full.signal(self.io);
        return line;
    }

    pub fn close(self: *LogQueue) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        self.closed = true;
        self.not_empty.broadcast(self.io);
        self.not_full.broadcast(self.io);
    }

    fn pushLocked(self: *LogQueue, line: []u8) void {
        self.buffer[self.tail] = line;
        self.tail = (self.tail + 1) % self.buffer.len;
        self.count += 1;
        self.not_empty.signal(self.io);
    }
};

pub const Logger = struct {
    allocator: Allocator,
    io: Io,
    file: Io.File,
    owns_file: bool,
    offset: u64 = 0,
    format: config_mod.LogFormat,
    access_enabled: bool,
    queue: LogQueue,
    thread: ?std.Thread = null,
    dropped_access: std.atomic.Value(u32) = .init(0),

    pub fn init(allocator: Allocator, io: Io, config: config_mod.Config) !Logger {
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
                .queue = try LogQueue.init(allocator, io, log_queue_capacity),
            };
        }

        return .{
            .allocator = allocator,
            .io = io,
            .file = std.Io.File.stderr(),
            .owns_file = false,
            .format = config.log_format,
            .access_enabled = config.access_log,
            .queue = try LogQueue.init(allocator, io, log_queue_capacity),
        };
    }

    pub fn start(self: *Logger) !void {
        self.thread = try std.Thread.spawn(.{
            .stack_size = worker_stack_size,
            .allocator = self.allocator,
        }, loggerThread, .{self});
    }

    pub fn deinit(self: *Logger) void {
        const dropped = self.dropped_access.load(.monotonic);
        if (dropped > 0) {
            self.event("warn", "dropped {d} access log lines", .{dropped}) catch {};
        }
        self.queue.close();
        if (self.thread) |thread| thread.join();
        self.queue.deinit();
        if (self.owns_file) self.file.close(self.io);
    }

    pub fn event(self: *Logger, level: []const u8, comptime fmt: []const u8, args: anytype) !void {
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

        const owned = try line.toOwnedSlice(self.allocator);
        if (!self.queue.pushBlocking(owned)) {
            self.allocator.free(owned);
            return error.LogClosed;
        }
    }

    pub fn access(self: *Logger, record: AccessRecord) void {
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

        const owned = line.toOwnedSlice(self.allocator) catch return;
        if (!self.queue.tryPush(owned)) {
            self.allocator.free(owned);
            _ = self.dropped_access.fetchAdd(1, .monotonic);
        }
    }

    fn writeLineDirect(self: *Logger, line: []const u8) !void {
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

fn loggerThread(logger: *Logger) void {
    while (logger.queue.pop()) |line| {
        logger.writeLineDirect(line) catch {};
        logger.allocator.free(line);
    }
}

pub fn appendRfc3339Timestamp(output: *std.ArrayList(u8), allocator: Allocator, io: Io) !void {
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

pub fn appendJsonString(output: *std.ArrayList(u8), allocator: Allocator, value: []const u8) !void {
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
