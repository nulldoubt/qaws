const std = @import("std");
const builtin = @import("builtin");
const cache_mod = @import("cache.zig");
const config_mod = @import("config.zig");
const http = @import("http.zig");
const logging = @import("logging.zig");
const platform = @import("platform.zig");
const qaws_version = @import("version.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const IpAddress = Io.net.IpAddress;

const version = qaws_version.string;
const server_name = "qaws/" ++ version;
pub const max_request_bytes = 16 * 1024;
const default_keep_alive_timeout_ms = config_mod.default_keep_alive_timeout_ms;
const default_max_requests_per_connection = config_mod.default_max_requests_per_connection;
const default_max_connections = config_mod.default_max_connections;
const default_cache_max_file_bytes = config_mod.default_cache_max_file_bytes;
const default_cache_max_total_bytes = config_mod.default_cache_max_total_bytes;
const default_cache_revalidate_ms = config_mod.default_cache_revalidate_ms;
const worker_stack_size = 512 * 1024;
pub const event_request_batch_limit = 16;
const event_accept_batch_limit = 64;

var shutdown_requested = std.atomic.Value(bool).init(false);
var sendfile_fallback_logged = std.atomic.Value(bool).init(false);

const LogFormat = config_mod.LogFormat;
const Header = config_mod.Header;
const Config = config_mod.Config;

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
const parseRequestOptions = http.parseRequestOptions;
const parseConnectionHeader = http.parseConnectionHeader;
const requestWantsKeepAlive = http.requestWantsKeepAlive;
const normalizeTarget = http.normalizeTarget;
const normalizeTargetFast = http.normalizeTargetFast;
const targetPathHasTrailingSlash = http.targetPathHasTrailingSlash;
const slashRedirectLocation = http.slashRedirectLocation;
const formatHttpDate = http.formatHttpDate;
const parseHttpDate = http.parseHttpDate;
const sendHeaders = http.sendHeaders;
const sendHeadersExtended = http.sendHeadersExtended;
const buildHeaderAlloc = http.buildHeaderAlloc;
const buildHeaderAllocExtended = http.buildHeaderAllocExtended;
const mimeType = http.mimeType;
const formatWeakEtag = http.formatWeakEtag;
const isNotModified = http.isNotModified;
const selectByteRange = http.selectByteRange;
const ifRangeAllows = http.ifRangeAllows;
const formatContentRange = http.formatContentRange;
const formatUnsatisfiedContentRange = http.formatUnsatisfiedContentRange;
const CachedEventResponse = cache_mod.CachedEventResponse;
const CachedFileSnapshot = cache_mod.CachedFileSnapshot;
const CacheLease = cache_mod.CacheLease;
const CacheView = cache_mod.CacheView;
const CacheAvailability = cache_mod.Availability;
const Representation = cache_mod.Representation;
const StaticCache = cache_mod.StaticCache;
const cachedEventResponseFromSnapshot = cache_mod.cachedEventResponseFromSnapshot;
const SendfileResult = platform.SendfileResult;
const RuntimeBackend = platform.RuntimeBackend;
const WakePipe = platform.WakePipe;
const selectRuntimeBackend = platform.selectRuntimeBackend;
const runtimeBackendName = platform.runtimeBackendName;
const detectPerformanceCpuCount = platform.detectPerformanceCpuCount;
const acceptNonblocking = platform.acceptNonblocking;
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
const epollAddUserData = platform.epollAddUserData;
const epollSetWriteInterest = platform.epollSetWriteInterest;
const epollSetWriteInterestUserData = platform.epollSetWriteInterestUserData;
const epollWait = platform.epollWait;
const kqueueCreate = platform.kqueueCreate;
const kqueueAdd = platform.kqueueAdd;
const kqueueAddUserData = platform.kqueueAddUserData;
const kqueueSetWriteInterest = platform.kqueueSetWriteInterest;
const kqueueSetReadInterest = platform.kqueueSetReadInterest;
const kqueueSetWriteInterestUserData = platform.kqueueSetWriteInterestUserData;
const kqueueSetReadInterestUserData = platform.kqueueSetReadInterestUserData;
const kqueueWait = platform.kqueueWait;
const sendfileSupportedForOs = platform.sendfileSupportedForOs;
const trySendfile = platform.trySendfile;
const trySendfileFrom = platform.trySendfileFrom;
const trySendfileStep = platform.trySendfileStep;

pub const FileTransferPath = enum {
    none,
    buffered,
    sendfile,
};

const event_wake_token: usize = 1;
const event_listener_token: usize = 2;

const ConnectionContext = struct {
    allocator: Allocator,
    io: Io,
    stream: Io.net.Stream,
    config: Config,
    logger: *Logger,
    cache: *StaticCache,
    active_connections: *std.atomic.Value(u32),
};

const WorkerContext = struct {
    allocator: Allocator,
    io: Io,
    config: Config,
    logger: *Logger,
    cache: *StaticCache,
    queue: *WorkerQueue,
    active_connections: *std.atomic.Value(u32),
};

const EventWorkerContext = struct {
    allocator: Allocator,
    io: Io,
    config: Config,
    logger: *Logger,
    cache: *StaticCache,
    cache_view: ?*CacheView = null,
    queue: ?*WorkerQueue = null,
    listener: ?*Io.net.Server = null,
    active_connections: *std.atomic.Value(u32),
    backend: RuntimeBackend,
    wake_read_fd: std.posix.fd_t,
    wake_write_fd: std.posix.fd_t,
};

pub const EventConnection = struct {
    stream: Io.net.Stream,
    remote_buffer: [128]u8 = undefined,
    remote_len: usize = 0,
    request_buffer: [max_request_bytes]u8 = undefined,
    request_start: usize = 0,
    request_len: usize = 0,
    served_requests: u32 = 0,
    last_active: Io.Timestamp,
    pending: PendingEventWrite = .{},
    write_interest: bool = false,
    closing: bool = false,
    previous: ?*EventConnection = null,
    next: ?*EventConnection = null,
    retired_next: ?*EventConnection = null,
    ready_previous: ?*EventConnection = null,
    ready_next: ?*EventConnection = null,
    ready_queued: bool = false,

    fn remote(self: *const EventConnection) []const u8 {
        return self.remote_buffer[0..self.remote_len];
    }

    fn hasPendingWrite(self: *const EventConnection) bool {
        return self.pending.active();
    }
};

const EventReadyQueue = struct {
    head: ?*EventConnection = null,
    tail: ?*EventConnection = null,
    count: usize = 0,

    fn enqueue(self: *EventReadyQueue, conn: *EventConnection) void {
        if (conn.ready_queued or conn.closing) return;
        conn.ready_previous = self.tail;
        conn.ready_next = null;
        if (self.tail) |tail| tail.ready_next = conn else self.head = conn;
        self.tail = conn;
        conn.ready_queued = true;
        self.count += 1;
    }

    fn pop(self: *EventReadyQueue) ?*EventConnection {
        const conn = self.head orelse return null;
        self.remove(conn);
        return conn;
    }

    fn remove(self: *EventReadyQueue, conn: *EventConnection) void {
        if (!conn.ready_queued) return;
        if (conn.ready_previous) |previous| {
            previous.ready_next = conn.ready_next;
        } else {
            self.head = conn.ready_next;
        }
        if (conn.ready_next) |next| {
            next.ready_previous = conn.ready_previous;
        } else {
            self.tail = conn.ready_previous;
        }
        conn.ready_previous = null;
        conn.ready_next = null;
        conn.ready_queued = false;
        self.count -= 1;
    }
};

const EventConnectionList = struct {
    head: ?*EventConnection = null,

    fn add(self: *EventConnectionList, conn: *EventConnection) void {
        conn.previous = null;
        conn.next = self.head;
        if (self.head) |head| head.previous = conn;
        self.head = conn;
    }

    fn remove(self: *EventConnectionList, conn: *EventConnection) void {
        if (conn.previous) |previous| {
            previous.next = conn.next;
        } else {
            self.head = conn.next;
        }
        if (conn.next) |next| next.previous = conn.previous;
        conn.previous = null;
        conn.next = null;
    }
};

pub const PendingEventWrite = struct {
    header: []const u8 = &.{},
    body: []const u8 = &.{},
    header_offset: usize = 0,
    body_offset: usize = 0,
    request_end: usize = 0,
    served_requests_after: u32 = 0,
    keep_open: bool = false,
    owns_header: bool = false,
    owns_body: bool = false,
    file: ?Io.File = null,
    file_offset: u64 = 0,
    file_remaining: u64 = 0,
    file_buffer: ?[]u8 = null,
    file_buffer_offset: usize = 0,
    file_buffer_len: usize = 0,
    use_sendfile: bool = false,
    cache_lease: ?CacheLease = null,
    access_enabled: bool = false,
    access_start: Io.Timestamp = undefined,
    access_record: AccessRecord = undefined,

    pub fn active(self: *const PendingEventWrite) bool {
        return self.request_end != 0;
    }

    pub fn complete(self: *const PendingEventWrite) bool {
        return self.header_offset >= self.header.len and
            self.body_offset >= self.body.len and
            self.file_remaining == 0 and
            self.file_buffer_offset >= self.file_buffer_len;
    }
};

const ProcessRequestResult = struct {
    keep_open: bool,
};

const RepresentationChoice = struct {
    representation: Representation,
    physical_path: []const u8,
};

const RepresentationSelection = union(enum) {
    selected: RepresentationChoice,
    directory,
    forbidden,
    not_found,
    not_acceptable,
};

pub const WorkerQueue = struct {
    allocator: Allocator,
    io: Io,
    buffer: []Io.net.Stream,
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,
    closed: bool = false,
    mutex: Io.Mutex = .init,
    condition: Io.Condition = .init,

    pub fn init(allocator: Allocator, io: Io, capacity: usize) !WorkerQueue {
        return .{
            .allocator = allocator,
            .io = io,
            .buffer = try allocator.alloc(Io.net.Stream, capacity),
        };
    }

    pub fn deinit(self: *WorkerQueue) void {
        self.allocator.free(self.buffer);
    }

    pub fn push(self: *WorkerQueue, stream: Io.net.Stream) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.closed or self.count == self.buffer.len) return false;
        self.buffer[self.tail] = stream;
        self.tail = (self.tail + 1) % self.buffer.len;
        self.count += 1;
        self.condition.signal(self.io);
        return true;
    }

    pub fn pop(self: *WorkerQueue) ?Io.net.Stream {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        while (self.count == 0 and !self.closed) {
            self.condition.waitUncancelable(self.io, &self.mutex);
        }
        if (self.count == 0) return null;

        const stream = self.buffer[self.head];
        self.head = (self.head + 1) % self.buffer.len;
        self.count -= 1;
        return stream;
    }

    pub fn popAvailable(self: *WorkerQueue) ?Io.net.Stream {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.count == 0) return null;
        const stream = self.buffer[self.head];
        self.head = (self.head + 1) % self.buffer.len;
        self.count -= 1;
        return stream;
    }

    pub fn close(self: *WorkerQueue) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        self.closed = true;
        self.condition.broadcast(self.io);
    }
};

pub fn resetShutdown() void {
    shutdown_requested.store(false, .seq_cst);
}

pub fn requestShutdown() void {
    shutdown_requested.store(true, .seq_cst);
}

fn formatRemoteAddress(address: IpAddress, buffer: []u8) []const u8 {
    var writer: Io.Writer = .fixed(buffer);
    address.format(&writer) catch return "-";
    return writer.buffered();
}

pub fn serve(allocator: Allocator, io: Io, config: Config, logger: *Logger, cache: *StaticCache) !void {
    var root_check = try Io.Dir.cwd().openDir(io, config.serve_dir, .{});
    root_check.close(io);

    var address = try IpAddress.parse(config.host, config.port);
    const backend = comptime selectRuntimeBackend(builtin.os.tag);
    return switch (backend) {
        .worker => {
            var server = try address.listen(io, .{ .reuse_address = true });
            defer server.deinit(io);
            return serveBlockingWorkers(allocator, io, config, logger, cache, &server, backend);
        },
        .epoll, .kqueue => {
            if (try serveEventWorkersReusePort(allocator, io, config, logger, cache, &address, backend)) return;
            logger.event("warn", "SO_REUSEPORT listeners unavailable; using the dispatcher accept path", .{}) catch {};
            var server = try address.listen(io, .{ .reuse_address = true });
            defer server.deinit(io);
            return serveEventWorkersDispatched(allocator, io, config, logger, cache, &server, backend);
        },
    };
}

fn serveBlockingWorkers(
    allocator: Allocator,
    io: Io,
    config: Config,
    logger: *Logger,
    cache: *StaticCache,
    server: *Io.net.Server,
    backend: RuntimeBackend,
) !void {
    const worker_count = resolveWorkerCount(io, config);
    var queue = try WorkerQueue.init(allocator, io, @intCast(config.max_connections));
    defer queue.deinit();

    var active_connections = std.atomic.Value(u32).init(0);
    var threads = try allocator.alloc(std.Thread, worker_count);
    defer allocator.free(threads);
    const contexts = try allocator.alloc(WorkerContext, worker_count);
    defer allocator.free(contexts);

    var started_workers: usize = 0;
    errdefer {
        queue.close();
        for (threads[0..started_workers]) |thread| thread.join();
    }

    for (contexts, 0..) |*context, index| {
        context.* = .{
            .allocator = allocator,
            .io = io,
            .config = config,
            .logger = logger,
            .cache = cache,
            .queue = &queue,
            .active_connections = &active_connections,
        };
        threads[index] = try std.Thread.spawn(.{
            .stack_size = worker_stack_size,
            .allocator = allocator,
        }, workerLoop, .{context});
        started_workers += 1;
    }
    defer {
        queue.close();
        for (threads[0..started_workers]) |thread| thread.join();
    }

    try logger.event("info", "serving {s} on {s}:{d} with {d} workers using {s}", .{ config.serve_dir, config.host, config.port, worker_count, runtimeBackendName(backend) });

    accept_loop: while (!shutdown_requested.load(.seq_cst)) {
        const stream = server.accept(io) catch |err| switch (err) {
            error.ConnectionAborted => continue,
            else => {
                if (shutdown_requested.load(.seq_cst)) break :accept_loop;
                return err;
            },
        };
        if (!tryAcquireConnection(&active_connections, config.max_connections)) {
            sendBusy(io, stream) catch |err| {
                logger.event("error", "busy response failed: {s}", .{@errorName(err)}) catch {};
            };
            continue;
        }

        if (!queue.push(stream)) {
            releaseConnection(&active_connections);
            sendBusy(io, stream) catch {};
            continue;
        }
    }

    logger.event("info", "shutdown", .{}) catch {};
}

fn serveEventWorkersReusePort(
    allocator: Allocator,
    io: Io,
    config: Config,
    logger: *Logger,
    cache: *StaticCache,
    address: *IpAddress,
    backend: RuntimeBackend,
) !bool {
    const worker_count = resolveWorkerCount(io, config);
    const servers = try allocator.alloc(Io.net.Server, worker_count);
    defer allocator.free(servers);

    var started_servers: usize = 0;
    while (started_servers < worker_count) : (started_servers += 1) {
        servers[started_servers] = address.listen(io, .{ .reuse_address = true }) catch |err| {
            for (servers[0..started_servers]) |*server| server.deinit(io);
            if (started_servers != 0 and shouldFallbackReusePort(err)) return false;
            return err;
        };
    }
    defer for (servers[0..started_servers]) |*server| server.deinit(io);

    for (servers) |server| {
        setFdNonblocking(server.socket.handle, true) catch return false;
    }

    const pipes = try allocator.alloc(WakePipe, worker_count);
    defer allocator.free(pipes);
    const threads = try allocator.alloc(std.Thread, worker_count);
    defer allocator.free(threads);
    const contexts = try allocator.alloc(EventWorkerContext, worker_count);
    defer allocator.free(contexts);

    var active_connections = std.atomic.Value(u32).init(0);
    var started_pipes: usize = 0;
    var started_workers: usize = 0;
    errdefer {
        shutdown_requested.store(true, .seq_cst);
        for (pipes[0..started_pipes]) |pipe| wakeFd(pipe.write) catch {};
        for (threads[0..started_workers]) |thread| thread.join();
        for (pipes[0..started_pipes]) |pipe| closeWakePipe(pipe);
    }

    for (contexts, 0..) |*context, index| {
        pipes[index] = try createWakePipe();
        started_pipes += 1;
        context.* = .{
            .allocator = allocator,
            .io = io,
            .config = config,
            .logger = logger,
            .cache = cache,
            .listener = &servers[index],
            .active_connections = &active_connections,
            .backend = backend,
            .wake_read_fd = pipes[index].read,
            .wake_write_fd = pipes[index].write,
        };
        threads[index] = try std.Thread.spawn(.{
            .stack_size = worker_stack_size,
            .allocator = allocator,
        }, eventWorkerLoop, .{context});
        started_workers += 1;
    }

    try logger.event("info", "serving {s} on {s}:{d} with {d} workers using {s}", .{ config.serve_dir, config.host, config.port, worker_count, runtimeBackendName(backend) });
    for (threads[0..started_workers]) |thread| thread.join();
    for (pipes[0..started_pipes]) |pipe| closeWakePipe(pipe);
    logger.event("info", "shutdown", .{}) catch {};
    return true;
}

pub fn shouldFallbackReusePort(err: anyerror) bool {
    return switch (err) {
        error.AddressInUse,
        error.OptionUnsupported,
        error.ProtocolUnsupportedBySystem,
        error.ProtocolUnsupportedByAddressFamily,
        error.SocketModeUnsupported,
        => true,
        else => false,
    };
}

fn serveEventWorkersDispatched(
    allocator: Allocator,
    io: Io,
    config: Config,
    logger: *Logger,
    cache: *StaticCache,
    server: *Io.net.Server,
    backend: RuntimeBackend,
) !void {
    const worker_count = resolveWorkerCount(io, config);
    var queues = try allocator.alloc(WorkerQueue, worker_count);
    defer allocator.free(queues);
    var pipes = try allocator.alloc(WakePipe, worker_count);
    defer allocator.free(pipes);
    var threads = try allocator.alloc(std.Thread, worker_count);
    defer allocator.free(threads);
    const contexts = try allocator.alloc(EventWorkerContext, worker_count);
    defer allocator.free(contexts);

    var active_connections = std.atomic.Value(u32).init(0);
    var started_queues: usize = 0;
    var started_pipes: usize = 0;
    var started_workers: usize = 0;
    errdefer {
        for (queues[0..started_queues]) |*queue| queue.close();
        for (pipes[0..started_pipes]) |pipe| wakeFd(pipe.write) catch {};
        for (threads[0..started_workers]) |thread| thread.join();
        for (pipes[0..started_pipes]) |pipe| closeWakePipe(pipe);
        for (queues[0..started_queues]) |*queue| queue.deinit();
    }

    for (contexts, 0..) |*context, index| {
        queues[index] = try WorkerQueue.init(allocator, io, @intCast(config.max_connections));
        started_queues += 1;
        pipes[index] = try createWakePipe();
        started_pipes += 1;
        context.* = .{
            .allocator = allocator,
            .io = io,
            .config = config,
            .logger = logger,
            .cache = cache,
            .queue = &queues[index],
            .active_connections = &active_connections,
            .backend = backend,
            .wake_read_fd = pipes[index].read,
            .wake_write_fd = pipes[index].write,
        };
        threads[index] = try std.Thread.spawn(.{
            .stack_size = worker_stack_size,
            .allocator = allocator,
        }, eventWorkerLoop, .{context});
        started_workers += 1;
    }
    defer {
        for (queues[0..started_queues]) |*queue| queue.close();
        for (pipes[0..started_pipes]) |pipe| wakeFd(pipe.write) catch {};
        for (threads[0..started_workers]) |thread| thread.join();
        for (pipes[0..started_pipes]) |pipe| closeWakePipe(pipe);
        for (queues[0..started_queues]) |*queue| queue.deinit();
    }

    try logger.event("info", "serving {s} on {s}:{d} with {d} workers using {s}", .{ config.serve_dir, config.host, config.port, worker_count, runtimeBackendName(backend) });

    var next_worker: usize = 0;
    accept_loop: while (!shutdown_requested.load(.seq_cst)) {
        const stream = server.accept(io) catch |err| switch (err) {
            error.ConnectionAborted => continue,
            else => {
                if (shutdown_requested.load(.seq_cst)) break :accept_loop;
                return err;
            },
        };
        if (!tryAcquireConnection(&active_connections, config.max_connections)) {
            sendBusy(io, stream) catch |err| {
                logger.event("error", "busy response failed: {s}", .{@errorName(err)}) catch {};
            };
            continue;
        }

        setFdNonblocking(stream.socket.handle, true) catch |err| {
            releaseConnection(&active_connections);
            logger.event("error", "failed to make socket nonblocking: {s}", .{@errorName(err)}) catch {};
            stream.close(io);
            continue;
        };

        const worker_index = next_worker;
        next_worker = (next_worker + 1) % worker_count;
        if (!queues[worker_index].push(stream)) {
            releaseConnection(&active_connections);
            setFdNonblocking(stream.socket.handle, false) catch {};
            sendBusy(io, stream) catch {};
            continue;
        }
        wakeFd(pipes[worker_index].write) catch |err| {
            logger.event("error", "event worker wake failed: {s}", .{@errorName(err)}) catch {};
        };
    }

    logger.event("info", "shutdown", .{}) catch {};
}

pub fn resolveWorkerCount(io: Io, config: Config) usize {
    if (config.workers > 0) return @intCast(config.workers);
    return detectPerformanceCpuCount(io);
}

pub fn tryAcquireConnection(active_connections: *std.atomic.Value(u32), max_connections: u32) bool {
    var current = active_connections.load(.seq_cst);
    while (current < max_connections) {
        if (active_connections.cmpxchgWeak(current, current + 1, .seq_cst, .seq_cst)) |actual| {
            current = actual;
        } else {
            return true;
        }
    }
    return false;
}

pub fn releaseConnection(active_connections: *std.atomic.Value(u32)) void {
    _ = active_connections.fetchSub(1, .seq_cst);
}

fn workerLoop(context: *WorkerContext) void {
    var root = Io.Dir.cwd().openDir(context.io, context.config.serve_dir, .{}) catch |err| {
        context.logger.event("error", "serve directory failed: {s}", .{@errorName(err)}) catch {};
        return;
    };
    defer root.close(context.io);
    var cache_view = context.cache.view(context.io);
    defer cache_view.deinit();

    while (context.queue.pop()) |stream| {
        handleConnection(context.allocator, context.io, root, stream, context.config, context.logger, &cache_view) catch |err| {
            if (!isNormalDisconnect(err)) {
                context.logger.event("error", "connection failed: {s}", .{@errorName(err)}) catch {};
            }
        };
        releaseConnection(context.active_connections);
    }
}

fn eventWorkerLoop(context: *EventWorkerContext) void {
    var root = Io.Dir.cwd().openDir(context.io, context.config.serve_dir, .{}) catch |err| {
        context.logger.event("error", "serve directory failed: {s}", .{@errorName(err)}) catch {};
        return;
    };
    defer root.close(context.io);
    var cache_view = context.cache.view(context.io);
    defer cache_view.deinit();
    context.cache_view = &cache_view;
    defer context.cache_view = null;

    switch (comptime selectRuntimeBackend(builtin.os.tag)) {
        .epoll => eventWorkerLoopEpoll(context, root) catch |err| {
            context.logger.event("error", "epoll worker failed: {s}", .{@errorName(err)}) catch {};
        },
        .kqueue => eventWorkerLoopKqueue(context, root) catch |err| {
            context.logger.event("error", "kqueue worker failed: {s}", .{@errorName(err)}) catch {};
        },
        .worker => unreachable,
    }
}

fn eventWorkerLoopEpoll(context: *EventWorkerContext, root: Io.Dir) !void {
    const epoll_fd = try epollCreate();
    defer closeFd(epoll_fd);

    try epollAddUserData(epoll_fd, context.wake_read_fd, event_wake_token);
    if (context.listener) |listener| try epollAddUserData(epoll_fd, listener.socket.handle, event_listener_token);

    var connections = EventConnectionList{};
    var ready = EventReadyQueue{};
    var retired: ?*EventConnection = null;
    defer closeAllEventConnections(context, &connections, &retired);
    var next_idle_scan = nextIdleScan(Io.Timestamp.now(context.io, .awake), context.config);

    var events: [128]std.os.linux.epoll_event = undefined;
    while (!shutdown_requested.load(.seq_cst)) {
        const count = try epollWait(epoll_fd, &events, if (ready.count != 0) 0 else eventWaitTimeoutMs(context.config));
        const batch_now = Io.Timestamp.now(context.io, .awake);
        var index: usize = 0;
        while (index < count) : (index += 1) {
            const event = events[index];
            const token = event.data.ptr;
            if (token == event_wake_token) {
                drainWakeFd(context.wake_read_fd);
                if (context.queue != null) try registerQueuedEpoll(context, epoll_fd, &connections, batch_now);
                continue;
            }
            if (token == event_listener_token) {
                try acceptReadyEpoll(context, epoll_fd, &connections, batch_now);
                continue;
            }
            const conn: *EventConnection = @ptrFromInt(token);
            if (conn.closing) continue;
            ready.remove(conn);
            if ((event.events & (std.os.linux.EPOLL.ERR | std.os.linux.EPOLL.HUP | std.os.linux.EPOLL.RDHUP)) != 0) {
                deferCloseEventConnection(context, &connections, &ready, &retired, conn);
                continue;
            }
            var keep_open = true;
            if ((event.events & std.os.linux.EPOLL.OUT) != 0 and conn.hasPendingWrite()) {
                keep_open = flushEventPendingWrite(context, conn, batch_now) catch |err| blk: {
                    if (!isNormalDisconnect(err)) {
                        context.logger.event("error", "event response write failed: {s}", .{@errorName(err)}) catch {};
                    }
                    break :blk false;
                };
            }
            if (keep_open and (event.events & std.os.linux.EPOLL.IN) != 0 and !conn.hasPendingWrite()) {
                keep_open = processEventConnection(context, root, conn, batch_now) catch |err| blk: {
                    if (!isNormalDisconnect(err)) {
                        context.logger.event("error", "event connection failed: {s}", .{@errorName(err)}) catch {};
                    }
                    break :blk false;
                };
            }
            if (!keep_open) {
                deferCloseEventConnection(context, &connections, &ready, &retired, conn);
            } else {
                syncEpollWriteInterest(epoll_fd, conn) catch |err| {
                    context.logger.event("error", "epoll write interest failed: {s}", .{@errorName(err)}) catch {};
                    deferCloseEventConnection(context, &connections, &ready, &retired, conn);
                };
                if (!conn.closing and !conn.hasPendingWrite() and hasCompleteBufferedRequest(conn)) ready.enqueue(conn);
            }
        }
        if (context.queue != null) try registerQueuedEpoll(context, epoll_fd, &connections, batch_now);
        processReadyEpoll(context, root, epoll_fd, &connections, &ready, &retired, batch_now);
        scanExpiredEventConnections(context, &connections, &ready, &retired, &next_idle_scan, batch_now);
        destroyRetiredEventConnections(context, &retired);
    }
}

fn eventWorkerLoopKqueue(context: *EventWorkerContext, root: Io.Dir) !void {
    const kq_fd = try kqueueCreate();
    defer closeFd(kq_fd);

    try kqueueAddUserData(kq_fd, context.wake_read_fd, event_wake_token);
    if (context.listener) |listener| try kqueueAddUserData(kq_fd, listener.socket.handle, event_listener_token);

    var connections = EventConnectionList{};
    var ready = EventReadyQueue{};
    var retired: ?*EventConnection = null;
    defer closeAllEventConnections(context, &connections, &retired);
    var next_idle_scan = nextIdleScan(Io.Timestamp.now(context.io, .awake), context.config);

    var events: [128]std.posix.Kevent = undefined;
    while (!shutdown_requested.load(.seq_cst)) {
        const count = try kqueueWait(kq_fd, &events, if (ready.count != 0) 0 else eventWaitTimeoutMs(context.config));
        const batch_now = Io.Timestamp.now(context.io, .awake);
        var index: usize = 0;
        while (index < count) : (index += 1) {
            const event = events[index];
            const token: usize = @intCast(event.udata);
            if (token == event_wake_token) {
                drainWakeFd(context.wake_read_fd);
                if (context.queue != null) try registerQueuedKqueue(context, kq_fd, &connections, batch_now);
                continue;
            }
            if (token == event_listener_token) {
                try acceptReadyKqueue(context, kq_fd, &connections, batch_now);
                continue;
            }
            const conn: *EventConnection = @ptrFromInt(token);
            if (conn.closing) continue;
            ready.remove(conn);
            if ((event.flags & std.c.EV.ERROR) != 0) {
                deferCloseEventConnection(context, &connections, &ready, &retired, conn);
                continue;
            }
            var keep_open = true;
            if (event.filter == std.c.EVFILT.WRITE and conn.hasPendingWrite()) {
                keep_open = flushEventPendingWrite(context, conn, batch_now) catch |err| blk: {
                    if (!isNormalDisconnect(err)) {
                        context.logger.event("error", "event response write failed: {s}", .{@errorName(err)}) catch {};
                    }
                    break :blk false;
                };
            }
            if (keep_open and event.filter == std.c.EVFILT.READ and !conn.hasPendingWrite()) {
                keep_open = processEventConnection(context, root, conn, batch_now) catch |err| blk: {
                    if (!isNormalDisconnect(err)) {
                        context.logger.event("error", "event connection failed: {s}", .{@errorName(err)}) catch {};
                    }
                    break :blk false;
                };
            }
            if (!keep_open) {
                deferCloseEventConnection(context, &connections, &ready, &retired, conn);
            } else {
                syncKqueueWriteInterest(kq_fd, conn) catch |err| {
                    context.logger.event("error", "kqueue write interest failed: {s}", .{@errorName(err)}) catch {};
                    deferCloseEventConnection(context, &connections, &ready, &retired, conn);
                };
                if (!conn.closing and !conn.hasPendingWrite() and hasCompleteBufferedRequest(conn)) ready.enqueue(conn);
            }
        }
        if (context.queue != null) try registerQueuedKqueue(context, kq_fd, &connections, batch_now);
        processReadyKqueue(context, root, kq_fd, &connections, &ready, &retired, batch_now);
        scanExpiredEventConnections(context, &connections, &ready, &retired, &next_idle_scan, batch_now);
        destroyRetiredEventConnections(context, &retired);
    }
}

fn processReadyEpoll(
    context: *EventWorkerContext,
    root: Io.Dir,
    epoll_fd: std.posix.fd_t,
    connections: *EventConnectionList,
    ready: *EventReadyQueue,
    retired: *?*EventConnection,
    batch_now: Io.Timestamp,
) void {
    const budget = ready.count;
    var processed: usize = 0;
    while (processed < budget) : (processed += 1) {
        const conn = ready.pop() orelse return;
        if (conn.closing) continue;
        const keep_open = processEventConnection(context, root, conn, batch_now) catch |err| blk: {
            if (!isNormalDisconnect(err)) {
                context.logger.event("error", "event ready connection failed: {s}", .{@errorName(err)}) catch {};
            }
            break :blk false;
        };
        if (!keep_open) {
            deferCloseEventConnection(context, connections, ready, retired, conn);
            continue;
        }
        syncEpollWriteInterest(epoll_fd, conn) catch |err| {
            context.logger.event("error", "epoll write interest failed: {s}", .{@errorName(err)}) catch {};
            deferCloseEventConnection(context, connections, ready, retired, conn);
        };
        if (!conn.closing and !conn.hasPendingWrite() and hasCompleteBufferedRequest(conn)) ready.enqueue(conn);
    }
}

fn processReadyKqueue(
    context: *EventWorkerContext,
    root: Io.Dir,
    kq_fd: std.posix.fd_t,
    connections: *EventConnectionList,
    ready: *EventReadyQueue,
    retired: *?*EventConnection,
    batch_now: Io.Timestamp,
) void {
    const budget = ready.count;
    var processed: usize = 0;
    while (processed < budget) : (processed += 1) {
        const conn = ready.pop() orelse return;
        if (conn.closing) continue;
        const keep_open = processEventConnection(context, root, conn, batch_now) catch |err| blk: {
            if (!isNormalDisconnect(err)) {
                context.logger.event("error", "event ready connection failed: {s}", .{@errorName(err)}) catch {};
            }
            break :blk false;
        };
        if (!keep_open) {
            deferCloseEventConnection(context, connections, ready, retired, conn);
            continue;
        }
        syncKqueueWriteInterest(kq_fd, conn) catch |err| {
            context.logger.event("error", "kqueue write interest failed: {s}", .{@errorName(err)}) catch {};
            deferCloseEventConnection(context, connections, ready, retired, conn);
        };
        if (!conn.closing and !conn.hasPendingWrite() and hasCompleteBufferedRequest(conn)) ready.enqueue(conn);
    }
}

fn acceptReadyEpoll(
    context: *EventWorkerContext,
    epoll_fd: std.posix.fd_t,
    connections: *EventConnectionList,
    batch_now: Io.Timestamp,
) !void {
    const listener = context.listener.?;
    var accepted: usize = 0;
    while (accepted < event_accept_batch_limit) : (accepted += 1) {
        const stream = acceptNonblocking(listener.socket.handle) catch |err| switch (err) {
            error.WouldBlock => return,
            error.ConnectionAborted => continue,
            else => return err,
        };
        if (!tryAcquireConnection(context.active_connections, context.config.max_connections)) {
            sendBusy(context.io, stream) catch {};
            continue;
        }
        const conn = createEventConnection(context, stream, batch_now) catch |err| {
            stream.close(context.io);
            releaseConnection(context.active_connections);
            return err;
        };
        epollAddUserData(epoll_fd, stream.socket.handle, @intFromPtr(conn)) catch |err| {
            destroyEventConnection(context, conn);
            return err;
        };
        connections.add(conn);
    }
}

fn acceptReadyKqueue(
    context: *EventWorkerContext,
    kq_fd: std.posix.fd_t,
    connections: *EventConnectionList,
    batch_now: Io.Timestamp,
) !void {
    const listener = context.listener.?;
    var accepted: usize = 0;
    while (accepted < event_accept_batch_limit) : (accepted += 1) {
        const stream = acceptNonblocking(listener.socket.handle) catch |err| switch (err) {
            error.WouldBlock => return,
            error.ConnectionAborted => continue,
            else => return err,
        };
        if (!tryAcquireConnection(context.active_connections, context.config.max_connections)) {
            sendBusy(context.io, stream) catch {};
            continue;
        }
        const conn = createEventConnection(context, stream, batch_now) catch |err| {
            stream.close(context.io);
            releaseConnection(context.active_connections);
            return err;
        };
        kqueueAddUserData(kq_fd, stream.socket.handle, @intFromPtr(conn)) catch |err| {
            destroyEventConnection(context, conn);
            return err;
        };
        connections.add(conn);
    }
}

fn registerQueuedEpoll(
    context: *EventWorkerContext,
    epoll_fd: std.posix.fd_t,
    connections: *EventConnectionList,
    batch_now: Io.Timestamp,
) !void {
    while (context.queue.?.popAvailable()) |stream| {
        const conn = createEventConnection(context, stream, batch_now) catch |err| {
            context.logger.event("error", "event connection allocation failed: {s}", .{@errorName(err)}) catch {};
            stream.close(context.io);
            releaseConnection(context.active_connections);
            continue;
        };
        epollAddUserData(epoll_fd, stream.socket.handle, @intFromPtr(conn)) catch |err| {
            destroyEventConnection(context, conn);
            context.logger.event("error", "epoll registration failed: {s}", .{@errorName(err)}) catch {};
            continue;
        };
        connections.add(conn);
    }
}

fn registerQueuedKqueue(
    context: *EventWorkerContext,
    kq_fd: std.posix.fd_t,
    connections: *EventConnectionList,
    batch_now: Io.Timestamp,
) !void {
    while (context.queue.?.popAvailable()) |stream| {
        const conn = createEventConnection(context, stream, batch_now) catch |err| {
            context.logger.event("error", "event connection allocation failed: {s}", .{@errorName(err)}) catch {};
            stream.close(context.io);
            releaseConnection(context.active_connections);
            continue;
        };
        kqueueAddUserData(kq_fd, stream.socket.handle, @intFromPtr(conn)) catch |err| {
            destroyEventConnection(context, conn);
            context.logger.event("error", "kqueue registration failed: {s}", .{@errorName(err)}) catch {};
            continue;
        };
        connections.add(conn);
    }
}

fn createEventConnection(context: *EventWorkerContext, stream: Io.net.Stream, batch_now: Io.Timestamp) !*EventConnection {
    const conn = try context.allocator.create(EventConnection);
    conn.* = .{
        .stream = stream,
        .last_active = batch_now,
    };
    if (context.logger.access_enabled) {
        const remote = formatRemoteAddress(stream.socket.address, &conn.remote_buffer);
        conn.remote_len = remote.len;
    } else {
        conn.remote_buffer[0] = '-';
        conn.remote_len = 1;
    }
    return conn;
}

fn destroyEventConnection(context: *EventWorkerContext, conn: *EventConnection) void {
    releasePendingResources(context, &conn.pending);
    conn.stream.close(context.io);
    releaseConnection(context.active_connections);
    context.allocator.destroy(conn);
}

fn deferCloseEventConnection(
    context: *EventWorkerContext,
    connections: *EventConnectionList,
    ready: *EventReadyQueue,
    retired: *?*EventConnection,
    conn: *EventConnection,
) void {
    if (conn.closing) return;
    ready.remove(conn);
    connections.remove(conn);
    conn.closing = true;
    releasePendingResources(context, &conn.pending);
    conn.pending = .{};
    conn.stream.close(context.io);
    releaseConnection(context.active_connections);
    conn.retired_next = retired.*;
    retired.* = conn;
}

fn destroyRetiredEventConnections(context: *EventWorkerContext, retired: *?*EventConnection) void {
    var current = retired.*;
    retired.* = null;
    while (current) |conn| {
        const next = conn.retired_next;
        context.allocator.destroy(conn);
        current = next;
    }
}

fn closeAllEventConnections(
    context: *EventWorkerContext,
    connections: *EventConnectionList,
    retired: *?*EventConnection,
) void {
    var current = connections.head;
    connections.head = null;
    while (current) |conn| {
        const next = conn.next;
        destroyEventConnection(context, conn);
        current = next;
    }
    destroyRetiredEventConnections(context, retired);
}

fn nextIdleScan(now: Io.Timestamp, config: Config) Io.Timestamp {
    return now.addDuration(
        Io.Duration.fromMilliseconds(@min(config.keep_alive_timeout_ms, @as(u32, 1000))),
    );
}

fn scanExpiredEventConnections(
    context: *EventWorkerContext,
    connections: *EventConnectionList,
    ready: *EventReadyQueue,
    retired: *?*EventConnection,
    next_scan: *Io.Timestamp,
    batch_now: Io.Timestamp,
) void {
    if (batch_now.nanoseconds < next_scan.nanoseconds) return;
    next_scan.* = batch_now.addDuration(
        Io.Duration.fromMilliseconds(@min(context.config.keep_alive_timeout_ms, @as(u32, 1000))),
    );

    var current = connections.head;
    while (current) |conn| {
        const next = conn.next;
        if (eventConnectionExpired(conn, batch_now, context.config)) {
            deferCloseEventConnection(context, connections, ready, retired, conn);
        }
        current = next;
    }
}

pub fn eventConnectionExpired(conn: *const EventConnection, now: Io.Timestamp, config: Config) bool {
    const idle_ms = conn.last_active.durationTo(now).toMilliseconds();
    return idle_ms >= config.keep_alive_timeout_ms;
}

fn processEventConnection(context: *EventWorkerContext, root: Io.Dir, conn: *EventConnection, batch_now: Io.Timestamp) !bool {
    if (conn.hasPendingWrite()) return flushEventPendingWrite(context, conn, batch_now);

    while (true) {
        if (conn.request_len == conn.request_buffer.len) {
            if (conn.request_start != 0) compactEventRequestBuffer(conn);
            if (conn.request_len == conn.request_buffer.len and !hasCompleteBufferedRequest(conn)) {
                try queueEventMemoryResponse(
                    context,
                    conn,
                    conn.request_len,
                    conn.served_requests,
                    false,
                    batch_now,
                    "-",
                    "-",
                    null,
                    .{ .code = 413, .reason = "Payload Too Large" },
                    "text/plain; charset=utf-8",
                    "Request too large\n",
                    true,
                    &.{},
                    .{},
                );
                return flushEventPendingWrite(context, conn, batch_now);
            }
            if (conn.request_len == conn.request_buffer.len) break;
        }
        const n = readFd(conn.stream.socket.handle, conn.request_buffer[conn.request_len..]) catch |err| switch (err) {
            error.WouldBlock => break,
            error.ConnectionResetByPeer, error.SocketUnconnected => return false,
            else => return err,
        };
        if (n == 0) return false;
        conn.request_len += n;
        conn.last_active = batch_now;
    }

    var processed_this_tick: usize = 0;
    while (std.mem.indexOf(u8, conn.request_buffer[conn.request_start..conn.request_len], "\r\n\r\n")) |header_end_rel| {
        if (shutdown_requested.load(.seq_cst)) return false;
        if (processed_this_tick >= event_request_batch_limit) return true;

        const request_end = conn.request_start + header_end_rel + 4;
        const request_bytes = conn.request_buffer[conn.request_start..request_end];
        const request = parseRequestOptions(request_bytes, context.logger.access_enabled) catch {
            try queueEventMemoryResponse(
                context,
                conn,
                request_end,
                conn.served_requests,
                false,
                batch_now,
                "-",
                "-",
                null,
                .{ .code = 400, .reason = "Bad Request" },
                "text/plain; charset=utf-8",
                "Bad request\n",
                true,
                &.{},
                .{},
            );
            return flushEventPendingWrite(context, conn, batch_now);
        };

        const current_request_count = conn.served_requests + 1;
        try prepareEventResponse(
            context,
            root,
            conn,
            request,
            request_end,
            current_request_count,
            batch_now,
        );
        processed_this_tick += 1;
        const keep_open = try flushEventPendingWrite(context, conn, batch_now);
        if (!keep_open) return false;
        if (conn.hasPendingWrite()) return true;
    }

    if (conn.request_len == conn.request_buffer.len and !hasCompleteBufferedRequest(conn)) {
        try queueEventMemoryResponse(
            context,
            conn,
            conn.request_len,
            conn.served_requests,
            false,
            batch_now,
            "-",
            "-",
            null,
            .{ .code = 413, .reason = "Payload Too Large" },
            "text/plain; charset=utf-8",
            "Request too large\n",
            true,
            &.{},
            .{},
        );
        return flushEventPendingWrite(context, conn, batch_now);
    }
    return true;
}

fn hasCompleteBufferedRequest(conn: *const EventConnection) bool {
    return std.mem.indexOf(u8, conn.request_buffer[conn.request_start..conn.request_len], "\r\n\r\n") != null;
}

fn compactEventRequestBuffer(conn: *EventConnection) void {
    if (conn.request_start == 0) return;
    const remaining = conn.request_len - conn.request_start;
    if (remaining != 0) {
        std.mem.copyForwards(
            u8,
            conn.request_buffer[0..remaining],
            conn.request_buffer[conn.request_start..conn.request_len],
        );
    }
    conn.request_start = 0;
    conn.request_len = remaining;
}

fn selectRepresentation(
    cache_view: *CacheView,
    io: Io,
    root: Io.Dir,
    logical_path: []const u8,
    accept_encoding: ?[]const u8,
    config: Config,
    brotli_buffer: []u8,
    gzip_buffer: []u8,
) !RepresentationSelection {
    if (!config.precompressed or accept_encoding == null or isDirectSidecarPath(logical_path)) {
        return .{ .selected = .{ .representation = .identity, .physical_path = logical_path } };
    }

    const brotli_path = appendSidecarPath(logical_path, ".br", brotli_buffer);
    const gzip_path = appendSidecarPath(logical_path, ".gz", gzip_buffer);
    const identity_state = try representationAvailability(
        cache_view,
        io,
        root,
        logical_path,
        logical_path,
        .identity,
    );
    if (identity_state == .directory) return .directory;

    const brotli_state = if (brotli_path) |path|
        try representationAvailability(cache_view, io, root, logical_path, path, .brotli)
    else
        CacheAvailability.unavailable;
    const gzip_state = if (gzip_path) |path|
        try representationAvailability(cache_view, io, root, logical_path, path, .gzip)
    else
        CacheAvailability.unavailable;

    const availability = http.EncodingAvailability{
        .identity = isAvailableRepresentation(identity_state),
        .gzip = isAvailableRepresentation(gzip_state),
        .brotli = isAvailableRepresentation(brotli_state),
    };
    if (!availability.identity and !availability.gzip and !availability.brotli) {
        return if (identity_state == .forbidden) .forbidden else .not_found;
    }

    return switch (http.selectContentEncoding(accept_encoding, availability)) {
        .not_acceptable => .not_acceptable,
        .selected => |coding| .{ .selected = switch (coding) {
            .identity => .{ .representation = .identity, .physical_path = logical_path },
            .gzip => .{ .representation = .gzip, .physical_path = gzip_path.? },
            .brotli => .{ .representation = .brotli, .physical_path = brotli_path.? },
        } },
    };
}

fn representationAvailability(
    cache_view: *CacheView,
    io: Io,
    root: Io.Dir,
    logical_path: []const u8,
    physical_path: []const u8,
    representation: Representation,
) !CacheAvailability {
    const cached = try cache_view.representationAvailability(
        root,
        logical_path,
        physical_path,
        representation,
    );
    if (cached != .unknown) return cached;

    var file = root.openFile(io, physical_path, .{
        .mode = .read_only,
        .allow_directory = false,
        .resolve_beneath = true,
    }) catch |err| return switch (err) {
        error.FileNotFound, error.NotDir => .unavailable,
        error.IsDir => .directory,
        error.AccessDenied => .forbidden,
        else => err,
    };
    defer file.close(io);
    const stat = try file.stat(io);
    return if (stat.kind == .file) .uncached else .unavailable;
}

fn isAvailableRepresentation(availability: CacheAvailability) bool {
    return availability == .cached or availability == .uncached;
}

fn appendSidecarPath(path: []const u8, suffix: []const u8, buffer: []u8) ?[]const u8 {
    if (path.len + suffix.len > buffer.len) return null;
    @memcpy(buffer[0..path.len], path);
    @memcpy(buffer[path.len..][0..suffix.len], suffix);
    return buffer[0 .. path.len + suffix.len];
}

fn isDirectSidecarPath(path: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(path, ".br") or std.ascii.endsWithIgnoreCase(path, ".gz");
}

fn representationName(representation: Representation) []const u8 {
    return switch (representation) {
        .identity => "identity",
        .gzip => "gzip",
        .brotli => "br",
    };
}

fn representationEncoding(representation: Representation) ?[]const u8 {
    return switch (representation) {
        .identity => null,
        .gzip => "gzip",
        .brotli => "br",
    };
}

fn prepareEventResponse(
    context: *EventWorkerContext,
    root: Io.Dir,
    conn: *EventConnection,
    request: Request,
    request_end: usize,
    current_request_count: u32,
    start: Io.Timestamp,
) !void {
    var keep_open = requestWantsKeepAlive(request, context.config, current_request_count);
    const is_head = std.mem.eql(u8, request.method, "HEAD");
    if (request.has_request_body) {
        try queueEventMemoryResponse(
            context,
            conn,
            request_end,
            current_request_count,
            false,
            start,
            request.method,
            request.target,
            request.user_agent,
            .{ .code = 400, .reason = "Bad Request" },
            "text/plain; charset=utf-8",
            "Bad request\n",
            !is_head,
            &.{},
            .{},
        );
        return;
    }

    if (!is_head and !std.mem.eql(u8, request.method, "GET")) {
        keep_open = false;
        try queueEventMemoryResponse(
            context,
            conn,
            request_end,
            current_request_count,
            keep_open,
            start,
            request.method,
            request.target,
            request.user_agent,
            .{ .code = 405, .reason = "Method Not Allowed" },
            "text/plain; charset=utf-8",
            "Method not allowed\n",
            true,
            &.{},
            .{ .allow = "GET, HEAD" },
        );
        return;
    }

    var relative_path_owned: ?[]u8 = null;
    defer if (relative_path_owned) |path| context.allocator.free(path);
    const relative_path = normalizeTargetFast(request.target, context.config.dotfiles) orelse blk: {
        relative_path_owned = normalizeTarget(context.allocator, request.target, context.config.dotfiles) catch {
            try queueEventMemoryResponse(
                context,
                conn,
                request_end,
                current_request_count,
                keep_open,
                start,
                request.method,
                request.target,
                request.user_agent,
                .{ .code = 403, .reason = "Forbidden" },
                "text/plain; charset=utf-8",
                "Forbidden\n",
                !is_head,
                &.{},
                .{},
            );
            return;
        };
        break :blk relative_path_owned.?;
    };

    return prepareEventPath(
        context,
        root,
        conn,
        request,
        relative_path,
        request_end,
        current_request_count,
        keep_open,
        is_head,
        start,
    );
}

fn prepareEventPath(
    context: *EventWorkerContext,
    root: Io.Dir,
    conn: *EventConnection,
    request: Request,
    relative_path: []const u8,
    request_end: usize,
    current_request_count: u32,
    keep_open: bool,
    is_head: bool,
    start: Io.Timestamp,
) anyerror!void {
    const response_connection = if (keep_open) "keep-alive" else "close";
    var brotli_buffer: [max_request_bytes + 3]u8 = undefined;
    var gzip_buffer: [max_request_bytes + 3]u8 = undefined;
    const choice = switch (try selectRepresentation(
        context.cache_view.?,
        context.io,
        root,
        relative_path,
        request.accept_encoding,
        context.config,
        &brotli_buffer,
        &gzip_buffer,
    )) {
        .selected => |selected| selected,
        .directory => return prepareEventDirectory(
            context,
            root,
            conn,
            request,
            relative_path,
            request_end,
            current_request_count,
            keep_open,
            is_head,
            start,
        ),
        .forbidden => {
            try queueEventMemoryResponse(
                context,
                conn,
                request_end,
                current_request_count,
                keep_open,
                start,
                request.method,
                request.target,
                request.user_agent,
                .{ .code = 403, .reason = "Forbidden" },
                "text/plain; charset=utf-8",
                "Forbidden\n",
                !is_head,
                &.{},
                .{},
            );
            return;
        },
        .not_found => {
            try queueEventMemoryResponse(
                context,
                conn,
                request_end,
                current_request_count,
                keep_open,
                start,
                request.method,
                request.target,
                request.user_agent,
                .{ .code = 404, .reason = "Not Found" },
                "text/plain; charset=utf-8",
                "Not found\n",
                !is_head,
                &.{},
                .{},
            );
            return;
        },
        .not_acceptable => {
            try queueEventMemoryResponse(
                context,
                conn,
                request_end,
                current_request_count,
                keep_open,
                start,
                request.method,
                request.target,
                request.user_agent,
                .{ .code = 406, .reason = "Not Acceptable" },
                "text/plain; charset=utf-8",
                "Not acceptable\n",
                !is_head,
                &.{},
                .{ .vary_accept_encoding = true },
            );
            return;
        },
    };

    const cached = try context.cache_view.?.prepareBorrowedAt(
        root,
        relative_path,
        choice.physical_path,
        choice.representation,
        request.if_none_match,
        request.if_modified_since,
        request.range,
        request.if_range,
        is_head,
        response_connection,
        start,
    );
    if (cached) |response| {
        conn.pending = .{
            .header = response.header,
            .body = response.body,
            .request_end = request_end,
            .served_requests_after = current_request_count,
            .keep_open = keep_open,
            .cache_lease = response.lease,
            .owns_header = response.owns_header,
        };
        setPendingAccess(context, conn, start, request.method, request.target, request.user_agent, response.status, response.bytes);
        return;
    }

    var file = root.openFile(context.io, choice.physical_path, .{
        .mode = .read_only,
        .allow_directory = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => {
            try queueEventMemoryResponse(
                context,
                conn,
                request_end,
                current_request_count,
                keep_open,
                start,
                request.method,
                request.target,
                request.user_agent,
                .{ .code = 404, .reason = "Not Found" },
                "text/plain; charset=utf-8",
                "Not found\n",
                !is_head,
                &.{},
                .{},
            );
            return;
        },
        error.IsDir => return prepareEventDirectory(
            context,
            root,
            conn,
            request,
            relative_path,
            request_end,
            current_request_count,
            keep_open,
            is_head,
            start,
        ),
        error.AccessDenied => {
            try queueEventMemoryResponse(
                context,
                conn,
                request_end,
                current_request_count,
                keep_open,
                start,
                request.method,
                request.target,
                request.user_agent,
                .{ .code = 403, .reason = "Forbidden" },
                "text/plain; charset=utf-8",
                "Forbidden\n",
                !is_head,
                &.{},
                .{},
            );
            return;
        },
        else => return err,
    };
    var file_owned = true;
    errdefer if (file_owned) file.close(context.io);

    const stat = try file.stat(context.io);
    if (stat.kind != .file) {
        file.close(context.io);
        file_owned = false;
        try queueEventMemoryResponse(
            context,
            conn,
            request_end,
            current_request_count,
            keep_open,
            start,
            request.method,
            request.target,
            request.user_agent,
            .{ .code = 404, .reason = "Not Found" },
            "text/plain; charset=utf-8",
            "Not found\n",
            !is_head,
            &.{},
            .{},
        );
        return;
    }

    const content_type = mimeType(relative_path);
    var last_modified_buffer: [64]u8 = undefined;
    const last_modified = if (context.config.last_modified) formatHttpDate(stat.mtime, &last_modified_buffer) else null;
    var etag_buffer: [128]u8 = undefined;
    const etag = if (context.config.etag)
        formatWeakEtag(stat.mtime.nanoseconds, stat.size, representationName(choice.representation), &etag_buffer)
    else
        null;
    if (isNotModified(request.if_none_match, request.if_modified_since, etag, stat.mtime.toSeconds(), context.config.last_modified)) {
        file.close(context.io);
        file_owned = false;
        try queueEventMemoryResponse(
            context,
            conn,
            request_end,
            current_request_count,
            keep_open,
            start,
            request.method,
            request.target,
            request.user_agent,
            .{ .code = 304, .reason = "Not Modified" },
            content_type,
            "",
            false,
            context.config.headers,
            .{
                .last_modified = last_modified,
                .etag = etag,
                .content_encoding = representationEncoding(choice.representation),
                .vary_accept_encoding = context.config.precompressed,
            },
        );
        return;
    }

    var selected_range: ?http.ByteRange = null;
    if (context.config.range_requests and ifRangeAllows(request.if_range, stat.mtime.toSeconds())) {
        switch (selectByteRange(request.range, stat.size)) {
            .ignore => {},
            .unsatisfiable => {
                file.close(context.io);
                file_owned = false;
                const body = "Range not satisfiable\n";
                var content_range_buffer: [64]u8 = undefined;
                const content_range = formatUnsatisfiedContentRange(stat.size, &content_range_buffer);
                try queueEventMemoryResponse(
                    context,
                    conn,
                    request_end,
                    current_request_count,
                    keep_open,
                    start,
                    request.method,
                    request.target,
                    request.user_agent,
                    .{ .code = 416, .reason = "Range Not Satisfiable" },
                    "text/plain; charset=utf-8",
                    body,
                    !is_head,
                    context.config.headers,
                    .{
                        .last_modified = last_modified,
                        .etag = etag,
                        .accept_ranges = true,
                        .content_range = content_range,
                        .vary_accept_encoding = context.config.precompressed,
                    },
                );
                return;
            },
            .satisfiable => |range| selected_range = range,
        }
    }

    var content_range_buffer: [96]u8 = undefined;
    const content_range = if (selected_range) |range|
        formatContentRange(range, stat.size, &content_range_buffer)
    else
        null;
    const response_status: ResponseStatus = if (selected_range != null)
        .{ .code = 206, .reason = "Partial Content" }
    else
        .{ .code = 200, .reason = "OK" };
    const response_size = if (selected_range) |range| range.length() else stat.size;

    const header = try buildHeaderAllocExtended(
        context.allocator,
        response_status,
        content_type,
        response_size,
        response_connection,
        context.config.headers,
        .{
            .last_modified = last_modified,
            .etag = etag,
            .accept_ranges = context.config.range_requests,
            .content_range = content_range,
            .content_encoding = representationEncoding(choice.representation),
            .vary_accept_encoding = context.config.precompressed,
        },
    );
    errdefer context.allocator.free(header);

    if (is_head) {
        file.close(context.io);
        file_owned = false;
    }
    conn.pending = .{
        .header = header,
        .request_end = request_end,
        .served_requests_after = current_request_count,
        .keep_open = keep_open,
        .owns_header = true,
        .file = if (is_head) null else file,
        .file_offset = if (selected_range) |range| range.start else 0,
        .file_remaining = if (is_head) 0 else response_size,
        .use_sendfile = !is_head and context.config.sendfile and sendfileSupportedForOs(builtin.os.tag),
    };
    setPendingAccess(context, conn, start, request.method, request.target, request.user_agent, response_status.code, if (is_head) 0 else response_size);
    file_owned = false;
}

fn prepareEventDirectory(
    context: *EventWorkerContext,
    root: Io.Dir,
    conn: *EventConnection,
    request: Request,
    relative_path: []const u8,
    request_end: usize,
    current_request_count: u32,
    keep_open: bool,
    is_head: bool,
    start: Io.Timestamp,
) !void {
    if (context.config.trailing_slash_redirect and !targetPathHasTrailingSlash(request.target)) {
        const location = try slashRedirectLocation(context.allocator, request.target);
        defer context.allocator.free(location);
        try queueEventMemoryResponse(
            context,
            conn,
            request_end,
            current_request_count,
            keep_open,
            start,
            request.method,
            request.target,
            request.user_agent,
            .{ .code = 308, .reason = "Permanent Redirect" },
            "text/plain; charset=utf-8",
            "Redirecting\n",
            !is_head,
            context.config.headers,
            .{ .location = location },
        );
        return;
    }

    const index_path = try std.fs.path.join(context.allocator, &.{ relative_path, "index.html" });
    defer context.allocator.free(index_path);
    return prepareEventPath(
        context,
        root,
        conn,
        request,
        index_path,
        request_end,
        current_request_count,
        keep_open,
        is_head,
        start,
    );
}

fn queueEventMemoryResponse(
    context: *EventWorkerContext,
    conn: *EventConnection,
    request_end: usize,
    served_requests_after: u32,
    keep_open: bool,
    start: Io.Timestamp,
    method: []const u8,
    target: []const u8,
    user_agent: ?[]const u8,
    status: ResponseStatus,
    content_type: []const u8,
    body: []const u8,
    send_body: bool,
    extra_headers: []const Header,
    options: http.ResponseHeaderOptions,
) !void {
    const connection = if (keep_open) "keep-alive" else "close";
    const header = try buildHeaderAllocExtended(
        context.allocator,
        status,
        content_type,
        body.len,
        connection,
        extra_headers,
        options,
    );
    conn.pending = .{
        .header = header,
        .body = if (send_body) body else &.{},
        .request_end = request_end,
        .served_requests_after = served_requests_after,
        .keep_open = keep_open,
        .owns_header = true,
    };
    setPendingAccess(context, conn, start, method, target, user_agent, status.code, if (send_body) body.len else 0);
}

fn setPendingAccess(
    context: *EventWorkerContext,
    conn: *EventConnection,
    start: Io.Timestamp,
    method: []const u8,
    target: []const u8,
    user_agent: ?[]const u8,
    status: u16,
    bytes: u64,
) void {
    if (!context.logger.access_enabled) return;
    conn.pending.access_enabled = true;
    conn.pending.access_start = start;
    conn.pending.access_record = .{
        .remote = conn.remote(),
        .method = method,
        .target = target,
        .status = status,
        .bytes = bytes,
        .duration_us = 0,
        .user_agent = user_agent,
    };
}

fn flushEventPendingWrite(context: *EventWorkerContext, conn: *EventConnection, batch_now: Io.Timestamp) !bool {
    while (conn.pending.active() and !conn.pending.complete()) {
        if (pendingWriteSlice(&conn.pending) != null) {
            const n = writePendingFd(conn.stream.socket.handle, &conn.pending) catch |err| switch (err) {
                error.WouldBlock => return retainPendingWrite(conn),
                error.BrokenPipe, error.ConnectionResetByPeer, error.SocketUnconnected, error.ConnectionAborted => return false,
                else => return err,
            };
            if (n == 0) return retainPendingWrite(conn);
            advancePendingWrite(&conn.pending, n);
            conn.last_active = batch_now;
            continue;
        }

        if (conn.pending.file_remaining != 0) {
            const keep_writing = try flushEventFileBody(context, conn, batch_now);
            if (!keep_writing) return retainPendingWrite(conn);
            continue;
        }
        break;
    }

    if (!conn.pending.active()) return true;
    if (!conn.pending.complete()) return retainPendingWrite(conn);
    return finishEventPendingWrite(context, conn, batch_now);
}

fn retainPendingWrite(conn: *EventConnection) bool {
    if (conn.pending.cache_lease) |*lease| lease.retain();
    return true;
}

fn flushEventFileBody(context: *EventWorkerContext, conn: *EventConnection, batch_now: Io.Timestamp) !bool {
    const pending = &conn.pending;
    const file = pending.file orelse return error.Unexpected;

    if (pending.use_sendfile) {
        switch (trySendfileStep(conn.stream.socket.handle, file, pending.file_offset, pending.file_remaining)) {
            .sent => |written| {
                if (written == 0) return error.EndOfStream;
                pending.file_offset += written;
                pending.file_remaining -= written;
                conn.last_active = batch_now;
                return true;
            },
            .would_block => return false,
            .unsupported => {
                pending.use_sendfile = false;
                logSendfileFallback(context.logger, error.SendfileUnsupported);
            },
            .failed => |err| return err,
        }
    }

    if (pending.file_buffer == null) {
        pending.file_buffer = try context.allocator.alloc(u8, 64 * 1024);
    }
    const buffer = pending.file_buffer.?;
    if (pending.file_buffer_offset >= pending.file_buffer_len) {
        const read_len: usize = @intCast(@min(pending.file_remaining, buffer.len));
        const read = try file.readPositionalAll(context.io, buffer[0..read_len], pending.file_offset);
        if (read == 0) return error.EndOfStream;
        pending.file_buffer_offset = 0;
        pending.file_buffer_len = read;
    }

    const written = writeFd(
        conn.stream.socket.handle,
        buffer[pending.file_buffer_offset..pending.file_buffer_len],
    ) catch |err| switch (err) {
        error.WouldBlock => return false,
        else => return err,
    };
    if (written == 0) return false;
    pending.file_buffer_offset += written;
    pending.file_offset += written;
    pending.file_remaining -= written;
    conn.last_active = batch_now;
    return true;
}

pub fn pendingWriteSlice(pending: *const PendingEventWrite) ?[]const u8 {
    if (pending.header_offset < pending.header.len) return pending.header[pending.header_offset..];
    if (pending.body_offset < pending.body.len) return pending.body[pending.body_offset..];
    return null;
}

pub fn advancePendingWrite(pending: *PendingEventWrite, written: usize) void {
    var remaining = written;
    if (pending.header_offset < pending.header.len) {
        const header_remaining = pending.header.len - pending.header_offset;
        const header_written = @min(header_remaining, remaining);
        pending.header_offset += header_written;
        remaining -= header_written;
    }
    if (remaining != 0 and pending.body_offset < pending.body.len) {
        const body_remaining = pending.body.len - pending.body_offset;
        pending.body_offset += @min(body_remaining, remaining);
    }
}

fn finishEventPendingWrite(context: *EventWorkerContext, conn: *EventConnection, batch_now: Io.Timestamp) bool {
    const request_end = conn.pending.request_end;
    const served_requests_after = conn.pending.served_requests_after;
    const keep_open = conn.pending.keep_open;
    if (conn.pending.access_enabled) {
        finishAccessLogAt(context.logger, conn.pending.access_start, batch_now, &conn.pending.access_record);
    }

    conn.request_start = request_end;
    if (conn.request_start == conn.request_len) {
        conn.request_start = 0;
        conn.request_len = 0;
    }
    conn.served_requests = served_requests_after;
    conn.last_active = batch_now;
    releasePendingResources(context, &conn.pending);
    conn.pending = .{};
    return keep_open;
}

fn releasePendingResources(context: *EventWorkerContext, pending: *PendingEventWrite) void {
    if (pending.cache_lease) |*lease| lease.release();
    if (pending.file) |file| file.close(context.io);
    if (pending.file_buffer) |buffer| context.allocator.free(buffer);
    if (pending.owns_header) context.allocator.free(@constCast(pending.header));
    if (pending.owns_body) context.allocator.free(@constCast(pending.body));
}

pub fn eventWaitTimeoutMs(config: Config) i32 {
    return @intCast(@min(config.keep_alive_timeout_ms, @as(u32, 1000)));
}

fn writePendingFd(fd: std.posix.fd_t, pending: *const PendingEventWrite) !usize {
    var iovecs: [2]std.posix.iovec_const = undefined;
    var count: usize = 0;
    if (pending.header_offset < pending.header.len) {
        const bytes = pending.header[pending.header_offset..];
        iovecs[count] = .{ .base = bytes.ptr, .len = bytes.len };
        count += 1;
    }
    if (pending.body_offset < pending.body.len) {
        const bytes = pending.body[pending.body_offset..];
        iovecs[count] = .{ .base = bytes.ptr, .len = bytes.len };
        count += 1;
    }
    if (count == 0) return 0;
    return writevFd(fd, iovecs[0..count]);
}

fn syncEpollWriteInterest(epoll_fd: std.posix.fd_t, conn: *EventConnection) !void {
    const enabled = conn.hasPendingWrite();
    if (conn.write_interest == enabled) return;
    try epollSetWriteInterestUserData(epoll_fd, conn.stream.socket.handle, @intFromPtr(conn), enabled);
    conn.write_interest = enabled;
}

fn syncKqueueWriteInterest(kq_fd: std.posix.fd_t, conn: *EventConnection) !void {
    const enabled = conn.hasPendingWrite();
    if (conn.write_interest == enabled) return;
    try kqueueSetReadInterestUserData(kq_fd, conn.stream.socket.handle, @intFromPtr(conn), !enabled);
    try kqueueSetWriteInterestUserData(kq_fd, conn.stream.socket.handle, @intFromPtr(conn), enabled);
    conn.write_interest = enabled;
}

fn sendBusy(io: Io, stream: Io.net.Stream) !void {
    defer stream.close(io);
    var writer_buffer: [1024]u8 = undefined;
    var writer = stream.writer(io, &writer_buffer);
    const out = &writer.interface;
    const body = "Server busy\n";
    try sendHeaders(out, .{ .code = 503, .reason = "Service Unavailable" }, "text/plain; charset=utf-8", body.len, "close", null, &.{}, null, null);
    try out.writeAll(body);
    try writer.interface.flush();
}

fn handleConnection(allocator: Allocator, io: Io, root: Io.Dir, stream: Io.net.Stream, config: Config, logger: *Logger, cache: *CacheView) !void {
    defer stream.close(io);

    var remote_buffer: [128]u8 = undefined;
    const remote = if (logger.access_enabled) formatRemoteAddress(stream.socket.address, &remote_buffer) else "-";

    var reader_buffer: [4096]u8 = undefined;
    var reader = ConnectionReader.init(io, stream, &reader_buffer);
    var request_buffer: [max_request_bytes]u8 = undefined;
    var writer_buffer: [8192]u8 = undefined;
    var writer = stream.writer(io, &writer_buffer);
    const out = &writer.interface;
    var served_requests: u32 = 0;

    while (!shutdown_requested.load(.seq_cst)) {
        const start: ?Io.Timestamp = if (logger.access_enabled) Io.Timestamp.now(io, .awake) else null;

        const request_bytes = readHttpRequest(&reader, keepAliveTimeout(config), &request_buffer) catch |err| switch (err) {
            error.Timeout, error.EndOfStream, error.ConnectionResetByPeer, error.SocketUnconnected => return,
            error.RequestTooLarge => {
                const result = try sendSimple(out, &writer, .{ .code = 413, .reason = "Payload Too Large" }, "Request too large\n", "close");
                finishBlockingAccess(logger, io, start, remote, "-", "-", null, result);
                return;
            },
            else => {
                const result = try sendSimple(out, &writer, .{ .code = 400, .reason = "Bad Request" }, "Bad request\n", "close");
                finishBlockingAccess(logger, io, start, remote, "-", "-", null, result);
                return;
            },
        };

        const request = parseRequestOptions(request_bytes, logger.access_enabled) catch {
            const result = try sendSimple(out, &writer, .{ .code = 400, .reason = "Bad Request" }, "Bad request\n", "close");
            finishBlockingAccess(logger, io, start, remote, "-", "-", null, result);
            return;
        };
        const current_request_count = served_requests + 1;
        const result = try processParsedRequest(
            allocator,
            io,
            root,
            stream,
            out,
            &writer,
            request,
            remote,
            config,
            logger,
            cache,
            current_request_count,
            start,
        );

        served_requests = current_request_count;
        if (!result.keep_open) return;
    }
}

fn processParsedRequest(
    allocator: Allocator,
    io: Io,
    root: Io.Dir,
    stream: Io.net.Stream,
    out: *Io.Writer,
    stream_writer: *Io.net.Stream.Writer,
    request: Request,
    remote: []const u8,
    config: Config,
    logger: *Logger,
    cache: *CacheView,
    current_request_count: u32,
    start: ?Io.Timestamp,
) !ProcessRequestResult {
    var keep_open = requestWantsKeepAlive(request, config, current_request_count);
    const response_connection = if (keep_open) "keep-alive" else "close";
    const is_head = std.mem.eql(u8, request.method, "HEAD");

    if (request.has_request_body) {
        const result = try sendSimpleForMethod(out, stream_writer, .{ .code = 400, .reason = "Bad Request" }, "Bad request\n", "close", is_head, .{});
        finishBlockingAccess(logger, io, start, remote, request.method, request.target, request.user_agent, result);
        return .{ .keep_open = false };
    }

    if (!is_head and !std.mem.eql(u8, request.method, "GET")) {
        keep_open = false;
        try sendHeaders(out, .{ .code = 405, .reason = "Method Not Allowed" }, "text/plain; charset=utf-8", 19, "close", "GET, HEAD", &.{}, null, null);
        try out.writeAll("Method not allowed\n");
        try stream_writer.interface.flush();
        finishBlockingAccess(logger, io, start, remote, request.method, request.target, request.user_agent, .{ .status = 405, .bytes = 19 });
        return .{ .keep_open = false };
    }

    var relative_path_owned: ?[]u8 = null;
    defer if (relative_path_owned) |path| allocator.free(path);
    const relative_path = normalizeTargetFast(request.target, config.dotfiles) orelse blk: {
        relative_path_owned = normalizeTarget(allocator, request.target, config.dotfiles) catch {
            const result = try sendSimpleForMethod(out, stream_writer, .{ .code = 403, .reason = "Forbidden" }, "Forbidden\n", response_connection, is_head, .{});
            finishBlockingAccess(logger, io, start, remote, request.method, request.target, request.user_agent, result);
            return .{ .keep_open = keep_open };
        };
        break :blk relative_path_owned.?;
    };

    const result = try servePath(
        allocator,
        io,
        root,
        stream,
        out,
        stream_writer,
        relative_path,
        request.target,
        request.if_none_match,
        request.if_modified_since,
        request.range,
        request.if_range,
        request.accept_encoding,
        is_head,
        response_connection,
        config,
        logger,
        cache,
    );
    finishBlockingAccess(logger, io, start, remote, request.method, request.target, request.user_agent, result);
    return .{ .keep_open = keep_open };
}

fn finishBlockingAccess(
    logger: *Logger,
    io: Io,
    start: ?Io.Timestamp,
    remote: []const u8,
    method: []const u8,
    target: []const u8,
    user_agent: ?[]const u8,
    result: ResponseResult,
) void {
    const started = start orelse return;
    var access_record = AccessRecord{
        .remote = remote,
        .method = method,
        .target = target,
        .status = result.status,
        .bytes = result.bytes,
        .duration_us = 0,
        .user_agent = user_agent,
    };
    finishAccessLog(logger, io, started, &access_record);
}

fn finishAccessLog(logger: *Logger, io: Io, start: Io.Timestamp, record: *AccessRecord) void {
    const end = Io.Timestamp.now(io, .awake);
    finishAccessLogAt(logger, start, end, record);
}

fn finishAccessLogAt(logger: *Logger, start: Io.Timestamp, end: Io.Timestamp, record: *AccessRecord) void {
    record.duration_us = start.durationTo(end).toMicroseconds();
    logger.access(record.*);
}

pub const ConnectionReader = struct {
    io: Io,
    stream: Io.net.Stream,
    buffer: []u8,
    start: usize = 0,
    end: usize = 0,

    fn init(io: Io, stream: Io.net.Stream, buffer: []u8) ConnectionReader {
        return .{
            .io = io,
            .stream = stream,
            .buffer = buffer,
        };
    }

    fn refill(self: *ConnectionReader, timeout: Io.Timeout) !void {
        const message = try self.stream.socket.receiveTimeout(self.io, self.buffer, timeout);
        if (message.data.len == 0) return error.EndOfStream;
        self.start = 0;
        self.end = message.data.len;
    }
};

pub fn keepAliveTimeout(config: Config) Io.Timeout {
    return .{ .duration = .{
        .raw = Io.Duration.fromMilliseconds(config.keep_alive_timeout_ms),
        .clock = .awake,
    } };
}

pub const RequestReadStep = struct {
    complete: bool,
    request_len: usize,
    consumed: usize,
};

pub fn readHttpRequest(reader: *ConnectionReader, timeout: Io.Timeout, request_buffer: []u8) ![]const u8 {
    var request_len: usize = 0;

    while (true) {
        if (reader.start >= reader.end) {
            try reader.refill(timeout);
        }

        const step = try appendRequestChunk(request_buffer, &request_len, reader.buffer[reader.start..reader.end]);
        reader.start += step.consumed;
        if (step.complete) return request_buffer[0..step.request_len];
    }
}

pub fn appendRequestChunk(request_buffer: []u8, request_len: *usize, chunk: []const u8) !RequestReadStep {
    const old_len = request_len.*;
    const room = request_buffer.len - old_len;
    const copied = @min(room, chunk.len);
    if (copied != 0) {
        @memcpy(request_buffer[old_len..][0..copied], chunk[0..copied]);
    }
    const new_len = old_len + copied;
    const search_start = if (old_len > 3) old_len - 3 else 0;
    if (std.mem.indexOf(u8, request_buffer[search_start..new_len], "\r\n\r\n")) |rel| {
        const request_end = search_start + rel + 4;
        request_len.* = request_end;
        return .{
            .complete = true,
            .request_len = request_end,
            .consumed = request_end - old_len,
        };
    }

    request_len.* = new_len;
    if (copied == room) return error.RequestTooLarge;
    return .{
        .complete = false,
        .request_len = new_len,
        .consumed = copied,
    };
}

fn servePath(
    allocator: Allocator,
    io: Io,
    root: Io.Dir,
    stream: Io.net.Stream,
    out: *Io.Writer,
    stream_writer: *Io.net.Stream.Writer,
    relative_path: []const u8,
    request_target: []const u8,
    if_none_match: ?[]const u8,
    if_modified_since: ?[]const u8,
    range_value: ?[]const u8,
    if_range: ?[]const u8,
    accept_encoding: ?[]const u8,
    is_head: bool,
    connection: []const u8,
    config: Config,
    logger: *Logger,
    cache: *CacheView,
) !ResponseResult {
    var brotli_buffer: [max_request_bytes + 3]u8 = undefined;
    var gzip_buffer: [max_request_bytes + 3]u8 = undefined;
    const choice = switch (try selectRepresentation(
        cache,
        io,
        root,
        relative_path,
        accept_encoding,
        config,
        &brotli_buffer,
        &gzip_buffer,
    )) {
        .selected => |selected| selected,
        .directory => {
            if (config.trailing_slash_redirect and !targetPathHasTrailingSlash(request_target)) {
                return sendRedirect(allocator, out, stream_writer, request_target, is_head, connection, config.headers);
            }
            const index_path = try std.fs.path.join(allocator, &.{ relative_path, "index.html" });
            defer allocator.free(index_path);
            return servePath(allocator, io, root, stream, out, stream_writer, index_path, request_target, if_none_match, if_modified_since, range_value, if_range, accept_encoding, is_head, connection, config, logger, cache);
        },
        .forbidden => return sendSimpleForMethod(out, stream_writer, .{ .code = 403, .reason = "Forbidden" }, "Forbidden\n", connection, is_head, .{}),
        .not_found => return sendSimpleForMethod(out, stream_writer, .{ .code = 404, .reason = "Not Found" }, "Not found\n", connection, is_head, .{}),
        .not_acceptable => return sendSimpleForMethod(
            out,
            stream_writer,
            .{ .code = 406, .reason = "Not Acceptable" },
            "Not acceptable\n",
            connection,
            is_head,
            .{ .vary_accept_encoding = true },
        ),
    };

    if (try cache.tryServeRepresentation(
        root,
        out,
        stream_writer,
        relative_path,
        choice.physical_path,
        choice.representation,
        if_none_match,
        if_modified_since,
        range_value,
        if_range,
        is_head,
        connection,
    )) |result| {
        return result;
    }

    var file = root.openFile(io, choice.physical_path, .{
        .mode = .read_only,
        .allow_directory = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => {
            return sendSimpleForMethod(out, stream_writer, .{ .code = 404, .reason = "Not Found" }, "Not found\n", connection, is_head, .{});
        },
        error.IsDir => {
            if (config.trailing_slash_redirect and !targetPathHasTrailingSlash(request_target)) {
                return sendRedirect(allocator, out, stream_writer, request_target, is_head, connection, config.headers);
            }
            const index_path = try std.fs.path.join(allocator, &.{ relative_path, "index.html" });
            defer allocator.free(index_path);
            return servePath(allocator, io, root, stream, out, stream_writer, index_path, request_target, if_none_match, if_modified_since, range_value, if_range, accept_encoding, is_head, connection, config, logger, cache);
        },
        error.AccessDenied => {
            return sendSimpleForMethod(out, stream_writer, .{ .code = 403, .reason = "Forbidden" }, "Forbidden\n", connection, is_head, .{});
        },
        else => return err,
    };
    defer file.close(io);

    const stat = try file.stat(io);
    if (stat.kind != .file) {
        return sendSimpleForMethod(out, stream_writer, .{ .code = 404, .reason = "Not Found" }, "Not found\n", connection, is_head, .{});
    }

    const content_type = mimeType(relative_path);
    var last_modified_buffer: [64]u8 = undefined;
    const last_modified = if (config.last_modified) formatHttpDate(stat.mtime, &last_modified_buffer) else null;
    var etag_buffer: [128]u8 = undefined;
    const etag = if (config.etag)
        formatWeakEtag(stat.mtime.nanoseconds, stat.size, representationName(choice.representation), &etag_buffer)
    else
        null;
    if (isNotModified(if_none_match, if_modified_since, etag, stat.mtime.toSeconds(), config.last_modified)) {
        try sendHeadersExtended(
            out,
            .{ .code = 304, .reason = "Not Modified" },
            content_type,
            0,
            connection,
            config.headers,
            .{
                .last_modified = last_modified,
                .etag = etag,
                .content_encoding = representationEncoding(choice.representation),
                .vary_accept_encoding = config.precompressed,
            },
        );
        try stream_writer.interface.flush();
        return .{ .status = 304, .bytes = 0 };
    }

    var selected_range: ?http.ByteRange = null;
    if (config.range_requests and ifRangeAllows(if_range, stat.mtime.toSeconds())) {
        switch (selectByteRange(range_value, stat.size)) {
            .ignore => {},
            .unsatisfiable => {
                const body = "Range not satisfiable\n";
                var content_range_buffer: [64]u8 = undefined;
                const content_range = formatUnsatisfiedContentRange(stat.size, &content_range_buffer);
                try sendHeadersExtended(
                    out,
                    .{ .code = 416, .reason = "Range Not Satisfiable" },
                    "text/plain; charset=utf-8",
                    body.len,
                    connection,
                    config.headers,
                    .{
                        .last_modified = last_modified,
                        .etag = etag,
                        .accept_ranges = true,
                        .content_range = content_range,
                        .vary_accept_encoding = config.precompressed,
                    },
                );
                if (!is_head) try out.writeAll(body);
                try stream_writer.interface.flush();
                return .{ .status = 416, .bytes = if (is_head) 0 else body.len };
            },
            .satisfiable => |range| selected_range = range,
        }
    }

    var content_range_buffer: [96]u8 = undefined;
    const content_range = if (selected_range) |range|
        formatContentRange(range, stat.size, &content_range_buffer)
    else
        null;
    const response_status: ResponseStatus = if (selected_range != null)
        .{ .code = 206, .reason = "Partial Content" }
    else
        .{ .code = 200, .reason = "OK" };
    const response_size = if (selected_range) |range| range.length() else stat.size;
    const response_offset = if (selected_range) |range| range.start else 0;

    try sendHeadersExtended(
        out,
        response_status,
        content_type,
        response_size,
        connection,
        config.headers,
        .{
            .last_modified = last_modified,
            .etag = etag,
            .accept_ranges = config.range_requests,
            .content_range = content_range,
            .content_encoding = representationEncoding(choice.representation),
            .vary_accept_encoding = config.precompressed,
        },
    );
    if (!is_head) {
        try sendFileBody(io, stream, out, stream_writer, file, response_offset, response_size, config, logger);
    }
    try stream_writer.interface.flush();
    return .{ .status = response_status.code, .bytes = if (is_head) 0 else response_size };
}

fn streamFile(io: Io, out: *Io.Writer, file: Io.File, start_offset: u64, size: u64) !void {
    var file_buffer: [64 * 1024]u8 = undefined;
    var offset = start_offset;
    var remaining = size;
    while (remaining != 0) {
        const read_len: usize = @intCast(@min(remaining, file_buffer.len));
        const count = try file.readPositionalAll(io, file_buffer[0..read_len], offset);
        if (count == 0) return error.EndOfStream;
        try out.writeAll(file_buffer[0..count]);
        offset += count;
        remaining -= count;
    }
}

pub fn selectFileTransferPath(config: Config, is_head: bool, cache_served: bool) FileTransferPath {
    if (cache_served or is_head) return .none;
    if (config.sendfile and sendfileSupportedForOs(builtin.os.tag)) return .sendfile;
    return .buffered;
}

fn sendFileBody(
    io: Io,
    stream: Io.net.Stream,
    out: *Io.Writer,
    stream_writer: *Io.net.Stream.Writer,
    file: Io.File,
    start_offset: u64,
    size: u64,
    config: Config,
    logger: *Logger,
) !void {
    if (selectFileTransferPath(config, false, false) != .sendfile) {
        try streamFile(io, out, file, start_offset, size);
        return;
    }

    try stream_writer.interface.flush();
    switch (trySendfileFrom(stream, file, start_offset, size)) {
        .sent => return,
        .fallback => |err| {
            if (isNormalDisconnect(err)) return err;
            logSendfileFallback(logger, err);
            try streamFile(io, out, file, start_offset, size);
        },
        .partial_error => |err| return err,
    }
}

fn logSendfileFallback(logger: *Logger, err: anyerror) void {
    if (sendfile_fallback_logged.cmpxchgStrong(false, true, .monotonic, .monotonic) == null) {
        logger.event("warn", "sendfile unavailable; falling back to buffered streaming: {s}", .{@errorName(err)}) catch {};
    }
}

fn sendSimple(out: *Io.Writer, stream_writer: *Io.net.Stream.Writer, status: ResponseStatus, body: []const u8, connection: []const u8) !ResponseResult {
    try sendHeaders(out, status, "text/plain; charset=utf-8", body.len, connection, null, &.{}, null, null);
    try out.writeAll(body);
    try stream_writer.interface.flush();
    return .{ .status = status.code, .bytes = body.len };
}

fn sendSimpleForMethod(
    out: *Io.Writer,
    stream_writer: *Io.net.Stream.Writer,
    status: ResponseStatus,
    body: []const u8,
    connection: []const u8,
    is_head: bool,
    options: http.ResponseHeaderOptions,
) !ResponseResult {
    try sendHeadersExtended(
        out,
        status,
        "text/plain; charset=utf-8",
        body.len,
        connection,
        &.{},
        options,
    );
    if (!is_head) try out.writeAll(body);
    try stream_writer.interface.flush();
    return .{ .status = status.code, .bytes = if (is_head) 0 else body.len };
}

fn sendRedirect(
    allocator: Allocator,
    out: *Io.Writer,
    stream_writer: *Io.net.Stream.Writer,
    request_target: []const u8,
    is_head: bool,
    connection: []const u8,
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
        connection,
        null,
        extra_headers,
        null,
        location,
    );
    if (!is_head) try out.writeAll(body);
    try stream_writer.interface.flush();
    return .{ .status = 308, .bytes = if (is_head) 0 else body.len };
}

test "event ready queue preserves order and supports removal" {
    var first = EventConnection{ .stream = undefined, .last_active = undefined };
    var second = EventConnection{ .stream = undefined, .last_active = undefined };
    var third = EventConnection{ .stream = undefined, .last_active = undefined };
    var queue = EventReadyQueue{};

    queue.enqueue(&first);
    queue.enqueue(&second);
    queue.enqueue(&third);
    queue.remove(&second);
    try std.testing.expectEqual(@as(usize, 2), queue.count);
    try std.testing.expectEqual(&first, queue.pop().?);
    try std.testing.expectEqual(&third, queue.pop().?);
    try std.testing.expect(queue.pop() == null);
}

test "event request offsets compact only when buffer space is needed" {
    var conn = EventConnection{ .stream = undefined, .last_active = undefined };
    const requests = "one\r\n\r\ntwo\r\n\r\n";
    @memcpy(conn.request_buffer[0..requests.len], requests);
    conn.request_start = 7;
    conn.request_len = requests.len;

    try std.testing.expect(hasCompleteBufferedRequest(&conn));
    compactEventRequestBuffer(&conn);
    try std.testing.expectEqual(@as(usize, 0), conn.request_start);
    try std.testing.expectEqualStrings("two\r\n\r\n", conn.request_buffer[0..conn.request_len]);
}
