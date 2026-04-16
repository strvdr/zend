const std = @import("std");
const ids = @import("../ids.zig");
const storage = @import("../storage.zig");
const http_helpers = @import("../http_helpers.zig");
const runtime_config = @import("../runtime_config.zig");

pub fn handleDelete(
    req: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    cfg: runtime_config.RuntimeConfig,
) !void {
    const target = req.head.target;

    const qmark = std.mem.indexOfScalar(u8, target, '?');
    const path_only = if (qmark) |i| target[0..i] else target;
    const query = if (qmark) |i| target[i + 1 ..] else "";

    const id = http_helpers.extractPathSuffix(path_only, "/blob/") orelse {
        http_helpers.respondText(req, cfg, .bad_request, "Missing id");
        return;
    };

    if (!ids.isValidId(id)) {
        http_helpers.respondText(req, cfg, .bad_request, "Invalid id");
        return;
    }

    var token: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |part| {
        if (std.mem.startsWith(u8, part, "token=")) {
            token = part["token=".len..];
            break;
        }
    }

    const provided_token = token orelse {
        http_helpers.respondText(req, cfg, .bad_request, "Missing token");
        return;
    };

    const meta_path = try storage.metaPathSlice(allocator, cfg.blob_dir, id);
    defer allocator.free(meta_path);

    const meta = std.fs.cwd().readFileAlloc(allocator, meta_path, 1024) catch {
        http_helpers.respondText(req, cfg, .not_found, "Not found");
        return;
    };
    defer allocator.free(meta);

    const newline = std.mem.indexOfScalar(u8, meta, '\n') orelse {
        http_helpers.respondText(req, cfg, .internal_server_error, "Corrupt metadata");
        return;
    };

    const stored_token = std.mem.trim(u8, meta[0..newline], &std.ascii.whitespace);

    if (!std.mem.eql(u8, stored_token, provided_token)) {
        http_helpers.respondText(req, cfg, .forbidden, "Invalid token");
        return;
    }

    storage.deleteBlob(allocator, cfg.blob_dir, id);

    try req.respond("", .{
        .status = .no_content,
        .extra_headers = &.{
            .{ .name = "access-control-allow-origin", .value = cfg.allowed_origins },
        },
    });

}
