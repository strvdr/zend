const std = @import("std");
const config = @import("../config.zig");
const ids = @import("../ids.zig");
const storage = @import("../storage.zig");
const http_helpers = @import("../http_helpers.zig");

pub fn handleDownload(req: *std.http.Server.Request, allocator: std.mem.Allocator) !void {
    const id = http_helpers.extractPathSuffix(req.head.target, "/download/") orelse {
        http_helpers.respondText(req, .bad_request, "Missing blob ID");
        return;
    };

    if (!ids.isValidId(id)) {
        http_helpers.respondText(req, .bad_request, "Invalid blob ID");
        return;
    }

    const path = try storage.blobPathSlice(allocator, id);
    defer allocator.free(path);

    const data = std.fs.cwd().readFileAlloc(allocator, path, config.MAX_UPLOAD_SIZE) catch |err| {
        if (err == error.FileNotFound) {
            http_helpers.respondText(req, .not_found, "Blob not found or already downloaded");
            return;
        }
        return err;
    };
    defer allocator.free(data);

    try req.respond(data, .{
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/octet-stream" },
            .{ .name = "access-control-allow-origin", .value = "*" },
        },
    });

    storage.deleteBlob(allocator, id);
    std.log.info("download+delete: {s} ({d} bytes)", .{ id, data.len });
}
