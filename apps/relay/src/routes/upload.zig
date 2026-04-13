const std = @import("std");
const ids = @import("../ids.zig");
const http_helpers = @import("../http_helpers.zig");
const storage = @import("../storage.zig");
const runtime_config = @import("../runtime_config.zig");

pub fn handleUpload(
    req: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    cfg: runtime_config.RuntimeConfig,
) !void {
    const body = http_helpers.readBody(req, allocator, cfg.max_upload_bytes) catch |err| {
        if (err == error.BodyTooLarge) {
            http_helpers.respondText(req, .payload_too_large, "Payload too large");
            return;
        }
        return err;
    };
    defer allocator.free(body);

    const id_buf = ids.randomHex();
    const token_buf = ids.randomHex();

    const id = id_buf[0..];
    const token = token_buf[0..];

    const blob_path = try storage.blobPath(allocator, cfg.blob_dir, id);
    defer allocator.free(blob_path);

    const meta_path = try storage.metaPath(allocator, cfg.blob_dir, id);
    defer allocator.free(meta_path);

    {
        const file = try std.fs.cwd().createFile(blob_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(body);
    }

    {
        const file = try std.fs.cwd().createFile(meta_path, .{ .truncate = true });
        defer file.close();

        var buf: [1024]u8 = undefined;
        var w = file.writer(&buf);
        try w.interface.print("{s}\n{d}\n", .{ token, std.time.timestamp() });
        try w.interface.flush();
    }

    const json = try std.fmt.allocPrint(
        allocator,
        "{{\"id\":\"{s}\",\"token\":\"{s}\"}}",
        .{ id, token },
    );
    defer allocator.free(json);

    req.respond(json, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "access-control-allow-origin", .value = "*" },
        },
    }) catch {};
}
