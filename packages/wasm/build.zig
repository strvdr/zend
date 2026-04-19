const std = @import("std");

const Shared = struct {
    packet_types: *std.Build.Module,
    blob_format: *std.Build.Module,
    protocol: *std.Build.Module,

    chacha20: *std.Build.Module,
    poly1305: *std.Build.Module,
    aead: *std.Build.Module,
    crypto: *std.Build.Module,

    bitwriter: *std.Build.Module,
    huffman: *std.Build.Module,
    compress: *std.Build.Module,
};

fn makeShared(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) Shared {
    const packet_types_mod = b.createModule(.{
        .root_source_file = b.path("../protocol/src/packet_types.zig"),
        .target = target,
        .optimize = optimize,
    });

    const chacha20_mod = b.createModule(.{
        .root_source_file = b.path("../crypto/src/chacha20.zig"),
        .target = target,
        .optimize = optimize,
    });

    const poly1305_mod = b.createModule(.{
        .root_source_file = b.path("../crypto/src/poly1305.zig"),
        .target = target,
        .optimize = optimize,
    });

    const aead_mod = b.createModule(.{
        .root_source_file = b.path("../crypto/src/aead.zig"),
        .target = target,
        .optimize = optimize,
    });
    aead_mod.addImport("chacha20", chacha20_mod);
    aead_mod.addImport("poly1305", poly1305_mod);

    const bitwriter_mod = b.createModule(.{
        .root_source_file = b.path("../compress/src/bitwriter.zig"),
        .target = target,
        .optimize = optimize,
    });

    const huffman_mod = b.createModule(.{
        .root_source_file = b.path("../compress/src/huffman.zig"),
        .target = target,
        .optimize = optimize,
    });
    huffman_mod.addImport("bitwriter", bitwriter_mod);

    const blob_format_mod = b.createModule(.{
        .root_source_file = b.path("../protocol/src/blob_format.zig"),
        .target = target,
        .optimize = optimize,
    });
    blob_format_mod.addImport("packet_types", packet_types_mod);
    blob_format_mod.addImport("aead", aead_mod);
    blob_format_mod.addImport("huffman", huffman_mod);

    const protocol_mod = b.createModule(.{
        .root_source_file = b.path("../protocol/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    protocol_mod.addImport("packet_types", packet_types_mod);
    protocol_mod.addImport("blob_format", blob_format_mod);

    const crypto_mod = b.createModule(.{
        .root_source_file = b.path("../crypto/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    crypto_mod.addImport("aead", aead_mod);
    crypto_mod.addImport("chacha20", chacha20_mod);
    crypto_mod.addImport("poly1305", poly1305_mod);

    const compress_mod = b.createModule(.{
        .root_source_file = b.path("../compress/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    compress_mod.addImport("bitwriter", bitwriter_mod);
    compress_mod.addImport("huffman", huffman_mod);

    return .{
        .packet_types = packet_types_mod,
        .blob_format = blob_format_mod,
        .protocol = protocol_mod,
        .chacha20 = chacha20_mod,
        .poly1305 = poly1305_mod,
        .aead = aead_mod,
        .crypto = crypto_mod,
        .bitwriter = bitwriter_mod,
        .huffman = huffman_mod,
        .compress = compress_mod,
    };
}

fn addSharedImports(root: *std.Build.Module, shared: Shared) void {
    root.addImport("protocol", shared.protocol);
    root.addImport("crypto", shared.crypto);
    root.addImport("compress", shared.compress);

    root.addImport("packet_types", shared.packet_types);
    root.addImport("blob_format", shared.blob_format);
    root.addImport("aead", shared.aead);
    root.addImport("chacha20", shared.chacha20);
    root.addImport("poly1305", shared.poly1305);
    root.addImport("bitwriter", shared.bitwriter);
    root.addImport("huffman", shared.huffman);
}

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    const target_query = std.Target.Query{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    };
    const target = b.resolveTargetQuery(target_query);

    const shared = makeShared(b, target, optimize);

    const wasm_root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    addSharedImports(wasm_root, shared);

    const exe = b.addExecutable(.{
        .name = "zend_wasm",
        .root_module = wasm_root,
    });

    exe.entry = .disabled;
    exe.rdynamic = true;
    exe.import_memory = true;
    exe.export_table = true;

    // 2 MiB initial memory, 16 MiB max.
    exe.initial_memory = 32 * 64 * 1024;
    exe.max_memory = 256 * 64 * 1024;

    b.installArtifact(exe);

    const check = b.step("check", "Check that the WASM module compiles");
    check.dependOn(&exe.step);
}
