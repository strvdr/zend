const std = @import("std");
const tcp = @import("tcp");

pub const MAX_MESSAGE_SIZE: u32 = 16 * 1024 * 1024;

pub fn writeMessage(conn: tcp.Connection, data: []const u8) !void {
    // Every message on the wire is length-prefixed with a big-endian u32.
    // This keeps packet boundaries explicit even though TCP itself is a stream.
    var lenBuf: [4]u8 = undefined;
    std.mem.writeInt(u32, &lenBuf, @intCast(data.len), .big);
    try conn.writeAll(&lenBuf);
    try conn.writeAll(data);
}

pub fn readMessage(conn: tcp.Connection, allocator: std.mem.Allocator) ![]u8 {
    var lenBuf: [4]u8 = undefined;
    try readExact(conn, &lenBuf);

    const len = std.mem.readInt(u32, &lenBuf, .big);
    if (len > MAX_MESSAGE_SIZE) {
        // Reject oversized frames before allocating.
        // This is both a sanity check and a basic abuse guard.
        return error.MessageTooLarge;
    }

    const buf = try allocator.alloc(u8, len);
    errdefer allocator.free(buf);

    try readExact(conn, buf);
    return buf;
}

fn readExact(conn: tcp.Connection, buf: []u8) !void {
    // TCP may return fewer bytes than requested even during normal operation.
    // Keep reading until the buffer is full or the peer closes the stream.
    var offset: usize = 0;
    while (offset < buf.len) {
        const n = try conn.read(buf[offset..]);
        if (n == 0) return error.EndOfStream;
        offset += n;
    }
}

pub fn freeMessage(allocator: std.mem.Allocator, msg: []u8) void {
    allocator.free(msg);
}

test "send and receive framed message over loopback" {
    const addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var server = try tcp.listen(addr);
    defer server.deinit();

    const t = try std.Thread.spawn(.{}, struct {
        fn run(listen_addr: std.net.Address) !void {
            const conn = try tcp.connect(std.testing.allocator, "127.0.0.1", listen_addr.getPort());
            defer conn.close();
            try writeMessage(conn, "hello from zend");
        }
    }.run, .{server.listen_address});

    const client = try tcp.accept(&server);
    defer client.close();

    const msg = try readMessage(client, std.testing.allocator);
    defer freeMessage(std.testing.allocator, msg);

    try std.testing.expectEqualSlices(u8, "hello from zend", msg);

    t.join();
}

test "large message exercises partial reads" {
    const addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var server = try tcp.listen(addr);
    defer server.deinit();

    const t = try std.Thread.spawn(.{}, struct {
        fn run(listen_addr: std.net.Address) !void {
            const conn = try tcp.connect(std.testing.allocator, "127.0.0.1", listen_addr.getPort());
            defer conn.close();

            var payload: [100_000]u8 = undefined;
            for (&payload, 0..) |*byte, i| {
                byte.* = @intCast(i % 251);
            }

            try writeMessage(conn, &payload);
        }
    }.run, .{server.listen_address});

    const client = try tcp.accept(&server);
    defer client.close();

    const msg = try readMessage(client, std.testing.allocator);
    defer freeMessage(std.testing.allocator, msg);

    try std.testing.expectEqual(@as(usize, 100_000), msg.len);

    for (msg, 0..) |byte, i| {
        try std.testing.expectEqual(@as(u8, @intCast(i % 251)), byte);
    }

    t.join();
}
