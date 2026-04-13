const std = @import("std");
const runtime_config = @import("runtime_config.zig");
const reaper = @import("reaper.zig");
const upload = @import("routes/upload.zig");
const download = @import("routes/download.zig");
const del = @import("routes/delete.zig");
const http_helpers = @import("http_helpers.zig");
const options = @import("routes/options.zig");

var gpa = std.heap.GeneralPurposeAllocator(.{}){};

pub fn main() !void {
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var cfg = try runtime_config.load(allocator);

    // Preserve the old behavior where a positional CLI port overrides the default.
    // Now it also overrides env config when provided.
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len > 1) {
        cfg.port = std.fmt.parseInt(u16, args[1], 10) catch cfg.port;
    }

    std.fs.cwd().makePath(cfg.blob_dir) catch |err| {
        std.log.err("cannot create blob directory '{s}': {s}", .{ cfg.blob_dir, @errorName(err) });
        return err;
    };

    const reap_thread = try std.Thread.spawn(.{}, reaper.reapLoop, .{ allocator, cfg });
    reap_thread.detach();

    const addr = try std.net.Address.parseIp(cfg.host, cfg.port);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();

    std.log.info("zend-relay listening on {s}:{d}", .{ cfg.host, cfg.port });
    std.log.info("blob_dir={s} max_upload_bytes={d} ttl_seconds={d}", .{
        cfg.blob_dir,
        cfg.max_upload_bytes,
        cfg.ttl_seconds,
    });

    while (true) {
        const conn = server.accept() catch |err| {
            std.log.err("accept: {s}", .{@errorName(err)});
            continue;
        };

        const thread = std.Thread.spawn(.{}, handleConnection, .{ conn, allocator, cfg }) catch |err| {
            std.log.err("spawn: {s}", .{@errorName(err)});
            conn.stream.close();
            continue;
        };
        thread.detach();
    }
}

fn handleConnection(
    conn: std.net.Server.Connection,
    allocator: std.mem.Allocator,
    cfg: runtime_config.RuntimeConfig,
) !void {
    defer conn.stream.close();

    var read_buf: [8 * 1024]u8 = undefined;
    var write_buf: [4 * 1024]u8 = undefined;

    var reader = conn.stream.reader(&read_buf).file_reader;
    var writer = conn.stream.writer(&write_buf).file_writer;

    var http_server = std.http.Server.init(&reader.interface, &writer.interface);

    var req = http_server.receiveHead() catch |err| {
        std.log.debug("receiveHead: {s}", .{@errorName(err)});
        return;
    };

    const target = req.head.target;

    if (req.head.method == .OPTIONS) {
        options.handleOptions(&req, cfg) catch {};
        return;
    } else if (req.head.method == .POST and std.mem.eql(u8, target, "/upload")) {
        upload.handleUpload(&req, allocator, cfg) catch |err| {
            std.log.err("upload: {s}", .{@errorName(err)});
            http_helpers.respondText(&req, .internal_server_error, "Internal error");
        };
    } else if (req.head.method == .GET and std.mem.eql(u8, target, "/healthz")) {
        try req.respond("ok", .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/plain" },
            },
        });
    } else if (req.head.method == .GET and std.mem.startsWith(u8, target, "/download/")) {
        download.handleDownload(&req, allocator, cfg) catch |err| {
            std.log.err("download: {s}", .{@errorName(err)});
            http_helpers.respondText(&req, .internal_server_error, "Internal error");
        };
    } else if (req.head.method == .DELETE and std.mem.startsWith(u8, target, "/blob/")) {
        del.handleDelete(&req, allocator, cfg) catch |err| {
            std.log.err("delete: {s}", .{@errorName(err)});
            http_helpers.respondText(&req, .internal_server_error, "Internal error");
        };
    } else {
        http_helpers.respondText(&req, .not_found, "Not found");
    }
}
