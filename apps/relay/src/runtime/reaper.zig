const std = @import("std");
const config = @import("config");
const runtime_config = @import("runtime_config");
const storage = @import("storage");

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
        if (std.mem.endsWith(u8, entry.name, ".meta")) {
            reapCompletedEntry(allocator, cfg, entry.name);
            continue;
        }

        if (std.mem.endsWith(u8, entry.name, ".upload")) {
            reapIncompleteEntry(allocator, cfg, entry.name);
            continue;
        }
    }
}

fn reapCompletedEntry(
    allocator: std.mem.Allocator,
    cfg: runtime_config.RuntimeConfig,
    entry_name: []const u8,
) void {
    const meta_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ cfg.blob_dir, entry_name }) catch return;
    defer allocator.free(meta_path);

    const content = std.fs.cwd().readFileAlloc(allocator, meta_path, 1024) catch return;
    defer allocator.free(content);

    const newline = std.mem.indexOfScalar(u8, content, '\n') orelse return;
    const ts_str = std.mem.trim(u8, content[newline + 1 ..], &std.ascii.whitespace);
    const created = std.fmt.parseInt(i64, ts_str, 10) catch return;

    if (std.time.timestamp() - created > cfg.ttl_seconds) {
        const id = entry_name[0 .. entry_name.len - ".meta".len];
        storage.deleteBlob(allocator, cfg.blob_dir, id);
        std.log.info("reaped expired blob id={s}", .{id});
    }
}

fn reapIncompleteEntry(
    allocator: std.mem.Allocator,
    cfg: runtime_config.RuntimeConfig,
    entry_name: []const u8,
) void {
    const upload_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ cfg.blob_dir, entry_name }) catch return;
    defer allocator.free(upload_path);

    const content = std.fs.cwd().readFileAlloc(allocator, upload_path, 4096) catch return;
    defer allocator.free(content);

    var it = std.mem.splitScalar(u8, content, '\n');

    // .upload files are tiny line-based state snapshots written by the append
    // route, so reaping can recover without needing any extra index.
    _ = it.next() orelse return; // token
    const created_line = it.next() orelse return;
    const created = std.fmt.parseInt(i64, created_line, 10) catch return;

    if (std.time.timestamp() - created > cfg.incomplete_ttl_seconds) {
        const id = entry_name[0 .. entry_name.len - ".upload".len];
        storage.deleteUploadTempFiles(allocator, cfg.blob_dir, id);
        std.log.info("reaped incomplete upload id={s}", .{id});
    }
}
