//! sls — Sig Language Server entry point (hosted: Windows/Linux/macOS).
//!
//! Wires the platform stdio backend to the shared LSP transport loop. The
//! protocol, dispatch, and analysis are the reusable @zpm/lsp modules (loop +
//! server); this file is just the hosted transport entry. The SB0 bare-metal
//! image (src/platform/sb0_entry.sig) runs the same @zpm/lsp loop over a UART
//! backend, and the SB0 *userspace* build (nexus apps/sls) runs it over the
//! kernel's channel syscalls. Zero allocator — all buffers are static.

const std = @import("std");
const stdio = @import("stdio");
const loop = @import("loop");
const message = @import("message");
const server_mod = @import("server");

pub const SERVER_NAME = "sls";
pub const SERVER_VERSION = "0.0.6";

// Static storage: the server owns a large fixed document store, and the
// transport buffers are large too. Both must live off the stack.
var server_state: server_mod.Server = .{ .info = .{ .name = SERVER_NAME, .version = SERVER_VERSION } };
var buffers: loop.Buffers = .{};

pub fn main() void {
    var io = stdio.Stdio.init();
    loop.run(&io, &server_state, &buffers);
}

test "hosted transport wires @zpm/lsp server end to end" {
    const msg = message.parse("{\"id\":1,\"method\":\"initialize\"}");
    try std.testing.expectEqualStrings("initialize", msg.method);
    var out: [4096]u8 = undefined;
    server_state = .{ .info = .{ .name = SERVER_NAME, .version = SERVER_VERSION } };
    const res = server_state.handle(msg, &out);
    try std.testing.expectEqual(server_mod.Outcome.respond, res.outcome);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "\"name\":\"sls\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "\"version\":\"0.0.6\"") != null);
}
