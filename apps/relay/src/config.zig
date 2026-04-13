const std = @import("std");

pub const DEFAULT_PORT: u16 = 8080;
pub const BLOB_DIR = "blobs";
pub const MAX_UPLOAD_SIZE: usize = 512 * 1024 * 1024; // 512 MiB
pub const TTL_SECONDS: i64 = 24 * 60 * 60; // 24 hours
pub const REAP_INTERVAL_NS: u64 = 60 * std.time.ns_per_s;
