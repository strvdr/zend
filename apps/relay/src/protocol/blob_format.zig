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

pub fn encryptFileBuffer(
    allocator: std.mem.Allocator,
    plaintext: []const u8,
    filename: []const u8,
    key: [32]u8,
) ![]u8 {
    const connection_id = [_]u8{0} ** 4;
    var counter: u64 = 1;

    var payload = std.ArrayList(u8){};
    errdefer payload.deinit(allocator);

    // metadata: filename_len(u16 LE) | filename | orig_size(u64 LE)
    var meta_buf = try allocator.alloc(u8, 2 + filename.len + 8);
    defer allocator.free(meta_buf);

    std.mem.writeInt(u16, meta_buf[0..2], @intCast(filename.len), .little);
    @memcpy(meta_buf[2..][0..filename.len], filename);
    std.mem.writeInt(u64, meta_buf[2 + filename.len ..][0..8], @intCast(plaintext.len), .little);

    try encryptAndAppend(&payload, key, connection_id, &counter, pkt.METADATA, meta_buf, allocator);

    var offset: usize = 0;
    var chunk_index: u32 = 0;

    while (offset < plaintext.len) {
        const end = @min(offset + pkt.CHUNK_SIZE, plaintext.len);
        const chunk = plaintext[offset..end];

        const compressed = huffman.encode(chunk, allocator) catch null;
        defer if (compressed) |c| allocator.free(c);

        const use_compression = if (compressed) |c| c.len < chunk.len else false;
        const data_to_send = if (use_compression) compressed.? else chunk;
        const flag: u8 = if (use_compression) 0x01 else 0x00;

        var chunk_buf = try allocator.alloc(u8, pkt.CHUNK_HEADER_SIZE + data_to_send.len);
        defer allocator.free(chunk_buf);

        std.mem.writeInt(u32, chunk_buf[0..4], chunk_index, .little);
        chunk_buf[4] = flag;
        @memcpy(chunk_buf[pkt.CHUNK_HEADER_SIZE..], data_to_send);

        try encryptAndAppend(&payload, key, connection_id, &counter, pkt.CHUNK, chunk_buf, allocator);

        offset = end;
        chunk_index += 1;
    }

    var done_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &done_buf, chunk_index, .little);
    try encryptAndAppend(&payload, key, connection_id, &counter, pkt.DONE, &done_buf, allocator);

    return try payload.toOwnedSlice(allocator);
}

pub fn decryptFileBuffer(
    allocator: std.mem.Allocator,
    blob: []const u8,
    key: [32]u8,
) !DecryptedFile {
    const connection_id = [_]u8{0} ** 4;
    var counter: u64 = 1;
    var pos: usize = 0;

    var filename: ?[]u8 = null;
    errdefer if (filename) |f| allocator.free(f);

    var out = std.ArrayList(u8){};
    errdefer out.deinit(allocator);

    while (pos + 4 <= blob.len) {
        const frame_len = std.mem.readInt(u32, blob[pos..][0..4], .big);
        pos += 4;

        if (pos + frame_len > blob.len) return error.TruncatedFrame;
        if (frame_len < 1 + pkt.TAG_SIZE) return error.FrameTooShort;

        const packet_type = blob[pos];
        pos += 1;

        const ciphertext_len = frame_len - 1 - pkt.TAG_SIZE;
        var packet_plaintext = try allocator.alloc(u8, ciphertext_len);
        defer allocator.free(packet_plaintext);

        @memcpy(packet_plaintext, blob[pos..][0..ciphertext_len]);
        pos += ciphertext_len;

        const tag = blob[pos..][0..pkt.TAG_SIZE].*;
        pos += pkt.TAG_SIZE;

        const nonce = makeNonce(connection_id, counter);
        counter += 1;

        try aead.decrypt(key, nonce, packet_plaintext, &[_]u8{}, tag, allocator);

        switch (packet_type) {
            pkt.METADATA => {
                if (packet_plaintext.len < 2 + 8) return error.InvalidMetadata;

                const fn_len = std.mem.readInt(u16, packet_plaintext[0..2], .little);
                if (packet_plaintext.len < 2 + fn_len + 8) return error.InvalidMetadata;

                if (filename != null) return error.DuplicateMetadata;
                filename = try allocator.dupe(u8, packet_plaintext[2..][0..fn_len]);

                // orig_size is preserved for parity, but not strictly needed here.
                _ = std.mem.readInt(u64, packet_plaintext[2 + fn_len ..][0..8], .little);
            },

            pkt.CHUNK => {
                if (packet_plaintext.len < pkt.CHUNK_HEADER_SIZE) return error.InvalidChunk;

                const flag = packet_plaintext[4];
                const chunk_payload = packet_plaintext[pkt.CHUNK_HEADER_SIZE..];

                if (flag == 0x01) {
                    const decompressed = try huffman.decode(chunk_payload, allocator);
                    defer allocator.free(decompressed);
                    try out.appendSlice(allocator, decompressed);
                } else {
                    try out.appendSlice(allocator, chunk_payload);
                }
            },

            pkt.DONE => {
                break;
            },

            else => return error.UnknownPacketType,
        }
    }

    const final_filename = filename orelse return error.NoMetadata;
    return .{
        .filename = final_filename,
        .bytes = try out.toOwnedSlice(allocator),
    };
}
