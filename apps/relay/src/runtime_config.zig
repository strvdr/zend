const std = @import("std");
const defaults = @import("config.zig");

pub const RuntimeConfig = struct {
    host: []const u8,
    port: u16,
    blob_dir: []const u8,
    max_upload_bytes: usize,
    ttl_seconds: i64,
    incomplete_ttl_seconds: i64,
    allowed_origins: []const u8,
};

pub fn load(allocator: std.mem.Allocator) !RuntimeConfig {
    return .{
        .host = try envOrDefault(allocator, "ZEND_RELAY_HOST", "0.0.0.0"),
        .port = try parseEnvOrDefault(u16, allocator, "ZEND_RELAY_PORT", defaults.DEFAULT_PORT),
        .blob_dir = try envOrDefault(allocator, "ZEND_BLOB_DIR", defaults.BLOB_DIR),
        .max_upload_bytes = try parseEnvOrDefault(usize, allocator, "ZEND_MAX_UPLOAD_BYTES", defaults.MAX_UPLOAD_SIZE),
        .ttl_seconds = try parseEnvOrDefault(i64, allocator, "ZEND_TTL_SECONDS", defaults.TTL_SECONDS),
        .incomplete_ttl_seconds = try parseEnvOrDefault(i64, allocator, "ZEND_INCOMPLETE_TTL_SECONDS", defaults.INCOMPLETE_TTL_SECONDS),
        .allowed_origins = try envOrDefault(allocator, "ZEND_ALLOWED_ORIGINS", "*"),
    };
}

fn envOrDefault(
    allocator: std.mem.Allocator,
    key: []const u8,
    default_value: []const u8,
) ![]const u8 {
    return std.process.getEnvVarOwned(allocator, key) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => try allocator.dupe(u8, default_value),
        else => err,
    };
}

fn parseEnvOrDefault(
    comptime T: type,
    allocator: std.mem.Allocator,
    key: []const u8,
    default_value: T,
) !T {
    const value = std.process.getEnvVarOwned(allocator, key) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return default_value,
        else => return err,
    };
    defer allocator.free(value);

    return std.fmt.parseInt(T, value, 10);
}
