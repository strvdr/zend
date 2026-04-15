const std = @import("std");
const aead = @import("aead");
const huffman = @import("huffman");
const pkt = @import("packet_types.zig");

pub const DecryptedFile = struct {
    filename: []u8,
    bytes: []u8,

    pub fn deinit(self: *DecryptedFile, allocator: std.mem.Allocator) void {
        allocator.free(self.filename);
        allocator.free(self.bytes);
    }
};

fn makeNonce(connection_id: [4]u8, counter: u64) [12]u8 {
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
    plaintext: []u8,
    allocator: std.mem.Allocator,
) !void {
    const nonce = makeNonce(connection_id, counter.*);

    var tag: [pkt.TAG_SIZE]u8 = undefined;
    try aead.encrypt(key, nonce, plaintext, &[_]u8{}, &tag, allocator);

    const frame_len: u32 = @intCast(1 + plaintext.len + pkt.TAG_SIZE);

    var len_buf: [pkt.FRAME_LEN_SIZE]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, frame_len, .big);

    try buf.appendSlice(allocator, &len_buf);
    try buf.append(allocator, packet_type);
    try buf.appendSlice(allocator, plaintext);
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
        };

        try self.emitMetadata(filename);
        self.started = true;
        return self;
    }

    pub fn deinit(self: *EncryptSession) void {
        self.result.deinit(self.allocator);
    }

    fn clearResult(self: *EncryptSession) void {
        self.result.clearRetainingCapacity();
    }

    fn emitMetadata(self: *EncryptSession, filename: []const u8) !void {
        self.clearResult();

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

        const compressed = huffman.encode(plaintext_chunk, self.allocator) catch null;
        defer if (compressed) |c| self.allocator.free(c);

        const use_compression = if (compressed) |c| c.len < plaintext_chunk.len else false;
        const payload = if (use_compression) compressed.? else plaintext_chunk;
        const flag: u8 = if (use_compression) 0x01 else 0x00;

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
    expected_chunks: ?u32,

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
            .expected_chunks = null,
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

        var pos: usize = 0;

        while (true) {
            if (self.pending.items.len - pos < pkt.FRAME_LEN_SIZE) break;

            // safe header read
            const frame_len = std.mem.readInt(u32, self.pending.items[pos..][0..4], .big);

            // guard against insane or partial frame lengths
            if (frame_len > (16 * 1024 * 1024)) return error.FrameTooLarge;
            
            if (frame_len < 1 + pkt.TAG_SIZE) return error.FrameTooShort;
            

            pos += pkt.FRAME_LEN_SIZE;

            const packet_type = self.pending.items[pos];
            pos += 1;

            const ciphertext_len = frame_len - 1 - pkt.TAG_SIZE;
            var packet_plaintext = try self.allocator.alloc(u8, ciphertext_len);
            defer self.allocator.free(packet_plaintext);

            @memcpy(packet_plaintext, self.pending.items[pos .. pos + ciphertext_len]);
            pos += ciphertext_len;

            const tag: [pkt.TAG_SIZE]u8 = self.pending.items[pos..][0..pkt.TAG_SIZE].*;
            pos += pkt.TAG_SIZE;

            const nonce = makeNonce(self.connection_id, self.counter);
            self.counter += 1;

            try aead.decrypt(self.key, nonce, packet_plaintext, &[_]u8{}, tag, self.allocator);

            switch (packet_type) {
                pkt.METADATA => {
                    if (packet_plaintext.len < 2 + 8) return error.InvalidMetadata;

                    const fn_len = std.mem.readInt(u16, packet_plaintext[0..2], .little);
                    if (packet_plaintext.len < 2 + fn_len + 8) return error.InvalidMetadata;
                    if (self.saw_metadata) return error.DuplicateMetadata;

                    self.filename = try self.allocator.dupe(u8, packet_plaintext[2 .. 2 + fn_len]);
                    self.saw_metadata = true;

                    _ = std.mem.readInt(
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
                        0x00 => try self.output.appendSlice(self.allocator, chunk_payload),
                        0x01 => {
                            const decompressed = try huffman.decode(chunk_payload, self.allocator);
                            defer self.allocator.free(decompressed);
                            try self.output.appendSlice(self.allocator, decompressed);
                        },
                        else => return error.InvalidCompressionFlag,
                    }
                },

                pkt.DONE => {
                    if (packet_plaintext.len != 4) return error.InvalidDonePacket;
                    self.expected_chunks = std.mem.readInt(u32, packet_plaintext[0..4], .little);
                    self.saw_done = true;
                    break;
                },

                else => return error.UnknownPacketType,
            }
        }

        if (pos > 0) {
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
    };
}
