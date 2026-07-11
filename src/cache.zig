const std = @import("std");
const config_mod = @import("config.zig");
const http = @import("http.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Representation = enum(u8) {
    identity,
    gzip,
    brotli,
};

const CacheKey = struct {
    path: []const u8,
    representation: Representation,
};

const CacheKeyContext = struct {
    pub fn hash(_: CacheKeyContext, key: CacheKey) u64 {
        var hasher = std.hash.Wyhash.init(@intFromEnum(key.representation));
        hasher.update(key.path);
        return hasher.final();
    }

    pub fn eql(_: CacheKeyContext, a: CacheKey, b: CacheKey) bool {
        return a.representation == b.representation and std.mem.eql(u8, a.path, b.path);
    }
};

const Generation = struct {
    cache: *StaticCache,
    references: std.atomic.Value(u32) = .init(1),
    memory_bytes: usize,
    size: u64,
    mtime_sec: i64,
    mtime_ns: i96,
    etag_buffer: [128]u8,
    etag_len: usize,
    response_200_keep_alive: []u8,
    header_200_keep_alive_len: usize,
    header_200_close: []u8,
    header_304_keep_alive: []u8,
    header_304_close: []u8,

    fn snapshot(self: *const Generation, connection: []const u8) CachedFileSnapshot {
        const keep_alive = std.mem.eql(u8, connection, "keep-alive");
        return .{
            .body = self.response_200_keep_alive[self.header_200_keep_alive_len..],
            .size = self.size,
            .mtime_sec = self.mtime_sec,
            .mtime_ns = self.mtime_ns,
            .etag = if (self.etag_len == 0) null else self.etag_buffer[0..self.etag_len],
            .header_200 = if (keep_alive)
                self.response_200_keep_alive[0..self.header_200_keep_alive_len]
            else
                self.header_200_close,
            .header_304 = if (keep_alive) self.header_304_keep_alive else self.header_304_close,
            .response_200 = if (keep_alive) self.response_200_keep_alive else &.{},
        };
    }
};

const CacheSlot = struct {
    path: []u8,
    physical_path: []const u8,
    physical_path_owned: ?[]u8,
    representation: Representation,
    refresh_mutex: Io.Mutex = .init,
    current: ?*Generation = null,
    version: std.atomic.Value(u64) = .init(0),
    revalidate_after_ms: std.atomic.Value(i64) = .init(0),
    memory_bytes: usize,

    fn key(self: *const CacheSlot) CacheKey {
        return .{ .path = self.path, .representation = self.representation };
    }
};

const SlotMap = std.HashMapUnmanaged(
    CacheKey,
    *CacheSlot,
    CacheKeyContext,
    std.hash_map.default_max_load_percentage,
);

const ViewEntry = struct {
    slot: *CacheSlot,
    generation: ?*Generation = null,
    version: u64 = std.math.maxInt(u64),
};

const ViewMap = std.HashMapUnmanaged(
    CacheKey,
    ViewEntry,
    CacheKeyContext,
    std.hash_map.default_max_load_percentage,
);

pub const CacheLease = struct {
    io: Io,
    generation: ?*Generation,

    pub fn release(self: *CacheLease) void {
        const generation = self.generation orelse return;
        self.generation = null;
        releaseGeneration(self.io, generation);
    }
};

pub const CachedEventResponse = struct {
    status: u16,
    bytes: u64,
    header: []const u8,
    body: []const u8,
    lease: ?CacheLease = null,
};

pub const CachedFileSnapshot = struct {
    body: []const u8,
    size: u64,
    mtime_sec: i64,
    mtime_ns: i96 = 0,
    etag: ?[]const u8 = null,
    header_200: []const u8,
    header_304: []const u8,
    response_200: []const u8,
};

const LeasedSnapshot = struct {
    snapshot: CachedFileSnapshot,
    lease: CacheLease,
};

pub const StaticCache = struct {
    allocator: Allocator,
    enabled: bool,
    max_file_bytes: usize,
    max_total_bytes: usize,
    revalidate_ms: u32,
    last_modified: bool,
    etag: bool,
    headers: []const config_mod.Header,
    metadata_mutex: Io.Mutex = .init,
    slots: SlotMap = .empty,
    resident_bytes: usize = 0,

    pub fn init(allocator: Allocator, config: config_mod.Config) StaticCache {
        return .{
            .allocator = allocator,
            .enabled = config.cache_enabled,
            .max_file_bytes = config.cache_max_file_bytes,
            .max_total_bytes = config.cache_max_total_bytes,
            .revalidate_ms = config.cache_revalidate_ms,
            .last_modified = config.last_modified,
            .etag = config.etag,
            .headers = config.headers,
        };
    }

    pub fn deinit(self: *StaticCache, io: Io) void {
        var iterator = self.slots.valueIterator();
        while (iterator.next()) |slot_ptr| {
            const slot = slot_ptr.*;
            if (slot.current) |generation| releaseGeneration(io, generation);
            if (slot.physical_path_owned) |path| self.allocator.free(path);
            self.allocator.free(slot.path);
            self.allocator.destroy(slot);
        }
        self.slots.deinit(self.allocator);
        self.resident_bytes = 0;
    }

    pub fn view(self: *StaticCache, io: Io) CacheView {
        return .{ .cache = self, .io = io };
    }

    pub fn residentBytes(self: *StaticCache, io: Io) usize {
        self.metadata_mutex.lockUncancelable(io);
        defer self.metadata_mutex.unlock(io);
        return self.resident_bytes;
    }

    fn getOrCreateSlot(
        self: *StaticCache,
        io: Io,
        logical_path: []const u8,
        physical_path: []const u8,
        representation: Representation,
    ) !?*CacheSlot {
        const lookup = CacheKey{ .path = logical_path, .representation = representation };
        self.metadata_mutex.lockUncancelable(io);
        defer self.metadata_mutex.unlock(io);

        if (self.slots.get(lookup)) |slot| return slot;

        const duplicate_physical = !std.mem.eql(u8, logical_path, physical_path);
        const slot_bytes = @sizeOf(CacheSlot) + logical_path.len + if (duplicate_physical) physical_path.len else 0;
        if (!fitsWithin(self.resident_bytes, slot_bytes, self.max_total_bytes)) return null;

        const owned_path = try self.allocator.dupe(u8, logical_path);
        errdefer self.allocator.free(owned_path);
        const owned_physical: ?[]u8 = if (duplicate_physical)
            try self.allocator.dupe(u8, physical_path)
        else
            null;
        errdefer if (owned_physical) |path| self.allocator.free(path);

        const slot = try self.allocator.create(CacheSlot);
        errdefer self.allocator.destroy(slot);
        slot.* = .{
            .path = owned_path,
            .physical_path = if (owned_physical) |path| path else owned_path,
            .physical_path_owned = owned_physical,
            .representation = representation,
            .memory_bytes = slot_bytes,
        };
        try self.slots.put(self.allocator, slot.key(), slot);
        self.resident_bytes += slot_bytes;
        return slot;
    }

    fn reserve(self: *StaticCache, io: Io, bytes: usize) bool {
        self.metadata_mutex.lockUncancelable(io);
        defer self.metadata_mutex.unlock(io);
        if (!fitsWithin(self.resident_bytes, bytes, self.max_total_bytes)) return false;
        self.resident_bytes += bytes;
        return true;
    }

    fn releaseBytes(self: *StaticCache, io: Io, bytes: usize) void {
        self.metadata_mutex.lockUncancelable(io);
        defer self.metadata_mutex.unlock(io);
        self.resident_bytes -= bytes;
    }
};

pub const CacheView = struct {
    cache: *StaticCache,
    io: Io,
    entries: ViewMap = .empty,

    pub fn deinit(self: *CacheView) void {
        var iterator = self.entries.valueIterator();
        while (iterator.next()) |entry| {
            if (entry.generation) |generation| releaseGeneration(self.io, generation);
        }
        self.entries.deinit(self.cache.allocator);
    }

    pub fn tryServe(
        self: *CacheView,
        root: Io.Dir,
        out: *Io.Writer,
        stream_writer: *Io.net.Stream.Writer,
        relative_path: []const u8,
        if_none_match: ?[]const u8,
        if_modified_since: ?[]const u8,
        is_head: bool,
        connection: []const u8,
    ) !?http.ResponseResult {
        var prepared = try self.prepare(
            root,
            relative_path,
            relative_path,
            .identity,
            if_none_match,
            if_modified_since,
            is_head,
            connection,
        ) orelse return null;
        defer if (prepared.lease) |*lease| lease.release();

        try out.writeAll(prepared.header);
        if (prepared.body.len != 0) try out.writeAll(prepared.body);
        try stream_writer.interface.flush();
        return .{ .status = prepared.status, .bytes = prepared.bytes };
    }

    pub fn tryPrepareEventResponse(
        self: *CacheView,
        root: Io.Dir,
        relative_path: []const u8,
        if_none_match: ?[]const u8,
        if_modified_since: ?[]const u8,
        is_head: bool,
        connection: []const u8,
    ) !?CachedEventResponse {
        return self.prepare(
            root,
            relative_path,
            relative_path,
            .identity,
            if_none_match,
            if_modified_since,
            is_head,
            connection,
        );
    }

    pub fn prepare(
        self: *CacheView,
        root: Io.Dir,
        logical_path: []const u8,
        physical_path: []const u8,
        representation: Representation,
        if_none_match: ?[]const u8,
        if_modified_since: ?[]const u8,
        is_head: bool,
        connection: []const u8,
    ) !?CachedEventResponse {
        if (!self.cache.enabled) return null;
        const slot = try self.cache.getOrCreateSlot(
            self.io,
            logical_path,
            physical_path,
            representation,
        ) orelse return null;
        const entry = try self.viewEntry(slot);

        const now = Io.Timestamp.now(self.io, .awake);
        const now_ms = timestampMilliseconds(now);
        if (now_ms >= slot.revalidate_after_ms.load(.monotonic)) {
            try self.refresh(root, slot, now, now_ms);
        }
        self.syncEntry(entry);

        const generation = entry.generation orelse return null;
        retainGeneration(generation);
        var lease = CacheLease{ .io = self.io, .generation = generation };
        errdefer lease.release();
        var response = cachedEventResponseFromSnapshot(
            self.cache.last_modified,
            generation.snapshot(connection),
            if_none_match,
            if_modified_since,
            is_head,
        );
        response.lease = lease;
        return response;
    }

    fn viewEntry(self: *CacheView, slot: *CacheSlot) !*ViewEntry {
        const result = try self.entries.getOrPut(self.cache.allocator, slot.key());
        if (!result.found_existing) {
            result.key_ptr.* = slot.key();
            result.value_ptr.* = .{ .slot = slot };
        }
        return result.value_ptr;
    }

    fn syncEntry(self: *CacheView, entry: *ViewEntry) void {
        const observed_version = entry.slot.version.load(.seq_cst);
        if (entry.version == observed_version) return;

        entry.slot.refresh_mutex.lockUncancelable(self.io);
        const version = entry.slot.version.load(.seq_cst);
        const generation = entry.slot.current;
        if (generation) |value| retainGeneration(value);
        entry.slot.refresh_mutex.unlock(self.io);

        const previous = entry.generation;
        entry.generation = generation;
        entry.version = version;
        if (previous) |value| releaseGeneration(self.io, value);
    }

    fn refresh(
        self: *CacheView,
        root: Io.Dir,
        slot: *CacheSlot,
        now: Io.Timestamp,
        now_ms: i64,
    ) !void {
        var old_generation: ?*Generation = null;
        slot.refresh_mutex.lockUncancelable(self.io);
        defer {
            slot.refresh_mutex.unlock(self.io);
            if (old_generation) |generation| releaseGeneration(self.io, generation);
        }

        if (now_ms < slot.revalidate_after_ms.load(.monotonic)) return;
        const next_revalidation = addMilliseconds(now_ms, self.cache.revalidate_ms);

        var file = root.openFile(self.io, slot.physical_path, .{
            .mode = .read_only,
            .allow_directory = false,
            .resolve_beneath = true,
        }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir, error.IsDir, error.AccessDenied => {
                old_generation = replaceCurrent(slot, null);
                slot.revalidate_after_ms.store(next_revalidation, .monotonic);
                return;
            },
            else => return err,
        };
        defer file.close(self.io);

        const stat = try file.stat(self.io);
        const body_len = std.math.cast(usize, stat.size) orelse {
            old_generation = replaceCurrent(slot, null);
            slot.revalidate_after_ms.store(next_revalidation, .monotonic);
            return;
        };
        if (stat.kind != .file or body_len > self.cache.max_file_bytes) {
            old_generation = replaceCurrent(slot, null);
            slot.revalidate_after_ms.store(next_revalidation, .monotonic);
            return;
        }

        if (slot.current) |current| {
            if (current.size == stat.size and current.mtime_ns == stat.mtime.nanoseconds) {
                slot.revalidate_after_ms.store(next_revalidation, .monotonic);
                return;
            }
        }

        const fresh = try buildGeneration(self.cache, self.io, file, stat, slot.path, now) orelse {
            old_generation = replaceCurrent(slot, null);
            slot.revalidate_after_ms.store(next_revalidation, .monotonic);
            return;
        };
        old_generation = replaceCurrent(slot, fresh);
        slot.revalidate_after_ms.store(next_revalidation, .monotonic);
    }
};

fn replaceCurrent(slot: *CacheSlot, generation: ?*Generation) ?*Generation {
    const previous = slot.current;
    slot.current = generation;
    _ = slot.version.fetchAdd(1, .seq_cst);
    return previous;
}

fn buildGeneration(
    cache: *StaticCache,
    io: Io,
    file: Io.File,
    stat: Io.File.Stat,
    logical_path: []const u8,
    now: Io.Timestamp,
) !?*Generation {
    _ = now;
    const body_len = std.math.cast(usize, stat.size) orelse return null;

    var last_modified_buffer: [64]u8 = undefined;
    const last_modified = if (cache.last_modified)
        http.formatHttpDate(stat.mtime, &last_modified_buffer)
    else
        null;
    const content_type = http.mimeType(logical_path);
    var etag_buffer: [128]u8 = undefined;
    const etag = if (cache.etag)
        http.formatWeakEtag(stat.mtime.nanoseconds, stat.size, "identity", &etag_buffer)
    else
        null;

    const header_200_keep_alive = try http.buildHeaderAllocExtended(
        cache.allocator,
        .{ .code = 200, .reason = "OK" },
        content_type,
        stat.size,
        "keep-alive",
        cache.headers,
        .{ .last_modified = last_modified, .etag = etag },
    );
    defer cache.allocator.free(header_200_keep_alive);

    const response_200_keep_alive = try cache.allocator.alloc(u8, header_200_keep_alive.len + body_len);
    errdefer cache.allocator.free(response_200_keep_alive);
    @memcpy(response_200_keep_alive[0..header_200_keep_alive.len], header_200_keep_alive);
    try readFileBody(io, file, response_200_keep_alive[header_200_keep_alive.len..]);

    const header_200_close = try http.buildHeaderAllocExtended(
        cache.allocator,
        .{ .code = 200, .reason = "OK" },
        content_type,
        stat.size,
        "close",
        cache.headers,
        .{ .last_modified = last_modified, .etag = etag },
    );
    errdefer cache.allocator.free(header_200_close);
    const header_304_keep_alive = try http.buildHeaderAllocExtended(
        cache.allocator,
        .{ .code = 304, .reason = "Not Modified" },
        content_type,
        0,
        "keep-alive",
        cache.headers,
        .{ .last_modified = last_modified, .etag = etag },
    );
    errdefer cache.allocator.free(header_304_keep_alive);
    const header_304_close = try http.buildHeaderAllocExtended(
        cache.allocator,
        .{ .code = 304, .reason = "Not Modified" },
        content_type,
        0,
        "close",
        cache.headers,
        .{ .last_modified = last_modified, .etag = etag },
    );
    errdefer cache.allocator.free(header_304_close);

    const generation = try cache.allocator.create(Generation);
    errdefer cache.allocator.destroy(generation);
    const memory_bytes = @sizeOf(Generation) +
        response_200_keep_alive.len +
        header_200_close.len +
        header_304_keep_alive.len +
        header_304_close.len;
    if (!cache.reserve(io, memory_bytes)) return null;

    generation.* = .{
        .cache = cache,
        .memory_bytes = memory_bytes,
        .size = stat.size,
        .mtime_sec = stat.mtime.toSeconds(),
        .mtime_ns = stat.mtime.nanoseconds,
        .etag_buffer = undefined,
        .etag_len = if (etag) |value| value.len else 0,
        .response_200_keep_alive = response_200_keep_alive,
        .header_200_keep_alive_len = header_200_keep_alive.len,
        .header_200_close = header_200_close,
        .header_304_keep_alive = header_304_keep_alive,
        .header_304_close = header_304_close,
    };
    if (etag) |value| @memcpy(generation.etag_buffer[0..value.len], value);
    return generation;
}

fn retainGeneration(generation: *Generation) void {
    _ = generation.references.fetchAdd(1, .monotonic);
}

fn releaseGeneration(io: Io, generation: *Generation) void {
    if (generation.references.fetchSub(1, .seq_cst) != 1) return;
    const cache = generation.cache;
    const memory_bytes = generation.memory_bytes;
    cache.allocator.free(generation.response_200_keep_alive);
    cache.allocator.free(generation.header_200_close);
    cache.allocator.free(generation.header_304_keep_alive);
    cache.allocator.free(generation.header_304_close);
    cache.allocator.destroy(generation);
    cache.releaseBytes(io, memory_bytes);
}

pub fn cachedEventResponseFromSnapshot(
    last_modified_enabled: bool,
    cached: CachedFileSnapshot,
    if_none_match: ?[]const u8,
    if_modified_since: ?[]const u8,
    is_head: bool,
) CachedEventResponse {
    if (http.isNotModified(if_none_match, if_modified_since, cached.etag, cached.mtime_sec, last_modified_enabled)) {
        return .{
            .status = 304,
            .bytes = 0,
            .header = cached.header_304,
            .body = &.{},
        };
    }

    return .{
        .status = 200,
        .bytes = if (is_head) 0 else cached.size,
        .header = if (!is_head and cached.response_200.len != 0) cached.response_200 else cached.header_200,
        .body = if (is_head or cached.response_200.len != 0) &.{} else cached.body,
    };
}

fn fitsWithin(current: usize, additional: usize, limit: usize) bool {
    return additional <= limit and current <= limit - additional;
}

fn timestampMilliseconds(timestamp: Io.Timestamp) i64 {
    const value = @divTrunc(timestamp.nanoseconds, std.time.ns_per_ms);
    return std.math.cast(i64, value) orelse if (value < 0) std.math.minInt(i64) else std.math.maxInt(i64);
}

fn addMilliseconds(value: i64, milliseconds: u32) i64 {
    return std.math.add(i64, value, milliseconds) catch std.math.maxInt(i64);
}

fn readFileBody(io: Io, file: Io.File, body: []u8) !void {
    var offset: usize = 0;
    var reader = file.reader(io, &.{});
    while (offset < body.len) {
        const count = reader.interface.readSliceShort(body[offset..]) catch |err| switch (err) {
            error.ReadFailed => return reader.err orelse err,
        };
        if (count == 0) return error.EndOfStream;
        offset += count;
    }
}

test "cache generations revalidate and reclaim old response storage" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(io, .{ .sub_path = "index.html", .data = "first" });

    var cache = StaticCache.init(allocator, .{
        .cache_max_total_bytes = 1024 * 1024,
        .cache_revalidate_ms = 1,
    });
    defer cache.deinit(io);
    var first_view = cache.view(io);
    defer first_view.deinit();
    var second_view = cache.view(io);
    defer second_view.deinit();

    var first = (try first_view.tryPrepareEventResponse(
        temporary.dir,
        "index.html",
        null,
        null,
        false,
        "keep-alive",
    )).?;
    defer if (first.lease) |*lease| lease.release();
    try std.testing.expect(std.mem.endsWith(u8, first.header, "first"));

    const slot = cache.slots.get(.{ .path = "index.html", .representation = .identity }).?;
    const original_generation = slot.current.?;
    try std.testing.expectEqual(
        @intFromPtr(original_generation.response_200_keep_alive.ptr) + original_generation.header_200_keep_alive_len,
        @intFromPtr(original_generation.snapshot("keep-alive").body.ptr),
    );

    slot.revalidate_after_ms.store(0, .monotonic);
    var unchanged = (try first_view.tryPrepareEventResponse(
        temporary.dir,
        "index.html",
        null,
        null,
        false,
        "keep-alive",
    )).?;
    try std.testing.expectEqual(original_generation, slot.current.?);

    var second = (try second_view.tryPrepareEventResponse(
        temporary.dir,
        "index.html",
        null,
        null,
        false,
        "keep-alive",
    )).?;
    if (second.lease) |*lease| lease.release();
    const before_refresh = cache.residentBytes(io);
    try temporary.dir.writeFile(io, .{ .sub_path = "index.html", .data = "second-generation" });
    slot.revalidate_after_ms.store(0, .monotonic);

    var fresh = (try first_view.tryPrepareEventResponse(
        temporary.dir,
        "index.html",
        null,
        null,
        false,
        "keep-alive",
    )).?;
    defer if (fresh.lease) |*lease| lease.release();
    try std.testing.expect(std.mem.endsWith(u8, fresh.header, "second-generation"));
    try std.testing.expect(slot.current.? != original_generation);
    const with_old_generation = cache.residentBytes(io);
    try std.testing.expect(with_old_generation > before_refresh);

    if (first.lease) |*lease| lease.release();
    if (unchanged.lease) |*lease| lease.release();
    first_view.deinit();
    first_view = cache.view(io);
    second_view.deinit();
    second_view = cache.view(io);
    try std.testing.expect(cache.residentBytes(io) < with_old_generation);
}

test "cache serves uncached when metadata cannot fit the cap" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(io, .{ .sub_path = "index.html", .data = "body" });

    var cache = StaticCache.init(allocator, .{ .cache_max_total_bytes = 1 });
    defer cache.deinit(io);
    var view = cache.view(io);
    defer view.deinit();
    try std.testing.expect(try view.tryPrepareEventResponse(
        temporary.dir,
        "index.html",
        null,
        null,
        false,
        "keep-alive",
    ) == null);
    try std.testing.expectEqual(@as(usize, 0), cache.residentBytes(io));
}
