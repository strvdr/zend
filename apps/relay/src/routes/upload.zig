const std = @import("std");
const ids = @import("../ids.zig");
const http_helpers = @import("../http_helpers.zig");
const storage = @import("../storage.zig");
const runtime_config = @import("../runtime_config.zig");

const UploadState = struct {
    token: []u8,
    created_at: i64,
    next_index: u32,
    bytes_written: u64,

    fn deinit(self: *UploadState, allocator: std.mem.Allocator) void {
        allocator.free(self.token);
    }
};

fn writeUploadState(
    allocator: std.mem.Allocator,
    cfg: runtime_config.RuntimeConfig,
    id: []const u8,
    token: []const u8,
    created_at: i64,
    next_index: u32,
    bytes_written: u64,
) !void {
    const path = try storage.uploadStatePath(allocator, cfg.blob_dir, id);
    defer allocator.free(path);

    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();

    var buf: [256]u8 = undefined;
    var w = file.writer(&buf);
    try w.interface.print("{s}\n{d}\n{d}\n{d}\n", .{
        token,
        created_at,
        next_index,
        bytes_written,
    });
    try w.interface.flush();
}

fn readUploadState(
    allocator: std.mem.Allocator,
    cfg: runtime_config.RuntimeConfig,
    id: []const u8,
) !UploadState {
    const path = try storage.uploadStatePath(allocator, cfg.blob_dir, id);
    defer allocator.free(path);

    const data = try std.fs.cwd().readFileAlloc(allocator, path, 4096);
    defer allocator.free(data);

    var it = std.mem.splitScalar(u8, data, '\n');

    const token_line = it.next() orelse return error.InvalidUploadState;
    const created_line = it.next() orelse return error.InvalidUploadState;
    const next_index_line = it.next() orelse return error.InvalidUploadState;
    const bytes_written_line = it.next() orelse return error.InvalidUploadState;

    return .{
        .token = try allocator.dupe(u8, token_line),
        .created_at = try std.fmt.parseInt(i64, created_line, 10),
        .next_index = try std.fmt.parseInt(u32, next_index_line, 10),
        .bytes_written = try std.fmt.parseInt(u64, bytes_written_line, 10),
    };
}

fn pathWithoutQuery(target: []const u8) []const u8 {
    return target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
}

fn queryValue(target: []const u8, key: []const u8) ?[]const u8 {
    const qmark = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    const query = target[qmark + 1 ..];
    var parts = std.mem.splitScalar(u8, query, '&');
    while (parts.next()) |part| {
        const eq = std.mem.indexOfScalar(u8, part, '=') orelse continue;
        if (std.mem.eql(u8, part[0..eq], key)) {
            return part[eq + 1 ..];
        }
    }
    return null;
}

fn idFromPrefix(target: []const u8, prefix: []const u8) ?[]const u8 {
    const path = pathWithoutQuery(target);
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    return path[prefix.len..];
}

fn respondJson(req: *std.http.Server.Request, json: []const u8) void {
    req.respond(json, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "access-control-allow-origin", .value = "*" },
        },
    }) catch {};
}

pub fn handleStart(
    req: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    cfg: runtime_config.RuntimeConfig,
) !void {
    if (req.head.method != .POST) {
        http_helpers.respondText(req, .method_not_allowed, "Method not allowed");
        return;
    }

    const id_buf = ids.randomHex();
    const token_buf = ids.randomHex();

    const id = id_buf[0..];
    const token = token_buf[0..];
    const created_at = std.time.timestamp();

    const tmp_blob_path = try storage.tmpBlobPath(allocator, cfg.blob_dir, id);
    defer allocator.free(tmp_blob_path);

    {
        const file = try std.fs.cwd().createFile(tmp_blob_path, .{ .truncate = true });
        defer file.close();
    }

    errdefer storage.deleteUploadTempFiles(allocator, cfg.blob_dir, id);

    try writeUploadState(allocator, cfg, id, token, created_at, 0, 0);

    std.log.info("upload start id={s} token={s} tmp={s}", .{
        id,
        token,
        tmp_blob_path,
    });

    const json = try std.fmt.allocPrint(
        allocator,
        "{{\"id\":\"{s}\",\"token\":\"{s}\"}}",
        .{ id, token },
    );
    defer allocator.free(json);

    respondJson(req, json);
}

pub fn handleAppend(
    req: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    cfg: runtime_config.RuntimeConfig,
) !void {
    if (req.head.method != .POST) {
        http_helpers.respondText(req, .method_not_allowed, "Method not allowed");
        return;
    }

    const id_slice = idFromPrefix(req.head.target, "/upload/append/") orelse {
        http_helpers.respondText(req, .bad_request, "Missing upload id");
        return;
    };

    const token_slice = queryValue(req.head.target, "token") orelse {
        http_helpers.respondText(req, .unauthorized, "Missing token");
        return;
    };

    const index_str = queryValue(req.head.target, "index") orelse {
        http_helpers.respondText(req, .bad_request, "Missing index");
        return;
    };

    const index = std.fmt.parseInt(u32, index_str, 10) catch {
        http_helpers.respondText(req, .bad_request, "Invalid index");
        return;
    };

    const id = try allocator.dupe(u8, id_slice);
    defer allocator.free(id);

    const token = try allocator.dupe(u8, token_slice);
    defer allocator.free(token);

    var state = readUploadState(allocator, cfg, id) catch {
        http_helpers.respondText(req, .not_found, "Upload session not found");
        return;
    };
    defer state.deinit(allocator);

    std.log.info("upload append begin id={s} index={d} expected_index={d} bytes_written_before={d} content_length={any} max_append_body_bytes={d} max_upload_bytes={d}", .{
        id,
        index,
        state.next_index,
        state.bytes_written,
        req.head.content_length,
        cfg.max_append_body_bytes,
        cfg.max_upload_bytes,
    });

    if (!std.mem.eql(u8, state.token, token)) {
        std.log.err("upload append token mismatch id={s} index={d}", .{ id, index });
        http_helpers.respondText(req, .unauthorized, "Invalid token");
        return;
    }

    if (index != state.next_index) {
        std.log.err("upload append unexpected index id={s} got={d} expected={d}", .{
            id,
            index,
            state.next_index,
        });
        http_helpers.respondText(req, .conflict, "Unexpected chunk index");
        return;
    }

    const remaining_upload_bytes: u64 = if (state.bytes_written >= cfg.max_upload_bytes)
        0
    else
        cfg.max_upload_bytes - state.bytes_written;

    const body_limit: usize = @intCast(@min(remaining_upload_bytes, cfg.max_append_body_bytes));

    const body = http_helpers.readBody(req, allocator, body_limit) catch |err| {
        std.log.err("upload append readBody failed id={s} index={d}: {s}", .{
            id,
            index,
            @errorName(err),
        });

        if (err == error.BodyTooLarge) {
            storage.deleteUploadTempFiles(allocator, cfg.blob_dir, id);
            http_helpers.respondText(req, .payload_too_large, "Upload exceeds the maximum allowed size");
            return;
        }

        return err;
    };
    defer allocator.free(body);

    std.log.info("upload append body read id={s} index={d} body_len={d}", .{
        id,
        index,
        body.len,
    });

    if (state.bytes_written + body.len > cfg.max_upload_bytes) {
        std.log.err("upload append too large id={s} index={d} existing={d} incoming={d} limit={d}", .{
            id,
            index,
            state.bytes_written,
            body.len,
            cfg.max_upload_bytes,
        });
        storage.deleteUploadTempFiles(allocator, cfg.blob_dir, id);
        http_helpers.respondText(req, .payload_too_large, "Upload exceeds the maximum allowed size");
        return;
    }

    const tmp_blob_path = try storage.tmpBlobPath(allocator, cfg.blob_dir, id);
    defer allocator.free(tmp_blob_path);

    const file = try std.fs.cwd().openFile(tmp_blob_path, .{ .mode = .read_write });
    defer file.close();

    const size_before = try file.getEndPos();
    std.log.info("upload append file size before write id={s} index={d} path={s} size_before={d}", .{
        id,
        index,
        tmp_blob_path,
        size_before,
    });

    try file.seekFromEnd(0);
    try file.writeAll(body);
    try file.sync();

    const new_size = try file.getEndPos();
    std.log.info("upload append file size after write id={s} index={d} size_after={d} delta={d} request_bytes={d}", .{
        id,
        index,
        new_size,
        new_size - size_before,
        body.len,
    });

    if (new_size > cfg.max_upload_bytes) {
        std.log.err("upload append exceeded max after write id={s} index={d} size_after={d} limit={d}", .{
            id,
            index,
            new_size,
            cfg.max_upload_bytes,
        });
        storage.deleteUploadTempFiles(allocator, cfg.blob_dir, id);
        http_helpers.respondText(req, .payload_too_large, "Upload exceeds the maximum allowed size");
        return;
    }

    try writeUploadState(
        allocator,
        cfg,
        id,
        state.token,
        state.created_at,
        state.next_index + 1,
        new_size,
    );

    std.log.info("upload append committed id={s} next_index={d} bytes_written={d}", .{
        id,
        state.next_index + 1,
        new_size,
    });

    respondJson(req, "{\"ok\":true}");
}

pub fn handleFinish(
    req: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    cfg: runtime_config.RuntimeConfig,
) !void {
    if (req.head.method != .POST) {
        http_helpers.respondText(req, .method_not_allowed, "Method not allowed");
        return;
    }

    const id = idFromPrefix(req.head.target, "/upload/finish/") orelse {
        http_helpers.respondText(req, .bad_request, "Missing upload id");
        return;
    };

    const token = queryValue(req.head.target, "token") orelse {
        http_helpers.respondText(req, .unauthorized, "Missing token");
        return;
    };

    var state = readUploadState(allocator, cfg, id) catch {
        http_helpers.respondText(req, .not_found, "Upload session not found");
        return;
    };
    defer state.deinit(allocator);

    if (!std.mem.eql(u8, state.token, token)) {
        std.log.err("upload finish token mismatch id={s}", .{id});
        http_helpers.respondText(req, .unauthorized, "Invalid token");
        return;
    }

    const tmp_blob_path = try storage.tmpBlobPath(allocator, cfg.blob_dir, id);
    defer allocator.free(tmp_blob_path);

    const blob_path = try storage.blobPath(allocator, cfg.blob_dir, id);
    defer allocator.free(blob_path);

    const meta_path = try storage.metaPath(allocator, cfg.blob_dir, id);
    defer allocator.free(meta_path);

    const tmp_size = blk: {
        const f = try std.fs.cwd().openFile(tmp_blob_path, .{});
        defer f.close();
        break :blk try f.getEndPos();
    };

    std.log.info("upload finish id={s} tmp={s} tmp_size={d} next_index={d} bytes_written={d}", .{
        id,
        tmp_blob_path,
        tmp_size,
        state.next_index,
        state.bytes_written,
    });

    if (tmp_size > cfg.max_upload_bytes or state.bytes_written > cfg.max_upload_bytes) {
        std.log.err("upload finish size limit exceeded id={s} tmp_size={d} bytes_written={d} limit={d}", .{
            id,
            tmp_size,
            state.bytes_written,
            cfg.max_upload_bytes,
        });
        storage.deleteUploadTempFiles(allocator, cfg.blob_dir, id);
        http_helpers.respondText(req, .payload_too_large, "Upload exceeds the maximum allowed size");
        return;
    }

    try std.fs.cwd().rename(tmp_blob_path, blob_path);
    errdefer std.fs.cwd().deleteFile(blob_path) catch {};

    std.log.info("upload finish renamed id={s} blob={s}", .{
        id,
        blob_path,
    });

    {
        const file = try std.fs.cwd().createFile(meta_path, .{ .truncate = true });
        defer file.close();

        var buf: [1024]u8 = undefined;
        var w = file.writer(&buf);
        try w.interface.print("{s}\n{d}\n", .{ state.token, std.time.timestamp() });
        try w.interface.flush();
    }

    {
        const state_path = try storage.uploadStatePath(allocator, cfg.blob_dir, id);
        defer allocator.free(state_path);
        std.fs.cwd().deleteFile(state_path) catch {};
    }

    const json = try std.fmt.allocPrint(
        allocator,
        "{{\"id\":\"{s}\",\"token\":\"{s}\"}}",
        .{ id, state.token },
    );
    defer allocator.free(json);

    respondJson(req, json);
}
