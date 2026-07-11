const std = @import("std");
const config_mod = @import("config.zig");
const version = @import("version.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const server_name = "qaws/" ++ version.string;

pub const HttpVersion = enum {
    http_1_0,
    http_1_1,
};

pub const ConnectionDirective = enum {
    none,
    keep_alive,
    close,
};

pub const Request = struct {
    method: []const u8,
    target: []const u8,
    version: HttpVersion,
    connection: ConnectionDirective = .none,
    user_agent: ?[]const u8 = null,
    if_modified_since: ?[]const u8 = null,
    has_request_body: bool = false,
};

pub const ResponseStatus = struct {
    code: u16,
    reason: []const u8,
};

pub const ResponseResult = struct {
    status: u16,
    bytes: u64,
};

pub fn parseRequest(bytes: []const u8) !Request {
    const line_end = std.mem.indexOf(u8, bytes, "\r\n") orelse return error.BadRequest;
    const line = bytes[0..line_end];

    var parts = std.mem.splitScalar(u8, line, ' ');
    const method = parts.next() orelse return error.BadRequest;
    const target = parts.next() orelse return error.BadRequest;
    const version_text = parts.next() orelse return error.BadRequest;
    if (parts.next() != null) return error.BadRequest;
    const version_value: HttpVersion = if (std.mem.eql(u8, version_text, "HTTP/1.1"))
        .http_1_1
    else if (std.mem.eql(u8, version_text, "HTTP/1.0"))
        .http_1_0
    else
        return error.BadRequest;
    if (target.len == 0 or target[0] != '/') return error.BadRequest;

    var user_agent: ?[]const u8 = null;
    var if_modified_since: ?[]const u8 = null;
    var connection: ConnectionDirective = .none;
    var has_request_body = false;
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
            } else if (std.ascii.eqlIgnoreCase(name, "Connection")) {
                connection = mergeConnectionDirective(connection, parseConnectionHeader(value));
            } else if (std.ascii.eqlIgnoreCase(name, "Content-Length")) {
                const length = std.fmt.parseInt(u64, value, 10) catch return error.BadRequest;
                if (length > 0) has_request_body = true;
            } else if (std.ascii.eqlIgnoreCase(name, "Transfer-Encoding")) {
                if (value.len != 0 and !std.ascii.eqlIgnoreCase(value, "identity")) {
                    has_request_body = true;
                }
            }
        }
        header_start = header_end + 2;
    }

    return .{
        .method = method,
        .target = target,
        .version = version_value,
        .connection = connection,
        .user_agent = user_agent,
        .if_modified_since = if_modified_since,
        .has_request_body = has_request_body,
    };
}

pub fn parseConnectionHeader(value: []const u8) ConnectionDirective {
    var result: ConnectionDirective = .none;
    var tokens = std.mem.splitScalar(u8, value, ',');
    while (tokens.next()) |token_raw| {
        const token = std.mem.trim(u8, token_raw, &std.ascii.whitespace);
        if (std.ascii.eqlIgnoreCase(token, "close")) return .close;
        if (std.ascii.eqlIgnoreCase(token, "keep-alive")) result = .keep_alive;
    }
    return result;
}

fn mergeConnectionDirective(current: ConnectionDirective, next: ConnectionDirective) ConnectionDirective {
    if (current == .close or next == .close) return .close;
    if (current == .keep_alive or next == .keep_alive) return .keep_alive;
    return .none;
}

pub fn requestWantsKeepAlive(request: Request, config: config_mod.Config, served_requests: u32) bool {
    if (!config.keep_alive) return false;
    if (served_requests >= config.max_requests_per_connection) return false;
    if (request.connection == .close) return false;
    return switch (request.version) {
        .http_1_1 => true,
        .http_1_0 => request.connection == .keep_alive,
    };
}

pub fn normalizeTarget(allocator: Allocator, target: []const u8, dotfiles: config_mod.DotfilePolicy) ![]u8 {
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

    if (output.items.len == 0) try output.appendSlice(allocator, "index.html");
    return try output.toOwnedSlice(allocator);
}

pub fn normalizeTargetFast(target: []const u8, dotfiles: config_mod.DotfilePolicy) ?[]const u8 {
    if (std.mem.eql(u8, target, "/")) return "index.html";
    if (std.mem.eql(u8, target, "/index.html")) return "index.html";
    if (target.len < 2 or target[0] != '/') return null;
    if (target[target.len - 1] == '/') return null;

    var segment_start: usize = 1;
    var i: usize = 1;
    while (i < target.len) : (i += 1) {
        switch (target[i]) {
            '?', '#', '%', '\\', 0 => return null,
            '/' => {
                if (!isFastSafeSegment(target[segment_start..i], dotfiles)) return null;
                segment_start = i + 1;
                if (segment_start >= target.len) return null;
            },
            else => {},
        }
    }
    if (!isFastSafeSegment(target[segment_start..], dotfiles)) return null;
    return target[1..];
}

fn isFastSafeSegment(segment: []const u8, dotfiles: config_mod.DotfilePolicy) bool {
    if (segment.len == 0) return false;
    if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
    return !isDotfileSegment(segment, dotfiles);
}

fn isDotfileSegment(segment: []const u8, dotfiles: config_mod.DotfilePolicy) bool {
    if (segment.len == 0 or segment[0] != '.') return false;
    return switch (dotfiles) {
        .allow => false,
        .deny_all => true,
        .deny_except_well_known => !std.mem.eql(u8, segment, ".well-known"),
    };
}

pub fn targetPathHasTrailingSlash(target: []const u8) bool {
    const q = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    if (q == 0) return false;
    return target[q - 1] == '/';
}

pub fn slashRedirectLocation(allocator: Allocator, target: []const u8) ![]u8 {
    const q = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    if (q > 0 and target[q - 1] == '/') return allocator.dupe(u8, target);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ target[0..q], target[q..] });
}

pub fn formatHttpDate(timestamp: Io.Timestamp, buffer: []u8) []const u8 {
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

pub fn parseHttpDate(value: []const u8) ?i64 {
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
    while (y < year) : (y += 1) days += std.time.epoch.getDaysInYear(y);
    var m: u8 = 1;
    while (m < month) : (m += 1) days += std.time.epoch.getDaysInMonth(year, @enumFromInt(m));
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

pub fn sendHeaders(
    out: *Io.Writer,
    status: ResponseStatus,
    content_type: []const u8,
    content_length: u64,
    connection: []const u8,
    allow: ?[]const u8,
    extra_headers: []const config_mod.Header,
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
    for (extra_headers) |header| try out.print("{s}: {s}\r\n", .{ header.name, header.value });
    try out.writeAll("\r\n");
}

pub fn buildHeaderAlloc(
    allocator: Allocator,
    status: ResponseStatus,
    content_type: []const u8,
    content_length: u64,
    connection: []const u8,
    allow: ?[]const u8,
    extra_headers: []const config_mod.Header,
    last_modified: ?[]const u8,
    location: ?[]const u8,
) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.print(allocator, "HTTP/1.1 {d} {s}\r\n", .{ status.code, status.reason });
    try output.print(allocator, "Server: {s}\r\n", .{server_name});
    try output.print(allocator, "Content-Type: {s}\r\n", .{content_type});
    try output.print(allocator, "Content-Length: {d}\r\n", .{content_length});
    try output.print(allocator, "Connection: {s}\r\n", .{connection});
    try output.appendSlice(allocator, "X-Content-Type-Options: nosniff\r\n");
    if (allow) |value| try output.print(allocator, "Allow: {s}\r\n", .{value});
    if (last_modified) |value| try output.print(allocator, "Last-Modified: {s}\r\n", .{value});
    if (location) |value| try output.print(allocator, "Location: {s}\r\n", .{value});
    for (extra_headers) |header| try output.print(allocator, "{s}: {s}\r\n", .{ header.name, header.value });
    try output.appendSlice(allocator, "\r\n");
    return try output.toOwnedSlice(allocator);
}

pub fn mimeType(path: []const u8) []const u8 {
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
