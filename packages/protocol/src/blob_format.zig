const std = @import("std");
const aead = @import("aead");
const huffman = @import("huffman");
const pkt = @import("packet_types");

const Sha256 = std.crypto.hash.sha2.Sha256;
const INTEGRITY_PACKET_SIZE: usize = 8 + 32; // plaintext_size(u64 LE) + sha256

pub const DecryptedFile = struct {
    filename: []u8,
    bytes: []u8,
    verified: bool,

    pub fn deinit(self: *DecryptedFile, allocator: std.mem.Allocator) void {
        allocator.free(self.filename);
        allocator.free(self.bytes);
    }
};

fn makeNonce(connection_id: [4]u8, counter: u64) [12]u8 {
    // Every encrypted packet uses a nonce built from:
    // - a per-transfer connection id
    // - a monotonically increasing packet counter
    //
    // The important invariant is that a given key must never reuse a nonce.
    var nonce = [_]u8{0} ** 12;
    @memcpy(nonce[0..4], &connection_id);
    std.mem.writeInt(u64, nonce[4..12], counter, .little);
    return nonce;
}

fn encryptAndAppend(
    buf: *std.ArrayList(u8),
    key: [32]u8,
    connection_id: [4]u8,
    counter: *u64,
    packet_type: u8,
    plaintext: []const u8,
    allocator: std.mem.Allocator,
) !void {
    const nonce = makeNonce(connection_id, counter.*);

    // AEAD encrypts in place, so duplicate the plaintext before mutating it.
    // This keeps the caller's buffer ownership simple and predictable.
    const ciphertext = try allocator.dupe(u8, plaintext);
    defer allocator.free(ciphertext);

    var tag: [pkt.TAG_SIZE]u8 = undefined;
    try aead.encrypt(key, nonce, ciphertext, &[_]u8{}, &tag, allocator);

    // Each frame on disk / over the wire is stored as:
    //   u32 frame_len (big-endian)
    //   u8  packet_type
    //   [ciphertext]
    //   [tag]
    //
    // The length includes everything after the length field.
    const frame_len: u32 = @intCast(1 + ciphertext.len + pkt.TAG_SIZE);

    var len_buf: [pkt.FRAME_LEN_SIZE]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, frame_len, .big);

    try buf.appendSlice(allocator, &len_buf);
    try buf.append(allocator, packet_type);
    try buf.appendSlice(allocator, ciphertext);
    try buf.appendSlice(allocator, &tag);

    counter.* += 1;
}

pub const EncryptSession = struct {
    allocator: std.mem.Allocator,
    key: [32]u8,
    connection_id: [4]u8,
    counter: u64,
    chunk_index: u32,
    total_plaintext_size: u64,
    started: bool,
    finished: bool,
    result: std.ArrayList(u8),
    plaintext_hasher: Sha256,

    pub fn init(
        allocator: std.mem.Allocator,
        key: [32]u8,
        filename: []const u8,
        total_plaintext_size: u64,
    ) !EncryptSession {
        var self = EncryptSession{
            .allocator = allocator,
            .key = key,
            .connection_id = [_]u8{0} ** pkt.CONNECTION_ID_SIZE,
            .counter = 1,
            .chunk_index = 0,
            .total_plaintext_size = total_plaintext_size,
            .started = false,
            .finished = false,
            .result = .{},
            .plaintext_hasher = Sha256.init(.{}),
        };

        // A session always begins by emitting metadata.
        // That means the first resultSlice() after init() already contains a
        // complete encrypted metadata frame ready to upload or write.
        try self.emitMetadata(filename);
        self.started = true;
        return self;
    }

    pub fn deinit(self: *EncryptSession) void {
        self.result.deinit(self.allocator);
    }

    fn clearResult(self: *EncryptSession) void {
        // result is reused as a "latest encoded output" scratch buffer.
        // Each call replaces the previous frame(s) instead of appending forever.
        self.result.clearRetainingCapacity();
    }

    fn emitMetadata(self: *EncryptSession, filename: []const u8) !void {
        self.clearResult();

        // Metadata plaintext layout:
        //   u16 filename_len
        //   [filename bytes]
        //   u64 total_plaintext_size
        //
        // This must be the first packet so the decoder knows what file it is
        // reconstructing before any chunk data arrives.
        var meta_buf = try self.allocator.alloc(u8, 2 + filename.len + 8);
        defer self.allocator.free(meta_buf);

        std.mem.writeInt(u16, meta_buf[0..2], @intCast(filename.len), .little);
        @memcpy(meta_buf[2..][0..filename.len], filename);
        std.mem.writeInt(u64, meta_buf[2 + filename.len ..][0..8], self.total_plaintext_size, .little);

        try encryptAndAppend(
            &self.result,
            self.key,
            self.connection_id,
            &self.counter,
            pkt.METADATA,
            meta_buf,
            self.allocator,
        );
    }

    pub fn encryptChunk(self: *EncryptSession, plaintext_chunk: []const u8) !void {
        if (!self.started) return error.SessionNotStarted;
        if (self.finished) return error.SessionAlreadyFinished;

        self.clearResult();

        // Hash the original plaintext, not the compressed bytes.
        // The integrity packet later proves the final recovered file contents.
        self.plaintext_hasher.update(plaintext_chunk);

        const compressed = huffman.encode(plaintext_chunk, self.allocator) catch null;
        defer if (compressed) |c| self.allocator.free(c);

        // Compression is opportunistic: only use it when it actually wins.
        const use_compression = if (compressed) |c| c.len < plaintext_chunk.len else false;
        const payload = if (use_compression) compressed.? else plaintext_chunk;
        const flag: u8 = if (use_compression) 0x01 else 0x00;

        // Chunk plaintext layout:
        //   u32 chunk_index
        //   u8  compression_flag
        //   [payload bytes]
        //
        // The explicit index makes the stream format easier to validate and
        // safer to debug when something goes out of order.
        var chunk_buf = try self.allocator.alloc(u8, pkt.CHUNK_HEADER_SIZE + payload.len);
        defer self.allocator.free(chunk_buf);

        std.mem.writeInt(u32, chunk_buf[0..4], self.chunk_index, .little);
        chunk_buf[4] = flag;
        @memcpy(chunk_buf[pkt.CHUNK_HEADER_SIZE..], payload);

        try encryptAndAppend(
            &self.result,
            self.key,
            self.connection_id,
            &self.counter,
            pkt.CHUNK,
            chunk_buf,
            self.allocator,
        );

        self.chunk_index += 1;
    }

    pub fn finish(self: *EncryptSession) !void {
        if (!self.started) return error.SessionNotStarted;
        if (self.finished) return error.SessionAlreadyFinished;

        self.clearResult();

        var digest: [32]u8 = undefined;
        var hasher = self.plaintext_hasher;
        hasher.final(&digest);

        // The integrity packet authenticates the recovered plaintext as a whole.
        // It lets the decoder verify both final size and final hash before
        // treating the file as complete.
        var integrity_buf: [INTEGRITY_PACKET_SIZE]u8 = undefined;
        std.mem.writeInt(u64, integrity_buf[0..8], self.total_plaintext_size, .little);
        @memcpy(integrity_buf[8..], &digest);

        try encryptAndAppend(
            &self.result,
            self.key,
            self.connection_id,
            &self.counter,
            pkt.INTEGRITY,
            &integrity_buf,
            self.allocator,
        );

        // DONE carries the number of emitted chunks.
        // It is the decoder's signal that no more frames should follow.
        var done_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &done_buf, self.chunk_index, .little);

        try encryptAndAppend(
            &self.result,
            self.key,
            self.connection_id,
            &self.counter,
            pkt.DONE,
            &done_buf,
            self.allocator,
        );

        self.finished = true;
    }

    pub fn resultSlice(self: *EncryptSession) []const u8 {
        return self.result.items;
    }

    pub fn takeResultOwned(self: *EncryptSession) ![]u8 {
        return try self.allocator.dupe(u8, self.result.items);
    }
};

pub const DecryptSession = struct {
    allocator: std.mem.Allocator,
    key: [32]u8,
    connection_id: [4]u8,
    counter: u64,
    pending: std.ArrayList(u8),
    output: std.ArrayList(u8),
    filename: ?[]u8,
    saw_metadata: bool,
    saw_done: bool,
    saw_integrity: bool,
    expected_chunks: ?u32,
    expected_plaintext_size: ?u64,
    expected_sha256: ?[32]u8,
    plaintext_hasher: Sha256,
    total_plaintext_bytes: u64,

    pub fn init(allocator: std.mem.Allocator, key: [32]u8) DecryptSession {
        return .{
            .allocator = allocator,
            .key = key,
            .connection_id = [_]u8{0} ** pkt.CONNECTION_ID_SIZE,
            .counter = 1,
            .pending = .{},
            .output = .{},
            .filename = null,
            .saw_metadata = false,
            .saw_done = false,
            .saw_integrity = false,
            .expected_chunks = null,
            .expected_plaintext_size = null,
            .expected_sha256 = null,
            .plaintext_hasher = Sha256.init(.{}),
            .total_plaintext_bytes = 0,
        };
    }

    pub fn deinit(self: *DecryptSession) void {
        self.pending.deinit(self.allocator);
        self.output.deinit(self.allocator);
        if (self.filename) |f| self.allocator.free(f);
    }

    fn clearOutput(self: *DecryptSession) void {
        self.output.clearRetainingCapacity();
    }

    pub fn pushBytes(self: *DecryptSession, bytes: []const u8) !void {
        if (self.saw_done) return error.SessionAlreadyFinished;

        self.clearOutput();
        try self.pending.appendSlice(self.allocator, bytes);

        const max_frame_len: usize = 16 * 1024 * 1024;
        var pos: usize = 0;

        while (true) {
            const available = self.pending.items.len - pos;
            if (available < pkt.FRAME_LEN_SIZE) break;

            const frame_len_u32 = std.mem.readInt(
                u32,
                self.pending.items[pos .. pos + pkt.FRAME_LEN_SIZE][0..pkt.FRAME_LEN_SIZE],
                .big,
            );
            const frame_len: usize = @intCast(frame_len_u32);

            if (frame_len > max_frame_len) return error.FrameTooLarge;
            if (frame_len < 1 + pkt.TAG_SIZE) return error.FrameTooShort;

            const total_frame_bytes = pkt.FRAME_LEN_SIZE + frame_len;
            if (available < total_frame_bytes) break;

            // At this point we know we have one full frame buffered.
            // Anything incomplete stays in pending until more bytes arrive.
            const frame_start = pos + pkt.FRAME_LEN_SIZE;
            const frame_end = pos + total_frame_bytes;
            const frame = self.pending.items[frame_start..frame_end];

            const packet_type = frame[0];
            const ciphertext_len = frame_len - 1 - pkt.TAG_SIZE;
            const ciphertext = frame[1 .. 1 + ciphertext_len];
            const tag_bytes = frame[1 + ciphertext_len .. frame.len];
            if (tag_bytes.len != pkt.TAG_SIZE) return error.InvalidTagSize;

            var packet_plaintext = try self.allocator.alloc(u8, ciphertext.len);
            defer self.allocator.free(packet_plaintext);
            @memcpy(packet_plaintext, ciphertext);

            var tag: [pkt.TAG_SIZE]u8 = undefined;
            @memcpy(&tag, tag_bytes);

            const nonce = makeNonce(self.connection_id, self.counter);
            self.counter += 1;

            // Decrypt exactly one packet at a time in stream order.
            // The counter advances with the packet sequence, not with byte offsets.
            try aead.decrypt(self.key, nonce, packet_plaintext, &[_]u8{}, tag, self.allocator);

            switch (packet_type) {
                pkt.METADATA => {
                    if (packet_plaintext.len < 2 + 8) return error.InvalidMetadata;

                    const fn_len = std.mem.readInt(u16, packet_plaintext[0..2], .little);
                    const metadata_len: usize = 2 + @as(usize, fn_len) + 8;
                    if (packet_plaintext.len < metadata_len) return error.InvalidMetadata;
                    if (self.saw_metadata) return error.DuplicateMetadata;

                    if (self.filename) |f| self.allocator.free(f);

                    // Keep an owned copy of the filename because packet_plaintext
                    // is temporary and freed at the end of this loop iteration.
                    self.filename = try self.allocator.dupe(u8, packet_plaintext[2 .. 2 + fn_len]);
                    self.saw_metadata = true;

                    self.expected_plaintext_size = std.mem.readInt(
                        u64,
                        packet_plaintext[2 + fn_len ..][0..8],
                        .little,
                    );
                },

                pkt.CHUNK => {
                    if (!self.saw_metadata) return error.ChunkBeforeMetadata;
                    if (packet_plaintext.len < pkt.CHUNK_HEADER_SIZE) return error.InvalidChunk;

                    const flag = packet_plaintext[4];
                    const chunk_payload = packet_plaintext[pkt.CHUNK_HEADER_SIZE..];

                    switch (flag) {
                        0x00 => {
                            try self.output.appendSlice(self.allocator, chunk_payload);
                            self.plaintext_hasher.update(chunk_payload);
                            self.total_plaintext_bytes += chunk_payload.len;
                        },
                        0x01 => {
                            const decompressed = try huffman.decode(chunk_payload, self.allocator);
                            defer self.allocator.free(decompressed);
                            try self.output.appendSlice(self.allocator, decompressed);
                            self.plaintext_hasher.update(decompressed);
                            self.total_plaintext_bytes += decompressed.len;
                        },
                        else => return error.InvalidCompressionFlag,
                    }
                },

                pkt.INTEGRITY => {
                    if (packet_plaintext.len != INTEGRITY_PACKET_SIZE) return error.InvalidIntegrityPacket;
                    if (self.saw_integrity) return error.DuplicateIntegrityPacket;

                    // Integrity is delayed until near the end because it describes
                    // the fully reconstructed plaintext, not individual packets.
                    self.expected_plaintext_size = std.mem.readInt(u64, packet_plaintext[0..8], .little);

                    var digest: [32]u8 = undefined;
                    @memcpy(&digest, packet_plaintext[8..40]);
                    self.expected_sha256 = digest;
                    self.saw_integrity = true;
                },

                pkt.DONE => {
                    if (packet_plaintext.len != 4) return error.InvalidDonePacket;
                    self.expected_chunks = std.mem.readInt(u32, packet_plaintext[0..4], .little);

                    if (!self.saw_integrity) return error.MissingIntegrity;

                    const expected_size = self.expected_plaintext_size orelse return error.MissingIntegrity;
                    const expected_hash = self.expected_sha256 orelse return error.MissingIntegrity;

                    if (self.total_plaintext_bytes != expected_size) return error.IntegritySizeMismatch;

                    var actual_hash: [32]u8 = undefined;
                    var hasher = self.plaintext_hasher;
                    hasher.final(&actual_hash);

                    if (!std.mem.eql(u8, &actual_hash, &expected_hash)) {
                        return error.IntegrityHashMismatch;
                    }

                    // DONE only succeeds after the full-file integrity check passes.
                    self.saw_done = true;
                    pos = frame_end;
                    break;
                },

                else => return error.UnknownPacketType,
            }

            pos = frame_end;
        }

        if (pos > 0) {
            // Compact any leftover partial frame to the front so the next pushBytes()
            // call can continue parsing without reallocating a new buffer.
            const remaining_len = self.pending.items.len - pos;
            std.mem.copyForwards(u8, self.pending.items[0..remaining_len], self.pending.items[pos..]);
            self.pending.items.len = remaining_len;
        }
    }

    pub fn outputSlice(self: *DecryptSession) []const u8 {
        return self.output.items;
    }

    pub fn takeOutputOwned(self: *DecryptSession) ![]u8 {
        return try self.allocator.dupe(u8, self.output.items);
    }

    pub fn filenameSlice(self: *DecryptSession) ?[]const u8 {
        return self.filename;
    }

    pub fn isDone(self: *const DecryptSession) bool {
        return self.saw_done;
    }
};

pub fn encryptFileBuffer(
    allocator: std.mem.Allocator,
    plaintext: []const u8,
    filename: []const u8,
    key: [32]u8,
) ![]u8 {
    var session = try EncryptSession.init(
        allocator,
        key,
        filename,
        @intCast(plaintext.len),
    );
    defer session.deinit();

    var out = std.ArrayList(u8){};
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, session.resultSlice());

    var offset: usize = 0;
    while (offset < plaintext.len) {
        const end = @min(offset + pkt.CHUNK_SIZE, plaintext.len);
        try session.encryptChunk(plaintext[offset..end]);
        try out.appendSlice(allocator, session.resultSlice());
        offset = end;
    }

    try session.finish();
    try out.appendSlice(allocator, session.resultSlice());

    return try out.toOwnedSlice(allocator);
}

pub fn decryptFileBuffer(
    allocator: std.mem.Allocator,
    blob: []const u8,
    key: [32]u8,
) !DecryptedFile {
    var session = DecryptSession.init(allocator, key);
    defer session.deinit();

    var out = std.ArrayList(u8){};
    errdefer out.deinit(allocator);

    var pos: usize = 0;
    while (pos < blob.len) {
        const end = @min(pos + (64 * 1024), blob.len);
        try session.pushBytes(blob[pos..end]);
        try out.appendSlice(allocator, session.outputSlice());
        pos = end;

        if (session.isDone()) break;
    }

    if (!session.isDone()) return error.IncompleteStream;

    const filename = session.filenameSlice() orelse return error.NoMetadata;

    return .{
        .filename = try allocator.dupe(u8, filename),
        .bytes = try out.toOwnedSlice(allocator),
        .verified = true,
    };
}

test "blob format round trips multi-chunk payload and preserves metadata" {
    var plaintext = std.ArrayList(u8){};
    defer plaintext.deinit(std.testing.allocator);

    try plaintext.appendNTimes(std.testing.allocator, 'A', pkt.CHUNK_SIZE + 173);
    for (0..(pkt.CHUNK_SIZE + 911)) |i| {
        try plaintext.append(std.testing.allocator, @intCast(i % 251));
    }

    const filename = "archive.tar";
    const key = [_]u8{0x42} ** 32;

    const blob = try encryptFileBuffer(std.testing.allocator, plaintext.items, filename, key);
    defer std.testing.allocator.free(blob);

    var decrypted = try decryptFileBuffer(std.testing.allocator, blob, key);
    defer decrypted.deinit(std.testing.allocator);

    try std.testing.expect(decrypted.verified);
    try std.testing.expectEqualStrings(filename, decrypted.filename);
    try std.testing.expectEqualSlices(u8, plaintext.items, decrypted.bytes);
}

test "decrypt session handles incremental frame delivery" {
    var plaintext = std.ArrayList(u8){};
    defer plaintext.deinit(std.testing.allocator);

    for (0..(pkt.CHUNK_SIZE * 2 + 257)) |i| {
        try plaintext.append(std.testing.allocator, @intCast((i * 17 + 31) % 256));
    }

    const filename = "streamed.bin";
    const key = [_]u8{0x7a} ** 32;

    const blob = try encryptFileBuffer(std.testing.allocator, plaintext.items, filename, key);
    defer std.testing.allocator.free(blob);

    var session = DecryptSession.init(std.testing.allocator, key);
    defer session.deinit();

    var recovered = std.ArrayList(u8){};
    defer recovered.deinit(std.testing.allocator);

    var pos: usize = 0;
    while (pos < blob.len) {
        const chunk_len = @min(3 + (pos % 23), blob.len - pos);
        try session.pushBytes(blob[pos .. pos + chunk_len]);
        try recovered.appendSlice(std.testing.allocator, session.outputSlice());
        pos += chunk_len;
    }

    try std.testing.expect(session.isDone());
    try std.testing.expectEqualStrings(filename, session.filenameSlice().?);
    try std.testing.expectEqualSlices(u8, plaintext.items, recovered.items);
}

test "blob format rejects tampered ciphertext" {
    const plaintext = "this blob should fail authentication when modified";
    const key = [_]u8{0x19} ** 32;

    const blob = try encryptFileBuffer(std.testing.allocator, plaintext, "tampered.txt", key);
    defer std.testing.allocator.free(blob);

    var tampered = try std.testing.allocator.dupe(u8, blob);
    defer std.testing.allocator.free(tampered);

    tampered[tampered.len - 8] ^= 0x55;

    try std.testing.expectError(
        error.AuthenticationFailed,
        decryptFileBuffer(std.testing.allocator, tampered, key),
    );
}

test "blob format rejects truncated blob" {
    const plaintext = "short file";
    const key = [_]u8{0xa4} ** 32;

    const blob = try encryptFileBuffer(std.testing.allocator, plaintext, "truncated.txt", key);
    defer std.testing.allocator.free(blob);

    try std.testing.expectError(
        error.IncompleteStream,
        decryptFileBuffer(std.testing.allocator, blob[0 .. blob.len - 1], key),
    );
}
