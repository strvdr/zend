const std = @import("std");
const runtime_config = @import("runtime_config.zig");
const http_helpers = @import("http_helpers.zig");
const upload = @import("routes/upload.zig");
const download = @import("routes/download.zig");
const delete = @import("routes/delete.zig");
const reaper = @import("reaper.zig");

fn pathWithoutQuery(target: []const u8) []const u8 {
    return target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
}

fn handleConnection(
    conn: std.net.Server.Connection,
    allocator: std.mem.Allocator,
    cfg: runtime_config.RuntimeConfig,
) !void {
    defer conn.stream.close();

    var in_buf: [16 * 1024]u8 = undefined;
    var out_buf: [16 * 1024]u8 = undefined;

    var in_reader = conn.stream.reader(&in_buf);
    var out_writer = conn.stream.writer(&out_buf);
    var server = std.http.Server.init(in_reader.interface(), &out_writer.interface);

    while (true) {
        var req = server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => break,
            else => return err,
        };

        const path = pathWithoutQuery(req.head.target);

        std.log.info("request method={s} path={s}", .{
            @tagName(req.head.method),
            path,
        });

        if (req.head.method == .OPTIONS) {
            req.respond("", .{
                .status = .no_content,
                .extra_headers = &.{
                    .{ .name = "access-control-allow-origin", .value = "*" },
                    .{ .name = "access-control-allow-methods", .value = "GET, POST, DELETE, OPTIONS" },
                    .{ .name = "access-control-allow-headers", .value = "content-type" },
                },
            }) catch {};
            continue;
        }

        if (std.mem.eql(u8, path, "/upload/start")) {
            upload.handleStart(&req, allocator, cfg) catch |err| {
                std.log.err("upload start failed: {s}", .{@errorName(err)});
                http_helpers.respondText(&req, .internal_server_error, "Upload start failed");
            };
            continue;
        }

        if (std.mem.startsWith(u8, path, "/upload/append/")) {
            upload.handleAppend(&req, allocator, cfg) catch |err| {
                std.log.err("upload append failed: {s}", .{@errorName(err)});
                http_helpers.respondText(&req, .internal_server_error, "Upload append failed");
            };
            continue;
        }

        if (std.mem.startsWith(u8, path, "/upload/finish/")) {
            upload.handleFinish(&req, allocator, cfg) catch |err| {
                std.log.err("upload finish failed: {s}", .{@errorName(err)});
                http_helpers.respondText(&req, .internal_server_error, "Upload finish failed");
            };
            continue;
        }

        if (std.mem.startsWith(u8, path, "/download/")) {
            download.handleDownload(&req, allocator, cfg) catch |err| {
                std.log.err("download failed: {s}", .{@errorName(err)});
                http_helpers.respondText(&req, .internal_server_error, "Download failed");
            };
            continue;
        }

        if (std.mem.startsWith(u8, path, "/delete/")) {
            delete.handleDelete(&req, allocator, cfg) catch |err| {
                std.log.err("delete failed: {s}", .{@errorName(err)});
                http_helpers.respondText(&req, .internal_server_error, "Delete failed");
            };
            continue;
        }

        http_helpers.respondText(&req, .not_found, "Not found");
    }
}

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    const cfg = try runtime_config.load(allocator);
    try std.fs.cwd().makePath(cfg.blob_dir);

    const addr = try std.net.Address.parseIp4("0.0.0.0", cfg.port);
    var listener = try addr.listen(.{
        .reuse_address = true,
    });
    defer listener.deinit();

    std.log.info("zend-relay listening on 0.0.0.0:{d}", .{cfg.port});
    std.log.info("blob_dir={s} max_upload_bytes={d} ttl_seconds={d}", .{
        cfg.blob_dir,
        cfg.max_upload_bytes,
        cfg.ttl_seconds,
    });

    const reaper_thread = try std.Thread.spawn(.{}, reaper.reapLoop, .{ allocator, cfg });
    reaper_thread.detach();

    while (true) {
        const conn = try listener.accept();
        const thread = try std.Thread.spawn(.{}, handleConnection, .{ conn, allocator, cfg });
        thread.detach();
    }
}
