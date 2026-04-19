const std = @import("std");

fn addSharedImports(
    b: *std.Build,
    root: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    // -----------------------------
    // protocol package
    // -----------------------------
    const packet_types_mod = b.createModule(.{
        .root_source_file = b.path("../../packages/protocol/src/packet_types.zig"),
        .target = target,
        .optimize = optimize,
    });

    const blob_format_mod = b.createModule(.{
        .root_source_file = b.path("../../packages/protocol/src/blob_format.zig"),
        .target = target,
        .optimize = optimize,
    });
    blob_format_mod.addImport("packet_types", packet_types_mod);

    const protocol_mod = b.createModule(.{
        .root_source_file = b.path("../../packages/protocol/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    protocol_mod.addImport("packet_types", packet_types_mod);
    protocol_mod.addImport("blob_format", blob_format_mod);

    // -----------------------------
    // crypto package
    // -----------------------------
    const chacha20_mod = b.createModule(.{
        .root_source_file = b.path("../../packages/crypto/src/chacha20.zig"),
        .target = target,
        .optimize = optimize,
    });

    const poly1305_mod = b.createModule(.{
        .root_source_file = b.path("../../packages/crypto/src/poly1305.zig"),
        .target = target,
        .optimize = optimize,
    });

    const aead_mod = b.createModule(.{
        .root_source_file = b.path("../../packages/crypto/src/aead.zig"),
        .target = target,
        .optimize = optimize,
    });
    aead_mod.addImport("chacha20", chacha20_mod);
    aead_mod.addImport("poly1305", poly1305_mod);

    const crypto_mod = b.createModule(.{
        .root_source_file = b.path("../../packages/crypto/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    crypto_mod.addImport("aead", aead_mod);
    crypto_mod.addImport("chacha20", chacha20_mod);
    crypto_mod.addImport("poly1305", poly1305_mod);

    // -----------------------------
    // compress package
    // -----------------------------
    const bitwriter_mod = b.createModule(.{
        .root_source_file = b.path("../../packages/compress/src/bitwriter.zig"),
        .target = target,
        .optimize = optimize,
    });

    const huffman_mod = b.createModule(.{
        .root_source_file = b.path("../../packages/compress/src/huffman.zig"),
        .target = target,
        .optimize = optimize,
    });
    huffman_mod.addImport("bitwriter", bitwriter_mod);

    const compress_mod = b.createModule(.{
        .root_source_file = b.path("../../packages/compress/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    compress_mod.addImport("bitwriter", bitwriter_mod);
    compress_mod.addImport("huffman", huffman_mod);

    // Package imports for app code.
    root.addImport("protocol", protocol_mod);
    root.addImport("crypto", crypto_mod);
    root.addImport("compress", compress_mod);

    // Leaf imports for any files still importing leaf modules directly.
    root.addImport("packet_types", packet_types_mod);
    root.addImport("blob_format", blob_format_mod);
    root.addImport("aead", aead_mod);
    root.addImport("chacha20", chacha20_mod);
    root.addImport("poly1305", poly1305_mod);
    root.addImport("bitwriter", bitwriter_mod);
    root.addImport("huffman", huffman_mod);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // -----------------------------
    // Relay executable
    // -----------------------------
    const exe_root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    addSharedImports(b, exe_root, target, optimize);

    const exe = b.addExecutable(.{
        .name = "zend-relay",
        .root_module = exe_root,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the relay server");
    run_step.dependOn(&run_cmd.step);

    // -----------------------------
    // Unit tests
    // -----------------------------
    const test_root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    addSharedImports(b, test_root, target, optimize);

    const unit_tests = b.addTest(.{
        .root_module = test_root,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run relay tests");
    test_step.dependOn(&run_unit_tests.step);
}
