const std = @import("std");
const config = @import("config.zig");

pub fn readBody(req: *std.http.Server.Request, allocator: std.mem.Allocator) ![]u8 {
    if (req.head.content_length) |cl| {
        if (cl > config.MAX_UPLOAD_SIZE) return error.PayloadTooLarge;
    }

    if (req.head.transfer_encoding == .none and req.head.content_length == null) {
        return try allocator.alloc(u8, 0);
    }

    var body_buf: [64 * 1024]u8 = undefined;
    var body_reader = req.server.reader.bodyReader(
        &body_buf,
        req.head.transfer_encoding,
        req.head.content_length,
    );

    var body_writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer body_writer.deinit();

    _ = try body_reader.streamRemaining(&body_writer.writer);

    const written = body_writer.written();
    if (written.len > config.MAX_UPLOAD_SIZE) {
        body_writer.deinit();
        return error.PayloadTooLarge;
    }

    return try body_writer.toOwnedSlice();
}

pub fn extractPathSuffix(target: []const u8, prefix: []const u8) ?[]const u8 {
    if (target.len <= prefix.len) return null;
    if (!std.mem.startsWith(u8, target, prefix)) return null;
    return target[prefix.len..];
}

pub fn respondText(req: *std.http.Server.Request, status: std.http.Status, msg: []const u8) void {
    req.respond(msg, .{
        .status = status,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/plain" },
            .{ .name = "access-control-allow-origin", .value = "*" },
        },
    }) catch {};
}
