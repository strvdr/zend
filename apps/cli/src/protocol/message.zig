const std = @import("std");
const tcp = @import("tcp");
const framing = @import("framing");

pub const PacketType = enum(u8) {
    hello = 0x01,
    ready = 0x02,
    metadata = 0x03,
    chunk = 0x04,
    done = 0x05,
    ack = 0x06,
};

pub const Packet = struct {
    packetType: PacketType,
    payload: []u8,
    rawBuf: []u8,

    pub fn free(self: Packet, allocator: std.mem.Allocator) void {
        // payload points into rawBuf, so only rawBuf should be freed.
        allocator.free(self.rawBuf);
    }
};

pub fn sendPacket(conn: tcp.Connection, allocator: std.mem.Allocator, pType: PacketType, payload: []const u8) !void {
    // The packet layer is intentionally tiny:
    // 1 byte type + raw payload, then handed to the framing layer.
    const buf = try allocator.alloc(u8, 1 + payload.len);
    defer allocator.free(buf);

    buf[0] = @intFromEnum(pType);
    @memcpy(buf[1..], payload);

    try framing.writeMessage(conn, buf);
}

pub fn recvPacket(conn: tcp.Connection, allocator: std.mem.Allocator) !Packet {
    const raw = try framing.readMessage(conn, allocator);
    errdefer allocator.free(raw);

    if (raw.len < 1) return error.InvalidPacket;

    
    // Packet parsing stays strict here so later protocol code can assume
    // the type byte has already been validated.
    const packet_type: PacketType = switch (raw[0]) {
        0x01 => .hello,
        0x02 => .ready,
        0x03 => .metadata,
        0x04 => .chunk,
        0x05 => .done,
        0x06 => .ack,
        else => return error.UnknownPacketType,
    };

    return .{
        .packetType = packet_type,
        .payload = raw[1..],
        .rawBuf = raw,
    };
}

test "send and receive typed packet" {
    const addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var server = try tcp.listen(addr);
    defer server.deinit();

    const t = try std.Thread.spawn(.{}, struct {
        fn run(listen_addr: std.net.Address) !void {
            const conn = try tcp.connect(std.testing.allocator, "127.0.0.1", listen_addr.getPort());
            defer conn.close();
            try sendPacket(conn, std.testing.allocator, .hello, "test payload");
        }
    }.run, .{server.listen_address});

    const conn = try tcp.accept(&server);
    defer conn.close();

    const pkt = try recvPacket(conn, std.testing.allocator);
    defer pkt.free(std.testing.allocator);

    try std.testing.expectEqual(PacketType.hello, pkt.packetType);
    try std.testing.expectEqualSlices(u8, "test payload", pkt.payload);

    t.join();
}
