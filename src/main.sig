//! sls — Sig Language Server entry point.
//!
//! The transport loop: read framed LSP messages from stdin, dispatch each to
//! the server, and write framed responses to stdout. This is the sole I/O site;
//! all protocol and analysis logic lives in pure, testable modules. Zero
//! allocator — a fixed inbound ring and a fixed response buffer.

const std = @import("std");
const stdio = @import("stdio");
const message = @import("message");
const msgwrite = message;
const server_mod = @import("server");

/// Inbound accumulation buffer. Must comfortably hold one full LSP message
/// (a large didOpen for a big file plus its headers).
const INBOUND_CAP = 512 * 1024;
/// Outbound response body buffer.
const OUTBOUND_CAP = 512 * 1024;

var inbound: [INBOUND_CAP]u8 = undefined;
var outbound: [OUTBOUND_CAP]u8 = undefined;
var chunk: [64 * 1024]u8 = undefined;

// The server owns the document store (~16 MiB of fixed slots). It must live in
// static storage, never on the stack, or entry overflows the thread stack.
var server_state: server_mod.Server = .{};

pub fn main() void {
    var io = stdio.Stdio.init();
    const srv = &server_state;

    var filled: usize = 0; // bytes currently buffered in `inbound`

    while (true) {
        // Drain as many complete frames as are already buffered.
        while (true) {
            const frame = message.readFrame(inbound[0..filled]) catch |err| switch (err) {
                error.Incomplete => break,
                // Malformed framing: drop the buffer and resync.
                error.MissingContentLength, error.Malformed => {
                    filled = 0;
                    break;
                },
            };

            const msg = message.parse(frame.body);
            const result = srv.handle(msg, &outbound);
            switch (result.outcome) {
                .respond => sendFramed(&io, result.body),
                .none => {},
                .exit => return,
            }

            // Shift any trailing bytes (start of the next frame) to the front.
            const remaining = filled - frame.consumed;
            if (remaining > 0) {
                std.mem.copyForwards(u8, inbound[0..remaining], inbound[frame.consumed..filled]);
            }
            filled = remaining;
        }

        // Need more bytes. Read a chunk from stdin.
        const n = io.read(&chunk) catch return;
        if (n == 0) return; // EOF
        if (filled + n > INBOUND_CAP) {
            // Oversized message beyond our capacity: reset to stay alive.
            filled = 0;
            continue;
        }
        @memcpy(inbound[filled .. filled + n], chunk[0..n]);
        filled += n;
    }
}

/// Frame a response body with its Content-Length header and write both.
fn sendFramed(io: *stdio.Stdio, body: []const u8) void {
    if (body.len == 0) return;
    var header_buf: [64]u8 = undefined;
    const header = msgwrite.writeHeader(&header_buf, body.len) catch return;
    io.writeAll(header) catch return;
    io.writeAll(body) catch return;
}

test "transport modules compile and link" {
    // Exercise the pure pieces so `test-server` covers the entry module too.
    const msg = message.parse("{\"id\":1,\"method\":\"initialize\"}");
    try std.testing.expectEqualStrings("initialize", msg.method);
    var out: [4096]u8 = undefined;
    var srv: server_mod.Server = .{};
    const res = srv.handle(msg, &out);
    try std.testing.expectEqual(server_mod.Outcome.respond, res.outcome);
}
