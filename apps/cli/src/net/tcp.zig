const std = @import("std");

pub const TCPError = error {
    EndOfStream,
};

pub const Connection = struct {
    stream: std.net.Stream,

    pub fn read(self: Connection, buf: []u8) !usize {
        const bytesRead = try self.stream.read(buf);
        if(bytesRead == 0) {
            // Normalize EOF into a project-local error so higher layers do not
            // need to care about raw socket semantics.
            return TCPError.EndOfStream;
        }

        return bytesRead;
    }

    pub fn writeAll(self: Connection, data: []const u8) !void {
        try self.stream.writeAll(data);
    }

    pub fn close(self: Connection) void {
        self.stream.close();
    }
};

pub fn connect(allocator: std.mem.Allocator, host: []const u8, port: u16) !Connection {
    const connectionStream = try std.net.tcpConnectToHost(allocator, host, port);

    return .{
        .stream = connectionStream,
    };
}

pub fn listen(address: std.net.Address) !std.net.Server {
    // reuse_address makes local restart / development less annoying when a
    // recent listener is still in TIME_WAIT.
    const server = try address.listen(. { .reuse_address = true });
    
    return server;
}

pub fn accept(server: *std.net.Server) !Connection {
    const acceptedServer = try server.accept();

    return .{
        .stream = acceptedServer.stream,
    };
}

test "send and receive bytes over loopback" {
    // set up a listener on port 0 (OS picks a free port)
    const addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var server = try listen(addr);
    defer server.deinit();

    // spawn a thread that connects and writes
    const t = try std.Thread.spawn(.{}, struct {
        fn run(listen_addr: std.net.Address) !void {
            const conn = try connect(std.testing.allocator, "127.0.0.1", listen_addr.getPort());
            defer conn.close();
            try conn.writeAll("hello");
        }
    }.run, .{server.listen_address});

    // accept on main thread, read, assert
    const client = try accept(&server);
    defer client.close();

    var buf: [5]u8 = undefined;
    const n = try client.read(&buf);
    try std.testing.expectEqualSlices(u8, "hello", buf[0..n]);

    t.join();
}
