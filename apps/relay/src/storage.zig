const std = @import("std");

pub fn blobPath(
    allocator: std.mem.Allocator,
    blob_dir: []const u8,
    id: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ blob_dir, id });
}

pub fn blobPathSlice(
    allocator: std.mem.Allocator,
    blob_dir: []const u8,
    id: []const u8,
) ![]u8 {
    return blobPath(allocator, blob_dir, id);
}

pub fn metaPath(
    allocator: std.mem.Allocator,
    blob_dir: []const u8,
    id: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}.meta", .{ blob_dir, id });
}

pub fn metaPathSlice(
    allocator: std.mem.Allocator,
    blob_dir: []const u8,
    id: []const u8,
) ![]u8 {
    return metaPath(allocator, blob_dir, id);
}

pub fn tmpBlobPath(
    allocator: std.mem.Allocator,
    blob_dir: []const u8,
    id: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}.part", .{ blob_dir, id });
}

pub fn uploadStatePath(
    allocator: std.mem.Allocator,
    blob_dir: []const u8,
    id: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}.upload", .{ blob_dir, id });
}

pub fn deleteBlob(
    allocator: std.mem.Allocator,
    blob_dir: []const u8,
    id: []const u8,
) void {
    if (blobPathSlice(allocator, blob_dir, id)) |p| {
        defer allocator.free(p);
        std.fs.cwd().deleteFile(p) catch {};
    } else |_| {}

    if (metaPathSlice(allocator, blob_dir, id)) |p| {
        defer allocator.free(p);
        std.fs.cwd().deleteFile(p) catch {};
    } else |_| {}
}

pub fn deleteUploadTempFiles(
    allocator: std.mem.Allocator,
    blob_dir: []const u8,
    id: []const u8,
) void {
    if (tmpBlobPath(allocator, blob_dir, id)) |p| {
        defer allocator.free(p);
        std.fs.cwd().deleteFile(p) catch {};
    } else |_| {}

    if (uploadStatePath(allocator, blob_dir, id)) |p| {
        defer allocator.free(p);
        std.fs.cwd().deleteFile(p) catch {};
    } else |_| {}
}
