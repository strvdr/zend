const std = @import("std");

pub const Response = struct {
    status: u16,
    body: []u8,

    pub fn free(self: Response, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
    }

    pub fn isSuccess(self: Response) bool {
        return self.status >= 200 and self.status < 300;
    }
};

fn ChunkForwardWriter(
    comptime ContextType: type,
    comptime on_chunk: fn (ContextType, []const u8) anyerror!void,
) type {
    return struct {
        context: ContextType,
        interface: std.Io.Writer,
        callback_error: ?anyerror = null,

        const Self = @This();

        fn init(context: ContextType) Self {
            return .{
                .context = context,
                .interface = .{
                    .vtable = &.{
                        .drain = drain,
                    },
                    .buffer = &.{},
                },
            };
        }

        fn drain(
            io_w: *std.Io.Writer,
            data: []const []const u8,
            splat: usize,
        ) std.Io.Writer.Error!usize {
            const self: *Self = @alignCast(@fieldParentPtr("interface", io_w));

            var written: usize = 0;

            for (data, 0..) |chunk, i| {
                const reps: usize = if (i == data.len - 1) splat else 1;
                var r: usize = 0;
                while (r < reps) : (r += 1) {
                    if (chunk.len == 0) continue;

                    on_chunk(self.context, chunk) catch |err| {
                        // std.Io.Writer needs a writer-shaped failure, so stash
                        // the real callback error here and surface it later.
                        self.callback_error = err;
                        return error.WriteFailed;
                    };
                    written += chunk.len;
                }
            }

            return written;
        }

        fn finish(self: *Self) !void {
            if (self.callback_error) |err| return err;
        }
    };
}

fn AllocatingChunkSink(
    comptime ContextType: type,
    comptime on_chunk: fn (ContextType, []const u8) anyerror!void,
) type {
    return struct {
        context: ContextType,
        body: std.Io.Writer.Allocating,

        const Self = @This();

        fn init(allocator: std.mem.Allocator, context: ContextType) Self {
            return .{
                .context = context,
                .body = .init(allocator),
            };
        }

        fn deinit(self: *Self) void {
            self.body.deinit();
        }

        fn onChunk(self: *Self, bytes: []const u8) !void {
            try on_chunk(self.context, bytes);
            try self.body.writer.writeAll(bytes);
        }

        fn toOwnedSlice(self: *Self) ![]u8 {
            return try self.body.toOwnedSlice();
        }
    };
}

pub fn post(
    allocator: std.mem.Allocator,
    url: []const u8,
    body: []const u8,
) !Response {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var response_buf: std.Io.Writer.Allocating = .init(allocator);
    defer response_buf.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body,
        .response_writer = &response_buf.writer,
    });

    return .{
        .status = @intFromEnum(result.status),
        .body = try response_buf.toOwnedSlice(),
    };
}

pub fn get(
    allocator: std.mem.Allocator,
    url: []const u8,
    out: anytype,
) !Response {
    const Context = struct {
        out: @TypeOf(out),

        fn onChunk(self: @This(), bytes: []const u8) !void {
            try self.out.writeAll(bytes);
        }
    };

    var sink = AllocatingChunkSink(Context, Context.onChunk).init(allocator, .{
        .out = out,
    });
    defer sink.deinit();

    var writer =
        ChunkForwardWriter(*@TypeOf(sink), AllocatingChunkSink(Context, Context.onChunk).onChunk)
            .init(&sink);

    var status: u16 = 0;
    try streamGet(allocator, url, &status, &writer, streamWriterChunk);

    try writer.finish();

    return .{
        .status = status,
        .body = try sink.toOwnedSlice(),
    };
}

fn streamWriterChunk(
    writer: anytype,
    bytes: []const u8,
) !void {
    try writer.interface.writeAll(bytes);
}

pub fn streamGet(
    allocator: std.mem.Allocator,
    url: []const u8,
    status_out: *u16,
    context: anytype,
    comptime on_chunk: fn (@TypeOf(context), []const u8) anyerror!void,
) !void {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const uri = try std.Uri.parse(url);

    var req = try client.request(.GET, uri, .{});
    defer req.deinit();

    try req.sendBodiless();

    const response = try req.receiveHead(&.{});
    status_out.* = @intFromEnum(response.head.status);

    var body_buf: [64 * 1024]u8 = undefined;
    var body_reader = req.reader.bodyReader(
        &body_buf,
        response.head.transfer_encoding,
        response.head.content_length,
    );

    var writer = ChunkForwardWriter(@TypeOf(context), on_chunk).init(context);

    // streamRemaining() drives the response body incrementally into our chunk
    // callback without buffering the whole download in memory first.
    _ = try body_reader.streamRemaining(&writer.interface);
    try writer.finish();
}
