const std = @import("std");
const blob_format = @import("blob_format");

var wasm_alloc = std.heap.WasmAllocator{};
const allocator = wasm_alloc.allocator();

var result_bytes: []u8 = &[_]u8{};
var result_filename: []u8 = &[_]u8{};
var error_bytes: []u8 = &[_]u8{};

fn setError(msg: []const u8) void {
    if (error_bytes.len > 0) allocator.free(error_bytes);
    error_bytes = allocator.dupe(u8, msg) catch &[_]u8{};
}

fn clearError() void {
    if (error_bytes.len > 0) allocator.free(error_bytes);
    error_bytes = &[_]u8{};
}

fn clearResultInternal() void {
    if (result_bytes.len > 0) allocator.free(result_bytes);
    if (result_filename.len > 0) allocator.free(result_filename);
    result_bytes = &[_]u8{};
    result_filename = &[_]u8{};
}

fn statusFromError(err: anyerror) u32 {
    return switch (err) {
        error.OutOfMemory => 3,
        error.InvalidMetadata,
        error.InvalidChunk,
        error.TruncatedFrame,
        error.FrameTooShort,
        error.UnknownPacketType,
        error.NoMetadata,
        error.DuplicateMetadata,
        error.AuthenticationFailed,
        => 2,
        else => 4,
    };
}

export fn alloc_input(len: usize) ?[*]u8 {
    const buf = allocator.alloc(u8, len) catch return null;
    return buf.ptr;
}

export fn free_input(ptr: [*]u8, len: usize) void {
    allocator.free(ptr[0..len]);
}

export fn clear_result() void {
    clearResultInternal();
    clearError();
}

export fn generate_key(_: [*]u8) u32 {
    setError("generate_key unsupported in freestanding wasm; generate in JS");
    return 4;
}

export fn encrypt(
    input_ptr: [*]const u8,
    input_len: usize,
    filename_ptr: [*]const u8,
    filename_len: usize,
    key_ptr: [*]const u8,
) u32 {
    clearResultInternal();
    clearError();

    const input = input_ptr[0..input_len];
    const filename = filename_ptr[0..filename_len];

    var key: [32]u8 = undefined;
    @memcpy(&key, key_ptr[0..32]);

    result_bytes = blob_format.encryptFileBuffer(allocator, input, filename, key) catch |err| {
        setError(@errorName(err));
        return statusFromError(err);
    };

    return 0;
}

export fn decrypt(
    input_ptr: [*]const u8,
    input_len: usize,
    key_ptr: [*]const u8,
) u32 {
    clearResultInternal();
    clearError();

    const input = input_ptr[0..input_len];

    var key: [32]u8 = undefined;
    @memcpy(&key, key_ptr[0..32]);

    var out = blob_format.decryptFileBuffer(allocator, input, key) catch |err| {
        setError(@errorName(err));
        return statusFromError(err);
    };
    defer out.deinit(allocator);

    result_filename = allocator.dupe(u8, out.filename) catch |err| {
        setError(@errorName(err));
        return statusFromError(err);
    };

    result_bytes = allocator.dupe(u8, out.bytes) catch |err| {
        allocator.free(result_filename);
        result_filename = &[_]u8{};
        setError(@errorName(err));
        return statusFromError(err);
    };

    return 0;
}

export fn result_ptr() [*]const u8 {
    return result_bytes.ptr;
}

export fn result_len() usize {
    return result_bytes.len;
}

export fn result_filename_ptr() [*]const u8 {
    return result_filename.ptr;
}

export fn result_filename_len() usize {
    return result_filename.len;
}

export fn error_ptr() [*]const u8 {
    return error_bytes.ptr;
}

export fn error_len() usize {
    return error_bytes.len;
}
