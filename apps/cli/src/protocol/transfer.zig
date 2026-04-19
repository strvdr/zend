const std = @import("std");
const tcp = @import("tcp");
const message = @import("message");
const aead = @import("aead");
const huffman = @import("huffman");
const progress = @import("progress");

const CHUNK_SIZE: usize = 64 * 1024;
const CHUNK_HEADER_SIZE: usize = 4 + 1;
const MAX_FILENAME_LEN: usize = 4096;

pub const ReceiveResult = struct {
    filename: []u8,
    file_size: u64,
};

fn buildNonce(connectionId: [4]u8, counter: u64) [12]u8 {
    // Nonces are split into:
    // - first 4 bytes: per-connection id
    // - last 8 bytes: monotonically increasing packet counter
    //
    // The important rule is that the same (key, nonce) pair must never repeat.
    var nonce = [_]u8{0} ** 12;
    @memcpy(nonce[0..4], &connectionId);
    std.mem.writeInt(u64, nonce[4..12], counter, .little);
    return nonce;
}

fn sendEncrypted(
    conn: tcp.Connection,
    sessionKey: [32]u8,
    connectionId: [4]u8,
    counter: *u64,
    packetType: message.PacketType,
    plaintext: []u8,
    allocator: std.mem.Allocator,
) !void {
    // Each encrypted protocol packet gets its own nonce derived from the
    // shared connection id plus a strictly increasing counter.
    const nonce = buildNonce(connectionId, counter.*);
    var tag: [16]u8 = undefined;

    // encrypt() mutates plaintext in place, so callers should treat the buffer
    // as consumed after this point.
    try aead.encrypt(sessionKey, nonce, plaintext, &[_]u8{}, &tag, allocator);

    // The wire format for encrypted packets is:
    //   ciphertext || tag
    //
    // The packet type itself stays outside the AEAD payload because it is part
    // of the outer protocol framing.
    var payload = try allocator.alloc(u8, plaintext.len + 16);
    defer allocator.free(payload);
    @memcpy(payload[0..plaintext.len], plaintext);
    @memcpy(payload[plaintext.len..], &tag);

    try message.sendPacket(conn, allocator, packetType, payload);
    counter.* += 1;
}

pub fn sendFile(conn: tcp.Connection, sessionKey: [32]u8, connectionId: [4]u8, filePath: []const u8, allocator: std.mem.Allocator) !void {
    const file = try std.fs.cwd().openFile(filePath, .{});
    defer file.close();

    const stat = try file.stat();
    const file_size = stat.size;
    const filename = std.fs.path.basename(filePath);

    if (filename.len > MAX_FILENAME_LEN) return error.FileNameTooLong;

    // Counter starts at 1 because the handshake already used the all-zero tail
    // nonce layout for its ready proof. Keeping transfer counters separate and
    // monotonic makes nonce reuse easier to reason about.
    var counter: u64 = 1;

    // Metadata layout:
    //   u16 filename_len
    //   [filename bytes]
    //   u64 file_size
    //
    // This packet arrives before any file data so the receiver can validate the
    // name, create the temp file, and initialize progress reporting.
    var metaBuf = try allocator.alloc(u8, 2 + filename.len + 8);
    defer allocator.free(metaBuf);
    std.mem.writeInt(u16, metaBuf[0..2], @intCast(filename.len), .little);
    @memcpy(metaBuf[2..][0..filename.len], filename);
    std.mem.writeInt(u64, metaBuf[2 + filename.len ..][0..8], file_size, .little);
    try sendEncrypted(conn, sessionKey, connectionId, &counter, .metadata, metaBuf, allocator);

    var bar = progress.Progress.init(file_size, "Sending");
    var chunkIndex: u32 = 0;
    var totalCompressed: u64 = 0;
    var totalRaw: u64 = 0;
    var chunksCompressed: u32 = 0;
    var file_buf: [CHUNK_SIZE]u8 = undefined;

    while (true) {
        const n = try file.read(&file_buf);
        if (n == 0) break;

        const chunk = file_buf[0..n];

        // Compression is opportunistic.
        // If Huffman output is not smaller, we send the original bytes instead.
        const compressed = huffman.encode(chunk, allocator) catch null;
        defer if (compressed) |c| allocator.free(c);

        const useCompression = if (compressed) |c| c.len < chunk.len else false;
        const dataToSend = if (useCompression) compressed.? else chunk;
        const flag: u8 = if (useCompression) 0x01 else 0x00;

        // Chunk layout:
        //   u32 chunk_index
        //   u8  compression_flag
        //   [payload bytes]
        //
        // The receiver uses the explicit index to reject reordering or missing
        // chunks instead of silently writing corrupted output.
        var chunkBuf = try allocator.alloc(u8, CHUNK_HEADER_SIZE + dataToSend.len);
        defer allocator.free(chunkBuf);

        std.mem.writeInt(u32, chunkBuf[0..4], chunkIndex, .little);
        chunkBuf[4] = flag;
        @memcpy(chunkBuf[CHUNK_HEADER_SIZE..], dataToSend);

        try sendEncrypted(conn, sessionKey, connectionId, &counter, .chunk, chunkBuf, allocator);

        totalRaw += chunk.len;
        totalCompressed += dataToSend.len;
        if (useCompression) chunksCompressed += 1;

        chunkIndex += 1;
    }
    bar.finish();

    if (totalRaw > 0) {
        const ratio: f64 = @as(f64, @floatFromInt(totalCompressed)) / @as(f64, @floatFromInt(totalRaw)) * 100.0;
        var compBuf: [32]u8 = undefined;
        const compStr = progress.formatSize(&compBuf, totalCompressed);
        progress.printDetail("Compression: {s} on wire ({d:.1}% of original, {d}/{d} chunks compressed)", .{
            compStr,
            ratio,
            chunksCompressed,
            chunkIndex,
        });
    }

    var doneBuf: [4]u8 = undefined;
    std.mem.writeInt(u32, &doneBuf, chunkIndex, .little);
    try sendEncrypted(conn, sessionKey, connectionId, &counter, .done, &doneBuf, allocator);

    progress.printStep("..", "Waiting for acknowledgment...", .{});

    const ackPacket = try message.recvPacket(conn, allocator);
    defer ackPacket.free(allocator);
    if (ackPacket.packetType != .ack) return error.TransferFailed;
}

const ReceiveState = struct {
    allocator: std.mem.Allocator,
    output_dir: []const u8,
    output_file: ?std.fs.File = null,
    final_path: []u8 = &[_]u8{},
    part_path: []u8 = &[_]u8{},
    completed: bool = false,

    fn init(allocator: std.mem.Allocator, output_dir: []const u8) ReceiveState {
        return .{
            .allocator = allocator,
            .output_dir = output_dir,
        };
    }

    fn deinit(self: *ReceiveState) void {
        if (self.output_file) |f| f.close();
        if (self.final_path.len > 0) self.allocator.free(self.final_path);
        if (self.part_path.len > 0) self.allocator.free(self.part_path);
    }

    fn startFile(self: *ReceiveState, filename: []const u8) !void {
        if (filename.len == 0 or filename.len > MAX_FILENAME_LEN) return error.InvalidPacket;
        if (std.mem.indexOfScalar(u8, filename, '/')) |_| return error.InvalidPacket;
        if (std.mem.indexOfScalar(u8, filename, '\\')) |_| return error.InvalidPacket;
        if (std.mem.eql(u8, filename, ".") or std.mem.eql(u8, filename, "..")) return error.InvalidPacket;

        // Only allow a bare filename here.
        // Path separators and dot-paths are rejected so a remote sender cannot
        // trick the receiver into writing outside the chosen output directory.
        self.final_path = try std.fs.path.join(self.allocator, &.{ self.output_dir, filename });
        self.part_path = try std.fmt.allocPrint(self.allocator, "{s}.part", .{self.final_path});

        if (std.fs.cwd().statFile(self.final_path)) |_| {
            // Refuse to overwrite an existing finished file.
            return error.OutputFileExists;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }

        if (std.fs.cwd().statFile(self.part_path)) |_| {
            // Clean up any stale temp file before starting fresh.
            std.fs.cwd().deleteFile(self.part_path) catch {};
        } else |_| {}

        self.output_file = try std.fs.cwd().createFile(self.part_path, .{});
    }

    fn finalize(self: *ReceiveState) !void {
        if (self.output_file) |f| {
            f.close();
            self.output_file = null;
        }

        // Rename is the point where the file becomes "real".
        // Until this succeeds, the receiver only exposes the .part file.
        try std.fs.cwd().rename(self.part_path, self.final_path);
        self.completed = true;
    }

    fn abortCleanup(self: *ReceiveState) void {
        if (self.output_file) |f| {
            f.close();
            self.output_file = null;
        }

        // On any failure, remove the partial output so the user is not left with
        // a file that looks valid but was never fully received.
        if (!self.completed and self.part_path.len > 0) {
            std.fs.cwd().deleteFile(self.part_path) catch {};
        }
    }
};

pub fn recvFile(conn: tcp.Connection, sessionKey: [32]u8, connectionId: [4]u8, outputDir: []const u8, allocator: std.mem.Allocator) !ReceiveResult {
    var state = ReceiveState.init(allocator, outputDir);
    defer state.deinit();
    errdefer state.abortCleanup();

    var counter: u64 = 1;

    progress.printStep("..", "Waiting for file metadata...", .{});

    const metaData = try recvEncrypted(conn, sessionKey, connectionId, &counter, .metadata, allocator);
    defer allocator.free(metaData);

    if (metaData.len < 10) return error.InvalidPacket;
    const filenameLen = std.mem.readInt(u16, metaData[0..2], .little);
    if (filenameLen == 0 or filenameLen > MAX_FILENAME_LEN) return error.InvalidPacket;
    if (metaData.len < 2 + filenameLen + 8) return error.InvalidPacket;

    const filename = metaData[2 .. 2 + filenameLen];
    const fileSize = std.mem.readInt(u64, metaData[2 + filenameLen ..][0..8], .little);

    var sizeBuf: [32]u8 = undefined;
    const sizeStr = progress.formatSize(&sizeBuf, fileSize);
    progress.printStep("<<", "Receiving \"{s}\" ({s})", .{ filename, sizeStr });

    try state.startFile(filename);
    progress.printDetail("Writing temporary file {s}", .{state.part_path});

    const outFile = state.output_file orelse return error.InvalidPacket;

    var bar = progress.Progress.init(fileSize, "Receiving");
    var bytesReceived: u64 = 0;
    var chunksDecompressed: u32 = 0;
    var totalChunks: u32 = 0;
    var expectedChunkIndex: u32 = 0;

    while (bytesReceived < fileSize) {
        const chunkData = try recvEncrypted(conn, sessionKey, connectionId, &counter, .chunk, allocator);
        defer allocator.free(chunkData);

        if (chunkData.len < CHUNK_HEADER_SIZE) return error.InvalidPacket;

        const chunkIndex = std.mem.readInt(u32, chunkData[0..4], .little);
        if (chunkIndex != expectedChunkIndex) return error.InvalidChunkOrder;
        expectedChunkIndex += 1;

        const flag = chunkData[4];
        const payload = chunkData[CHUNK_HEADER_SIZE..];
        totalChunks += 1;

        // Chunk ordering is checked explicitly rather than inferred from arrival.
        // TCP preserves byte order, but this still catches protocol bugs,
        // duplication, or malformed input before it touches disk.
        if (flag == 0x01) {
            const decompressed = try huffman.decode(payload, allocator);
            defer allocator.free(decompressed);

            if (bytesReceived + decompressed.len > fileSize) return error.InvalidPacket;
            try outFile.writeAll(decompressed);
            bytesReceived += decompressed.len;
            bar.update(decompressed.len);
            chunksDecompressed += 1;
        } else if (flag == 0x00) {
            if (bytesReceived + payload.len > fileSize) return error.InvalidPacket;
            try outFile.writeAll(payload);
            bytesReceived += payload.len;
            bar.update(payload.len);
        } else {
            return error.InvalidCompressionFlag;
        }
    }
    bar.finish();

    if (chunksDecompressed > 0) {
        progress.printDetail("Decompressed {d}/{d} chunks", .{ chunksDecompressed, totalChunks });
    }

    const doneData = try recvEncrypted(conn, sessionKey, connectionId, &counter, .done, allocator);
    defer allocator.free(doneData);
    if (doneData.len != 4) return error.InvalidPacket;

    const announcedChunkCount = std.mem.readInt(u32, doneData[0..4], .little);
    if (announcedChunkCount != expectedChunkIndex) return error.InvalidPacket;

    try state.finalize();
    try message.sendPacket(conn, allocator, .ack, &[_]u8{0x00});
    progress.printDetail("Saved to {s}", .{state.final_path});

    return .{
        .filename = try allocator.dupe(u8, filename),
        .file_size = fileSize,
    };
}

fn recvEncrypted(conn: tcp.Connection, sessionKey: [32]u8, connectionId: [4]u8, counter: *u64, expectedType: message.PacketType, allocator: std.mem.Allocator) ![]u8 {
    const packet = try message.recvPacket(conn, allocator);
    defer packet.free(allocator);

    if (packet.packetType != expectedType) return error.UnexpectedPacketType;
    if (packet.payload.len < 16) return error.InvalidPacket;

    const ciphertextLen = packet.payload.len - 16;
    const tag = packet.payload[ciphertextLen..][0..16].*;

    const plaintext = try allocator.alloc(u8, ciphertextLen);
    errdefer allocator.free(plaintext);
    @memcpy(plaintext, packet.payload[0..ciphertextLen]);

    const nonce = buildNonce(connectionId, counter.*);
    try aead.decrypt(sessionKey, nonce, plaintext, &[_]u8{}, tag, allocator);
    counter.* += 1;

    return plaintext;
}
