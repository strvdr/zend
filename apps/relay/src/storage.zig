const std = @import("std");
const config = @import("config.zig");

pub fn blobPath(allocator: std.mem.Allocator, id: *const [16]u8) ![]u8 {
    return std.fmt.allocPrint(allocator, config.BLOB_DIR ++ "/{s}", .{id});
}

pub fn blobPathSlice(allocator: std.mem.Allocator, id: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, config.BLOB_DIR ++ "/{s}", .{id});
}

pub fn metaPath(allocator: std.mem.Allocator, id: *const [16]u8) ![]u8 {
    return std.fmt.allocPrint(allocator, config.BLOB_DIR ++ "/{s}.meta", .{id});
}

pub fn metaPathSlice(allocator: std.mem.Allocator, id: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, config.BLOB_DIR ++ "/{s}.meta", .{id});
}

pub fn deleteBlob(allocator: std.mem.Allocator, id: []const u8) void {
    if (blobPathSlice(allocator, id)) |p| {
        defer allocator.free(p);
        std.fs.cwd().deleteFile(p) catch {};
    } else |_| {}

    if (metaPathSlice(allocator, id)) |p| {
        defer allocator.free(p);
        std.fs.cwd().deleteFile(p) catch {};
    } else |_| {}
}
