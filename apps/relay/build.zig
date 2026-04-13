const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // -----------------------------
    // Relay executable
    // -----------------------------
    const exe = b.addExecutable(.{
        .name = "zend-relay",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the relay server");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run relay tests");
    test_step.dependOn(&run_unit_tests.step);

    // -----------------------------
    // WASM target
    // -----------------------------
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    const chacha20_mod = b.createModule(.{
        .root_source_file = b.path("src/crypto/chacha20.zig"),
        .target = wasm_target,
        .optimize = optimize,
    });

    const poly1305_mod = b.createModule(.{
        .root_source_file = b.path("src/crypto/poly1305.zig"),
        .target = wasm_target,
        .optimize = optimize,
    });

    const aead_mod = b.createModule(.{
        .root_source_file = b.path("src/crypto/aead.zig"),
        .target = wasm_target,
        .optimize = optimize,
    });
    aead_mod.addImport("chacha20", chacha20_mod);
    aead_mod.addImport("poly1305", poly1305_mod);

    const huffman_mod = b.createModule(.{
        .root_source_file = b.path("src/compress/huffman.zig"),
        .target = wasm_target,
        .optimize = optimize,
    });

    const packet_types_mod = b.createModule(.{
        .root_source_file = b.path("src/protocol/packet_types.zig"),
        .target = wasm_target,
        .optimize = optimize,
    });

    const blob_format_mod = b.createModule(.{
        .root_source_file = b.path("src/protocol/blob_format.zig"),
        .target = wasm_target,
        .optimize = optimize,
    });
    blob_format_mod.addImport("aead", aead_mod);
    blob_format_mod.addImport("huffman", huffman_mod);
    blob_format_mod.addImport("packet_types", packet_types_mod);

    const wasm_main_mod = b.createModule(.{
        .root_source_file = b.path("src/wasm/main.zig"),
        .target = wasm_target,
        .optimize = optimize,
    });
    wasm_main_mod.addImport("blob_format", blob_format_mod);

    const wasm = b.addExecutable(.{
        .name = "zend_wasm",
        .root_module = wasm_main_mod,
    });

    wasm.entry = .disabled;
    wasm.rdynamic = true;

    const install_wasm = b.addInstallBinFile(
        wasm.getEmittedBin(),
        "zend_wasm.wasm",
    );

    const wasm_step = b.step("wasm", "Build the Zend WASM module");
    wasm_step.dependOn(&install_wasm.step);
}
