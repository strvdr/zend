const std = @import("std");
const blob_format = @import("blob_format");
const relay = @import("relay");
const progress = @import("progress");
const tcp = @import("tcp");
const handshake = @import("handshake");
const transfer = @import("transfer");

const CHUNK_SIZE: usize = 64 * 1024;

fn printRelaySendError(err: anyerror) void {
    switch (err) {
        relay.Error.PayloadTooLarge => progress.printError("upload rejected: file exceeds the relay size limit", .{}),
        relay.Error.RateLimited => progress.printError("upload rate-limited by relay; try again in a moment", .{}),
        relay.Error.RelayUnavailable => progress.printError("relay is unavailable right now", .{}),
        relay.Error.InvalidToken => progress.printError("upload session was rejected by relay", .{}),
        relay.Error.Conflict => progress.printError("upload state conflict at relay; retry the upload", .{}),
        else => progress.printError("upload failed: {s}", .{@errorName(err)}),
    }
}

fn printP2PSendError(err: anyerror) void {
    switch (err) {
        error.ConnectionRefused => progress.printError("peer is not listening on that address/port", .{}),
        error.ConnectionTimedOut => progress.printError("connection timed out before the peer responded", .{}),
        error.NetworkUnreachable => progress.printError("network unreachable; check the address and your connection", .{}),
        error.HostUnreachable => progress.printError("host unreachable; check the peer address", .{}),
        error.EndOfStream => progress.printError("peer closed the connection before the transfer completed", .{}),
        error.HandshakeFailed => progress.printError("secure handshake failed", .{}),
        error.TransferFailed => progress.printError("peer rejected the transfer", .{}),
        error.BrokenPipe => progress.printError("connection dropped during transfer", .{}),
        else => progress.printError("transfer failed: {s}", .{@errorName(err)}),
    }
}

pub fn run(filePath: []const u8, allocator: std.mem.Allocator) !void {
    return runRelay(filePath, allocator);
}

pub fn runRelay(filePath: []const u8, allocator: std.mem.Allocator) !void {
    progress.printHeader();
    const started_ms = std.time.milliTimestamp();

    const file = std.fs.cwd().openFile(filePath, .{}) catch |err| {
        progress.printError("could not open {s}: {s}", .{ filePath, @errorName(err) });
        return err;
    };
    defer file.close();

    const stat = file.stat() catch |err| {
        progress.printError("could not stat {s}: {s}", .{ filePath, @errorName(err) });
        return err;
    };

    const file_size = stat.size;
    const filename = std.fs.path.basename(filePath);

    var size_buf: [32]u8 = undefined;
    progress.printStep("→", "staging {s} ({s})", .{ filename, progress.formatSize(&size_buf, file_size) });
    progress.printDetail("encrypted locally before any bytes leave the machine", .{});

    var session_key: [32]u8 = undefined;
    std.crypto.random.bytes(&session_key);

    var session_spinner = progress.Spinner.start("creating relay session", progress.Palette.upload);
    var upload = relay.startUpload(allocator) catch |err| {
        printRelaySendError(err);
        return err;
    };
    defer upload.free(allocator);
    session_spinner.done("relay session ready");

    // EncryptSession emits metadata immediately on init(), so the first upload
    // append is the encrypted metadata frame.
    var enc = try blob_format.EncryptSession.init(allocator, session_key, filename, file_size);
    defer enc.deinit();

    var upload_index: u32 = 0;
    var wire_bytes: u64 = 0;

    relay.appendUpload(allocator, upload.id, upload.token, upload_index, enc.resultSlice()) catch |err| {
        printRelaySendError(err);
        return err;
    };

    wire_bytes += enc.resultSlice().len;
    upload_index += 1;

    var bar = progress.Progress.initStyled(file_size, "encrypt+upload", "\x1b[96m", "flow");
    var file_buf: [CHUNK_SIZE]u8 = undefined;

    while (true) {
        const n = file.read(&file_buf) catch |err| {
            progress.printError("read failed: {s}", .{@errorName(err)});
            return err;
        };

        if (n == 0) break;

        // Each plaintext chunk becomes one fresh encrypted frame batch in
        // enc.resultSlice(), then gets appended to the relay immediately.
        try enc.encryptChunk(file_buf[0..n]);
        relay.appendUpload(allocator, upload.id, upload.token, upload_index, enc.resultSlice()) catch |err| {
            if (bar.transferredBytes > 0) std.debug.print("\n", .{});
            printRelaySendError(err);
            return err;
        };

        wire_bytes += enc.resultSlice().len;
        upload_index += 1;
        bar.update(n);
    }
    bar.finish();

    try enc.finish();
    relay.appendUpload(allocator, upload.id, upload.token, upload_index, enc.resultSlice()) catch |err| {
        printRelaySendError(err);
        return err;
    };
    wire_bytes += enc.resultSlice().len;

    var finalize_spinner = progress.Spinner.start("sealing final integrity packet", progress.Palette.upload);
    relay.finishUpload(allocator, upload.id, upload.token) catch |err| {
        printRelaySendError(err);
        return err;
    };
    finalize_spinner.done("upload committed to relay");

    if (file_size > 0) {
        const ratio: f64 = @as(f64, @floatFromInt(wire_bytes)) /
            @as(f64, @floatFromInt(file_size)) * 100.0;
        var wire_buf: [32]u8 = undefined;
        progress.printDetail("sealed payload {s} · {d:.1}% of original · integrity trailer included", .{
            progress.formatSize(&wire_buf, wire_bytes),
            ratio,
        });
    }

    var key_encoded: [std.base64.url_safe_no_pad.Encoder.calcSize(32)]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&key_encoded, &session_key);

    const app_url = try relay.appUrl(allocator);
    defer allocator.free(app_url);

    const share_url = try std.fmt.allocPrint(allocator, "{s}/d/{s}#{s}", .{ app_url, upload.id, key_encoded });
    defer allocator.free(share_url);

    progress.printStep("done", "upload complete", .{});
    progress.printLink(share_url);
    progress.printNote("the fragment after # is the decryption key and is never sent to the relay", .{});
    progress.printNote("sealed blob includes an integrity packet so browser and CLI clients can verify contents", .{});
    progress.printNote("relay policy: one successful download, automatic expiry after 24 hours", .{});
    progress.printSummary(filename, file_size, std.time.milliTimestamp() - started_ms);
}

pub fn runP2P(filePath: []const u8, host: []const u8, port: u16, allocator: std.mem.Allocator) !void {
    progress.printHeader();
    const started_ms = std.time.milliTimestamp();

    const file = std.fs.cwd().openFile(filePath, .{}) catch |err| {
        progress.printError("could not open {s}: {s}", .{ filePath, @errorName(err) });
        return err;
    };
    defer file.close();

    const stat = file.stat() catch |err| {
        progress.printError("could not stat {s}: {s}", .{ filePath, @errorName(err) });
        return err;
    };

    const file_size = stat.size;
    const filename = std.fs.path.basename(filePath);

    var size_buf: [32]u8 = undefined;
    progress.printStep("→", "connecting to {s}:{d}", .{ host, port });
    progress.printDetail("sending {s} ({s}) directly peer-to-peer", .{
        filename,
        progress.formatSize(&size_buf, file_size),
    });

    const conn = tcp.connect(allocator, host, port) catch |err| {
        printP2PSendError(err);
        return err;
    };
    defer conn.close();

    progress.printStep("..", "performing handshake...", .{});
    const hs = handshake.handshakeSender(conn, allocator) catch |err| {
        printP2PSendError(err);
        return err;
    };
    progress.printStep("OK", "secure channel established", .{});

    // After the handshake, the transfer path reuses the negotiated session key
    // and connection id for all encrypted packets.
    transfer.sendFile(conn, hs.sessionKey, hs.connectionId, filePath, allocator) catch |err| {
        printP2PSendError(err);
        return err;
    };

    progress.printNote("peer-to-peer transfer completed without using the relay for file contents", .{});
    progress.printSummary(filename, file_size, std.time.milliTimestamp() - started_ms);
}
