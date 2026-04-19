const std = @import("std");
const http = @import("http");

pub const RELAY_URL = "https://relay.zend.foo";
pub const APP_URL = "https://www.zend.foo";

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
    const url = RELAY_URL ++ "/upload/start";
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
    const url = try std.fmt.allocPrint(
        allocator,
        RELAY_URL ++ "/upload/append/{s}?token={s}&index={d}",
        .{ id, token, index },
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
    const url = try std.fmt.allocPrint(
        allocator,
        RELAY_URL ++ "/upload/finish/{s}?token={s}",
        .{ id, token },
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
    const url = try std.fmt.allocPrint(allocator, RELAY_URL ++ "/download/{s}", .{id});
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
