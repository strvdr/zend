const std = @import("std");
const bitwriter = @import("bitwriter.zig");

const HuffmanNode = struct {
    freq: u32,
    byteVal: ?u8,
    left: ?usize,
    right: ?usize,
};

const HuffmanCode = struct {
    bits: [256]u1,
    len: u8,
};

const HuffmanTree = struct {
    nodes: std.ArrayList(HuffmanNode),
    root: usize,
};

fn buildFrequencyTable(data: []const u8) [256]u32 { 
    var freq = [_]u32{0} ** 256;
    for(data) |byte| {
        freq[byte] += 1;
    }

    return freq;
}

fn compareNodes(nodes: []const HuffmanNode, a: usize, b: usize) std.math.Order {
    return std.math.order(nodes[a].freq, nodes[b].freq);
}

fn buildTree(freq: [256]u32, allocator: std.mem.Allocator) !HuffmanTree {
    var nodes = std.ArrayList(HuffmanNode){};
    try nodes.ensureTotalCapacity(allocator, 511);

    for(freq, 0..) |f, i| {
        if(f > 0) {
            try nodes.append(allocator, .{
                .freq = f,
                .byteVal = @intCast(i), 
                .left = null,
                .right = null,
            });
        }
    }

    var pQueue = std.PriorityQueue(usize, []const HuffmanNode, compareNodes).init(allocator, nodes.items);
    defer pQueue.deinit();

    for(0..nodes.items.len) |i| {
        try pQueue.add(i);
    }

    if (pQueue.count() == 1) {
        try nodes.append(allocator, .{
            .freq = 0,
            .byteVal = null,
            .left = null,
            .right = null,
        });
        pQueue.context = nodes.items;
        try pQueue.add(nodes.items.len - 1);
    }

    while(pQueue.count() > 1) {
        const left = pQueue.remove();
        const right = pQueue.remove();

        try nodes.append(allocator, .{
            .freq = nodes.items[left].freq + nodes.items[right].freq,
            .byteVal = null,
            .left = left,
            .right = right,
        });
        
        pQueue.context = nodes.items;
        try pQueue.add(nodes.items.len - 1);
    }

    return .{ .nodes = nodes, .root = pQueue.remove() };
}

fn generateCodes(nodes: []const HuffmanNode, nodeIndex: usize, currentCode: [256]u1, depth: u8, codeTable: *[256]HuffmanCode) void {
    const node = nodes[nodeIndex];

    //base case: leaf  node (has a byte value)
    if(node.byteVal) |byte| {
        codeTable[byte] = .{
            .bits = currentCode,
            .len = if(depth == 0) 1 else depth,
        };
        return;
    }

    if(node.left) |left| {
        var leftCode = currentCode;
        leftCode[depth] = 0;
        generateCodes(nodes, left, leftCode, depth + 1, codeTable);
    }

    if(node.right) |right| {
        var rightCode = currentCode;
        rightCode[depth] = 1;
        generateCodes(nodes, right, rightCode, depth + 1, codeTable);
    }
}

pub fn encode(data: []const u8, allocator: std.mem.Allocator) ![]u8 { 
    if (data.len == 0) {
        var output = std.ArrayList(u8){};
        defer output.deinit(allocator);

        const zero_freq = [_]u32{0} ** 256;
        for (zero_freq) |f| {
            var buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &buf, f, .little);
            try output.appendSlice(allocator, &buf);
        }

        var len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_buf, 0, .little);
        try output.appendSlice(allocator, &len_buf);

        return output.toOwnedSlice(allocator);
    }

    const freq = buildFrequencyTable(data);

    var tree = try buildTree(freq, allocator);
    defer tree.nodes.deinit(allocator);

    //......... this is disgusting
    var codeTable = [_]HuffmanCode{.{ .bits = [_]u1{0} ** 256, .len = 0 }} ** 256;
    generateCodes(tree.nodes.items, tree.root, [_]u1{0} ** 256, 0, &codeTable);

    var output = std.ArrayList(u8){};
    defer output.deinit(allocator);

    for(freq) |f| {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, f, .little);
        try output.appendSlice(allocator, &buf);
    }

    var lenBuf: [4]u8 = undefined;
    std.mem.writeInt(u32, &lenBuf, @intCast(data.len), .little);
    try output.appendSlice(allocator, &lenBuf);

    var writer = bitwriter.BitWriter.init();
    for(data) |byte| {
        const code = codeTable[byte];
        for(0..code.len) |i| {
            try writer.writeBit(allocator, code.bits[i]);
        }
    }

    try writer.flush(allocator);

    try output.appendSlice(allocator, writer.output.items);
    writer.deinit(allocator);

    return output.toOwnedSlice(allocator);
}

pub fn decode(compressed: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const header_len: usize = 256 * 4 + 4; // freq table + original length

    if (compressed.len < header_len) {
        return error.TruncatedHuffmanHeader;
    }

    var freq: [256]u32 = undefined;
    var total_freq: u64 = 0;

    for (0..256) |i| {
        const offset = i * 4;
        freq[i] = std.mem.readInt(u32, compressed[offset ..][0..4], .little);
        total_freq += freq[i];
    }

    const data_len_u32 = std.mem.readInt(u32, compressed[1024 .. 1028], .little);
    const data_len: usize = @intCast(data_len_u32);

    if (data_len == 0) {
        return allocator.alloc(u8, 0);
    }

    var tree = try buildTree(freq, allocator);
    defer tree.nodes.deinit(allocator);

    if (tree.nodes.items.len == 0) {
        return error.InvalidHuffmanTree;
    }

    const bit_data = compressed[1028..];
    var output = try allocator.alloc(u8, data_len);
    errdefer allocator.free(output);

    // Special case: only one symbol in the tree.
    if (tree.nodes.items[tree.root].byteVal) |byte| {
        @memset(output, byte);
        return output;
    }

    var bytes_decoded: usize = 0;
    var bit_index: usize = 0;
    var node_index = tree.root;

    while (bytes_decoded < data_len) {
        const byte_pos = bit_index / 8;
        if (byte_pos >= bit_data.len) {
            return error.TruncatedHuffmanBitstream;
        }

        const bit_pos: u3 = @intCast(7 - (bit_index % 8));
        const bit = (bit_data[byte_pos] >> bit_pos) & 1;
        bit_index += 1;

        const node = tree.nodes.items[node_index];
        node_index = if (bit == 0)
            node.left orelse return error.InvalidHuffmanTree
        else
            node.right orelse return error.InvalidHuffmanTree;

        if (tree.nodes.items[node_index].byteVal) |byte| {
            output[bytes_decoded] = byte;
            bytes_decoded += 1;
            node_index = tree.root;
        }
    }

    return output;
}

test "huffman round trip - simple string" {
    const input = "hello huffman encoding!";
    const compressed = try encode(input, std.testing.allocator);
    defer std.testing.allocator.free(compressed);

    const decompressed = try decode(compressed, std.testing.allocator);
    defer std.testing.allocator.free(decompressed);

    try std.testing.expectEqualSlices(u8, input, decompressed);
}

test "huffman round trip - skewed data compresses" {
 
    var input: [10000]u8 = undefined;
    for (&input, 0..) |*byte, i| {
        byte.* = if (i < 9000) 'a' else 'b';
    }

    const compressed = try encode(&input, std.testing.allocator);
    defer std.testing.allocator.free(compressed);

    // should be smaller than input (minus the 1028-byte header)
    try std.testing.expect(compressed.len < input.len);

    const decompressed = try decode(compressed, std.testing.allocator);
    defer std.testing.allocator.free(decompressed);

    try std.testing.expectEqualSlices(u8, &input, decompressed);
}

test "huffman round trip - all same byte" {
    const input = [_]u8{0xAA} ** 500;

    const compressed = try encode(&input, std.testing.allocator);
    defer std.testing.allocator.free(compressed);

    const decompressed = try decode(compressed, std.testing.allocator);
    defer std.testing.allocator.free(decompressed);

    try std.testing.expectEqualSlices(u8, &input, decompressed);
}
