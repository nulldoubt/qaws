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

pub const FileTransferPath = enum {
    none,
    buffered,
    sendfile,
};

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
    queue: *WorkerQueue,
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
    request_len: usize = 0,
    served_requests: u32 = 0,
    last_active: Io.Timestamp,
    pending: PendingEventWrite = .{},
    write_interest: bool = false,

    fn remote(self: *const EventConnection) []const u8 {
        return self.remote_buffer[0..self.remote_len];
    }

    fn hasPendingWrite(self: *const EventConnection) bool {
        return self.pending.active();
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
    access_start: Io.Timestamp = undefined,
    access_record: AccessRecord = undefined,

    pub fn active(self: *const PendingEventWrite) bool {
        return self.request_end != 0;
    }

    pub fn complete(self: *const PendingEventWrite) bool {
        return self.header_offset >= self.header.len and self.body_offset >= self.body.len;
    }
};

const ProcessRequestResult = struct {
    keep_open: bool,
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
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    const backend = comptime selectRuntimeBackend(builtin.os.tag);
    return switch (backend) {
        .worker => serveBlockingWorkers(allocator, io, config, logger, cache, &server, backend),
        .epoll, .kqueue => serveEventWorkers(allocator, io, config, logger, cache, &server, backend),
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
    const worker_count = resolveWorkerCount(config);
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

fn serveEventWorkers(
    allocator: Allocator,
    io: Io,
    config: Config,
    logger: *Logger,
    cache: *StaticCache,
    server: *Io.net.Server,
    backend: RuntimeBackend,
) !void {
    const worker_count = resolveWorkerCount(config);
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

pub fn resolveWorkerCount(config: Config) usize {
    if (config.workers > 0) return @intCast(config.workers);
    const detected = std.Thread.getCpuCount() catch 1;
    return @max(@as(usize, 1), detected);
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

    while (context.queue.pop()) |stream| {
        handleConnection(context.allocator, context.io, root, stream, context.config, context.logger, context.cache) catch |err| {
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

    try epollAdd(epoll_fd, context.wake_read_fd);

    var connections = std.AutoHashMap(std.posix.fd_t, *EventConnection).init(context.allocator);
    defer {
        closeAllEventConnections(context, &connections);
        connections.deinit();
    }

    var events: [128]std.os.linux.epoll_event = undefined;
    while (!shutdown_requested.load(.seq_cst)) {
        const count = try epollWait(epoll_fd, &events, eventWaitTimeoutMs(context.config));
        var index: usize = 0;
        while (index < count) : (index += 1) {
            const event = events[index];
            const fd = event.data.fd;
            if (fd == context.wake_read_fd) {
                drainWakeFd(context.wake_read_fd);
                try registerQueuedEpoll(context, epoll_fd, &connections);
                continue;
            }
            if ((event.events & (std.os.linux.EPOLL.ERR | std.os.linux.EPOLL.HUP | std.os.linux.EPOLL.RDHUP)) != 0) {
                closeEventConnection(context, &connections, fd);
                continue;
            }
            if (connections.get(fd)) |conn| {
                var keep_open = true;
                if ((event.events & std.os.linux.EPOLL.OUT) != 0 and conn.hasPendingWrite()) {
                    keep_open = flushEventPendingWrite(context, conn) catch |err| blk: {
                        if (!isNormalDisconnect(err)) {
                            context.logger.event("error", "event response write failed: {s}", .{@errorName(err)}) catch {};
                        }
                        break :blk false;
                    };
                }
                if (keep_open and (event.events & std.os.linux.EPOLL.IN) != 0 and !conn.hasPendingWrite()) {
                    keep_open = processEventConnection(context, root, conn) catch |err| blk: {
                        if (!isNormalDisconnect(err)) {
                            context.logger.event("error", "event connection failed: {s}", .{@errorName(err)}) catch {};
                        }
                        break :blk false;
                    };
                }
                if (!keep_open) {
                    closeEventConnection(context, &connections, fd);
                } else {
                    syncEpollWriteInterest(epoll_fd, conn) catch |err| {
                        context.logger.event("error", "epoll write interest failed: {s}", .{@errorName(err)}) catch {};
                        closeEventConnection(context, &connections, fd);
                    };
                }
            }
        }
        try registerQueuedEpoll(context, epoll_fd, &connections);
        closeExpiredEventConnections(context, &connections);
    }
}

fn eventWorkerLoopKqueue(context: *EventWorkerContext, root: Io.Dir) !void {
    const kq_fd = try kqueueCreate();
    defer closeFd(kq_fd);

    try kqueueAdd(kq_fd, context.wake_read_fd);

    var connections = std.AutoHashMap(std.posix.fd_t, *EventConnection).init(context.allocator);
    defer {
        closeAllEventConnections(context, &connections);
        connections.deinit();
    }

    var events: [128]std.posix.Kevent = undefined;
    while (!shutdown_requested.load(.seq_cst)) {
        const count = try kqueueWait(kq_fd, &events, eventWaitTimeoutMs(context.config));
        var index: usize = 0;
        while (index < count) : (index += 1) {
            const event = events[index];
            const fd: std.posix.fd_t = @intCast(event.udata);
            if (fd == context.wake_read_fd) {
                drainWakeFd(context.wake_read_fd);
                try registerQueuedKqueue(context, kq_fd, &connections);
                continue;
            }
            if ((event.flags & std.c.EV.ERROR) != 0) {
                closeEventConnection(context, &connections, fd);
                continue;
            }
            if (connections.get(fd)) |conn| {
                var keep_open = true;
                if (event.filter == std.c.EVFILT.WRITE and conn.hasPendingWrite()) {
                    keep_open = flushEventPendingWrite(context, conn) catch |err| blk: {
                        if (!isNormalDisconnect(err)) {
                            context.logger.event("error", "event response write failed: {s}", .{@errorName(err)}) catch {};
                        }
                        break :blk false;
                    };
                }
                if (keep_open and event.filter == std.c.EVFILT.READ and !conn.hasPendingWrite()) {
                    keep_open = processEventConnection(context, root, conn) catch |err| blk: {
                        if (!isNormalDisconnect(err)) {
                            context.logger.event("error", "event connection failed: {s}", .{@errorName(err)}) catch {};
                        }
                        break :blk false;
                    };
                }
                if (!keep_open) {
                    closeEventConnection(context, &connections, fd);
                } else {
                    syncKqueueWriteInterest(kq_fd, conn) catch |err| {
                        context.logger.event("error", "kqueue write interest failed: {s}", .{@errorName(err)}) catch {};
                        closeEventConnection(context, &connections, fd);
                    };
                }
            }
        }
        try registerQueuedKqueue(context, kq_fd, &connections);
        closeExpiredEventConnections(context, &connections);
    }
}

fn registerQueuedEpoll(
    context: *EventWorkerContext,
    epoll_fd: std.posix.fd_t,
    connections: *std.AutoHashMap(std.posix.fd_t, *EventConnection),
) !void {
    while (context.queue.popAvailable()) |stream| {
        const fd = stream.socket.handle;
        const conn = createEventConnection(context, stream) catch |err| {
            context.logger.event("error", "event connection allocation failed: {s}", .{@errorName(err)}) catch {};
            stream.close(context.io);
            releaseConnection(context.active_connections);
            continue;
        };
        connections.put(fd, conn) catch |err| {
            destroyEventConnection(context, conn);
            return err;
        };
        epollAdd(epoll_fd, fd) catch |err| {
            closeEventConnection(context, connections, fd);
            context.logger.event("error", "epoll registration failed: {s}", .{@errorName(err)}) catch {};
            continue;
        };
    }
}

fn registerQueuedKqueue(
    context: *EventWorkerContext,
    kq_fd: std.posix.fd_t,
    connections: *std.AutoHashMap(std.posix.fd_t, *EventConnection),
) !void {
    while (context.queue.popAvailable()) |stream| {
        const fd = stream.socket.handle;
        const conn = createEventConnection(context, stream) catch |err| {
            context.logger.event("error", "event connection allocation failed: {s}", .{@errorName(err)}) catch {};
            stream.close(context.io);
            releaseConnection(context.active_connections);
            continue;
        };
        connections.put(fd, conn) catch |err| {
            destroyEventConnection(context, conn);
            return err;
        };
        kqueueAdd(kq_fd, fd) catch |err| {
            closeEventConnection(context, connections, fd);
            context.logger.event("error", "kqueue registration failed: {s}", .{@errorName(err)}) catch {};
            continue;
        };
    }
}

fn createEventConnection(context: *EventWorkerContext, stream: Io.net.Stream) !*EventConnection {
    const conn = try context.allocator.create(EventConnection);
    conn.* = .{
        .stream = stream,
        .last_active = Io.Timestamp.now(context.io, .awake),
    };
    const remote = formatRemoteAddress(stream.socket.address, &conn.remote_buffer);
    conn.remote_len = remote.len;
    return conn;
}

fn destroyEventConnection(context: *EventWorkerContext, conn: *EventConnection) void {
    conn.stream.close(context.io);
    releaseConnection(context.active_connections);
    context.allocator.destroy(conn);
}

fn closeEventConnection(
    context: *EventWorkerContext,
    connections: *std.AutoHashMap(std.posix.fd_t, *EventConnection),
    fd: std.posix.fd_t,
) void {
    if (connections.fetchRemove(fd)) |entry| {
        destroyEventConnection(context, entry.value);
    }
}

fn closeAllEventConnections(
    context: *EventWorkerContext,
    connections: *std.AutoHashMap(std.posix.fd_t, *EventConnection),
) void {
    var values = connections.valueIterator();
    while (values.next()) |conn| {
        destroyEventConnection(context, conn.*);
    }
    connections.clearRetainingCapacity();
}

fn closeExpiredEventConnections(
    context: *EventWorkerContext,
    connections: *std.AutoHashMap(std.posix.fd_t, *EventConnection),
) void {
    const now = Io.Timestamp.now(context.io, .awake);
    while (true) {
        var expired: ?std.posix.fd_t = null;
        var iterator = connections.iterator();
        while (iterator.next()) |entry| {
            if (eventConnectionExpired(entry.value_ptr.*, now, context.config)) {
                expired = entry.key_ptr.*;
                break;
            }
        }
        closeEventConnection(context, connections, expired orelse return);
    }
}

pub fn eventConnectionExpired(conn: *const EventConnection, now: Io.Timestamp, config: Config) bool {
    if (conn.hasPendingWrite()) return false;
    const idle_ms = conn.last_active.durationTo(now).toMilliseconds();
    return idle_ms >= config.keep_alive_timeout_ms;
}

fn processEventConnection(context: *EventWorkerContext, root: Io.Dir, conn: *EventConnection) !bool {
    if (conn.hasPendingWrite()) return flushEventPendingWrite(context, conn);

    while (true) {
        if (conn.request_len == conn.request_buffer.len) {
            if (std.mem.indexOf(u8, conn.request_buffer[0..conn.request_len], "\r\n\r\n") == null) {
                try sendEventRequestError(context, root, conn, .{ .code = 413, .reason = "Payload Too Large" }, "Request too large\n");
                return false;
            }
            break;
        }
        const n = readFd(conn.stream.socket.handle, conn.request_buffer[conn.request_len..]) catch |err| switch (err) {
            error.WouldBlock => break,
            error.ConnectionResetByPeer, error.SocketUnconnected => return false,
            else => return err,
        };
        if (n == 0) return false;
        conn.request_len += n;
        conn.last_active = Io.Timestamp.now(context.io, .awake);
    }

    var processed_this_tick: usize = 0;
    while (std.mem.indexOf(u8, conn.request_buffer[0..conn.request_len], "\r\n\r\n")) |header_end_rel| {
        if (shutdown_requested.load(.seq_cst)) return false;
        if (processed_this_tick >= event_request_batch_limit) return true;

        const request_end = header_end_rel + 4;
        const request_bytes = conn.request_buffer[0..request_end];
        const request = parseRequest(request_bytes) catch {
            try sendEventRequestError(context, root, conn, .{ .code = 400, .reason = "Bad Request" }, "Bad request\n");
            return false;
        };

        const current_request_count = conn.served_requests + 1;
        if (try tryServeCachedEventFastPath(context, root, conn, request, request_end, current_request_count, Io.Timestamp.now(context.io, .awake))) |keep_open| {
            processed_this_tick += 1;
            if (!keep_open) return false;
            if (conn.hasPendingWrite()) return true;
            continue;
        }

        try setFdNonblocking(conn.stream.socket.handle, false);
        var writer_buffer: [8192]u8 = undefined;
        var writer = conn.stream.writer(context.io, &writer_buffer);
        const out = &writer.interface;
        const result = try processParsedRequest(
            context.allocator,
            context.io,
            root,
            conn.stream,
            out,
            &writer,
            request,
            conn.remote(),
            context.config,
            context.logger,
            context.cache,
            current_request_count,
            Io.Timestamp.now(context.io, .awake),
        );

        const remaining = conn.request_len - request_end;
        if (remaining != 0) {
            std.mem.copyForwards(u8, conn.request_buffer[0..remaining], conn.request_buffer[request_end..conn.request_len]);
        }
        conn.request_len = remaining;
        conn.served_requests = current_request_count;
        conn.last_active = Io.Timestamp.now(context.io, .awake);

        if (!result.keep_open) return false;
        try setFdNonblocking(conn.stream.socket.handle, true);
        processed_this_tick += 1;
    }

    if (conn.request_len == conn.request_buffer.len) {
        try sendEventRequestError(context, root, conn, .{ .code = 413, .reason = "Payload Too Large" }, "Request too large\n");
        return false;
    }
    return true;
}

fn tryServeCachedEventFastPath(
    context: *EventWorkerContext,
    root: Io.Dir,
    conn: *EventConnection,
    request: Request,
    request_end: usize,
    current_request_count: u32,
    start: Io.Timestamp,
) !?bool {
    if (request.has_request_body) return null;

    const is_head = std.mem.eql(u8, request.method, "HEAD");
    if (!is_head and !std.mem.eql(u8, request.method, "GET")) return null;

    const relative_path = normalizeTargetFast(request.target, context.config.dotfiles) orelse return null;
    const keep_open = requestWantsKeepAlive(request, context.config, current_request_count);
    const response_connection = if (keep_open) "keep-alive" else "close";
    const cached = try context.cache.tryPrepareEventResponse(
        context.io,
        root,
        relative_path,
        request.if_modified_since,
        is_head,
        response_connection,
    ) orelse return null;

    conn.pending = .{
        .header = cached.header,
        .body = cached.body,
        .request_end = request_end,
        .served_requests_after = current_request_count,
        .keep_open = keep_open,
        .access_start = start,
        .access_record = .{
            .remote = conn.remote(),
            .method = request.method,
            .target = request.target,
            .status = cached.status,
            .bytes = cached.bytes,
            .duration_us = 0,
            .user_agent = request.user_agent,
        },
    };

    return try flushEventPendingWrite(context, conn);
}

fn flushEventPendingWrite(context: *EventWorkerContext, conn: *EventConnection) !bool {
    while (conn.pending.active() and !conn.pending.complete()) {
        const n = writePendingFd(conn.stream.socket.handle, &conn.pending) catch |err| switch (err) {
            error.WouldBlock => return true,
            error.BrokenPipe, error.ConnectionResetByPeer, error.SocketUnconnected, error.ConnectionAborted => return false,
            else => return err,
        };
        if (n == 0) return true;
        advancePendingWrite(&conn.pending, n);
    }

    if (!conn.pending.active()) return true;
    if (!conn.pending.complete()) return true;
    return finishEventPendingWrite(context, conn);
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

fn finishEventPendingWrite(context: *EventWorkerContext, conn: *EventConnection) bool {
    var pending = conn.pending;
    finishAccessLog(context.logger, context.io, pending.access_start, &pending.access_record);

    const remaining = conn.request_len - pending.request_end;
    if (remaining != 0) {
        std.mem.copyForwards(u8, conn.request_buffer[0..remaining], conn.request_buffer[pending.request_end..conn.request_len]);
    }
    conn.request_len = remaining;
    conn.served_requests = pending.served_requests_after;
    conn.last_active = Io.Timestamp.now(context.io, .awake);
    conn.pending = .{};
    return pending.keep_open;
}

fn sendEventRequestError(
    context: *EventWorkerContext,
    root: Io.Dir,
    conn: *EventConnection,
    status: ResponseStatus,
    body: []const u8,
) !void {
    _ = root;
    try setFdNonblocking(conn.stream.socket.handle, false);
    var writer_buffer: [1024]u8 = undefined;
    var writer = conn.stream.writer(context.io, &writer_buffer);
    try sendRequestError(
        context.io,
        context.logger,
        &writer.interface,
        &writer,
        conn.remote(),
        status,
        body,
        Io.Timestamp.now(context.io, .awake),
    );
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
    try epollSetWriteInterest(epoll_fd, conn.stream.socket.handle, enabled);
    conn.write_interest = enabled;
}

fn syncKqueueWriteInterest(kq_fd: std.posix.fd_t, conn: *EventConnection) !void {
    const enabled = conn.hasPendingWrite();
    if (conn.write_interest == enabled) return;
    try kqueueSetWriteInterest(kq_fd, conn.stream.socket.handle, enabled);
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

fn handleConnection(allocator: Allocator, io: Io, root: Io.Dir, stream: Io.net.Stream, config: Config, logger: *Logger, cache: *StaticCache) !void {
    defer stream.close(io);

    var remote_buffer: [128]u8 = undefined;
    const remote = formatRemoteAddress(stream.socket.address, &remote_buffer);

    var reader_buffer: [4096]u8 = undefined;
    var reader = ConnectionReader.init(io, stream, &reader_buffer);
    var request_buffer: [max_request_bytes]u8 = undefined;
    var writer_buffer: [8192]u8 = undefined;
    var writer = stream.writer(io, &writer_buffer);
    const out = &writer.interface;
    var served_requests: u32 = 0;

    while (!shutdown_requested.load(.seq_cst)) {
        const start = Io.Timestamp.now(io, .awake);
        var access_record = AccessRecord{
            .remote = remote,
            .method = "-",
            .target = "-",
            .status = 500,
            .bytes = 0,
            .duration_us = 0,
            .user_agent = null,
        };

        const request_bytes = readHttpRequest(&reader, keepAliveTimeout(config), &request_buffer) catch |err| switch (err) {
            error.Timeout, error.EndOfStream, error.ConnectionResetByPeer, error.SocketUnconnected => return,
            error.RequestTooLarge => {
                const result = try sendSimple(out, &writer, .{ .code = 413, .reason = "Payload Too Large" }, "Request too large\n", "close");
                access_record.status = result.status;
                access_record.bytes = result.bytes;
                finishAccessLog(logger, io, start, &access_record);
                return;
            },
            else => {
                const result = try sendSimple(out, &writer, .{ .code = 400, .reason = "Bad Request" }, "Bad request\n", "close");
                access_record.status = result.status;
                access_record.bytes = result.bytes;
                finishAccessLog(logger, io, start, &access_record);
                return;
            },
        };

        const request = parseRequest(request_bytes) catch {
            const result = try sendSimple(out, &writer, .{ .code = 400, .reason = "Bad Request" }, "Bad request\n", "close");
            access_record.status = result.status;
            access_record.bytes = result.bytes;
            finishAccessLog(logger, io, start, &access_record);
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
    cache: *StaticCache,
    current_request_count: u32,
    start: Io.Timestamp,
) !ProcessRequestResult {
    var access_record = AccessRecord{
        .remote = remote,
        .method = request.method,
        .target = request.target,
        .status = 500,
        .bytes = 0,
        .duration_us = 0,
        .user_agent = request.user_agent,
    };

    var keep_open = requestWantsKeepAlive(request, config, current_request_count);
    const response_connection = if (keep_open) "keep-alive" else "close";

    if (request.has_request_body) {
        const result = try sendSimple(out, stream_writer, .{ .code = 400, .reason = "Bad Request" }, "Bad request\n", "close");
        access_record.status = result.status;
        access_record.bytes = result.bytes;
        finishAccessLog(logger, io, start, &access_record);
        return .{ .keep_open = false };
    }

    const is_head = std.mem.eql(u8, request.method, "HEAD");
    if (!is_head and !std.mem.eql(u8, request.method, "GET")) {
        keep_open = false;
        try sendHeaders(out, .{ .code = 405, .reason = "Method Not Allowed" }, "text/plain; charset=utf-8", 19, "close", "GET, HEAD", &.{}, null, null);
        try out.writeAll("Method not allowed\n");
        try stream_writer.interface.flush();
        access_record.status = 405;
        access_record.bytes = 19;
        finishAccessLog(logger, io, start, &access_record);
        return .{ .keep_open = false };
    }

    var relative_path_owned: ?[]u8 = null;
    defer if (relative_path_owned) |path| allocator.free(path);
    const relative_path = normalizeTargetFast(request.target, config.dotfiles) orelse blk: {
        relative_path_owned = normalizeTarget(allocator, request.target, config.dotfiles) catch {
            const result = try sendSimple(out, stream_writer, .{ .code = 403, .reason = "Forbidden" }, "Forbidden\n", response_connection);
            access_record.status = result.status;
            access_record.bytes = result.bytes;
            finishAccessLog(logger, io, start, &access_record);
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
        request.if_modified_since,
        is_head,
        response_connection,
        config,
        logger,
        cache,
    );
    access_record.status = result.status;
    access_record.bytes = result.bytes;
    finishAccessLog(logger, io, start, &access_record);
    return .{ .keep_open = keep_open };
}

fn sendRequestError(
    io: Io,
    logger: *Logger,
    out: *Io.Writer,
    stream_writer: *Io.net.Stream.Writer,
    remote: []const u8,
    status: ResponseStatus,
    body: []const u8,
    start: Io.Timestamp,
) !void {
    var access_record = AccessRecord{
        .remote = remote,
        .method = "-",
        .target = "-",
        .status = status.code,
        .bytes = 0,
        .duration_us = 0,
        .user_agent = null,
    };
    const result = try sendSimple(out, stream_writer, status, body, "close");
    access_record.status = result.status;
    access_record.bytes = result.bytes;
    finishAccessLog(logger, io, start, &access_record);
}

fn finishAccessLog(logger: *Logger, io: Io, start: Io.Timestamp, record: *AccessRecord) void {
    const end = Io.Timestamp.now(io, .awake);
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
    if_modified_since: ?[]const u8,
    is_head: bool,
    connection: []const u8,
    config: Config,
    logger: *Logger,
    cache: *StaticCache,
) !ResponseResult {
    if (try cache.tryServe(io, root, out, stream_writer, relative_path, if_modified_since, is_head, connection)) |result| {
        return result;
    }

    var file = root.openFile(io, relative_path, .{
        .mode = .read_only,
        .allow_directory = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => {
            return sendSimple(out, stream_writer, .{ .code = 404, .reason = "Not Found" }, "Not found\n", connection);
        },
        error.IsDir => {
            if (config.trailing_slash_redirect and !targetPathHasTrailingSlash(request_target)) {
                return sendRedirect(allocator, out, stream_writer, request_target, is_head, connection, config.headers);
            }
            const index_path = try std.fs.path.join(allocator, &.{ relative_path, "index.html" });
            defer allocator.free(index_path);
            return servePath(allocator, io, root, stream, out, stream_writer, index_path, request_target, if_modified_since, is_head, connection, config, logger, cache);
        },
        error.AccessDenied => {
            return sendSimple(out, stream_writer, .{ .code = 403, .reason = "Forbidden" }, "Forbidden\n", connection);
        },
        else => return err,
    };
    defer file.close(io);

    const stat = try file.stat(io);
    if (stat.kind != .file) {
        return sendSimple(out, stream_writer, .{ .code = 404, .reason = "Not Found" }, "Not found\n", connection);
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
                        connection,
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

    try sendHeaders(out, .{ .code = 200, .reason = "OK" }, content_type, stat.size, connection, null, config.headers, last_modified, null);
    if (!is_head) {
        try sendFileBody(io, stream, out, stream_writer, file, stat.size, config, logger);
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
    size: u64,
    config: Config,
    logger: *Logger,
) !void {
    if (selectFileTransferPath(config, false, false) != .sendfile) {
        try streamFile(io, out, file);
        return;
    }

    try stream_writer.interface.flush();
    switch (trySendfile(stream, file, size)) {
        .sent => return,
        .fallback => |err| {
            if (isNormalDisconnect(err)) return err;
            logSendfileFallback(logger, err);
            try streamFile(io, out, file);
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
