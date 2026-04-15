const std = @import("std");
const http_helpers = @import("../http_helpers.zig");
const storage = @import("../storage.zig");
const runtime_config = @import("../runtime_config.zig");

pub fn handleDownload(
    req: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    cfg: runtime_config.RuntimeConfig,
) !void {
    if (req.head.method != .GET) {
        http_helpers.respondText(req, .method_not_allowed, "Method not allowed");
        return;
    }

    const prefix = "/download/";
    if (!std.mem.startsWith(u8, req.head.target, prefix)) {
        http_helpers.respondText(req, .bad_request, "Invalid download path");
        return;
    }

    const id = req.head.target[prefix.len..];
    if (id.len == 0) {
        http_helpers.respondText(req, .bad_request, "Missing id");
        return;
    }

    std.log.info("download begin id={s}", .{id});

    const blob_path = try storage.blobPath(allocator, cfg.blob_dir, id);
    defer allocator.free(blob_path);

    const data = std.fs.cwd().readFileAlloc(allocator, blob_path, cfg.max_upload_bytes) catch {
        std.log.err("download not found id={s} path={s}", .{ id, blob_path });
        http_helpers.respondText(req, .not_found, "Not found");
        return;
    };
    defer allocator.free(data);

    std.log.info("download blob size id={s} bytes={d} path={s}", .{
        id,
        data.len,
        blob_path,
    });

    try req.respond(data, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/octet-stream" },
            .{ .name = "access-control-allow-origin", .value = "*" },
        },
    });

    std.log.info("download served id={s} bytes={d}", .{
        id,
        data.len,
    });

    storage.deleteBlob(allocator, cfg.blob_dir, id);
    std.log.info("download consumed id={s}", .{id});
}
