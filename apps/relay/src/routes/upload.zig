const std = @import("std");
const ids = @import("../ids.zig");
const storage = @import("../storage.zig");
const http_helpers = @import("../http_helpers.zig");

pub fn handleUpload(req: *std.http.Server.Request, allocator: std.mem.Allocator) !void {
    const body = http_helpers.readBody(req, allocator) catch |err| {
        if (err == error.PayloadTooLarge) {
            http_helpers.respondText(req, .payload_too_large, "Payload too large");
            return;
        }
        return err;
    };
    defer allocator.free(body);

    if (body.len == 0) {
        http_helpers.respondText(req, .bad_request, "Empty body");
        return;
    }

    const id = ids.randomHex();
    const token = ids.randomHex();

    {
        const path = try storage.blobPath(allocator, &id);
        defer allocator.free(path);
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll(body);
    }

    {
        const path = try storage.metaPath(allocator, &id);
        defer allocator.free(path);
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        var buf: [256]u8 = undefined;
        const content = try std.fmt.bufPrint(&buf, "{s}\n{d}", .{ token, std.time.timestamp() });
        try file.writeAll(content);
    }

    var resp_buf: [256]u8 = undefined;
    const json = try std.fmt.bufPrint(&resp_buf,
        \\{{"id":"{s}","token":"{s}"}}
    , .{ id, token });

    try req.respond(json, .{
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "access-control-allow-origin", .value = "*" },
        },
    });

    std.log.info("upload: {s} ({d} bytes)", .{ id, body.len });
}
