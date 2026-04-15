const std = @import("std");

pub const DEFAULT_PORT: u16 = 8080;
pub const BLOB_DIR = "blobs";
pub const MAX_UPLOAD_SIZE: usize = 512 * 1024 * 1024; // 512 MiB
pub const MAX_APPEND_BODY_SIZE: usize = 1024 * 1024; // 1 MiB
pub const TTL_SECONDS: i64 = 24 * 60 * 60; // 24 hours
pub const INCOMPLETE_TTL_SECONDS: i64 = 60 * 60; // 1 hour
pub const REAP_INTERVAL_NS: u64 = 60 * std.time.ns_per_s;

pub const RATE_LIMIT_WINDOW_SECONDS: i64 = 60;
pub const RATE_LIMIT_MAX_REQUESTS_PER_IP: u32 = 240;
pub const RATE_LIMIT_MAX_UPLOAD_STARTS_PER_IP: u32 = 20;
pub const RATE_LIMIT_MAX_UPLOAD_APPENDS_PER_IP: u32 = 1200;
pub const RATE_LIMIT_MAX_UPLOAD_FINISHES_PER_IP: u32 = 40;
pub const RATE_LIMIT_MAX_DOWNLOADS_PER_IP: u32 = 120;
