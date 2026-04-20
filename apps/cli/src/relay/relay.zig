const std = @import("std");
const http = @import("http");

pub const DEFAULT_RELAY_URL = "https://relay.zend.foo";
pub const DEFAULT_APP_URL = "https://www.zend.foo";

pub const UploadSession = struct {
    id: []u8,
    token: []u8,

    pub fn free(self: UploadSession, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.token);
    }
};

pub const Error = error{
    InvalidResponse,
    UnexpectedStatus,
    NotFound,
    ExpiredOrConsumed,
    InvalidToken,
    PayloadTooLarge,
    RateLimited,
    Conflict,
    RelayUnavailable,
};

fn envOrDefault(
    allocator: std.mem.Allocator,
    key: []const u8,
    default_value: []const u8,
) ![]u8 {
    return std.process.getEnvVarOwned(allocator, key) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => try allocator.dupe(u8, default_value),
        else => err,
    };
}

pub fn relayUrl(allocator: std.mem.Allocator) ![]u8 {
    return envOrDefault(allocator, "ZEND_CLI_RELAY_URL", DEFAULT_RELAY_URL);
}

pub fn appUrl(allocator: std.mem.Allocator) ![]u8 {
    return envOrDefault(allocator, "ZEND_CLI_APP_URL", DEFAULT_APP_URL);
}

fn extractJsonString(allocator: std.mem.Allocator, json: []const u8, key: []const u8) ![]u8 {
    // This is intentionally a tiny string extractor, not a full JSON parser.
    // It is only suitable for the relay's small fixed responses like:
    //   {"id":"...","token":"..."}
    const pattern = try std.fmt.allocPrint(allocator, "\"{s}\":\"", .{key});
    defer allocator.free(pattern);

    const start = std.mem.indexOf(u8, json, pattern) orelse return error.InvalidResponse;
    const value_start = start + pattern.len;
    const rest = json[value_start..];
    const end_rel = std.mem.indexOfScalar(u8, rest, '"') orelse return error.InvalidResponse;
    return allocator.dupe(u8, rest[0..end_rel]);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn mapHttpError(status: u16, body: []const u8) Error!void {
    // Map raw relay HTTP statuses into CLI-facing errors that are easier to
    // present cleanly at the call site.
    switch (status) {
        401, 403 => return error.InvalidToken,
        404 => {
            // The relay uses 404 for both missing blobs and links that were
            // already consumed / expired, so the body text disambiguates them.
            if (containsIgnoreCase(body, "consumed") or containsIgnoreCase(body, "expired")) {
                return error.ExpiredOrConsumed;
            }
            return error.NotFound;
        },
        409 => return error.Conflict,
        413 => return error.PayloadTooLarge,
        429 => return error.RateLimited,
        500...599 => return error.RelayUnavailable,
        else => return error.UnexpectedStatus,
    }
}

fn requireSuccess(response: http.Response) !void {
    if (!response.isSuccess()) {
        // Log the raw relay response once here so higher-level callers can stay
        // focused on user-facing messaging.
        std.log.err("relay HTTP failure status={d} body={s}", .{ response.status, response.body });
        return mapHttpError(response.status, response.body);
    }
}

pub fn startUpload(allocator: std.mem.Allocator) !UploadSession {
    const base_url = try relayUrl(allocator);
    defer allocator.free(base_url);

    const url = try std.fmt.allocPrint(allocator, "{s}/upload/start", .{base_url});
    defer allocator.free(url);

    const response = try http.post(allocator, url, "");
    defer response.free(allocator);
    try requireSuccess(response);

    return .{
        .id = try extractJsonString(allocator, response.body, "id"),
        .token = try extractJsonString(allocator, response.body, "token"),
    };
}

pub fn appendUpload(
    allocator: std.mem.Allocator,
    id: []const u8,
    token: []const u8,
    index: u32,
    bytes: []const u8,
) !void {
    const base_url = try relayUrl(allocator);
    defer allocator.free(base_url);

    const url = try std.fmt.allocPrint(
        allocator,
        "{s}/upload/append/{s}?token={s}&index={d}",
        .{ base_url, id, token, index },
    );
    defer allocator.free(url);

    const response = try http.post(allocator, url, bytes);
    defer response.free(allocator);
    try requireSuccess(response);
}

pub fn finishUpload(
    allocator: std.mem.Allocator,
    id: []const u8,
    token: []const u8,
) !void {
    const base_url = try relayUrl(allocator);
    defer allocator.free(base_url);

    const url = try std.fmt.allocPrint(
        allocator,
        "{s}/upload/finish/{s}?token={s}",
        .{ base_url, id, token },
    );
    defer allocator.free(url);

    const response = try http.post(allocator, url, "");
    defer response.free(allocator);
    try requireSuccess(response);
}

pub fn downloadStream(
    allocator: std.mem.Allocator,
    id: []const u8,
    downstream: anytype,
    comptime on_chunk: fn (@TypeOf(downstream), []const u8) anyerror!void,
) !void {
    const base_url = try relayUrl(allocator);
    defer allocator.free(base_url);

    const url = try std.fmt.allocPrint(allocator, "{s}/download/{s}", .{ base_url, id });
    defer allocator.free(url);

    const Wrapper = struct {
        status: *u16,
        allocator: std.mem.Allocator,
        error_body: std.ArrayList(u8),
        downstream: @TypeOf(downstream),

        fn handle(self: *@This(), bytes: []const u8) anyerror!void {
            if (self.status.* >= 200 and self.status.* < 300) {
                // Successful downloads are streamed directly to the caller.
                try on_chunk(self.downstream, bytes);
            } else {
                // For error responses, capture the body so it can be logged and
                // mapped after the request completes.
                try self.error_body.appendSlice(self.allocator, bytes);
            }
        }
    };

    var status: u16 = 0;
    var wrapper = Wrapper{
        .status = &status,
        .allocator = allocator,
        .error_body = .empty,
        .downstream = downstream,
    };
    defer wrapper.error_body.deinit(allocator);

    try http.streamGet(allocator, url, &status, &wrapper, Wrapper.handle);

    if (status < 200 or status >= 300) {
        std.log.err("relay HTTP failure status={d} body={s}", .{ status, wrapper.error_body.items });
        return mapHttpError(status, wrapper.error_body.items);
    }
}

pub fn download(
    allocator: std.mem.Allocator,
    id: []const u8,
    out: anytype,
) !void {
    try downloadStream(allocator, id, out, struct {
        fn writeChunk(writer: @TypeOf(out), bytes: []const u8) anyerror!void {
            try writer.writeAll(bytes);
        }
    }.writeChunk);
}
