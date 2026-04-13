const std = @import("std");
const config = @import("config.zig");
const runtime_config = @import("runtime_config.zig");
const storage = @import("storage.zig");

pub fn reapLoop(
    allocator: std.mem.Allocator,
    cfg: runtime_config.RuntimeConfig,
) void {
    while (true) {
        std.Thread.sleep(config.REAP_INTERVAL_NS);
        reapOnce(allocator, cfg);
    }
}

pub fn reapOnce(
    allocator: std.mem.Allocator,
    cfg: runtime_config.RuntimeConfig,
) void {
    var dir = std.fs.cwd().openDir(cfg.blob_dir, .{ .iterate = true }) catch return;
    defer dir.close();

    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".meta")) continue;

        const meta_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ cfg.blob_dir, entry.name }) catch continue;
        defer allocator.free(meta_path);

        const content = std.fs.cwd().readFileAlloc(allocator, meta_path, 1024) catch continue;
        defer allocator.free(content);

        const newline = std.mem.indexOfScalar(u8, content, '\n') orelse continue;
        const ts_str = std.mem.trim(u8, content[newline + 1 ..], &std.ascii.whitespace);
        const created = std.fmt.parseInt(i64, ts_str, 10) catch continue;

        if (std.time.timestamp() - created > cfg.ttl_seconds) {
            const id = entry.name[0 .. entry.name.len - ".meta".len];
            storage.deleteBlob(allocator, cfg.blob_dir, id);
            std.log.info("reaped expired: {s}", .{id});
        }
    }
}
