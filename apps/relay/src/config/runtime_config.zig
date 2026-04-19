const std = @import("std");
const defaults = @import("config");

pub const RuntimeConfig = struct {
    host: []const u8,
    port: u16,
    blob_dir: []const u8,
    max_upload_bytes: usize,
    max_append_body_bytes: usize,
    ttl_seconds: i64,
    incomplete_ttl_seconds: i64,
    allowed_origins: []const u8,
    rate_limit_window_seconds: i64,
    rate_limit_max_requests_per_ip: u32,
    rate_limit_max_upload_starts_per_ip: u32,
    rate_limit_max_upload_appends_per_ip: u32,
    rate_limit_max_upload_finishes_per_ip: u32,
    rate_limit_max_downloads_per_ip: u32,
};

pub fn load(allocator: std.mem.Allocator) !RuntimeConfig {
    return .{
        .host = try envOrDefault(allocator, "ZEND_RELAY_HOST", "0.0.0.0"),
        .port = try parseEnvOrDefault(u16, allocator, "ZEND_RELAY_PORT", defaults.DEFAULT_PORT),
        .blob_dir = try envOrDefault(allocator, "ZEND_BLOB_DIR", defaults.BLOB_DIR),
        .max_upload_bytes = try parseEnvOrDefault(usize, allocator, "ZEND_MAX_UPLOAD_BYTES", defaults.MAX_UPLOAD_SIZE),
        .max_append_body_bytes = try parseEnvOrDefault(usize, allocator, "ZEND_MAX_APPEND_BODY_BYTES", defaults.MAX_APPEND_BODY_SIZE),
        .ttl_seconds = try parseEnvOrDefault(i64, allocator, "ZEND_TTL_SECONDS", defaults.TTL_SECONDS),
        .incomplete_ttl_seconds = try parseEnvOrDefault(i64, allocator, "ZEND_INCOMPLETE_TTL_SECONDS", defaults.INCOMPLETE_TTL_SECONDS),
        .allowed_origins = try envOrDefault(allocator, "ZEND_ALLOWED_ORIGINS", "https://www.zend.foo"),
        .rate_limit_window_seconds = try parseEnvOrDefault(i64, allocator, "ZEND_RATE_LIMIT_WINDOW_SECONDS", defaults.RATE_LIMIT_WINDOW_SECONDS),
        .rate_limit_max_requests_per_ip = try parseEnvOrDefault(u32, allocator, "ZEND_RATE_LIMIT_MAX_REQUESTS_PER_IP", defaults.RATE_LIMIT_MAX_REQUESTS_PER_IP),
        .rate_limit_max_upload_starts_per_ip = try parseEnvOrDefault(u32, allocator, "ZEND_RATE_LIMIT_MAX_UPLOAD_STARTS_PER_IP", defaults.RATE_LIMIT_MAX_UPLOAD_STARTS_PER_IP),
        .rate_limit_max_upload_appends_per_ip = try parseEnvOrDefault(u32, allocator, "ZEND_RATE_LIMIT_MAX_UPLOAD_APPENDS_PER_IP", defaults.RATE_LIMIT_MAX_UPLOAD_APPENDS_PER_IP),
        .rate_limit_max_upload_finishes_per_ip = try parseEnvOrDefault(u32, allocator, "ZEND_RATE_LIMIT_MAX_UPLOAD_FINISHES_PER_IP", defaults.RATE_LIMIT_MAX_UPLOAD_FINISHES_PER_IP),
        .rate_limit_max_downloads_per_ip = try parseEnvOrDefault(u32, allocator, "ZEND_RATE_LIMIT_MAX_DOWNLOADS_PER_IP", defaults.RATE_LIMIT_MAX_DOWNLOADS_PER_IP),
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
