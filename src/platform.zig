const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;

pub const SendfileResult = union(enum) {
    sent: u64,
    fallback: anyerror,
    partial_error: anyerror,
};

pub const RuntimeBackend = enum {
    worker,
    epoll,
    kqueue,
};

pub const WakePipe = struct {
    read: std.posix.fd_t,
    write: std.posix.fd_t,
};

pub fn selectRuntimeBackend(os_tag: std.Target.Os.Tag) RuntimeBackend {
    return switch (os_tag) {
        .linux => .epoll,
        .macos, .freebsd => .kqueue,
        else => .worker,
    };
}

pub fn runtimeBackendName(backend: RuntimeBackend) []const u8 {
    return switch (backend) {
        .worker => "worker",
        .epoll => "epoll",
        .kqueue => "kqueue",
    };
}

pub fn detectPerformanceCpuCount(io: Io) usize {
    const logical_count = @max(@as(usize, 1), std.Thread.getCpuCount() catch 1);
    return switch (builtin.os.tag) {
        .linux => detectLinuxPerformanceCpuCount(io, logical_count) orelse logical_count,
        .macos => detectMacPerformanceCpuCount() orelse logical_count,
        else => logical_count,
    };
}

pub fn highestCapacityCpuCount(capacities: []const u32) usize {
    var highest: u32 = 0;
    var count: usize = 0;
    for (capacities) |capacity| {
        if (capacity > highest) {
            highest = capacity;
            count = 1;
        } else if (capacity == highest and capacity != 0) {
            count += 1;
        }
    }
    return count;
}

fn detectLinuxPerformanceCpuCount(io: Io, logical_count: usize) ?usize {
    var capacities: [1024]u32 = undefined;
    const count = @min(logical_count, capacities.len);
    var found: usize = 0;

    for (0..count) |cpu| {
        var path_buffer: [96]u8 = undefined;
        const path = std.fmt.bufPrint(
            &path_buffer,
            "/sys/devices/system/cpu/cpu{d}/cpu_capacity",
            .{cpu},
        ) catch return null;
        var value_buffer: [32]u8 = undefined;
        const value = Io.Dir.cwd().readFile(io, path, &value_buffer) catch continue;
        const capacity = std.fmt.parseInt(u32, std.mem.trim(u8, value, &std.ascii.whitespace), 10) catch continue;
        if (capacity == 0) continue;
        capacities[found] = capacity;
        found += 1;
    }

    if (found == 0) return null;
    const selected = highestCapacityCpuCount(capacities[0..found]);
    return if (selected == 0) null else selected;
}

fn detectMacPerformanceCpuCount() ?usize {
    if (comptime builtin.os.tag != .macos) return null;

    var count: c_int = 0;
    var count_len: usize = @sizeOf(c_int);
    const rc = std.posix.system.sysctlbyname(
        "hw.perflevel0.logicalcpu",
        &count,
        &count_len,
        null,
        0,
    );
    if (std.posix.errno(rc) != .SUCCESS or count <= 0) return null;
    return @intCast(count);
}

pub fn createWakePipe() !WakePipe {
    return switch (builtin.os.tag) {
        .linux => blk: {
            var fds: [2]i32 = undefined;
            const rc = std.os.linux.pipe2(&fds, .{ .NONBLOCK = true, .CLOEXEC = true });
            switch (std.os.linux.errno(rc)) {
                .SUCCESS => break :blk .{ .read = fds[0], .write = fds[1] },
                .MFILE => return error.ProcessFdQuotaExceeded,
                .NFILE => return error.SystemFdQuotaExceeded,
                else => return error.Unexpected,
            }
        },
        else => blk: {
            var fds: [2]std.c.fd_t = undefined;
            if (std.c.pipe(&fds) != 0) return error.Unexpected;
            errdefer {
                closeFd(fds[0]);
                closeFd(fds[1]);
            }
            try setFdNonblocking(fds[0], true);
            try setFdNonblocking(fds[1], true);
            try setFdCloseOnExec(fds[0]);
            try setFdCloseOnExec(fds[1]);
            break :blk .{ .read = fds[0], .write = fds[1] };
        },
    };
}

pub fn closeWakePipe(pipe: WakePipe) void {
    closeFd(pipe.read);
    closeFd(pipe.write);
}

pub fn wakeFd(fd: std.posix.fd_t) !void {
    const byte: [1]u8 = .{1};
    _ = writeFd(fd, &byte) catch |err| switch (err) {
        error.WouldBlock => return,
        else => return err,
    };
}

pub fn drainWakeFd(fd: std.posix.fd_t) void {
    var buffer: [64]u8 = undefined;
    while (true) {
        const n = readFd(fd, &buffer) catch |err| switch (err) {
            error.WouldBlock => return,
            else => return,
        };
        if (n == 0 or n < buffer.len) return;
    }
}

pub fn readFd(fd: std.posix.fd_t, buffer: []u8) !usize {
    return std.posix.read(fd, buffer);
}

pub fn writeFd(fd: std.posix.fd_t, bytes: []const u8) !usize {
    if (bytes.len == 0) return 0;
    return switch (builtin.os.tag) {
        .linux => while (true) {
            const rc = std.os.linux.write(fd, bytes.ptr, bytes.len);
            switch (std.os.linux.errno(rc)) {
                .SUCCESS => return @intCast(rc),
                .INTR => continue,
                .AGAIN => return error.WouldBlock,
                .BADF => return error.Unexpected,
                .PIPE => return error.BrokenPipe,
                .CONNRESET => return error.ConnectionResetByPeer,
                .NOTCONN => return error.SocketUnconnected,
                .CONNABORTED => return error.ConnectionAborted,
                else => return error.Unexpected,
            }
        },
        else => while (true) {
            const rc = std.c.write(fd, bytes.ptr, bytes.len);
            switch (std.posix.errno(rc)) {
                .SUCCESS => return @intCast(rc),
                .INTR => continue,
                .AGAIN => return error.WouldBlock,
                .BADF => return error.Unexpected,
                .PIPE => return error.BrokenPipe,
                .CONNRESET => return error.ConnectionResetByPeer,
                .NOTCONN => return error.SocketUnconnected,
                .CONNABORTED => return error.ConnectionAborted,
                else => return error.Unexpected,
            }
        },
    };
}

pub fn writevFd(fd: std.posix.fd_t, iovecs: []const std.posix.iovec_const) !usize {
    if (iovecs.len == 0) return 0;
    return switch (builtin.os.tag) {
        .linux => while (true) {
            const rc = std.os.linux.writev(fd, iovecs.ptr, iovecs.len);
            switch (std.os.linux.errno(rc)) {
                .SUCCESS => return @intCast(rc),
                .INTR => continue,
                .AGAIN => return error.WouldBlock,
                .BADF => return error.Unexpected,
                .PIPE => return error.BrokenPipe,
                .CONNRESET => return error.ConnectionResetByPeer,
                .NOTCONN => return error.SocketUnconnected,
                .CONNABORTED => return error.ConnectionAborted,
                else => return error.Unexpected,
            }
        },
        else => while (true) {
            const rc = std.c.writev(fd, iovecs.ptr, @intCast(iovecs.len));
            switch (std.posix.errno(rc)) {
                .SUCCESS => return @intCast(rc),
                .INTR => continue,
                .AGAIN => return error.WouldBlock,
                .BADF => return error.Unexpected,
                .PIPE => return error.BrokenPipe,
                .CONNRESET => return error.ConnectionResetByPeer,
                .NOTCONN => return error.SocketUnconnected,
                .CONNABORTED => return error.ConnectionAborted,
                else => return error.Unexpected,
            }
        },
    };
}

pub fn isNormalDisconnect(err: anyerror) bool {
    return switch (err) {
        error.BrokenPipe,
        error.ConnectionResetByPeer,
        error.SocketUnconnected,
        error.ConnectionAborted,
        error.EndOfStream,
        => true,
        else => false,
    };
}

pub fn closeFd(fd: std.posix.fd_t) void {
    switch (builtin.os.tag) {
        .linux => _ = std.os.linux.close(fd),
        else => _ = std.c.close(fd),
    }
}

pub fn setFdNonblocking(fd: std.posix.fd_t, enabled: bool) !void {
    const get_rc = std.posix.system.fcntl(fd, std.posix.F.GETFL, @as(usize, 0));
    switch (std.posix.errno(get_rc)) {
        .SUCCESS => {},
        else => return error.Unexpected,
    }
    var flags: std.posix.O = @bitCast(@as(u32, @intCast(get_rc)));
    flags.NONBLOCK = enabled;
    const flag_bits: u32 = @bitCast(flags);
    const set_rc = std.posix.system.fcntl(fd, std.posix.F.SETFL, @as(usize, flag_bits));
    switch (std.posix.errno(set_rc)) {
        .SUCCESS => {},
        else => return error.Unexpected,
    }
}

pub fn setFdCloseOnExec(fd: std.posix.fd_t) !void {
    const get_rc = std.posix.system.fcntl(fd, std.posix.F.GETFD, @as(usize, 0));
    switch (std.posix.errno(get_rc)) {
        .SUCCESS => {},
        else => return error.Unexpected,
    }
    const flags = @as(usize, @intCast(get_rc)) | std.posix.FD_CLOEXEC;
    const set_rc = std.posix.system.fcntl(fd, std.posix.F.SETFD, flags);
    switch (std.posix.errno(set_rc)) {
        .SUCCESS => {},
        else => return error.Unexpected,
    }
}

pub fn epollCreate() !std.posix.fd_t {
    const rc = std.os.linux.epoll_create1(std.os.linux.EPOLL.CLOEXEC);
    switch (std.os.linux.errno(rc)) {
        .SUCCESS => return @intCast(rc),
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        .NOMEM => return error.SystemResources,
        else => return error.Unexpected,
    }
}

pub fn epollAdd(epoll_fd: std.posix.fd_t, fd: std.posix.fd_t) !void {
    var event = std.os.linux.epoll_event{
        .events = epollConnectionEvents(false),
        .data = .{ .fd = fd },
    };
    const rc = std.os.linux.epoll_ctl(epoll_fd, std.os.linux.EPOLL.CTL_ADD, fd, &event);
    switch (std.os.linux.errno(rc)) {
        .SUCCESS => {},
        else => return error.Unexpected,
    }
}

pub fn epollSetWriteInterest(epoll_fd: std.posix.fd_t, fd: std.posix.fd_t, enabled: bool) !void {
    var event = std.os.linux.epoll_event{
        .events = epollConnectionEvents(enabled),
        .data = .{ .fd = fd },
    };
    const rc = std.os.linux.epoll_ctl(epoll_fd, std.os.linux.EPOLL.CTL_MOD, fd, &event);
    switch (std.os.linux.errno(rc)) {
        .SUCCESS => {},
        else => return error.Unexpected,
    }
}

fn epollConnectionEvents(write_enabled: bool) u32 {
    var events: u32 = std.os.linux.EPOLL.IN | std.os.linux.EPOLL.ERR | std.os.linux.EPOLL.HUP | std.os.linux.EPOLL.RDHUP;
    if (write_enabled) events |= std.os.linux.EPOLL.OUT;
    return events;
}

pub fn epollWait(epoll_fd: std.posix.fd_t, events: []std.os.linux.epoll_event, timeout_ms: i32) !usize {
    while (true) {
        const rc = std.os.linux.epoll_wait(epoll_fd, events.ptr, @intCast(events.len), timeout_ms);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            else => return error.Unexpected,
        }
    }
}

pub fn kqueueCreate() !std.posix.fd_t {
    while (true) {
        const rc = std.posix.system.kqueue();
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            else => return error.Unexpected,
        }
    }
}

pub fn kqueueAdd(kq_fd: std.posix.fd_t, fd: std.posix.fd_t) !void {
    var changes = [_]std.posix.Kevent{.{
        .ident = @intCast(fd),
        .filter = std.c.EVFILT.READ,
        .flags = std.c.EV.ADD | std.c.EV.ENABLE,
        .fflags = 0,
        .data = 0,
        .udata = @intCast(fd),
    }};
    var ignored: [1]std.posix.Kevent = undefined;
    const rc = std.posix.system.kevent(kq_fd, changes[0..].ptr, @intCast(changes.len), &ignored, 0, null);
    switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        .INTR => return kqueueAdd(kq_fd, fd),
        else => return error.Unexpected,
    }
}

pub fn kqueueSetWriteInterest(kq_fd: std.posix.fd_t, fd: std.posix.fd_t, enabled: bool) !void {
    var changes = [_]std.posix.Kevent{.{
        .ident = @intCast(fd),
        .filter = std.c.EVFILT.WRITE,
        .flags = if (enabled) std.c.EV.ADD | std.c.EV.ENABLE else std.c.EV.DELETE,
        .fflags = 0,
        .data = 0,
        .udata = @intCast(fd),
    }};
    var ignored: [1]std.posix.Kevent = undefined;
    const rc = std.posix.system.kevent(kq_fd, changes[0..].ptr, @intCast(changes.len), &ignored, 0, null);
    switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        .INTR => return kqueueSetWriteInterest(kq_fd, fd, enabled),
        .NOENT => if (!enabled) return,
        else => return error.Unexpected,
    }
}

pub fn kqueueWait(kq_fd: std.posix.fd_t, events: []std.posix.Kevent, timeout_ms: i32) !usize {
    var timeout = std.posix.timespec{
        .sec = @divTrunc(timeout_ms, 1000),
        .nsec = @intCast(@mod(timeout_ms, 1000) * std.time.ns_per_ms),
    };
    while (true) {
        const rc = std.posix.system.kevent(kq_fd, undefined, 0, events.ptr, @intCast(events.len), &timeout);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            else => return error.Unexpected,
        }
    }
}

pub fn sendfileSupportedForOs(os_tag: std.Target.Os.Tag) bool {
    return switch (os_tag) {
        .linux, .macos, .freebsd => true,
        else => false,
    };
}

pub fn trySendfile(stream: Io.net.Stream, file: Io.File, size: u64) SendfileResult {
    if (size == 0) return .{ .sent = 0 };
    return switch (builtin.os.tag) {
        .linux => trySendfileLinux(stream, file, size),
        .macos => trySendfileDarwin(stream, file, size),
        .freebsd => trySendfileFreebsd(stream, file, size),
        else => .{ .fallback = error.SendfileUnsupported },
    };
}

fn fallbackOrPartial(sent: u64, err: anyerror) SendfileResult {
    if (sent == 0) return .{ .fallback = err };
    return .{ .partial_error = err };
}

fn trySendfileLinux(stream: Io.net.Stream, file: Io.File, size: u64) SendfileResult {
    var offset: i64 = 0;
    var sent: u64 = 0;
    var remaining = size;
    while (remaining != 0) {
        const chunk = @min(remaining, @as(u64, 1 << 30));
        const rc = std.os.linux.sendfile(stream.socket.handle, file.handle, &offset, @intCast(chunk));
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => {
                const n: u64 = @intCast(rc);
                if (n == 0) break;
                sent += n;
                remaining -= n;
            },
            .INTR => continue,
            .AGAIN => return fallbackOrPartial(sent, error.SendfileWouldBlock),
            .INVAL, .NOSYS, .OPNOTSUPP, .NOTSOCK => return fallbackOrPartial(sent, error.SendfileUnsupported),
            .PIPE => return fallbackOrPartial(sent, error.BrokenPipe),
            .CONNRESET => return fallbackOrPartial(sent, error.ConnectionResetByPeer),
            .NOTCONN => return fallbackOrPartial(sent, error.SocketUnconnected),
            .CONNABORTED => return fallbackOrPartial(sent, error.ConnectionAborted),
            else => return fallbackOrPartial(sent, error.SendfileFailed),
        }
    }
    return .{ .sent = sent };
}

fn trySendfileDarwin(stream: Io.net.Stream, file: Io.File, size: u64) SendfileResult {
    var offset: std.c.off_t = 0;
    var sent: u64 = 0;
    var remaining = size;
    while (remaining != 0) {
        const chunk = @min(remaining, @as(u64, @intCast(std.math.maxInt(i32))));
        var len: std.c.off_t = @intCast(chunk);
        const rc = std.c.sendfile(file.handle, stream.socket.handle, offset, &len, null, 0);
        const transferred: u64 = if (len > 0) @intCast(len) else 0;
        switch (std.posix.errno(rc)) {
            .SUCCESS => {},
            .INTR => if (transferred == 0) continue,
            .AGAIN => if (transferred == 0) return fallbackOrPartial(sent, error.SendfileWouldBlock),
            .INVAL, .OPNOTSUPP, .NOTSOCK, .NOSYS => return fallbackOrPartial(sent, error.SendfileUnsupported),
            .PIPE => return fallbackOrPartial(sent, error.BrokenPipe),
            .CONNRESET => return fallbackOrPartial(sent, error.ConnectionResetByPeer),
            .NOTCONN => return fallbackOrPartial(sent, error.SocketUnconnected),
            .CONNABORTED => return fallbackOrPartial(sent, error.ConnectionAborted),
            else => return fallbackOrPartial(sent, error.SendfileFailed),
        }
        if (transferred == 0) break;
        sent += transferred;
        remaining -= transferred;
        offset += @intCast(transferred);
    }
    return .{ .sent = sent };
}

fn trySendfileFreebsd(stream: Io.net.Stream, file: Io.File, size: u64) SendfileResult {
    var offset: std.c.off_t = 0;
    var sent: u64 = 0;
    var remaining = size;
    while (remaining != 0) {
        const chunk = @min(remaining, @as(u64, std.math.maxInt(usize)));
        var sbytes: std.c.off_t = 0;
        const rc = std.c.sendfile(file.handle, stream.socket.handle, offset, @intCast(chunk), null, &sbytes, 0);
        const transferred: u64 = if (sbytes > 0) @intCast(sbytes) else 0;
        switch (std.posix.errno(rc)) {
            .SUCCESS => {},
            .INTR, .BUSY => if (transferred == 0) continue,
            .AGAIN => if (transferred == 0) return fallbackOrPartial(sent, error.SendfileWouldBlock),
            .INVAL, .OPNOTSUPP, .NOTSOCK, .NOSYS => return fallbackOrPartial(sent, error.SendfileUnsupported),
            .PIPE => return fallbackOrPartial(sent, error.BrokenPipe),
            .CONNRESET => return fallbackOrPartial(sent, error.ConnectionResetByPeer),
            .NOTCONN => return fallbackOrPartial(sent, error.SocketUnconnected),
            .CONNABORTED => return fallbackOrPartial(sent, error.ConnectionAborted),
            else => return fallbackOrPartial(sent, error.SendfileFailed),
        }
        if (transferred == 0) break;
        sent += transferred;
        remaining -= transferred;
        offset += @intCast(transferred);
    }
    return .{ .sent = sent };
}
