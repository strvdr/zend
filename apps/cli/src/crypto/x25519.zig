const std = @import("std");

const p: u256 = (1 << 255) - 19;

fn feAdd(a: u256, b: u256) u256 {
    return (a + b) % p;
}

fn feSub(a: u256, b: u256) u256 {
    return (a + p - b) % p;
}

fn feMul(a: u256, b: u256) u256 {
    const product: u512 = @as(u512, a) * @as(u512, b);
    return @intCast(product % p);
}

fn feSquare(a: u256) u256 {
    const product: u512 = @as(u512, a) * @as(u512, a);
    return @intCast(product % p);
}

fn feInverse(a: u256) u256 {
    const exp = p - 2;
    var result: u256 = 1;
    var base = a;
    var e = exp;
    while(e > 0) {
        if(e & 1 == 1) {
            result = feMul(result, base);
        }
        base = feSquare(base);
        e >>= 1;
    }

    return result;
}

fn clampPrivateKey(key: [32]u8) [32]u8 {
    // X25519 requires scalar clamping before scalar multiplication.
    // This is part of the algorithm, not an optional hardening step.
    var clamped = key;
    clamped[0] &= 248;
    clamped[31] &= 127;
    clamped[31] |= 64;
    return clamped;
}

fn montgomeryLadder(k: u256, u: u256) u256 {
    // The Montgomery ladder performs scalar multiplication in a regular,
    // step-by-step pattern. That regular structure is one of the reasons
    // Curve25519 is attractive for key exchange implementations.
    var x_2: u256 = 1;
    var z_2: u256 = 0;
    var x_3: u256 = u;
    var z_3: u256 = 1;
    var swap: u256 = 0;

    var i: i16 = 254;
    while (i >= 0) : (i -= 1) {
        const k_t = (k >> @intCast(i)) & 1;
        swap ^= k_t;

        // Conditional swaps keep the ladder aligned with the current scalar bit
        // without branching on secret data.
        cswap(&x_2, &x_3, swap);
        cswap(&z_2, &z_3, swap);
        swap = k_t;

        const a = feAdd(x_2, z_2);
        const aa = feSquare(a);
        const b = feSub(x_2, z_2);
        const bb = feSquare(b);
        const e = feSub(aa, bb);
        const c = feAdd(x_3, z_3);
        const d = feSub(x_3, z_3);
        const da = feMul(d, a);
        const cb = feMul(c, b);
        x_3 = feSquare(feAdd(da, cb));
        z_3 = feMul(u, feSquare(feSub(da, cb)));
        x_2 = feMul(aa, bb);
        z_2 = feMul(e, feAdd(aa, feMul(121665, e)));
    }

    cswap(&x_2, &x_3, swap);
    cswap(&z_2, &z_3, swap);
    return feMul(x_2, feInverse(z_2));
}

fn cswap(a: *u256, b: *u256, swapFlag: u256) void {
    // Branch-free conditional swap.
    // swapFlag is expected to be 0 or 1.
    const mask = 0 -% swapFlag;
    const temp = mask & (a.* ^ b.*);
    a.* ^= temp;
    b.* ^= temp;
}

pub fn x25519(k: [32]u8, u: [32]u8) [32]u8 {
    const clamped = clampPrivateKey(k);

    // The u-coordinate is interpreted little-endian and masked to 255 bits
    // per the X25519 definition.
    const kScalar = std.mem.readInt(u256, &clamped, .little);
    const uPoint = std.mem.readInt(u256, &u, .little) & ((@as(u256, 1) << 255) - 1);

    const result = montgomeryLadder(kScalar, uPoint);

    var out: [32]u8 = undefined;
    std.mem.writeInt(u256, &out, result, .little);
    return out;
}

pub fn generatePublicKey(privateKey: [32]u8) [32]u8 {
    const basepoint = [_]u8{9} ++ [_]u8{0} ** 31;
    return x25519(privateKey, basepoint);
}

pub fn sharedSecret(myPrivate: [32]u8, theirPublic: [32]u8) [32]u8 {
    return x25519(myPrivate, theirPublic);
}

test "ensure arithmetic functions are correct" {
    for(1..200) |a| {
        try std.testing.expectEqual(1, feMul(a, feInverse(a)));
        try std.testing.expectEqual(0, feAdd(a, feSub(p, a)) % p);
    }
}

test "X25519 - RFC 7748 Section 5.2 Vector 1" {
    const scalar = [32]u8{
        0xa5, 0x46, 0xe3, 0x6b, 0xf0, 0x52, 0x7c, 0x9d,
        0x3b, 0x16, 0x15, 0x4b, 0x82, 0x46, 0x5e, 0xdd,
        0x62, 0x14, 0x4c, 0x0a, 0xc1, 0xfc, 0x5a, 0x18,
        0x50, 0x6a, 0x22, 0x44, 0xba, 0x44, 0x9a, 0xc4,
    };
    const u_coord = [32]u8{
        0xe6, 0xdb, 0x68, 0x67, 0x58, 0x30, 0x30, 0xdb,
        0x35, 0x94, 0xc1, 0xa4, 0x24, 0xb1, 0x5f, 0x7c,
        0x72, 0x66, 0x24, 0xec, 0x26, 0xb3, 0x35, 0x3b,
        0x10, 0xa9, 0x03, 0xa6, 0xd0, 0xab, 0x1c, 0x4c,
    };
    const expected = [32]u8{
        0xc3, 0xda, 0x55, 0x37, 0x9d, 0xe9, 0xc6, 0x90,
        0x8e, 0x94, 0xea, 0x4d, 0xf2, 0x8d, 0x08, 0x4f,
        0x32, 0xec, 0xcf, 0x03, 0x49, 0x1c, 0x71, 0xf7,
        0x54, 0xb4, 0x07, 0x55, 0x77, 0xa2, 0x85, 0x52,
    };

    const result = x25519(scalar, u_coord);
    try std.testing.expectEqualSlices(u8, &expected, &result);
}

test "X25519 - RFC 7748 Section 5.2 Vector 2" {
    const scalar = [32]u8{
        0x4b, 0x66, 0xe9, 0xd4, 0xd1, 0xb4, 0x67, 0x3c,
        0x5a, 0xd2, 0x26, 0x91, 0x95, 0x7d, 0x6a, 0xf5,
        0xc1, 0x1b, 0x64, 0x21, 0xe0, 0xea, 0x01, 0xd4,
        0x2c, 0xa4, 0x16, 0x9e, 0x79, 0x18, 0xba, 0x0d,
    };
    const u_coord = [32]u8{
        0xe5, 0x21, 0x0f, 0x12, 0x78, 0x68, 0x11, 0xd3,
        0xf4, 0xb7, 0x95, 0x9d, 0x05, 0x38, 0xae, 0x2c,
        0x31, 0xdb, 0xe7, 0x10, 0x6f, 0xc0, 0x3c, 0x3e,
        0xfc, 0x4c, 0xd5, 0x49, 0xc7, 0x15, 0xa4, 0x93,
    };
    const expected = [32]u8{
        0x95, 0xcb, 0xde, 0x94, 0x76, 0xe8, 0x90, 0x7d,
        0x7a, 0xad, 0xe4, 0x5c, 0xb4, 0xb8, 0x73, 0xf8,
        0x8b, 0x59, 0x5a, 0x68, 0x79, 0x9f, 0xa1, 0x52,
        0xe6, 0xf8, 0xf7, 0x64, 0x7a, 0xac, 0x79, 0x57,
    };

    const result = x25519(scalar, u_coord);
    try std.testing.expectEqualSlices(u8, &expected, &result);
}

test "X25519 Diffie-Hellman round trip" {
    // Alice's private key (arbitrary 32 bytes)
    const alice_private = [32]u8{
        0x77, 0x07, 0x6d, 0x0a, 0x73, 0x18, 0xa5, 0x7d,
        0x3c, 0x16, 0xc1, 0x72, 0x51, 0xb2, 0x66, 0x45,
        0xdf, 0x4c, 0x2f, 0x87, 0xeb, 0xc0, 0x99, 0x2a,
        0xb1, 0x77, 0xfb, 0xa5, 0x1d, 0xb9, 0x2c, 0x2a,
    };
    // Bob's private key (arbitrary 32 bytes)
    const bob_private = [32]u8{
        0x5d, 0xab, 0x08, 0x7e, 0x62, 0x4a, 0x8a, 0x4b,
        0x79, 0xe1, 0x7f, 0x8b, 0x83, 0x80, 0x0e, 0xe6,
        0x6f, 0x3b, 0xb1, 0x29, 0x26, 0x18, 0xb6, 0xfd,
        0x1c, 0x2f, 0x8b, 0x27, 0xff, 0x88, 0xe0, 0xeb,
    };

    // both generate public keys
    const alice_public = generatePublicKey(alice_private);
    const bob_public = generatePublicKey(bob_private);

    // both compute shared secret
    const alice_shared = sharedSecret(alice_private, bob_public);
    const bob_shared = sharedSecret(bob_private, alice_public);

    // must match
    try std.testing.expectEqualSlices(u8, &alice_shared, &bob_shared);
}
