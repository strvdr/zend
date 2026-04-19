const std = @import("std");
const send = @import("send");
const recv = @import("recv");
const download = @import("download");

const DEFAULT_PORT: u16 = 9000;
const DEFAULT_HOST: []const u8 = "127.0.0.1";

const Config = union(enum) {
    // Relay upload:
    //   zend ./file
    sending_relay: struct {
        filePath: []const u8,
    },
    // Direct peer-to-peer send:
    //   zend ./file 192.168.1.42:9000
    sending_p2p: struct {
        host: []const u8,
        port: u16,
        filePath: []const u8,
    },
    // Passive receive mode:
    //   zend
    //   zend :9000
    receiving: struct {
        port: u16,
        outputDir: []const u8,
    },
    // Relay download:
    //   zend https://...
    downloading: struct {
        url: []const u8,
        outputDir: []const u8,
    },
};

fn parseAddress(arg: []const u8) ?struct { host: ?[]const u8, port: ?u16 } {
    if (arg.len > 1 and arg[0] == ':') {
        // Shorthand receive syntax like ":4567".
        const port = std.fmt.parseInt(u16, arg[1..], 10) catch return null;
        return .{ .host = null, .port = port };
    }

    if (std.mem.lastIndexOfScalar(u8, arg, ':')) |colon| {
        if (colon > 0 and colon < arg.len - 1) {
            // Host:port form used for direct peer-to-peer sends.
            const port = std.fmt.parseInt(u16, arg[colon + 1 ..], 10) catch return null;
            return .{ .host = arg[0..colon], .port = port };
        }
    }

    if (arg.len > 0 and arg[0] != '-') {
        if (looksLikeAddress(arg)) {
            // Bare host without a port.
            return .{ .host = arg, .port = null };
        }
    }

    return null;
}

fn looksLikeAddress(s: []const u8) bool {
    if (s.len == 0) return false;

    // This is intentionally heuristic, not a full hostname parser.
    // It is only used to make the CLI's positional arguments feel natural.
    if (std.mem.indexOfScalar(u8, s, '.')) |_| return true;
    if (std.mem.indexOfScalar(u8, s, ':')) |_| return true;

    for (s) |c| {
        // A dash usually means this is a flag or flag-like token,
        // not a host argument.
        if (c == '-') return false;
    }
    return true;
}

fn fileExists(path: []const u8) bool {
    _ = std.fs.cwd().statFile(path) catch return false;
    return true;
}

fn looksLikeUrl(s: []const u8) bool {
    return std.mem.startsWith(u8, s, "http://") or std.mem.startsWith(u8, s, "https://");
}

fn parseArgs(args: []const []const u8) Config {
    if (args.len >= 2) {
        // Keep old "zend send ..." / "zend recv ..." syntax working so newer
        // CLI cleanup does not break existing habits or scripts.
        if (std.mem.eql(u8, args[1], "send")) {
            return parseLegacySend(args[2..]);
        } else if (std.mem.eql(u8, args[1], "recv")) {
            return parseLegacyRecv(args[2..]);
        }
    }

    var filePath: ?[]const u8 = null;
    var downloadUrl: ?[]const u8 = null;
    var host: ?[]const u8 = null;
    var port: ?u16 = null;
    var outputDir: []const u8 = ".";

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--host") and i + 1 < args.len) {
            host = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--port") and i + 1 < args.len) {
            port = std.fmt.parseInt(u16, args[i + 1], 10) catch {
                fatal("Invalid port: {s}", .{args[i + 1]});
            };
            i += 1;
        } else if (std.mem.eql(u8, arg, "--out") and i + 1 < args.len) {
            outputDir = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            std.process.exit(0);
        } else if (arg[0] == '-') {
            fatal("Unknown flag: {s}", .{arg});
        } else {
            // Positional parsing is intentionally permissive:
            // - URL => relay download
            // - existing file => send/upload
            // - host[:port] => peer address or receive port
            if (looksLikeUrl(arg)) {
                downloadUrl = arg;
            } else if (fileExists(arg)) {
                filePath = arg;
            } else if (parseAddress(arg)) |addr| {
                if (addr.host) |h| host = h;
                if (addr.port) |p| port = p;
            } else if (filePath != null) {
                // If a file is already known, a second free-form positional
                // argument is treated as the peer host.
                host = arg;
            } else {
                fatal("No such file: {s}", .{arg});
            }
        }
    }

    if (downloadUrl) |url| {
        return .{ .downloading = .{
            .url = url,
            .outputDir = outputDir,
        } };
    }

    if (filePath) |fp| {
        if (host != null or port != null) {
            return .{ .sending_p2p = .{
                .host = host orelse DEFAULT_HOST,
                .port = port orelse DEFAULT_PORT,
                .filePath = fp,
            } };
        } else {
            return .{ .sending_relay = .{
                .filePath = fp,
            } };
        }
    } else {
        // No file and no URL means the CLI falls back to receive mode.
        return .{ .receiving = .{
            .port = port orelse DEFAULT_PORT,
            .outputDir = outputDir,
        } };
    }
}

fn parseLegacySend(args: []const []const u8) Config {
    var host: []const u8 = DEFAULT_HOST;
    var port: u16 = DEFAULT_PORT;
    var filePath: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--host") and i + 1 < args.len) {
            host = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--port") and i + 1 < args.len) {
            port = std.fmt.parseInt(u16, args[i + 1], 10) catch {
                fatal("Invalid port: {s}", .{args[i + 1]});
            };
            i += 1;
        } else {
            filePath = args[i];
        }
    }

    if (filePath) |fp| {
        return .{ .sending_p2p = .{ .host = host, .port = port, .filePath = fp } };
    } else {
        fatal("No file specified", .{});
    }
}

fn parseLegacyRecv(args: []const []const u8) Config {
    var port: u16 = DEFAULT_PORT;
    var outputDir: []const u8 = ".";

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--port") and i + 1 < args.len) {
            port = std.fmt.parseInt(u16, args[i + 1], 10) catch {
                fatal("Invalid port: {s}", .{args[i + 1]});
            };
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--out") and i + 1 < args.len) {
            outputDir = args[i + 1];
            i += 1;
        }
    }

    // Legacy recv mode always means "listen for an incoming direct transfer".
    return .{ .receiving = .{ .port = port, .outputDir = outputDir } };
}

fn fatal(comptime fmt: []const u8, fmtArgs: anytype) noreturn {
    // fatal() always prints usage afterward so bad CLI input is immediately
    // recoverable without needing to re-run --help.
    std.debug.print("Error: " ++ fmt ++ "\n", fmtArgs);
    printUsage();
    std.process.exit(1);
}

fn printUsage() void {
    std.debug.print(
        \\
        \\Usage: zend [file] [peer] [options]
        \\       zend [url] [options]
        \\       zend [listen-address] [options]
        \\
        \\Modes:
        \\  zend <file>
        \\      Encrypt and upload to the relay.
        \\
        \\  zend <file> <peer>
        \\      Send directly to a peer.
        \\      Examples:
        \\        zend ./file.tar 192.168.1.42
        \\        zend ./file.tar 192.168.1.42:4567
        \\        zend ./file.tar localhost:4567
        \\
        \\  zend <url>
        \\      Download and decrypt from the relay.
        \\
        \\  zend
        \\  zend :4567
        \\      Listen for direct peer-to-peer transfers.
        \\
        \\Options:
        \\  --out  <dir>      Output directory (download/receive mode)
        \\  --port <port>     Port number (receive mode, default: 9000)
        \\  --host <host>     Legacy direct-send host override
        \\  -h, --help        Show this help
        \\
        \\Legacy syntax:
        \\  zend send --host <host> --port <port> <file>
        \\  zend recv --port <port> --out <dir>
        \\
    , .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const config = parseArgs(args);

    // Parsing decides the mode once up front so the rest of main() is just a
    // clean dispatch table instead of interleaved CLI conditionals.
    switch (config) {
        .sending_relay => |s| try send.runRelay(s.filePath, allocator),
        .sending_p2p => |s| try send.runP2P(s.filePath, s.host, s.port, allocator),
        .receiving => |r| try recv.run(r.port, r.outputDir, allocator),
        .downloading => |d| try download.run(d.url, d.outputDir, allocator),
    }
}
