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
    if (req.head.content_length) |cl| {
        if (cl > cfg.max_upload_bytes) {
            http_helpers.respondText(req, .payload_too_large, "Payload too large");
            return;
        }
    }

    const id_buf = ids.randomHex();
    const token_buf = ids.randomHex();

    const id = id_buf[0..];
    const token = token_buf[0..];

    const blob_path = try storage.blobPath(allocator, cfg.blob_dir, id);
    defer allocator.free(blob_path);

    const meta_path = try storage.metaPath(allocator, cfg.blob_dir, id);
    defer allocator.free(meta_path);

    const tmp_blob_path = try std.fmt.allocPrint(allocator, "{s}.part", .{blob_path});
    defer allocator.free(tmp_blob_path);

    const cwd = std.fs.cwd();

    var tmp_file_created = false;
    errdefer {
        if (tmp_file_created) {
            cwd.deleteFile(tmp_blob_path) catch {};
        }
    }

    {
        const file = try cwd.createFile(tmp_blob_path, .{ .truncate = true });
        defer file.close();

        tmp_file_created = true;

        var body_buf: [64 * 1024]u8 = undefined;
        var file_buf: [64 * 1024]u8 = undefined;

        const body_reader = req.server.reader.bodyReader(
            &body_buf,
            req.head.transfer_encoding,
            req.head.content_length,
        );

        var file_writer = file.writer(&file_buf);

        _ = try body_reader.streamRemaining(&file_writer.interface);
        try file_writer.interface.flush();

        const written = try file.getEndPos();
        if (written > cfg.max_upload_bytes) {
            http_helpers.respondText(req, .payload_too_large, "Payload too large");
            return;
        }

        try file.sync();
    }

    try cwd.rename(tmp_blob_path, blob_path);
    errdefer cwd.deleteFile(blob_path) catch {};

    {
        const file = try cwd.createFile(meta_path, .{ .truncate = true });
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
