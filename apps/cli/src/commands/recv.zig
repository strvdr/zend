const std = @import("std");
const tcp = @import("tcp");
const handshake = @import("handshake");
const transfer = @import("transfer");
const progress = @import("progress");

fn printReceiveHints(port: u16) void {
    // Keep the first-run hints close to the listen step so local testing is
    // obvious without needing to read the help text first.
    progress.printDetail("local test: zend ./file 127.0.0.1:{d}", .{ port });
    progress.printDetail("LAN send:   zend ./file <your-ip>:{d}", .{ port });
}

fn printRecvError(err: anyerror) void {
    // Map lower-level transport / protocol failures into messages that are
    // easier to understand from the CLI.
    switch (err) {
        error.ConnectionRefused => progress.printError("incoming connection was refused", .{}),
        error.ConnectionTimedOut => progress.printError("connection timed out", .{}),
        error.EndOfStream => progress.printError("peer closed the connection before completion", .{}),
        error.HandshakeFailed => progress.printError("secure handshake failed", .{}),
        error.InvalidPacket => progress.printError("received malformed packet data", .{}),
        error.UnexpectedPacketType => progress.printError("received packets in an unexpected order", .{}),
        error.OutputFileExists => progress.printError("refusing to overwrite an existing file", .{}),
        error.InvalidCompressionFlag => progress.printError("received an unknown compression flag", .{}),
        error.InvalidChunkOrder => progress.printError("received chunks out of order", .{}),
        error.FileTooLarge => progress.printError("incoming file metadata exceeded safe limits", .{}),
        else => progress.printError("receive failed: {s}", .{ @errorName(err) }),
    }
}

pub fn run(port: u16, outputDir: []const u8, allocator: std.mem.Allocator) !void {
    progress.printHeader();

    const addr = try std.net.Address.parseIp("0.0.0.0", port);
    var server = tcp.listen(addr) catch |err| {
        progress.printError("could not listen on port {d}: {s}", .{ port, @errorName(err) });
        return err;
    };
    defer server.deinit();

    progress.printStep("..", "listening on port {d}", .{ port });
    printReceiveHints(port);

    // Receive mode accepts exactly one connection, handles one transfer,
    // then exits. That keeps the CLI behavior simple and predictable.
    const conn = tcp.accept(&server) catch |err| {
        printRecvError(err);
        return err;
    };
    defer conn.close();

    progress.printStep("OK", "connection accepted", .{});
    progress.printStep("..", "performing key exchange...", .{});

    const hs = handshake.handshakeReceiver(conn, allocator) catch |err| {
        printRecvError(err);
        return err;
    };
    progress.printStep("OK", "secure channel established (X25519 + ChaCha20-Poly1305)", .{});

    const start_time = std.time.milliTimestamp();

    // After the handshake succeeds, the receiver hands off to the transfer
    // layer, which validates packet order, integrity, and file safety rules.
    const received = transfer.recvFile(conn, hs.sessionKey, hs.connectionId, outputDir, allocator) catch |err| {
        printRecvError(err);
        return err;
    };
    defer allocator.free(received.filename);

    progress.printStep("..", "Finalizing transfer...", .{});
    progress.printNote("peer-to-peer transfer completed without using the relay for file contents", .{});
    progress.printSummary(received.filename, received.file_size, std.time.milliTimestamp() - start_time);
}
