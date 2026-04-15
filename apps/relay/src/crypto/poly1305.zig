// takes a 32-byte one-time key and a message
// produces a 16-byte authentication tag
// receiver computes tag and rejects the message
// if it doesn't match. ChaCha20 provides confidentiality
// and Poly1305 provides integrity

const std = @import("std");

fn clamp(r: [16]u8) [16]u8 {
    var clamped = r;
    clamped[3] &= 15;
    clamped[7] &= 15;
    clamped[11] &= 15;
    clamped[15] &= 15;
    clamped[4] &= 252;
    clamped[8] &= 252;
    clamped[12] &= 252;

    return clamped;
}

fn leBytesToNumber(bytes: []const u8) u128 {
    var result: u128 = 0;

    for(bytes, 0..) |byte, i| {
        result |= @as(u128, byte) << @intCast(i * 8);
    }

    return result;
}

fn leNumberToBytes(number: u128) [16]u8 {
    var result: [16]u8 = undefined;
    std.mem.writeInt(u128, &result, number, .little);
    return result;
}

pub fn poly1305Mac(msg: []const u8, key: [32]u8) [16]u8 {
    const rBytes: [16]u8 = key[0..16].*;
    const sBytes: [16]u8 = key[16..32].*;
    const p: u256 = (1 << 130) - 5;

    const rClamped: [16]u8 = clamp(rBytes);
    const r = @as(u256, leBytesToNumber(&rClamped));
    const s = @as(u256, leBytesToNumber(&sBytes));

    var acc: u256 = 0;
    var i: usize = 0;
    while(i < msg.len) {
        const end = @min(i + 16, msg.len);
        const chunk = msg[i..end];

        var n: u256 = @as(u256, leBytesToNumber(chunk));
        n |= @as(u256, 1) << @intCast(chunk.len * 8);

        acc += n;
        acc = (acc * r) % p;

        i += 16;
    }

    const result: u128 = @intCast((acc + s) % (1 << 128));
    const out: [16]u8 = leNumberToBytes(result);

    return out;
}

test "poly1305 MAC - RFC 8439 Section 2.5.2" {
    const key = [32]u8{
        // r (first 16 bytes)
        0x85, 0xd6, 0xbe, 0x78, 0x57, 0x55, 0x6d, 0x33,
        0x7f, 0x44, 0x52, 0xfe, 0x42, 0xd5, 0x06, 0xa8,
        // s (last 16 bytes)
        0x01, 0x03, 0x80, 0x8a, 0xfb, 0x0d, 0xb2, 0xfd,
        0x4a, 0xbf, 0xf6, 0xaf, 0x41, 0x49, 0xf5, 0x1b,
    };

    // "Cryptographic Forum Research Group"
    const msg = [_]u8{
        0x43, 0x72, 0x79, 0x70, 0x74, 0x6f, 0x67, 0x72,
        0x61, 0x70, 0x68, 0x69, 0x63, 0x20, 0x46, 0x6f,
        0x72, 0x75, 0x6d, 0x20, 0x52, 0x65, 0x73, 0x65,
        0x61, 0x72, 0x63, 0x68, 0x20, 0x47, 0x72, 0x6f,
        0x75, 0x70,
    };

    const expected_tag = [16]u8{
        0xa8, 0x06, 0x1d, 0xc1, 0x30, 0x51, 0x36, 0xc6,
        0xc2, 0x2b, 0x8b, 0xaf, 0x0c, 0x01, 0x27, 0xa9,
    };

    const tag = poly1305Mac(&msg, key);

    try std.testing.expectEqualSlices(u8, &expected_tag, &tag);
}
