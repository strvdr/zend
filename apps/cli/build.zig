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
        .root_source_file = b.path("../../packages/protocol/src/packet_types.zig"),
        .target = target,
        .optimize = optimize,
    });

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

    const blob_format_mod = b.createModule(.{
        .root_source_file = b.path("../../packages/protocol/src/blob_format.zig"),
        .target = target,
        .optimize = optimize,
    });
    blob_format_mod.addImport("packet_types", packet_types_mod);
    blob_format_mod.addImport("aead", aead_mod);
    blob_format_mod.addImport("huffman", huffman_mod);

    const protocol_mod = b.createModule(.{
        .root_source_file = b.path("../../packages/protocol/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    protocol_mod.addImport("packet_types", packet_types_mod);
    protocol_mod.addImport("blob_format", blob_format_mod);

    const crypto_mod = b.createModule(.{
        .root_source_file = b.path("../../packages/crypto/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    crypto_mod.addImport("aead", aead_mod);
    crypto_mod.addImport("chacha20", chacha20_mod);
    crypto_mod.addImport("poly1305", poly1305_mod);

    const compress_mod = b.createModule(.{
        .root_source_file = b.path("../../packages/compress/src/root.zig"),
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
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const shared = makeShared(b, target, optimize);

    const progress_mod = b.createModule(.{
        .root_source_file = b.path("src/protocol/progress.zig"),
        .target = target,
        .optimize = optimize,
    });
    addSharedImports(progress_mod, shared);

    const tcp_mod = b.createModule(.{
        .root_source_file = b.path("src/net/tcp.zig"),
        .target = target,
        .optimize = optimize,
    });
    addSharedImports(tcp_mod, shared);

    const framing_mod = b.createModule(.{
        .root_source_file = b.path("src/net/framing.zig"),
        .target = target,
        .optimize = optimize,
    });
    addSharedImports(framing_mod, shared);
    framing_mod.addImport("tcp", tcp_mod);

    const x25519_mod = b.createModule(.{
        .root_source_file = b.path("src/crypto/x25519.zig"),
        .target = target,
        .optimize = optimize,
    });
    addSharedImports(x25519_mod, shared);

    const message_mod = b.createModule(.{
        .root_source_file = b.path("src/protocol/message.zig"),
        .target = target,
        .optimize = optimize,
    });
    addSharedImports(message_mod, shared);
    message_mod.addImport("tcp", tcp_mod);
    message_mod.addImport("framing", framing_mod);

    const handshake_mod = b.createModule(.{
        .root_source_file = b.path("src/protocol/handshake.zig"),
        .target = target,
        .optimize = optimize,
    });
    addSharedImports(handshake_mod, shared);
    handshake_mod.addImport("tcp", tcp_mod);
    handshake_mod.addImport("message", message_mod);
    handshake_mod.addImport("aead", shared.aead);
    handshake_mod.addImport("x25519", x25519_mod);

    const transfer_mod = b.createModule(.{
        .root_source_file = b.path("src/protocol/transfer.zig"),
        .target = target,
        .optimize = optimize,
    });
    addSharedImports(transfer_mod, shared);
    transfer_mod.addImport("tcp", tcp_mod);
    transfer_mod.addImport("message", message_mod);
    transfer_mod.addImport("aead", shared.aead);
    transfer_mod.addImport("progress", progress_mod);
    transfer_mod.addImport("huffman", shared.huffman);

    const http_mod = b.createModule(.{
        .root_source_file = b.path("src/net/http.zig"),
        .target = target,
        .optimize = optimize,
    });
    addSharedImports(http_mod, shared);

    const relay_mod = b.createModule(.{
        .root_source_file = b.path("src/relay/relay.zig"),
        .target = target,
        .optimize = optimize,
    });
    addSharedImports(relay_mod, shared);
    relay_mod.addImport("http", http_mod);

    const send_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/send.zig"),
        .target = target,
        .optimize = optimize,
    });
    addSharedImports(send_mod, shared);
    send_mod.addImport("tcp", tcp_mod);
    send_mod.addImport("handshake", handshake_mod);
    send_mod.addImport("transfer", transfer_mod);
    send_mod.addImport("progress", progress_mod);
    send_mod.addImport("aead", shared.aead);
    send_mod.addImport("huffman", shared.huffman);
    send_mod.addImport("relay", relay_mod);
    send_mod.addImport("blob_format", shared.blob_format);
    send_mod.addImport("packet_types", shared.packet_types);

    const recv_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/recv.zig"),
        .target = target,
        .optimize = optimize,
    });
    addSharedImports(recv_mod, shared);
    recv_mod.addImport("tcp", tcp_mod);
    recv_mod.addImport("handshake", handshake_mod);
    recv_mod.addImport("transfer", transfer_mod);
    recv_mod.addImport("progress", progress_mod);

    const download_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/download.zig"),
        .target = target,
        .optimize = optimize,
    });
    addSharedImports(download_mod, shared);
    download_mod.addImport("aead", shared.aead);
    download_mod.addImport("huffman", shared.huffman);
    download_mod.addImport("relay", relay_mod);
    download_mod.addImport("progress", progress_mod);
    download_mod.addImport("packet_types", shared.packet_types);

    const main_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    addSharedImports(main_mod, shared);
    main_mod.addImport("send", send_mod);
    main_mod.addImport("recv", recv_mod);
    main_mod.addImport("download", download_mod);

    const exe = b.addExecutable(.{
        .name = "zend",
        .root_module = main_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run zend");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run all tests");

    const src_test_files = &[_][]const u8{
        "src/net/tcp.zig",
        "src/net/framing.zig",
        "../../packages/crypto/src/chacha20.zig",
        "../../packages/crypto/src/poly1305.zig",
        "../../packages/crypto/src/aead.zig",
        "src/crypto/x25519.zig",
        "../../packages/compress/src/bitwriter.zig",
        "../../packages/compress/src/huffman.zig",
        "src/protocol/message.zig",
        "src/protocol/handshake.zig",
    };

    for (src_test_files) |path| {
        const test_mod = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        });

        addSharedImports(test_mod, shared);
        test_mod.addImport("tcp", tcp_mod);
        test_mod.addImport("framing", framing_mod);
        test_mod.addImport("x25519", x25519_mod);
        test_mod.addImport("message", message_mod);
        test_mod.addImport("handshake", handshake_mod);
        test_mod.addImport("transfer", transfer_mod);

        const t = b.addTest(.{
            .root_module = test_mod,
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}
