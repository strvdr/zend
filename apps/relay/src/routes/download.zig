const std = @import("std");
const ids = @import("../ids.zig");
const storage = @import("../storage.zig");
const http_helpers = @import("../http_helpers.zig");
const runtime_config = @import("../runtime_config.zig");

pub fn handleDownload(
    req: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    cfg: runtime_config.RuntimeConfig,
) !void {
    const target = req.head.target;
    const id = http_helpers.extractPathSuffix(target, "/download/") orelse {
        http_helpers.respondText(req, .bad_request, "Missing id");
        return;
    };

    if (!ids.isValidId(id)) {
        http_helpers.respondText(req, .bad_request, "Invalid id");
        return;
    }

    const path = try storage.blobPathSlice(allocator, cfg.blob_dir, id);
    defer allocator.free(path);

    const data = std.fs.cwd().readFileAlloc(allocator, path, cfg.max_upload_bytes) catch {
        http_helpers.respondText(req, .not_found, "Not found");
        return;
    };
    defer allocator.free(data);

    try req.respond(data, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/octet-stream" },
            .{ .name = "access-control-allow-origin", .value = "*" },
        },
    });

    storage.deleteBlob(allocator, cfg.blob_dir, id);
}
