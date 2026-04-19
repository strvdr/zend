const std = @import("std");
const chacha20 = @import("chacha20");
const poly1305 = @import("poly1305");

fn poly1305KeyGen(key: [32]u8, nonce: [12]u8) [32]u8 {
    // ChaCha20-Poly1305 derives the one-time MAC key from block counter 0.
    // We generate one keystream block and take its first 32 bytes.
    var block = [_]u8{0} ** 64;
    chacha20.chacha20Xor(key, nonce, 0, &block);
    return block[0..32].*;
}

fn buildMacData(aad: []const u8, ciphertext: []const u8, allocator: std.mem.Allocator) ![]u8 {
    // Poly1305 authenticates a specific padded layout:
    //   aad || pad16(aad) || ciphertext || pad16(ciphertext)
    //   || aad_len_le64 || ciphertext_len_le64
    //
    // The padding bytes are zeros and are only present to align each section
    // to a 16-byte boundary as required by RFC 8439.
    const aadPad = if (aad.len % 16 == 0) 0 else 16 - (aad.len % 16);
    const ctPad = if (ciphertext.len % 16 == 0) 0 else 16 - (ciphertext.len % 16);
    const totalLen = aad.len + aadPad + ciphertext.len + ctPad + 8 + 8;

    const buf = try allocator.alloc(u8, totalLen);
    var offset: usize = 0;

    @memcpy(buf[offset..][0..aad.len], aad);
    offset += aad.len;

    @memset(buf[offset..][0..aadPad], 0);
    offset += aadPad;

    @memcpy(buf[offset..][0..ciphertext.len], ciphertext);
    offset += ciphertext.len;

    @memset(buf[offset..][0..ctPad], 0);
    offset += ctPad;

    std.mem.writeInt(u64, buf[offset..][0..8], @intCast(aad.len), .little);
    offset += 8;

    std.mem.writeInt(u64, buf[offset..][0..8], @intCast(ciphertext.len), .little);

    return buf;
}

pub fn encrypt(key: [32]u8, nonce: [12]u8, plaintext: []u8, aad: []const u8, out_tag: *[16]u8, allocator: std.mem.Allocator) !void {
    const oneTimeKey: [32]u8 = poly1305KeyGen(key, nonce);

    // Encrypt in place using ChaCha20 with counter 1.
    // Counter 0 is reserved for the Poly1305 key derivation step above.
    chacha20.chacha20Xor(key, nonce, 1, plaintext);

    const macData: []u8 = try buildMacData(aad, plaintext, allocator);
    defer allocator.free(macData);

    out_tag.* = poly1305.poly1305Mac(macData, oneTimeKey);
}

pub fn decrypt(key: [32]u8, nonce: [12]u8, ciphertext: []u8, aad: []const u8, tag: [16]u8, allocator: std.mem.Allocator) !void {
    const oneTimeKey: [32]u8 = poly1305KeyGen(key, nonce);
    const macData: []u8 = try buildMacData(aad, ciphertext, allocator);
    defer allocator.free(macData);

    const expectedTag = poly1305.poly1305Mac(macData, oneTimeKey);

    // Always verify the tag before decrypting.
    // That prevents unauthenticated bytes from ever being treated as plaintext.
    var match = true;
    for (expectedTag, tag) |a, b| {
        if (a != b) match = false;
    }

    if (!match) return error.AuthenticationFailed;

    chacha20.chacha20Xor(key, nonce, 1, ciphertext);
}

test "aead round trip" {
    const key = [_]u8{0x42} ** 32;
    const nonce = [_]u8{0x07} ** 12;
    const aad = "some header data";

    var plaintext = "hello from zend".*;
    const original = plaintext;

    var tag: [16]u8 = undefined;
    try encrypt(key, nonce, &plaintext, aad, &tag, std.testing.allocator);

    // plaintext is now ciphertext — should differ from original
    try std.testing.expect(!std.mem.eql(u8, &original, &plaintext));

    // decrypt in place
    try decrypt(key, nonce, &plaintext, aad, tag, std.testing.allocator);

    // should match original
    try std.testing.expectEqualSlices(u8, &original, &plaintext);
}

test "aead detects tampered ciphertext" {
    const key = [_]u8{0x42} ** 32;
    const nonce = [_]u8{0x07} ** 12;
    const aad = "header";

    var plaintext = "secret message!!".*;
    var tag: [16]u8 = undefined;
    try encrypt(key, nonce, &plaintext, aad, &tag, std.testing.allocator);

    // flip one bit
    plaintext[0] ^= 1;

    // decrypt should fail
    try std.testing.expectError(
        error.AuthenticationFailed,
        decrypt(key, nonce, &plaintext, aad, tag, std.testing.allocator),
    );
}

test "AEAD ChaCha20-Poly1305 - RFC 8439 Section 2.8.2" {
    const key = [32]u8{
        0x80, 0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
        0x88, 0x89, 0x8a, 0x8b, 0x8c, 0x8d, 0x8e, 0x8f,
        0x90, 0x91, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97,
        0x98, 0x99, 0x9a, 0x9b, 0x9c, 0x9d, 0x9e, 0x9f,
    };
    // nonce = 07:00:00:00 ++ 40:41:42:43:44:45:46:47
    const nonce = [12]u8{
        0x07, 0x00, 0x00, 0x00, 0x40, 0x41, 0x42, 0x43,
        0x44, 0x45, 0x46, 0x47,
    };
    const aad = [_]u8{
        0x50, 0x51, 0x52, 0x53, 0xc0, 0xc1, 0xc2, 0xc3,
        0xc4, 0xc5, 0xc6, 0xc7,
    };

    // Sunscreen plaintext (114 bytes)
    var plaintext = [_]u8{
        0x4c, 0x61, 0x64, 0x69, 0x65, 0x73, 0x20, 0x61,
        0x6e, 0x64, 0x20, 0x47, 0x65, 0x6e, 0x74, 0x6c,
        0x65, 0x6d, 0x65, 0x6e, 0x20, 0x6f, 0x66, 0x20,
        0x74, 0x68, 0x65, 0x20, 0x63, 0x6c, 0x61, 0x73,
        0x73, 0x20, 0x6f, 0x66, 0x20, 0x27, 0x39, 0x39,
        0x3a, 0x20, 0x49, 0x66, 0x20, 0x49, 0x20, 0x63,
        0x6f, 0x75, 0x6c, 0x64, 0x20, 0x6f, 0x66, 0x66,
        0x65, 0x72, 0x20, 0x79, 0x6f, 0x75, 0x20, 0x6f,
        0x6e, 0x6c, 0x79, 0x20, 0x6f, 0x6e, 0x65, 0x20,
        0x74, 0x69, 0x70, 0x20, 0x66, 0x6f, 0x72, 0x20,
        0x74, 0x68, 0x65, 0x20, 0x66, 0x75, 0x74, 0x75,
        0x72, 0x65, 0x2c, 0x20, 0x73, 0x75, 0x6e, 0x73,
        0x63, 0x72, 0x65, 0x65, 0x6e, 0x20, 0x77, 0x6f,
        0x75, 0x6c, 0x64, 0x20, 0x62, 0x65, 0x20, 0x69,
        0x74, 0x2e,
    };

    const expected_ciphertext = [_]u8{
        0xd3, 0x1a, 0x8d, 0x34, 0x64, 0x8e, 0x60, 0xdb,
        0x7b, 0x86, 0xaf, 0xbc, 0x53, 0xef, 0x7e, 0xc2,
        0xa4, 0xad, 0xed, 0x51, 0x29, 0x6e, 0x08, 0xfe,
        0xa9, 0xe2, 0xb5, 0xa7, 0x36, 0xee, 0x62, 0xd6,
        0x3d, 0xbe, 0xa4, 0x5e, 0x8c, 0xa9, 0x67, 0x12,
        0x82, 0xfa, 0xfb, 0x69, 0xda, 0x92, 0x72, 0x8b,
        0x1a, 0x71, 0xde, 0x0a, 0x9e, 0x06, 0x0b, 0x29,
        0x05, 0xd6, 0xa5, 0xb6, 0x7e, 0xcd, 0x3b, 0x36,
        0x92, 0xdd, 0xbd, 0x7f, 0x2d, 0x77, 0x8b, 0x8c,
        0x98, 0x03, 0xae, 0xe3, 0x28, 0x09, 0x1b, 0x58,
        0xfa, 0xb3, 0x24, 0xe4, 0xfa, 0xd6, 0x75, 0x94,
        0x55, 0x85, 0x80, 0x8b, 0x48, 0x31, 0xd7, 0xbc,
        0x3f, 0xf4, 0xde, 0xf0, 0x8e, 0x4b, 0x7a, 0x9d,
        0xe5, 0x76, 0xd2, 0x65, 0x86, 0xce, 0xc6, 0x4b,
        0x61, 0x16,
    };

    const expected_tag = [16]u8{
        0x1a, 0xe1, 0x0b, 0x59, 0x4f, 0x09, 0xe2, 0x6a,
        0x7e, 0x90, 0x2e, 0xcb, 0xd0, 0x60, 0x06, 0x91,
    };

    var tag: [16]u8 = undefined;
    try encrypt(key, nonce, &plaintext, &aad, &tag, std.testing.allocator);

    // verify ciphertext matches
    try std.testing.expectEqualSlices(u8, &expected_ciphertext, &plaintext);

    // verify tag matches
    try std.testing.expectEqualSlices(u8, &expected_tag, &tag);
}
