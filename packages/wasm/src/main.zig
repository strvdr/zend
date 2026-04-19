const std = @import("std");
const blob_format = @import("blob_format");

const allocator = std.heap.wasm_allocator;

var result_bytes: []u8 = &[_]u8{};
var result_filename: []u8 = &[_]u8{};
var error_bytes: []u8 = &[_]u8{};

const WasmDecryptSession = struct {
    allocator: std.mem.Allocator,
    key: [32]u8,
    pending: std.ArrayList(u8),
    output: []u8,
    filename: ?[]u8,
    done: bool,

    fn init(alloc: std.mem.Allocator, key: [32]u8) WasmDecryptSession {
        return .{
            .allocator = alloc,
            .key = key,
            .pending = .{},
            .output = &[_]u8{},
            .filename = null,
            .done = false,
        };
    }

    fn deinit(self: *WasmDecryptSession) void {
        self.pending.deinit(self.allocator);
        if (self.output.len > 0) self.allocator.free(self.output);
        if (self.filename) |name| self.allocator.free(name);
        self.output = &[_]u8{};
        self.filename = null;
        self.done = false;
    }

    fn pushBytes(self: *WasmDecryptSession, input: []const u8) !void {
        if (self.done) return error.SessionAlreadyFinished;

        try self.pending.appendSlice(self.allocator, input);

        var out = blob_format.decryptFileBuffer(self.allocator, self.pending.items, self.key) catch |err| switch (err) {
            error.IncompleteStream => return,
            else => return err,
        };
        defer out.deinit(self.allocator);

        if (self.output.len > 0) self.allocator.free(self.output);
        self.output = try self.allocator.dupe(u8, out.bytes);

        if (self.filename) |name| self.allocator.free(name);
        self.filename = try self.allocator.dupe(u8, out.filename);
        self.done = true;
    }

    fn outputSlice(self: *const WasmDecryptSession) []const u8 {
        return self.output;
    }

    fn filenameSlice(self: *const WasmDecryptSession) ?[]const u8 {
        return self.filename;
    }

    fn isDone(self: *const WasmDecryptSession) bool {
        return self.done;
    }
};
var encrypt_session: ?blob_format.EncryptSession = null;
var decrypt_session: ?WasmDecryptSession = null;


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

fn clearEncryptSession() void {
    if (encrypt_session) |*session| {
        session.deinit();
    }
    encrypt_session = null;
}

fn clearDecryptSession() void {
    if (decrypt_session) |*session| {
        session.deinit();
    }
    decrypt_session = null;
}

fn clearAllState() void {
    clearEncryptSession();
    clearDecryptSession();
    clearResultInternal();
    clearError();
}

fn publishEncryptResult() u32 {
    clearResultInternal();

    const session = &(encrypt_session orelse {
        setError("NoEncryptSession");
        return 4;
    });

    result_bytes = allocator.dupe(u8, session.resultSlice()) catch |err| {
        setError(@errorName(err));
        return statusFromError(err);
    };

    return 0;
}

fn publishDecryptOutput() u32 {
    clearResultInternal();

    const session = &(decrypt_session orelse {
        setError("NoDecryptSession");
        return 4;
    });

    result_bytes = allocator.dupe(u8, session.outputSlice()) catch |err| {
        setError(@errorName(err));
        return statusFromError(err);
    };

    if (session.filenameSlice()) |name| {
        result_filename = allocator.dupe(u8, name) catch |err| {
            allocator.free(result_bytes);
            result_bytes = &[_]u8{};
            setError(@errorName(err));
            return statusFromError(err);
        };
    }

    return 0;
}

fn statusFromError(err: anyerror) u32 {
    return switch (err) {
        error.OutOfMemory => 3,

        error.InvalidMetadata,
        error.InvalidChunk,
        error.FrameTooShort,
        error.FrameTooLarge,
        error.InvalidTagSize,
        error.UnknownPacketType,
        error.NoMetadata,
        error.DuplicateMetadata,
        error.AuthenticationFailed,
        error.InvalidCompressionFlag,
        error.InvalidDonePacket,
        error.ChunkBeforeMetadata,
        error.IncompleteStream,
        error.SessionNotStarted,
        error.SessionAlreadyFinished,
        error.InvalidIntegrityPacket,
        error.DuplicateIntegrityPacket,
        error.MissingIntegrity,
        error.IntegritySizeMismatch,
        error.IntegrityHashMismatch,
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

export fn clear_sessions() void {
    clearAllState();
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

export fn begin_encrypt(
    filename_ptr: [*]const u8,
    filename_len: usize,
    total_size: usize,
    key_ptr: [*]const u8,
) u32 {
    clearEncryptSession();
    clearResultInternal();
    clearError();

    const filename = filename_ptr[0..filename_len];

    var key: [32]u8 = undefined;
    @memcpy(&key, key_ptr[0..32]);

    encrypt_session = blob_format.EncryptSession.init(
        allocator,
        key,
        filename,
        @intCast(total_size),
    ) catch |err| {
        setError(@errorName(err));
        return statusFromError(err);
    };

    return publishEncryptResult();
}

export fn encrypt_chunk(
    input_ptr: [*]const u8,
    input_len: usize,
) u32 {
    clearResultInternal();
    clearError();

    const input = input_ptr[0..input_len];

    var session = &(encrypt_session orelse {
        setError("NoEncryptSession");
        return 4;
    });

    session.encryptChunk(input) catch |err| {
        setError(@errorName(err));
        return statusFromError(err);
    };

    return publishEncryptResult();
}

export fn finish_encrypt() u32 {
    clearResultInternal();
    clearError();

    var session = &(encrypt_session orelse {
        setError("NoEncryptSession");
        return 4;
    });

    session.finish() catch |err| {
        setError(@errorName(err));
        return statusFromError(err);
    };

    return publishEncryptResult();
}

export fn begin_decrypt(
    key_ptr: [*]const u8,
) u32 {
    clearDecryptSession();
    clearResultInternal();
    clearError();

    var key: [32]u8 = undefined;
    @memcpy(&key, key_ptr[0..32]);

    decrypt_session = WasmDecryptSession.init(allocator, key);
    return 0;
}

export fn push_blob_bytes(
    input_ptr: [*]const u8,
    input_len: usize,
) u32 {
    clearResultInternal();
    clearError();

    const input = input_ptr[0..input_len];

    var session = &(decrypt_session orelse {
        setError("NoDecryptSession");
        return 4;
    });

    session.pushBytes(input) catch |err| {
        setError(@errorName(err));
        return statusFromError(err);
    };

    return publishDecryptOutput();
}

export fn decrypt_done() u32 {
    const session = decrypt_session orelse return 0;
    return if (session.isDone()) 1 else 0;
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
