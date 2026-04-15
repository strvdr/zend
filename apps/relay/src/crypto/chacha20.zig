const std = @import("std");

fn chachaBlock(key: [8]u32, counter: u32, nonce: [3]u32) [16]u32 { 
    var state = [16]u32 {
        0x61707865, 0x3320646e, 0x79622d32, 0x6b206574,
        key[0], key[1], key[2], key[3],
        key[4], key[5], key[6], key[7],
        counter, nonce[0], nonce[1], nonce[2],
    };

    const original = state;

   
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        // column rounds
        quarterRound(&state, 0, 4,  8, 12);
        quarterRound(&state, 1, 5,  9, 13);
        quarterRound(&state, 2, 6, 10, 14);
        quarterRound(&state, 3, 7, 11, 15);
        // diagonal rounds
        quarterRound(&state, 0, 5, 10, 15);
        quarterRound(&state, 1, 6, 11, 12);
        quarterRound(&state, 2, 7,  8, 13);
        quarterRound(&state, 3, 4,  9, 14);
    }

    for(&state, original) |*s, o| {
        s.* = s.* +% o;
    }

    return state;
}

fn quarterRound(stateMatrix: *[16]u32, a: usize, b: usize, c: usize, d: usize) void {
    stateMatrix[a] = stateMatrix[a] +% stateMatrix[b];
    stateMatrix[d] ^= stateMatrix[a];
    stateMatrix[d] = std.math.rotl(u32, stateMatrix[d], 16);
    stateMatrix[c] = stateMatrix[c] +% stateMatrix[d];
    stateMatrix[b] ^= stateMatrix[c];
    stateMatrix[b] = std.math.rotl(u32, stateMatrix[b], 12);
    stateMatrix[a] = stateMatrix[a] +% stateMatrix[b];
    stateMatrix[d] ^= stateMatrix[a];
    stateMatrix[d] = std.math.rotl(u32, stateMatrix[d], 8);
    stateMatrix[c] = stateMatrix[c] +% stateMatrix[d];
    stateMatrix[b] ^= stateMatrix[c];
    stateMatrix[b] = std.math.rotl(u32, stateMatrix[b], 7);
}

fn blockToBytes(stateMatrix: [16]u32) [64]u8 {
    var buf: [64]u8 = undefined;

    for(stateMatrix, 0..) |word, i| {
        std.mem.writeInt(u32, buf[i*4..][0..4], word, .little);
    }

    return buf;
}

fn bytesToWords(comptime n: usize, bytes: [n * 4]u8) [n]u32 {
    var words: [n]u32 = undefined;
    for(0..n) |i| {
        words[i] = std.mem.readInt(u32, bytes[i * 4 ..][0..4], .little);
    }

    return words;
}

pub fn chacha20Xor(key: [32]u8, nonce: [12]u8, counter: u32, data: []u8) void {
    const keyWords = bytesToWords(8, key);
    const nonceWords = bytesToWords(3, nonce);
    
    var currentCounter = counter;
    var offset: usize = 0;
    while(offset < data.len) { 
        const end = @min(offset + 64, data.len);
        const chunk = data[offset..end];

        const block = chachaBlock(keyWords, currentCounter, nonceWords);
        const blockBytes = blockToBytes(block);

        for(chunk, 0..) |*byte, i| {
            byte.* ^= blockBytes[i];
        }

        offset += 64;
        currentCounter += 1;
    }
}

test "chacha20 quarter round - RFC 8439 Section 2.1.1" {
    var state = [16]u32{
        0x11111111, 0x01020304, 0x9b8d6f43, 0x01234567,
        0, 0, 0, 0,
        0, 0, 0, 0,
        0, 0, 0, 0,
    };

    quarterRound(&state, 0, 1, 2, 3);

    try std.testing.expectEqual(@as(u32, 0xea2a92f4), state[0]);
    try std.testing.expectEqual(@as(u32, 0xcb1cf8ce), state[1]);
    try std.testing.expectEqual(@as(u32, 0x4581472e), state[2]);
    try std.testing.expectEqual(@as(u32, 0x5881c4bb), state[3]);
}

test "chacha20 block function - RFC 8439 Section 2.3.2" {
    const key = [8]u32{
        0x03020100, 0x07060504, 0x0b0a0908, 0x0f0e0d0c,
        0x13121110, 0x17161514, 0x1b1a1918, 0x1f1e1d1c,
    };

    const nonce = [3]u32{
        0x09000000, 0x4a000000, 0x00000000,
    };

    const counter: u32 = 1;

    const result = chachaBlock(key, counter, nonce);

    const expected = [16]u32{
        0xe4e7f110, 0x15593bd1, 0x1fdd0f50, 0xc47120a3,
        0xc7f4d1c7, 0x0368c033, 0x9aaa2204, 0x4e6cd4c3,
        0x466482d2, 0x09aa9f07, 0x05d7c214, 0xa2028bd9,
        0xd19c12b5, 0xb94e16de, 0xe883d0cb, 0x4e3c50a2,
    };

    for (expected, result) |exp, got| {
        try std.testing.expectEqual(exp, got);
    }
}

test "chacha20 encrypt - RFC 8439 Section 2.4.2" {
    const key = [32]u8{
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
        0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
        0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
        0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f,
    };
    const nonce = [12]u8{
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x4a,
        0x00, 0x00, 0x00, 0x00,
    };
    const counter: u32 = 1;

    // "Ladies and Gentlemen of the class of '99: If I could offer you only 
    // one tip for the future, sunscreen would be it."
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

    const expectedCiphertext = [_]u8{
        0x6e, 0x2e, 0x35, 0x9a, 0x25, 0x68, 0xf9, 0x80,
        0x41, 0xba, 0x07, 0x28, 0xdd, 0x0d, 0x69, 0x81,
        0xe9, 0x7e, 0x7a, 0xec, 0x1d, 0x43, 0x60, 0xc2,
        0x0a, 0x27, 0xaf, 0xcc, 0xfd, 0x9f, 0xae, 0x0b,
        0xf9, 0x1b, 0x65, 0xc5, 0x52, 0x47, 0x33, 0xab,
        0x8f, 0x59, 0x3d, 0xab, 0xcd, 0x62, 0xb3, 0x57,
        0x16, 0x39, 0xd6, 0x24, 0xe6, 0x51, 0x52, 0xab,
        0x8f, 0x53, 0x0c, 0x35, 0x9f, 0x08, 0x61, 0xd8,
        0x07, 0xca, 0x0d, 0xbf, 0x50, 0x0d, 0x6a, 0x61,
        0x56, 0xa3, 0x8e, 0x08, 0x8a, 0x22, 0xb6, 0x5e,
        0x52, 0xbc, 0x51, 0x4d, 0x16, 0xcc, 0xf8, 0x06,
        0x81, 0x8c, 0xe9, 0x1a, 0xb7, 0x79, 0x37, 0x36,
        0x5a, 0xf9, 0x0b, 0xbf, 0x74, 0xa3, 0x5b, 0xe6,
        0xb4, 0x0b, 0x8e, 0xed, 0xf2, 0x78, 0x5e, 0x42,
        0x87, 0x4d,
    };

    // encrypt in place
    chacha20Xor(key, nonce, counter, &plaintext);

    try std.testing.expectEqualSlices(u8, &expectedCiphertext, &plaintext);
}
