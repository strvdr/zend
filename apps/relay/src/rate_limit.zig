const std = @import("std");
const runtime_config = @import("runtime_config.zig");

pub const RouteKind = enum {
    upload_start,
    upload_append,
    upload_finish,
    download,
    other,
};

const Entry = struct {
    window_started_at: i64,
    total_requests: u32,
    upload_starts: u32,
    upload_appends: u32,
    upload_finishes: u32,
    downloads: u32,
};

pub const Decision = struct {
    allowed: bool,
    retry_after_seconds: u32,
};

pub const RateLimiter = struct {
    allocator: std.mem.Allocator,
    cfg: runtime_config.RuntimeConfig,
    mutex: std.Thread.Mutex = .{},
    entries: std.StringHashMap(Entry),

    pub fn init(allocator: std.mem.Allocator, cfg: runtime_config.RuntimeConfig) RateLimiter {
        return .{
            .allocator = allocator,
            .cfg = cfg,
            .entries = std.StringHashMap(Entry).init(allocator),
        };
    }

    pub fn deinit(self: *RateLimiter) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.entries.deinit();
    }

    pub fn allow(self: *RateLimiter, ip: []const u8, route: RouteKind) !Decision {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.timestamp();
        const window = self.cfg.rate_limit_window_seconds;

        const gop = try self.entries.getOrPut(ip);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, ip);
            gop.value_ptr.* = .{
                .window_started_at = now,
                .total_requests = 0,
                .upload_starts = 0,
                .upload_appends = 0,
                .upload_finishes = 0,
                .downloads = 0,
            };
        }

        var entry = gop.value_ptr;
        if (now - entry.window_started_at >= window) {
            entry.* = .{
                .window_started_at = now,
                .total_requests = 0,
                .upload_starts = 0,
                .upload_appends = 0,
                .upload_finishes = 0,
                .downloads = 0,
            };
        }

        if (entry.total_requests >= self.cfg.rate_limit_max_requests_per_ip) {
            return .{ .allowed = false, .retry_after_seconds = retryAfter(now, entry.window_started_at, window) };
        }

        switch (route) {
            .upload_start => {
                if (entry.upload_starts >= self.cfg.rate_limit_max_upload_starts_per_ip) {
                    return .{ .allowed = false, .retry_after_seconds = retryAfter(now, entry.window_started_at, window) };
                }
            },
            .upload_append => {
                if (entry.upload_appends >= self.cfg.rate_limit_max_upload_appends_per_ip) {
                    return .{ .allowed = false, .retry_after_seconds = retryAfter(now, entry.window_started_at, window) };
                }
            },
            .upload_finish => {
                if (entry.upload_finishes >= self.cfg.rate_limit_max_upload_finishes_per_ip) {
                    return .{ .allowed = false, .retry_after_seconds = retryAfter(now, entry.window_started_at, window) };
                }
            },
            .download => {
                if (entry.downloads >= self.cfg.rate_limit_max_downloads_per_ip) {
                    return .{ .allowed = false, .retry_after_seconds = retryAfter(now, entry.window_started_at, window) };
                }
            },
            .other => {},
        }

        entry.total_requests += 1;
        switch (route) {
            .upload_start => entry.upload_starts += 1,
            .upload_append => entry.upload_appends += 1,
            .upload_finish => entry.upload_finishes += 1,
            .download => entry.downloads += 1,
            .other => {},
        }

        return .{ .allowed = true, .retry_after_seconds = 0 };
    }
};

fn retryAfter(now: i64, started: i64, window: i64) u32 {
    const remaining = (started + window) - now;
    if (remaining <= 0) return 1;
    return @intCast(remaining);
}
