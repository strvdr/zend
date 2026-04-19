const std = @import("std");

pub const BitWriter = struct {
    output: std.ArrayList(u8),
    currentByte: u8,
    bitCount: u3, 
    
    pub fn init() BitWriter {
        return .{
            .output = .{},
            .currentByte = 0,
            .bitCount = 0,
        };
    }

    pub fn deinit(self: *BitWriter, allocator: std.mem.Allocator) void {
        self.output.deinit(allocator);
    }

    pub fn writeBit(self: *BitWriter, allocator: std.mem.Allocator, bit: u1) !void {
        // Bits are packed from most-significant to least-significant position
        // within each output byte.
        self.currentByte = (self.currentByte << 1) | bit;
        self.bitCount +%= 1;
        
        if(self.bitCount == 0) {
            // Once a byte is full, emit it and reset the staging state.
            try self.output.append(allocator, self.currentByte);
            self.currentByte = 0;
        }
    }

    pub fn writeBits(self: *BitWriter, allocator: std.mem.Allocator, bits: []const u1) !void {
        // writeBits() emits the high bit first so the logical bitstream order
        // matches the order used by the Huffman codes.
        for(bits) |bit| {
            try self.writeBit(allocator, bit);
        }
    }

    pub fn flush(self: *BitWriter, allocator: std.mem.Allocator) !void {
        if(self.bitCount > 0) {
            // Any partially filled byte is emitted as-is with zero padding in
            // the unused low bits.
            const shift: u4 = @as(u4, 8) - @as(u4, self.bitCount);
            try self.output.append(allocator, self.currentByte << @intCast(shift));
            self.currentByte = 0;
            self.bitCount = 0;
        }
    }
};

test "write one full byte MSB-first" {
    var writer = BitWriter.init();
    defer writer.deinit(std.testing.allocator);

    // write 10110001 = 0xB1
    const bits = [_]u1{ 1, 0, 1, 1, 0, 0, 0, 1 };
    for (bits) |bit| {
        try writer.writeBit(std.testing.allocator, bit);
    }

    try std.testing.expectEqual(@as(usize, 1), writer.output.items.len);
    try std.testing.expectEqual(@as(u8, 0xB1), writer.output.items[0]);
}

test "flush partial byte pads with zeros" {
    var writer = BitWriter.init();
    defer writer.deinit(std.testing.allocator);

    // write 5 bits: 10110
    const bits = [_]u1{ 1, 0, 1, 1, 0 };
    for (bits) |bit| {
        try writer.writeBit(std.testing.allocator, bit);
    }

    try writer.flush(std.testing.allocator);

    // 10110 padded to 10110000 = 0xB0
    try std.testing.expectEqual(@as(usize, 1), writer.output.items.len);
    try std.testing.expectEqual(@as(u8, 0xB0), writer.output.items[0]);
}

test "multiple bytes plus partial" {
    var writer = BitWriter.init();
    defer writer.deinit(std.testing.allocator);

    // write 11111111 00000000 110
    // = 0xFF, 0x00, then flush gives 0xC0
    const bits = [_]u1{ 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 0 };
    for (bits) |bit| {
        try writer.writeBit(std.testing.allocator, bit);
    }

    try writer.flush(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), writer.output.items.len);
    try std.testing.expectEqual(@as(u8, 0xFF), writer.output.items[0]);
    try std.testing.expectEqual(@as(u8, 0x00), writer.output.items[1]);
    try std.testing.expectEqual(@as(u8, 0xC0), writer.output.items[2]);
}
