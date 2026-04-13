const std = @import("std");
const config = @import("config.zig");
const reaper = @import("reaper.zig");
const http_helpers = @import("http_helpers.zig");
const upload = @import("routes/upload.zig");
const download = @import("routes/download.zig");
const del = @import("routes/delete.zig");

var gpa = std.heap.GeneralPurposeAllocator(.{}){};

pub fn main() !void {
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.fs.cwd().makePath(config.BLOB_DIR) catch |err| {
        std.log.err("cannot create blob directory '{s}': {s}", .{ config.BLOB_DIR, @errorName(err) });
        return err;
    };

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const port: u16 = if (args.len > 1)
        std.fmt.parseInt(u16, args[1], 10) catch config.DEFAULT_PORT
    else
        config.DEFAULT_PORT;

    const reap_thread = try std.Thread.spawn(.{}, reaper.reapLoop, .{allocator});
    reap_thread.detach();

    const addr = try std.net.Address.parseIp("0.0.0.0", port);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();

    std.log.info("zend-relay listening on :{d}", .{port});

    while (true) {
        const conn = server.accept() catch |err| {
            std.log.err("accept: {s}", .{@errorName(err)});
            continue;
        };

        const thread = std.Thread.spawn(.{}, handleConnection, .{ conn, allocator }) catch |err| {
            std.log.err("spawn: {s}", .{@errorName(err)});
            conn.stream.close();
            continue;
        };
        thread.detach();
    }
}

fn handleConnection(conn: std.net.Server.Connection, allocator: std.mem.Allocator) void {
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

    if (req.head.method == .POST and std.mem.eql(u8, target, "/upload")) {
        upload.handleUpload(&req, allocator) catch |err| {
            std.log.err("upload: {s}", .{@errorName(err)});
            http_helpers.respondText(&req, .internal_server_error, "Internal error");
        };
    } else if (req.head.method == .GET and std.mem.startsWith(u8, target, "/download/")) {
        download.handleDownload(&req, allocator) catch |err| {
            std.log.err("download: {s}", .{@errorName(err)});
            http_helpers.respondText(&req, .internal_server_error, "Internal error");
        };
    } else if (req.head.method == .DELETE and std.mem.startsWith(u8, target, "/blob/")) {
        del.handleDelete(&req, allocator) catch |err| {
            std.log.err("delete: {s}", .{@errorName(err)});
            http_helpers.respondText(&req, .internal_server_error, "Internal error");
        };
    } else {
        http_helpers.respondText(&req, .not_found, "Not found");
    }
}
