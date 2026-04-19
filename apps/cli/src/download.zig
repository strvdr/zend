// download.zig
// Downloads and decrypts a file from the relay given a zend URL.

const std = @import("std");
const aead = @import("aead");
const huffman = @import("huffman");
const relay = @import("relay");
const progress = @import("progress");
const pkt = @import("packet_types");

const Sha256 = std.crypto.hash.sha2.Sha256;
const INTEGRITY_PACKET_SIZE: usize = 8 + 32; // plaintext_size(u64 LE) + sha256

const ParsedUrl = struct {
    id: []const u8,
    key: [32]u8,
};

const StreamSink = struct {
    state: *DecodeState,

    // The relay download path is fully streaming:
    // incoming bytes go straight into the incremental decoder.
    pub fn write(self: *StreamSink, bytes: []const u8) !usize {
        try self.state.pushBytes(bytes);
        return bytes.len;
    }

    pub fn writeAll(self: *StreamSink, bytes: []const u8) !void {
        try self.state.pushBytes(bytes);
    }

    pub fn flush(self: *StreamSink) !void {
        _ = self;
    }
};

const DecodeState = struct {
    allocator: std.mem.Allocator,
    key: [32]u8,
    connection_id: [4]u8 = [_]u8{0} ** 4,
    counter: u64 = 1,
    pending: std.ArrayList(u8),
    output_file: ?std.fs.File = null,
    filename: []u8 = &[_]u8{},
    total_expected: u64 = 0,
    bytes_written: u64 = 0,
    bar: ?progress.Progress = null,
    output_dir: []const u8,

    saw_metadata: bool = false,
    saw_integrity: bool = false,
    saw_done: bool = false,
    expected_sha256: ?[32]u8 = null,
    plaintext_hasher: Sha256 = Sha256.init(.{}),

    fn init(allocator: std.mem.Allocator, key: [32]u8, output_dir: []const u8) DecodeState {
        return .{
            .allocator = allocator,
            .key = key,
            .pending = .empty,
            .output_dir = output_dir,
        };
    }

    fn deinit(self: *DecodeState) void {
        if (self.output_file) |f| f.close();
        if (self.filename.len > 0) self.allocator.free(self.filename);
        self.pending.deinit(self.allocator);
    }

    fn pushBytes(self: *DecodeState, bytes: []const u8) !void {
        try self.pending.appendSlice(self.allocator, bytes);
        try self.processPending(false);
    }

    fn finish(self: *DecodeState) !void {
        try self.processPending(true);
        if (self.pending.items.len != 0) return error.TrailingGarbage;
        if (!self.saw_metadata) return error.NoFileReceived;
        if (!self.saw_done) return error.MissingDone;
        if (self.output_file == null) return error.NoFileReceived;
    }

    fn processPending(self: *DecodeState, final: bool) !void {
        var pos: usize = 0;
        while (true) {
            if (self.pending.items.len - pos < pkt.FRAME_LEN_SIZE) break;

            const frame_len = std.mem.readInt(u32, self.pending.items[pos..][0..pkt.FRAME_LEN_SIZE], .big);
            if (frame_len < 1 + pkt.TAG_SIZE) return error.FrameTooShort;
            if (self.pending.items.len - pos < pkt.FRAME_LEN_SIZE + frame_len) break;

            pos += pkt.FRAME_LEN_SIZE;
            const packet_type = self.pending.items[pos];
            pos += 1;

            const ciphertext_len = frame_len - 1 - pkt.TAG_SIZE;
            const plaintext = try self.allocator.alloc(u8, ciphertext_len);
            defer self.allocator.free(plaintext);
            @memcpy(plaintext, self.pending.items[pos .. pos + ciphertext_len]);
            pos += ciphertext_len;

            const tag = self.pending.items[pos..][0..pkt.TAG_SIZE].*;
            pos += pkt.TAG_SIZE;

            var nonce = [_]u8{0} ** 12;
            @memcpy(nonce[0..4], &self.connection_id);
            std.mem.writeInt(u64, nonce[4..12], self.counter, .little);
            self.counter += 1;

            // The decoder advances one packet nonce at a time in stream order.
            // Partial frames are left buffered until enough bytes arrive.
            try aead.decrypt(self.key, nonce, plaintext, &[_]u8{}, tag, self.allocator);
            try self.handlePacket(packet_type, plaintext);
        }

        if (pos > 0) {
            const remaining = self.pending.items.len - pos;
            std.mem.copyForwards(u8, self.pending.items[0..remaining], self.pending.items[pos..]);
            self.pending.items.len = remaining;
        }

        if (final and self.pending.items.len != 0) {
            // If the network stream is over but a partial frame remains buffered,
            // the blob was truncated or malformed.
            return error.TruncatedFrame;
        }
    }

    fn handlePacket(self: *DecodeState, packet_type: u8, plaintext: []const u8) !void {
        switch (packet_type) {
            pkt.METADATA => {
                if (plaintext.len < 2 + 8) return error.InvalidMetadata;

                const fn_len = std.mem.readInt(u16, plaintext[0..2], .little);
                if (plaintext.len < 2 + fn_len + 8) return error.InvalidMetadata;
                if (self.saw_metadata) return error.DuplicateMetadata;

                if (self.filename.len > 0) self.allocator.free(self.filename);
                self.filename = try self.allocator.dupe(u8, plaintext[2..][0..fn_len]);
                self.total_expected = std.mem.readInt(u64, plaintext[2 + fn_len..][0..8], .little);
                self.saw_metadata = true;

                var size_buf: [32]u8 = undefined;
                progress.printStep("<<", "Receiving \"{s}\" ({s})", .{
                    self.filename,
                    progress.formatSize(&size_buf, self.total_expected),
                });

                const out_path = try std.fs.path.join(self.allocator, &.{ self.output_dir, self.filename });
                defer self.allocator.free(out_path);

                // The output file is created as soon as metadata arrives because
                // the following chunk packets stream directly to disk.
                self.output_file = try std.fs.cwd().createFile(out_path, .{});
                self.bar = progress.Progress.init(self.total_expected, "Writing");
            },

            pkt.CHUNK => {
                if (!self.saw_metadata) return error.ChunkBeforeMetadata;
                if (plaintext.len < pkt.CHUNK_HEADER_SIZE) return error.InvalidChunk;

                const flag = plaintext[4];
                const chunk_payload = plaintext[pkt.CHUNK_HEADER_SIZE..];

                const f = self.output_file orelse return error.ChunkBeforeMetadata;

                switch (flag) {
                    0x00 => {
                        try f.writeAll(chunk_payload);
                        self.plaintext_hasher.update(chunk_payload);
                        self.bytes_written += chunk_payload.len;
                        if (self.bar) |*b| b.update(chunk_payload.len);
                    },
                    0x01 => {
                        const decompressed = try huffman.decode(chunk_payload, self.allocator);
                        defer self.allocator.free(decompressed);

                        try f.writeAll(decompressed);
                        self.plaintext_hasher.update(decompressed);
                        self.bytes_written += decompressed.len;
                        if (self.bar) |*b| b.update(decompressed.len);
                    },
                    else => return error.InvalidCompressionFlag,
                }
            },

            pkt.INTEGRITY => {
                if (plaintext.len != INTEGRITY_PACKET_SIZE) return error.InvalidIntegrityPacket;
                if (self.saw_integrity) return error.DuplicateIntegrityPacket;

                // Integrity describes the final recovered plaintext file, not the
                // encrypted blob size or compressed chunk sizes.
                self.total_expected = std.mem.readInt(u64, plaintext[0..8], .little);

                var digest: [32]u8 = undefined;
                @memcpy(&digest, plaintext[8..40]);
                self.expected_sha256 = digest;
                self.saw_integrity = true;
            },

            pkt.DONE => {
                if (plaintext.len != 4) return error.InvalidDonePacket;
                if (self.saw_done) return error.DuplicateDone;
                if (!self.saw_integrity) return error.MissingIntegrity;

                const expected_hash = self.expected_sha256 orelse return error.MissingIntegrity;

                if (self.bytes_written != self.total_expected) {
                    return error.IntegritySizeMismatch;
                }

                var actual_hash: [32]u8 = undefined;
                var hasher = self.plaintext_hasher;
                hasher.final(&actual_hash);

                if (!std.mem.eql(u8, &actual_hash, &expected_hash)) {
                    return error.IntegrityHashMismatch;
                }

                // DONE only marks success after the full-file hash matches.
                self.saw_done = true;
                if (self.bar) |*b| b.finish();
            },

            else => return error.UnknownPacketType,
        }
    }
};

fn parseUrl(url: []const u8) !ParsedUrl {
    const hash_pos = std.mem.lastIndexOfScalar(u8, url, '#') orelse
        return error.MissingKeyFragment;

    const url_part = url[0..hash_pos];
    const key_fragment = url[hash_pos + 1 ..];

    if (key_fragment.len != std.base64.url_safe_no_pad.Encoder.calcSize(32))
        return error.InvalidKeyLength;

    var key: [32]u8 = undefined;
    try std.base64.url_safe_no_pad.Decoder.decode(&key, key_fragment);

    const slash_pos = std.mem.lastIndexOfScalar(u8, url_part, '/') orelse
        return error.InvalidUrl;
    const id = url_part[slash_pos + 1 ..];
    if (id.len == 0) return error.InvalidUrl;

    // The key is taken from the fragment so it stays client-side.
    // Only the relay id is part of the network request.
    return .{ .id = id, .key = key };
}

pub fn run(url: []const u8, outputDir: []const u8, allocator: std.mem.Allocator) !void {
    progress.printHeader();

    const parsed = parseUrl(url) catch |err| {
        std.debug.print("Error: invalid zend URL ({s})\n", .{@errorName(err)});
        std.debug.print("Expected: https://www.zend.foo/d/{{id}}#{{key}}\n", .{});
        return err;
    };

    progress.printStep("..", "Downloading from relay (id: {s})...", .{parsed.id});
    progress.printStep("..", "Streaming and decrypting...", .{});

    var state = DecodeState.init(allocator, parsed.key, outputDir);
    defer state.deinit();

    var sink = StreamSink{ .state = &state };
    try relay.download(allocator, parsed.id, &sink);
    try sink.flush();
    try state.finish();

    const out_path = try std.fs.path.join(allocator, &.{ outputDir, state.filename });
    defer allocator.free(out_path);
    progress.printDetail("Saved to {s}", .{out_path});
    progress.printStep("OK", "Transfer complete", .{});
}
