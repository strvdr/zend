const std = @import("std");
const runtime_config = @import("runtime_config");

pub fn handleOptions(
    req: *std.http.Server.Request,
    cfg: runtime_config.RuntimeConfig,
) !void {
    try req.respond("", .{
        .status = .no_content,
        .extra_headers = &.{
            .{ .name = "access-control-allow-origin", .value = cfg.allowed_origins },
            .{ .name = "access-control-allow-methods", .value = "GET, POST, DELETE, OPTIONS" },
            .{ .name = "access-control-allow-headers", .value = "content-type" },
            .{ .name = "access-control-max-age", .value = "86400" },
        },
    });
}
