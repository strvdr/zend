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
    // Incomplete uploads live as two files: the .part payload and the .upload
    // progress record. We always clean them up as a pair.
    if (tmpBlobPath(allocator, blob_dir, id)) |p| {
        defer allocator.free(p);
        std.fs.cwd().deleteFile(p) catch {};
    } else |_| {}

    if (uploadStatePath(allocator, blob_dir, id)) |p| {
        defer allocator.free(p);
        std.fs.cwd().deleteFile(p) catch {};
    } else |_| {}
}

test "deleteBlob removes ciphertext and metadata files together" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const blob_dir = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/blob-store", .{tmp.sub_path});
    defer std.testing.allocator.free(blob_dir);

    try std.fs.cwd().makePath(blob_dir);

    const id = "blob123";
    const blob_path = try blobPath(std.testing.allocator, blob_dir, id);
    defer std.testing.allocator.free(blob_path);

    const meta_path = try metaPath(std.testing.allocator, blob_dir, id);
    defer std.testing.allocator.free(meta_path);

    {
        const file = try std.fs.cwd().createFile(blob_path, .{});
        defer file.close();
        try file.writeAll("ciphertext");
    }
    {
        const file = try std.fs.cwd().createFile(meta_path, .{});
        defer file.close();
        try file.writeAll("token\n123\n");
    }

    deleteBlob(std.testing.allocator, blob_dir, id);

    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(blob_path, .{}));
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(meta_path, .{}));
}

test "deleteUploadTempFiles removes part and state files together" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const blob_dir = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/upload-store", .{tmp.sub_path});
    defer std.testing.allocator.free(blob_dir);

    try std.fs.cwd().makePath(blob_dir);

    const id = "upload123";
    const part_path = try tmpBlobPath(std.testing.allocator, blob_dir, id);
    defer std.testing.allocator.free(part_path);

    const state_path = try uploadStatePath(std.testing.allocator, blob_dir, id);
    defer std.testing.allocator.free(state_path);

    {
        const file = try std.fs.cwd().createFile(part_path, .{});
        defer file.close();
        try file.writeAll("partial");
    }
    {
        const file = try std.fs.cwd().createFile(state_path, .{});
        defer file.close();
        try file.writeAll("token\n123\n0\n7\n");
    }

    deleteUploadTempFiles(std.testing.allocator, blob_dir, id);

    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(part_path, .{}));
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(state_path, .{}));
}
