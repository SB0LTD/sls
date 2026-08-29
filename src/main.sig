//! sls — Sig Language Server entry point (hosted: Windows/Linux/macOS).
//!
//! Wires the platform stdio backend to the shared LSP transport loop. The loop,
//! protocol, and analysis all live in reusable modules; this file is just the
//! hosted entry. The SB0 bare-metal image (src/platform/sb0_entry.sig) runs the
//! same loop over a UART backend. Zero allocator — all buffers are static.

const std = @import("std");
const stdio = @import("stdio");
const loop = @import("loop");
const message = @import("message");
const server_mod = @import("server");

// Static storage: the server owns a large fixed document store, and the
// transport buffers are large too. Both must live off the stack.
var server_state: server_mod.Server = .{};
var buffers: loop.Buffers = .{};

pub fn main() void {
    var io = stdio.Stdio.init();
    loop.run(&io, &server_state, &buffers);
}

test "transport modules compile and link" {
    // Exercise the pure pieces so `test-main` covers the entry module too.
    const msg = message.parse("{\"id\":1,\"method\":\"initialize\"}");
    try std.testing.expectEqualStrings("initialize", msg.method);
    var out: [4096]u8 = undefined;
    server_state = .{};
    const res = server_state.handle(msg, &out);
    try std.testing.expectEqual(server_mod.Outcome.respond, res.outcome);
}
