const std = @import("std");
const config = @import("config.zig");
const storage = @import("storage.zig");

pub fn reapLoop(allocator: std.mem.Allocator) void {
    while (true) {
        std.Thread.sleep(config.REAP_INTERVAL_NS);
        reapOnce(allocator);
    }
}

pub fn reapOnce(allocator: std.mem.Allocator) void {
    var dir = std.fs.cwd().openDir(config.BLOB_DIR, .{ .iterate = true }) catch return;
    defer dir.close();

    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".meta")) continue;

        const mp = std.fmt.allocPrint(allocator, config.BLOB_DIR ++ "/{s}", .{entry.name}) catch continue;
        defer allocator.free(mp);

        const content = std.fs.cwd().readFileAlloc(allocator, mp, 1024) catch continue;
        defer allocator.free(content);

        const newline = std.mem.indexOfScalar(u8, content, '\n') orelse continue;
        const ts_str = std.mem.trim(u8, content[newline + 1 ..], &std.ascii.whitespace);
        const created = std.fmt.parseInt(i64, ts_str, 10) catch continue;

        if (std.time.timestamp() - created > config.TTL_SECONDS) {
            const id = entry.name[0 .. entry.name.len - 5];
            storage.deleteBlob(allocator, id);
            std.log.info("reaped expired: {s}", .{id});
        }
    }
}
