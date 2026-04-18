const std = @import("std");
const runtime_config = @import("runtime_config.zig");
const http_helpers = @import("http_helpers.zig");
const upload = @import("routes/upload.zig");
const download = @import("routes/download.zig");
const delete = @import("routes/delete.zig");
const reaper = @import("reaper.zig");
const rate_limit = @import("rate_limit.zig");

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
