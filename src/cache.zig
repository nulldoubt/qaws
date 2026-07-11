const std = @import("std");
const config_mod = @import("config.zig");
const http = @import("http.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const CachedEventResponse = struct {
    status: u16,
    bytes: u64,
    header: []const u8,
    body: []const u8,
};

const CachedFile = struct {
    path: []u8,
    valid: bool,
    body: []u8,
    size: u64,
    mtime_sec: i64,
    content_type: []const u8,
    last_modified: ?[]u8,
    header_200_keep_alive: []u8,
    header_200_close: []u8,
    header_304_keep_alive: []u8,
    header_304_close: []u8,
    response_200_keep_alive: []u8,
    revalidate_after_ns: i96,

    fn snapshot(self: CachedFile, connection: []const u8) CachedFileSnapshot {
        const keep_alive = std.mem.eql(u8, connection, "keep-alive");
        return .{
            .body = self.body,
            .size = self.size,
            .mtime_sec = self.mtime_sec,
            .header_200 = if (keep_alive) self.header_200_keep_alive else self.header_200_close,
            .header_304 = if (keep_alive) self.header_304_keep_alive else self.header_304_close,
            .response_200 = if (keep_alive) self.response_200_keep_alive else &.{},
        };
    }
};

pub const CachedFileSnapshot = struct {
    body: []const u8,
    size: u64,
    mtime_sec: i64,
    header_200: []const u8,
    header_304: []const u8,
    response_200: []const u8,
};

pub const StaticCache = struct {
    allocator: Allocator,
    enabled: bool,
    max_file_bytes: usize,
    max_total_bytes: usize,
    revalidate_ms: u32,
    last_modified: bool,
    headers: []const config_mod.Header,
    mutex: Io.Mutex = .init,
    entries: std.ArrayList(CachedFile) = .empty,
    entry_indexes: std.StringHashMapUnmanaged(usize) = .empty,
    retired: std.ArrayList([]u8) = .empty,
    total_body_bytes: usize = 0,

    pub fn init(allocator: Allocator, config: config_mod.Config) StaticCache {
        return .{
            .allocator = allocator,
            .enabled = config.cache_enabled,
            .max_file_bytes = config.cache_max_file_bytes,
            .max_total_bytes = config.cache_max_total_bytes,
            .revalidate_ms = config.cache_revalidate_ms,
            .last_modified = config.last_modified,
            .headers = config.headers,
        };
    }

    pub fn deinit(self: *StaticCache) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.path);
            if (entry.body.len != 0) self.allocator.free(entry.body);
            if (entry.last_modified) |value| self.allocator.free(value);
            self.allocator.free(entry.header_200_keep_alive);
            self.allocator.free(entry.header_200_close);
            self.allocator.free(entry.header_304_keep_alive);
            self.allocator.free(entry.header_304_close);
            self.allocator.free(entry.response_200_keep_alive);
        }
        for (self.retired.items) |bytes| {
            if (bytes.len != 0) self.allocator.free(bytes);
        }
        self.entry_indexes.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        self.retired.deinit(self.allocator);
    }

    pub fn tryServe(
        self: *StaticCache,
        io: Io,
        root: Io.Dir,
        out: *Io.Writer,
        stream_writer: *Io.net.Stream.Writer,
        relative_path: []const u8,
        if_modified_since: ?[]const u8,
        is_head: bool,
        connection: []const u8,
    ) !?http.ResponseResult {
        if (!self.enabled) return null;

        const cached = try self.snapshot(io, root, relative_path, connection) orelse return null;
        if (self.last_modified) {
            if (if_modified_since) |value| {
                if (http.parseHttpDate(value)) |since| {
                    if (since >= cached.mtime_sec) {
                        try out.writeAll(cached.header_304);
                        try stream_writer.interface.flush();
                        return .{ .status = 304, .bytes = 0 };
                    }
                }
            }
        }

        try out.writeAll(cached.header_200);
        if (!is_head) try out.writeAll(cached.body);
        try stream_writer.interface.flush();
        return .{ .status = 200, .bytes = if (is_head) 0 else cached.size };
    }

    pub fn tryPrepareEventResponse(
        self: *StaticCache,
        io: Io,
        root: Io.Dir,
        relative_path: []const u8,
        if_modified_since: ?[]const u8,
        is_head: bool,
        connection: []const u8,
    ) !?CachedEventResponse {
        if (!self.enabled) return null;

        const cached = try self.snapshot(io, root, relative_path, connection) orelse return null;
        return cachedEventResponseFromSnapshot(self.last_modified, cached, if_modified_since, is_head);
    }

    fn snapshot(self: *StaticCache, io: Io, root: Io.Dir, relative_path: []const u8, connection: []const u8) !?CachedFileSnapshot {
        return self.snapshotWithLoad(io, root, relative_path, connection, true);
    }

    fn snapshotWithLoad(self: *StaticCache, io: Io, root: Io.Dir, relative_path: []const u8, connection: []const u8, allow_load: bool) !?CachedFileSnapshot {
        const now = Io.Timestamp.now(io, .awake);
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        if (self.entry_indexes.get(relative_path)) |index| {
            const entry = &self.entries.items[index];
            if (now.nanoseconds >= entry.revalidate_after_ns) {
                if (try self.loadEntry(io, root, relative_path, now, entry.body.len)) |fresh| {
                    self.replaceEntry(entry, fresh);
                } else {
                    entry.valid = false;
                    entry.revalidate_after_ns = self.nextRevalidate(now).nanoseconds;
                }
            }
            if (!entry.valid) return null;
            return entry.snapshot(connection);
        }

        if (!allow_load) return null;
        var entry = try self.loadEntry(io, root, relative_path, now, 0) orelse return null;
        errdefer self.destroyLoadedEntry(&entry);
        try self.entry_indexes.put(self.allocator, entry.path, self.entries.items.len);
        errdefer _ = self.entry_indexes.remove(entry.path);
        try self.entries.append(self.allocator, entry);
        return self.entries.items[self.entries.items.len - 1].snapshot(connection);
    }

    fn loadEntry(self: *StaticCache, io: Io, root: Io.Dir, relative_path: []const u8, now: Io.Timestamp, replacing_body_len: usize) !?CachedFile {
        var file = root.openFile(io, relative_path, .{
            .mode = .read_only,
            .allow_directory = false,
            .resolve_beneath = true,
        }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir, error.IsDir, error.AccessDenied => return null,
            else => return err,
        };
        defer file.close(io);

        const stat = try file.stat(io);
        if (stat.kind != .file) return null;
        const body_len = std.math.cast(usize, stat.size) orelse return null;
        if (body_len > self.max_file_bytes) return null;
        if (self.total_body_bytes - replacing_body_len + body_len > self.max_total_bytes) return null;

        const body = try self.allocator.alloc(u8, body_len);
        errdefer self.allocator.free(body);
        try readFileBody(io, file, body);

        var last_modified_buffer: [64]u8 = undefined;
        const last_modified: ?[]u8 = if (self.last_modified)
            try self.allocator.dupe(u8, http.formatHttpDate(stat.mtime, &last_modified_buffer))
        else
            null;
        errdefer if (last_modified) |value| self.allocator.free(value);

        const content_type = http.mimeType(relative_path);
        const header_200_keep_alive = try http.buildHeaderAlloc(self.allocator, .{ .code = 200, .reason = "OK" }, content_type, stat.size, "keep-alive", null, self.headers, last_modified, null);
        errdefer self.allocator.free(header_200_keep_alive);
        const header_200_close = try http.buildHeaderAlloc(self.allocator, .{ .code = 200, .reason = "OK" }, content_type, stat.size, "close", null, self.headers, last_modified, null);
        errdefer self.allocator.free(header_200_close);
        const header_304_keep_alive = try http.buildHeaderAlloc(self.allocator, .{ .code = 304, .reason = "Not Modified" }, content_type, 0, "keep-alive", null, self.headers, last_modified, null);
        errdefer self.allocator.free(header_304_keep_alive);
        const header_304_close = try http.buildHeaderAlloc(self.allocator, .{ .code = 304, .reason = "Not Modified" }, content_type, 0, "close", null, self.headers, last_modified, null);
        errdefer self.allocator.free(header_304_close);
        const response_200_keep_alive = try concatAlloc(self.allocator, header_200_keep_alive, body);
        errdefer self.allocator.free(response_200_keep_alive);

        const path = try self.allocator.dupe(u8, relative_path);
        errdefer self.allocator.free(path);

        self.total_body_bytes += body_len;
        return .{
            .path = path,
            .valid = true,
            .body = body,
            .size = stat.size,
            .mtime_sec = stat.mtime.toSeconds(),
            .content_type = content_type,
            .last_modified = last_modified,
            .header_200_keep_alive = header_200_keep_alive,
            .header_200_close = header_200_close,
            .header_304_keep_alive = header_304_keep_alive,
            .header_304_close = header_304_close,
            .response_200_keep_alive = response_200_keep_alive,
            .revalidate_after_ns = self.nextRevalidate(now).nanoseconds,
        };
    }

    fn replaceEntry(self: *StaticCache, entry: *CachedFile, fresh: CachedFile) void {
        self.retire(entry.body);
        if (entry.last_modified) |value| self.retire(value);
        self.retire(entry.header_200_keep_alive);
        self.retire(entry.header_200_close);
        self.retire(entry.header_304_keep_alive);
        self.retire(entry.header_304_close);
        self.retire(entry.response_200_keep_alive);
        self.total_body_bytes -= @intCast(entry.body.len);

        const old_path = entry.path;
        entry.* = fresh;
        self.allocator.free(entry.path);
        entry.path = old_path;
    }

    fn destroyLoadedEntry(self: *StaticCache, entry: *CachedFile) void {
        self.allocator.free(entry.path);
        if (entry.body.len != 0) {
            self.total_body_bytes -= @intCast(entry.body.len);
            self.allocator.free(entry.body);
        }
        if (entry.last_modified) |value| self.allocator.free(value);
        self.allocator.free(entry.header_200_keep_alive);
        self.allocator.free(entry.header_200_close);
        self.allocator.free(entry.header_304_keep_alive);
        self.allocator.free(entry.header_304_close);
        self.allocator.free(entry.response_200_keep_alive);
    }

    fn retire(self: *StaticCache, bytes: []u8) void {
        if (bytes.len == 0) return;
        self.retired.append(self.allocator, bytes) catch {};
    }

    fn nextRevalidate(self: StaticCache, now: Io.Timestamp) Io.Timestamp {
        return now.addDuration(Io.Duration.fromMilliseconds(self.revalidate_ms));
    }
};

pub fn cachedEventResponseFromSnapshot(
    last_modified_enabled: bool,
    cached: CachedFileSnapshot,
    if_modified_since: ?[]const u8,
    is_head: bool,
) CachedEventResponse {
    if (last_modified_enabled) {
        if (if_modified_since) |value| {
            if (http.parseHttpDate(value)) |since| {
                if (since >= cached.mtime_sec) {
                    return .{
                        .status = 304,
                        .bytes = 0,
                        .header = cached.header_304,
                        .body = &.{},
                    };
                }
            }
        }
    }

    return .{
        .status = 200,
        .bytes = if (is_head) 0 else cached.size,
        .header = if (!is_head and cached.response_200.len != 0) cached.response_200 else cached.header_200,
        .body = if (is_head or cached.response_200.len != 0) &.{} else cached.body,
    };
}

fn concatAlloc(allocator: Allocator, first: []const u8, second: []const u8) ![]u8 {
    const output = try allocator.alloc(u8, first.len + second.len);
    @memcpy(output[0..first.len], first);
    @memcpy(output[first.len..], second);
    return output;
}

fn readFileBody(io: Io, file: Io.File, body: []u8) !void {
    var offset: usize = 0;
    var reader = file.reader(io, &.{});
    while (offset < body.len) {
        const n = reader.interface.readSliceShort(body[offset..]) catch |err| switch (err) {
            error.ReadFailed => return reader.err orelse err,
        };
        if (n == 0) return error.EndOfStream;
        offset += n;
    }
}
