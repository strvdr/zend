const std = @import("std");

pub fn randomHex() [16]u8 {
    var raw: [8]u8 = undefined;
    std.crypto.random.bytes(&raw);
    const hex = "0123456789abcdef";
    var out: [16]u8 = undefined;
    for (raw, 0..) |byte, i| {
        out[i * 2] = hex[byte >> 4];
        out[i * 2 + 1] = hex[byte & 0x0f];
    }
    return out;
}

pub fn isValidId(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    for (id) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    }
    return true;
}

test "randomHex returns lowercase fixed-width hex" {
    const id = randomHex();

    try std.testing.expectEqual(@as(usize, 16), id.len);
    for (id) |c| {
        try std.testing.expect(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'));
    }
}

test "isValidId accepts safe ids and rejects unsafe path-like ids" {
    try std.testing.expect(isValidId("abc123"));
    try std.testing.expect(isValidId("A_b-c_123"));

    try std.testing.expect(!isValidId(""));
    try std.testing.expect(!isValidId("../secret"));
    try std.testing.expect(!isValidId("with/slash"));
    try std.testing.expect(!isValidId("with space"));
    try std.testing.expect(!isValidId("semi:semicolon"));
    try std.testing.expect(!isValidId("trailing."));
    try std.testing.expect(!isValidId("null\x00byte"));

    const too_long = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    try std.testing.expect(!isValidId(too_long));
}
