const std = @import("std");
const blob_format = @import("blob_format");
const runtime_config = @import("runtime_config");
const http_helpers = @import("http_helpers");
const upload = @import("upload");
const download = @import("download");
const delete = @import("delete");
const reaper = @import("reaper");
const rate_limit = @import("rate_limit");
const storage = @import("storage");

fn pathWithoutQuery(target: []const u8) []const u8 {
    return target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
}

fn clientIpString(allocator: std.mem.Allocator, conn: std.net.Server.Connection) ![]u8 {
    const full = try std.fmt.allocPrint(allocator, "{f}", .{conn.address});
    defer allocator.free(full);

    if (full.len == 0) return allocator.dupe(u8, "unknown");

    // The formatter gives us host:port (or [v6]:port). Strip the port so the
    // limiter keys off a stable client IP regardless of the ephemeral source port.
    if (full[0] == '[') {
        const end = std.mem.indexOfScalar(u8, full, ']') orelse full.len;
        if (end > 1) return allocator.dupe(u8, full[1..end]);
    }

    if (std.mem.lastIndexOfScalar(u8, full, ':')) |last_colon| {
        if (std.mem.indexOfScalar(u8, full, '.')) |_| {
            return allocator.dupe(u8, full[0..last_colon]);
        }
    }

    return allocator.dupe(u8, full);
}

fn classifyRoute(path: []const u8) rate_limit.RouteKind {
    if (std.mem.eql(u8, path, "/upload/start")) return .upload_start;
    if (std.mem.startsWith(u8, path, "/upload/append/")) return .upload_append;
    if (std.mem.startsWith(u8, path, "/upload/finish/")) return .upload_finish;
    if (std.mem.startsWith(u8, path, "/download/")) return .download;
    return .other;
}

fn respondRateLimited(req: *std.http.Server.Request, cfg: runtime_config.RuntimeConfig, retry_after_seconds: u32) void {
    var retry_buf: [32]u8 = undefined;
    const retry_value = std.fmt.bufPrint(&retry_buf, "{d}", .{retry_after_seconds}) catch "60";

    req.respond("Too many requests", .{
        .status = .too_many_requests,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/plain; charset=utf-8" },
            .{ .name = "access-control-allow-origin", .value = cfg.allowed_origins },
            .{ .name = "retry-after", .value = retry_value },
        },
    }) catch {};
}

fn handleConnection(
    conn: std.net.Server.Connection,
    allocator: std.mem.Allocator,
    cfg: runtime_config.RuntimeConfig,
    limiter: *rate_limit.RateLimiter,
) !void {
    defer conn.stream.close();

    var in_buf: [16 * 1024]u8 = undefined;
    var out_buf: [16 * 1024]u8 = undefined;

    var in_reader = conn.stream.reader(&in_buf);
    var out_writer = conn.stream.writer(&out_buf);
    var server = std.http.Server.init(in_reader.interface(), &out_writer.interface);

    const client_ip = try clientIpString(allocator, conn);
    defer allocator.free(client_ip);

    while (true) {
        var req = server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => break,
            else => return err,
        };

        const path = pathWithoutQuery(req.head.target);

        std.log.info("request ip={s} method={s} path={s}", .{
            client_ip,
            @tagName(req.head.method),
            path,
        });

        if (req.head.method == .OPTIONS) {
            req.respond("", .{
                .status = .no_content,
                .extra_headers = &.{
                    .{ .name = "access-control-allow-origin", .value = cfg.allowed_origins },
                    .{ .name = "access-control-allow-methods", .value = "GET, POST, DELETE, OPTIONS" },
                    .{ .name = "access-control-allow-headers", .value = "content-type" },
                },
            }) catch {};
            continue;
        }

        // Rate limiting happens once we know the route shape so one IP cannot
        // starve the relay by spamming a single hot endpoint.
        const route_kind = classifyRoute(path);
        const decision = try limiter.allow(client_ip, route_kind);
        if (!decision.allowed) {
            std.log.warn("rate limit exceeded ip={s} path={s} retry_after={d}", .{
                client_ip,
                path,
                decision.retry_after_seconds,
            });
            respondRateLimited(&req, cfg, decision.retry_after_seconds);
            continue;
        }

        if (std.mem.eql(u8, path, "/upload/start")) {
            upload.handleStart(&req, allocator, cfg) catch |err| {
                std.log.err("upload start failed: {s}", .{@errorName(err)});
                http_helpers.respondText(&req, cfg, .internal_server_error, "Upload start failed");
            };
            continue;
        }

        if (std.mem.startsWith(u8, path, "/upload/append/")) {
            upload.handleAppend(&req, allocator, cfg) catch |err| {
                std.log.err("upload append failed: {s}", .{@errorName(err)});
                http_helpers.respondText(&req, cfg, .internal_server_error, "Upload append failed");
            };
            continue;
        }

        if (std.mem.startsWith(u8, path, "/upload/finish/")) {
            upload.handleFinish(&req, allocator, cfg) catch |err| {
                std.log.err("upload finish failed: {s}", .{@errorName(err)});
                http_helpers.respondText(&req, cfg, .internal_server_error, "Upload finish failed");
            };
            continue;
        }

        if (std.mem.startsWith(u8, path, "/download/")) {
            download.handleDownload(&req, allocator, cfg) catch |err| {
                std.log.err("download failed: {s}", .{@errorName(err)});
                http_helpers.respondText(&req, cfg, .internal_server_error, "Download failed");
            };
            continue;
        }

        if (std.mem.startsWith(u8, path, "/delete/")) {
            delete.handleDelete(&req, allocator, cfg) catch |err| {
                std.log.err("delete failed: {s}", .{@errorName(err)});
                http_helpers.respondText(&req, cfg, .internal_server_error, "Delete failed");
            };
            continue;
        }

        http_helpers.respondText(&req, cfg, .not_found, "Not found");
    }
}

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    const cfg = try runtime_config.load(allocator);
    try std.fs.cwd().makePath(cfg.blob_dir);

    var limiter = rate_limit.RateLimiter.init(allocator, cfg);
    defer limiter.deinit();

    const addr = try std.net.Address.parseIp(cfg.host, cfg.port);
    var listener = try addr.listen(.{
        .reuse_address = true,
    });
    defer listener.deinit();

    std.log.info("zend-relay listening on {s}:{d}", .{ cfg.host, cfg.port });
    std.log.info("blob_dir={s} max_upload_bytes={d} ttl_seconds={d}", .{
        cfg.blob_dir,
        cfg.max_upload_bytes,
        cfg.ttl_seconds,
    });
    std.log.info("rate_limit window={d}s total={d} starts={d} appends={d} finishes={d} downloads={d}", .{
        cfg.rate_limit_window_seconds,
        cfg.rate_limit_max_requests_per_ip,
        cfg.rate_limit_max_upload_starts_per_ip,
        cfg.rate_limit_max_upload_appends_per_ip,
        cfg.rate_limit_max_upload_finishes_per_ip,
        cfg.rate_limit_max_downloads_per_ip,
    });

    // Cleanup runs on its own cadence so expired blobs do not require a request
    // path to come through first.
    const reaper_thread = try std.Thread.spawn(.{}, reaper.reapLoop, .{ allocator, cfg });
    reaper_thread.detach();

    while (true) {
        const conn = try listener.accept();
        const thread = try std.Thread.spawn(.{}, handleConnection, .{ conn, allocator, cfg, &limiter });
        thread.detach();
    }
}

const TestResponse = struct {
    status: u16,
    body: []u8,

    fn deinit(self: TestResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
    }
};

fn testRequest(
    allocator: std.mem.Allocator,
    url: []const u8,
    method: std.http.Method,
    payload: []const u8,
) !TestResponse {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var response_buf: std.Io.Writer.Allocating = .init(allocator);
    defer response_buf.deinit();

    const request_payload: ?[]const u8 = if (method.requestHasBody()) payload else null;

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = request_payload,
        .response_writer = &response_buf.writer,
    });

    return .{
        .status = @intFromEnum(result.status),
        .body = try response_buf.toOwnedSlice(),
    };
}

fn extractJsonString(allocator: std.mem.Allocator, json: []const u8, key: []const u8) ![]u8 {
    const pattern = try std.fmt.allocPrint(allocator, "\"{s}\":\"", .{key});
    defer allocator.free(pattern);

    const start = std.mem.indexOf(u8, json, pattern) orelse return error.InvalidResponse;
    const value_start = start + pattern.len;
    const rest = json[value_start..];
    const end_rel = std.mem.indexOfScalar(u8, rest, '"') orelse return error.InvalidResponse;
    return allocator.dupe(u8, rest[0..end_rel]);
}

fn testRuntimeConfig(blob_dir: []const u8, port: u16) runtime_config.RuntimeConfig {
    return .{
        .host = "127.0.0.1",
        .port = port,
        .blob_dir = blob_dir,
        .max_upload_bytes = 4 * 1024 * 1024,
        .max_append_body_bytes = 4 * 1024 * 1024,
        .ttl_seconds = 3600,
        .incomplete_ttl_seconds = 300,
        .allowed_origins = "*",
        .rate_limit_window_seconds = 60,
        .rate_limit_max_requests_per_ip = 64,
        .rate_limit_max_upload_starts_per_ip = 16,
        .rate_limit_max_upload_appends_per_ip = 32,
        .rate_limit_max_upload_finishes_per_ip = 16,
        .rate_limit_max_downloads_per_ip = 16,
    };
}

fn serveTestRelay(
    cfg: runtime_config.RuntimeConfig,
    expected_connections: usize,
    bound_port: *std.atomic.Value(u16),
) !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    try std.fs.cwd().makePath(cfg.blob_dir);

    var limiter = rate_limit.RateLimiter.init(allocator, cfg);
    defer limiter.deinit();

    const addr = try std.net.Address.parseIp(cfg.host, cfg.port);
    var listener = try addr.listen(.{
        .reuse_address = true,
    });
    defer listener.deinit();

    bound_port.store(listener.listen_address.getPort(), .release);

    var served: usize = 0;
    while (served < expected_connections) : (served += 1) {
        const conn = try listener.accept();
        try handleConnection(conn, allocator, cfg, &limiter);
    }
}

fn serveTestRelayOrPanic(
    cfg: runtime_config.RuntimeConfig,
    expected_connections: usize,
    bound_port: *std.atomic.Value(u16),
) void {
    serveTestRelay(cfg, expected_connections, bound_port) catch |err| {
        std.debug.panic("serveTestRelay failed: {s}", .{@errorName(err)});
    };
}

test "relay end-to-end upload download and consume-on-read" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const blob_dir = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/relay-e2e-blobs", .{tmp.sub_path});
    defer std.testing.allocator.free(blob_dir);

    const cfg = testRuntimeConfig(blob_dir, 0);
    var port = std.atomic.Value(u16).init(0);

    const server_thread = try std.Thread.spawn(.{}, serveTestRelayOrPanic, .{ cfg, 5, &port });
    defer server_thread.join();

    while (port.load(.acquire) == 0) {
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }

    const plaintext = "zend relay end-to-end test payload";
    const filename = "e2e.txt";
    const key = [_]u8{0x11} ** 32;

    const blob = try blob_format.encryptFileBuffer(std.testing.allocator, plaintext, filename, key);
    defer std.testing.allocator.free(blob);

    const base_url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{port.load(.acquire)});
    defer std.testing.allocator.free(base_url);

    const start_url = try std.fmt.allocPrint(std.testing.allocator, "{s}/upload/start", .{base_url});
    defer std.testing.allocator.free(start_url);
    var start_resp = try testRequest(std.testing.allocator, start_url, .POST, "");
    defer start_resp.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 200), start_resp.status);

    const upload_id = try extractJsonString(std.testing.allocator, start_resp.body, "id");
    defer std.testing.allocator.free(upload_id);
    const upload_token = try extractJsonString(std.testing.allocator, start_resp.body, "token");
    defer std.testing.allocator.free(upload_token);

    const split_at = blob.len / 2;

    const append0_url = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/upload/append/{s}?token={s}&index=0",
        .{ base_url, upload_id, upload_token },
    );
    defer std.testing.allocator.free(append0_url);
    var append0_resp = try testRequest(std.testing.allocator, append0_url, .POST, blob[0..split_at]);
    defer append0_resp.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 200), append0_resp.status);

    const append1_url = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/upload/append/{s}?token={s}&index=1",
        .{ base_url, upload_id, upload_token },
    );
    defer std.testing.allocator.free(append1_url);
    var append1_resp = try testRequest(std.testing.allocator, append1_url, .POST, blob[split_at..]);
    defer append1_resp.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 200), append1_resp.status);

    const finish_url = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/upload/finish/{s}?token={s}",
        .{ base_url, upload_id, upload_token },
    );
    defer std.testing.allocator.free(finish_url);
    var finish_resp = try testRequest(std.testing.allocator, finish_url, .POST, "");
    defer finish_resp.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 200), finish_resp.status);

    const download_url = try std.fmt.allocPrint(std.testing.allocator, "{s}/download/{s}", .{ base_url, upload_id });
    defer std.testing.allocator.free(download_url);
    var download_resp = try testRequest(std.testing.allocator, download_url, .GET, "");
    defer download_resp.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 200), download_resp.status);

    var decrypted = try blob_format.decryptFileBuffer(std.testing.allocator, download_resp.body, key);
    defer decrypted.deinit(std.testing.allocator);
    try std.testing.expect(decrypted.verified);
    try std.testing.expectEqualStrings(filename, decrypted.filename);
    try std.testing.expectEqualSlices(u8, plaintext, decrypted.bytes);

    const blob_path = try storage.blobPath(std.testing.allocator, blob_dir, upload_id);
    defer std.testing.allocator.free(blob_path);
    const meta_path = try storage.metaPath(std.testing.allocator, blob_dir, upload_id);
    defer std.testing.allocator.free(meta_path);

    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(blob_path, .{}));
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(meta_path, .{}));
}

test "relay delete requires correct token and removes blob" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const blob_dir = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/relay-delete-blobs", .{tmp.sub_path});
    defer std.testing.allocator.free(blob_dir);

    const cfg = testRuntimeConfig(blob_dir, 0);
    var port = std.atomic.Value(u16).init(0);

    const server_thread = try std.Thread.spawn(.{}, serveTestRelayOrPanic, .{ cfg, 5, &port });
    defer server_thread.join();

    while (port.load(.acquire) == 0) {
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }

    const key = [_]u8{0x23} ** 32;
    const blob = try blob_format.encryptFileBuffer(std.testing.allocator, "delete me", "delete.txt", key);
    defer std.testing.allocator.free(blob);

    const base_url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{port.load(.acquire)});
    defer std.testing.allocator.free(base_url);

    const start_url = try std.fmt.allocPrint(std.testing.allocator, "{s}/upload/start", .{base_url});
    defer std.testing.allocator.free(start_url);
    var start_resp = try testRequest(std.testing.allocator, start_url, .POST, "");
    defer start_resp.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 200), start_resp.status);

    const upload_id = try extractJsonString(std.testing.allocator, start_resp.body, "id");
    defer std.testing.allocator.free(upload_id);
    const upload_token = try extractJsonString(std.testing.allocator, start_resp.body, "token");
    defer std.testing.allocator.free(upload_token);

    const append_url = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/upload/append/{s}?token={s}&index=0",
        .{ base_url, upload_id, upload_token },
    );
    defer std.testing.allocator.free(append_url);
    var append_resp = try testRequest(std.testing.allocator, append_url, .POST, blob);
    defer append_resp.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 200), append_resp.status);

    const finish_url = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/upload/finish/{s}?token={s}",
        .{ base_url, upload_id, upload_token },
    );
    defer std.testing.allocator.free(finish_url);
    var finish_resp = try testRequest(std.testing.allocator, finish_url, .POST, "");
    defer finish_resp.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 200), finish_resp.status);

    const bad_delete_url = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/delete/{s}?token=wrongtoken",
        .{ base_url, upload_id },
    );
    defer std.testing.allocator.free(bad_delete_url);
    var bad_delete_resp = try testRequest(std.testing.allocator, bad_delete_url, .DELETE, "");
    defer bad_delete_resp.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 403), bad_delete_resp.status);

    const good_delete_url = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/delete/{s}?token={s}",
        .{ base_url, upload_id, upload_token },
    );
    defer std.testing.allocator.free(good_delete_url);
    var good_delete_resp = try testRequest(std.testing.allocator, good_delete_url, .DELETE, "");
    defer good_delete_resp.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 204), good_delete_resp.status);

    const blob_path = try storage.blobPath(std.testing.allocator, blob_dir, upload_id);
    defer std.testing.allocator.free(blob_path);
    const meta_path = try storage.metaPath(std.testing.allocator, blob_dir, upload_id);
    defer std.testing.allocator.free(meta_path);

    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(blob_path, .{}));
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(meta_path, .{}));
}
