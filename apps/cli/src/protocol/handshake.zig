const std = @import("std");
const tcp = @import("tcp");
const message = @import("message");
const x25519 = @import("x25519");
const aead = @import("aead");

pub const HandshakeResult = struct {
    sessionKey: [32]u8,
    connectionId: [4]u8,
};

pub fn handshakeSender(conn: tcp.Connection, allocator: std.mem.Allocator) !HandshakeResult {
    // The sender begins by waiting for the receiver's hello packet.
    // That packet carries the receiver's public key plus the connection id
    // that both sides will later fold into every nonce.
    const helloPacket = try message.recvPacket(conn, allocator);
    defer helloPacket.free(allocator);

    if (helloPacket.packetType != .hello) return error.HandshakeFailed;
    if (helloPacket.payload.len != 36) return error.HandshakeFailed;

    const theirPubKey = helloPacket.payload[0..32].*;
    const connectionId = helloPacket.payload[32..36].*;

    // Generate an ephemeral keypair for this session only.
    // Nothing here is meant to be reused across transfers.
    var privateKey: [32]u8 = undefined;
    std.crypto.random.bytes(&privateKey);
    const pubKey = x25519.generatePublicKey(privateKey);

    try message.sendPacket(conn, allocator, .hello, &pubKey);

    // Both sides derive the same session key from their private key
    // and the other side's public key.
    const sessionKey = x25519.sharedSecret(privateKey, theirPubKey);

    // The ready packet proves both sides derived the same key.
    // We encrypt a fixed byte using nonce counter 0 semantics:
    // connection id in the first 4 bytes, remaining bytes zeroed.
    var readyByte = [_]u8{0xAA};
    var tag: [16]u8 = undefined;
    var nonce = [_]u8{0} ** 12;
    @memcpy(nonce[0..4], &connectionId);

    try aead.encrypt(sessionKey, nonce, readyByte[0..], &[_]u8{}, &tag, allocator);

    var readyPayload: [17]u8 = undefined;
    readyPayload[0] = readyByte[0];
    @memcpy(readyPayload[1..17], &tag);

    try message.sendPacket(conn, allocator, .ready, &readyPayload);

    return .{
        .sessionKey = sessionKey,
        .connectionId = connectionId,
    };
}

pub fn handshakeReceiver(conn: tcp.Connection, allocator: std.mem.Allocator) !HandshakeResult {
    // The receiver creates its ephemeral keypair first, then sends the hello
    // packet that seeds the session with both its public key and a fresh
    // connection id.
    var privateKey: [32]u8 = undefined;
    std.crypto.random.bytes(&privateKey);
    const pubKey = x25519.generatePublicKey(privateKey);

    var connectionId: [4]u8 = undefined;
    std.crypto.random.bytes(&connectionId);

    var helloPayload: [36]u8 = undefined;
    @memcpy(helloPayload[0..32], &pubKey);
    @memcpy(helloPayload[32..36], &connectionId);

    try message.sendPacket(conn, allocator, .hello, &helloPayload);

    const helloPacket = try message.recvPacket(conn, allocator);
    defer helloPacket.free(allocator);

    if (helloPacket.packetType != .hello) return error.HandshakeFailed;
    if (helloPacket.payload.len != 32) return error.HandshakeFailed;

    const theirPubKey = helloPacket.payload[0..32].*;
    const sessionKey = x25519.sharedSecret(privateKey, theirPubKey);

    // The sender must now prove it derived the same shared key.
    // If this authenticated byte does not decrypt correctly, the handshake
    // stops here instead of letting the transfer proceed with a bad key.
    const readyPacket = try message.recvPacket(conn, allocator);
    defer readyPacket.free(allocator);

    if (readyPacket.packetType != .ready) return error.HandshakeFailed;
    if (readyPacket.payload.len != 17) return error.HandshakeFailed;

    var readyByte = [_]u8{readyPacket.payload[0]};
    const tag = readyPacket.payload[1..17].*;

    var nonce = [_]u8{0} ** 12;
    @memcpy(nonce[0..4], &connectionId);

    try aead.decrypt(sessionKey, nonce, readyByte[0..], &[_]u8{}, tag, allocator);

    if (readyByte[0] != 0xAA) return error.HandshakeFailed;

    return .{
        .sessionKey = sessionKey,
        .connectionId = connectionId,
    };
}

test "handshake produces matching session keys" {
    const addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var server = try tcp.listen(addr);
    defer server.deinit();

    var senderResult: HandshakeResult = undefined;

    const t = try std.Thread.spawn(.{}, struct {
        fn run(listen_addr: std.net.Address, result: *HandshakeResult) !void {
            const conn = try tcp.connect(std.testing.allocator, "127.0.0.1", listen_addr.getPort());
            defer conn.close();
            result.* = try handshakeSender(conn, std.testing.allocator);
        }
    }.run, .{ server.listen_address, &senderResult });

    const conn = try tcp.accept(&server);
    defer conn.close();

    const receiverResult = try handshakeReceiver(conn, std.testing.allocator);

    t.join();

    try std.testing.expectEqualSlices(u8, &receiverResult.sessionKey, &senderResult.sessionKey);
    try std.testing.expectEqualSlices(u8, &receiverResult.connectionId, &senderResult.connectionId);
}
