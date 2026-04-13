const std = @import("std");
const ids = @import("../ids.zig");
const storage = @import("../storage.zig");
const http_helpers = @import("../http_helpers.zig");

pub fn handleDelete(req: *std.http.Server.Request, allocator: std.mem.Allocator) !void {
    const after_prefix = http_helpers.extractPathSuffix(req.head.target, "/blob/") orelse {
        http_helpers.respondText(req, .bad_request, "Missing blob ID");
        return;
    };

    const question = std.mem.indexOfScalar(u8, after_prefix, '?');
    const id = if (question) |q| after_prefix[0..q] else after_prefix;

    if (!ids.isValidId(id)) {
        http_helpers.respondText(req, .bad_request, "Invalid blob ID");
        return;
    }

    const provided_token = blk: {
        if (question) |q| {
            const query = after_prefix[q + 1 ..];
            if (std.mem.startsWith(u8, query, "token=")) {
                break :blk query["token=".len..];
            }
        }
        http_helpers.respondText(req, .bad_request, "Missing token");
        return;
    };

    const mp = try storage.metaPathSlice(allocator, id);
    defer allocator.free(mp);

    const meta = std.fs.cwd().readFileAlloc(allocator, mp, 1024) catch |err| {
        if (err == error.FileNotFound) {
            http_helpers.respondText(req, .not_found, "Blob not found");
            return;
        }
        return err;
    };
    defer allocator.free(meta);

    const newline = std.mem.indexOfScalar(u8, meta, '\n') orelse {
        http_helpers.respondText(req, .internal_server_error, "Corrupt metadata");
        return;
    };
    const stored_token = meta[0..newline];

    if (!std.mem.eql(u8, provided_token, stored_token)) {
        http_helpers.respondText(req, .forbidden, "Invalid token");
        return;
    }

    storage.deleteBlob(allocator, id);

    try req.respond("", .{
        .status = .no_content,
        .extra_headers = &.{
            .{ .name = "access-control-allow-origin", .value = "*" },
        },
    });

    std.log.info("delete (token): {s}", .{id});
}
