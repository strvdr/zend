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

const RelayModules = struct {
    config: *std.Build.Module,
    runtime_config: *std.Build.Module,
    http_helpers: *std.Build.Module,
    ids: *std.Build.Module,
    storage: *std.Build.Module,
    rate_limit: *std.Build.Module,
    reaper: *std.Build.Module,
    options: *std.Build.Module,
    upload: *std.Build.Module,
    download: *std.Build.Module,
    delete: *std.Build.Module,
};

fn makeRelayModules(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    shared: Shared,
) RelayModules {
    const config_mod = b.createModule(.{
        .root_source_file = b.path("src/config/config.zig"),
        .target = target,
        .optimize = optimize,
    });
    addSharedImports(config_mod, shared);

    const runtime_config_mod = b.createModule(.{
        .root_source_file = b.path("src/config/runtime_config.zig"),
        .target = target,
        .optimize = optimize,
    });
    addSharedImports(runtime_config_mod, shared);
    runtime_config_mod.addImport("config", config_mod);

    const http_helpers_mod = b.createModule(.{
        .root_source_file = b.path("src/http/http_helpers.zig"),
        .target = target,
        .optimize = optimize,
    });
    addSharedImports(http_helpers_mod, shared);
    http_helpers_mod.addImport("runtime_config", runtime_config_mod);

    const ids_mod = b.createModule(.{
        .root_source_file = b.path("src/storage/ids.zig"),
        .target = target,
        .optimize = optimize,
    });
    addSharedImports(ids_mod, shared);

    const storage_mod = b.createModule(.{
        .root_source_file = b.path("src/storage/storage.zig"),
        .target = target,
        .optimize = optimize,
    });
    addSharedImports(storage_mod, shared);
    storage_mod.addImport("ids", ids_mod);
    storage_mod.addImport("runtime_config", runtime_config_mod);

    const rate_limit_mod = b.createModule(.{
        .root_source_file = b.path("src/runtime/rate_limit.zig"),
        .target = target,
        .optimize = optimize,
    });
    addSharedImports(rate_limit_mod, shared);
    rate_limit_mod.addImport("runtime_config", runtime_config_mod);

    const reaper_mod = b.createModule(.{
        .root_source_file = b.path("src/runtime/reaper.zig"),
        .target = target,
        .optimize = optimize,
    });
    addSharedImports(reaper_mod, shared);
    reaper_mod.addImport("runtime_config", runtime_config_mod);
    reaper_mod.addImport("storage", storage_mod);
    reaper_mod.addImport("config", config_mod);

    const options_mod = b.createModule(.{
        .root_source_file = b.path("src/routes/options.zig"),
        .target = target,
        .optimize = optimize,
    });
    addSharedImports(options_mod, shared);
    options_mod.addImport("http_helpers", http_helpers_mod);

    const upload_mod = b.createModule(.{
        .root_source_file = b.path("src/routes/upload.zig"),
        .target = target,
        .optimize = optimize,
    });
    addSharedImports(upload_mod, shared);
    upload_mod.addImport("http_helpers", http_helpers_mod);
    upload_mod.addImport("ids", ids_mod);
    upload_mod.addImport("runtime_config", runtime_config_mod);
    upload_mod.addImport("storage", storage_mod);

    const download_mod = b.createModule(.{
        .root_source_file = b.path("src/routes/download.zig"),
        .target = target,
        .optimize = optimize,
    });
    addSharedImports(download_mod, shared);
    download_mod.addImport("http_helpers", http_helpers_mod);
    download_mod.addImport("runtime_config", runtime_config_mod);
    download_mod.addImport("storage", storage_mod);

    const delete_mod = b.createModule(.{
        .root_source_file = b.path("src/routes/delete.zig"),
        .target = target,
        .optimize = optimize,
    });
    addSharedImports(delete_mod, shared);
    delete_mod.addImport("http_helpers", http_helpers_mod);
    delete_mod.addImport("runtime_config", runtime_config_mod);
    delete_mod.addImport("storage", storage_mod);
    delete_mod.addImport("ids", ids_mod);

    return .{
        .config = config_mod,
        .runtime_config = runtime_config_mod,
        .http_helpers = http_helpers_mod,
        .ids = ids_mod,
        .storage = storage_mod,
        .rate_limit = rate_limit_mod,
        .reaper = reaper_mod,
        .options = options_mod,
        .upload = upload_mod,
        .download = download_mod,
        .delete = delete_mod,
    };
}

fn addRelayImports(root: *std.Build.Module, relay: RelayModules) void {
    root.addImport("config", relay.config);
    root.addImport("runtime_config", relay.runtime_config);
    root.addImport("http_helpers", relay.http_helpers);
    root.addImport("ids", relay.ids);
    root.addImport("storage", relay.storage);
    root.addImport("rate_limit", relay.rate_limit);
    root.addImport("reaper", relay.reaper);

    root.addImport("options", relay.options);
    root.addImport("upload", relay.upload);
    root.addImport("download", relay.download);
    root.addImport("delete", relay.delete);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const shared = makeShared(b, target, optimize);
    const relay = makeRelayModules(b, target, optimize, shared);

    const exe_root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    addSharedImports(exe_root, shared);
    addRelayImports(exe_root, relay);

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

    const test_root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    addSharedImports(test_root, shared);
    addRelayImports(test_root, relay);

    const unit_tests = b.addTest(.{
        .root_module = test_root,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run relay tests");
    test_step.dependOn(&run_unit_tests.step);
}
