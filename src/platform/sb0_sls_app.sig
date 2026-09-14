//! sls — the Sig Language Server as a native SB0X userspace process.
//!
//! Packaged as an SB0X image (sls.sb0x) and published as an sls release
//! artifact. The generic SB0/Nexus kernel loads it off a FAT disk at boot
//! (APP.SBX + APP.MFT declaring profile=stdio) and launches it at EL0 with the
//! stdio capability profile: a single bidirectional console `channel` handle
//! (index 1) is delegated. sls reads framed LSP requests via `channel_receive`
//! and writes framed responses via `channel_send`, then exits.
//!
//! The LSP protocol/dispatch/analysis is the reusable @zpm/lsp code (`loop` +
//! `server`), driven over a channel-syscall I/O backend — the same server the
//! hosted (Windows/Linux/macOS) sls binary runs; only the byte pipe differs.
//!
//! Contrast with src/platform/sb0_entry.sig: that is a bare-metal SB0K probe
//! that talks straight to the PL011 UART with no kernel under it. This app runs
//! on Nexus and speaks the channel syscall ABI.

const builtin = @import("builtin");
const lsp_loop = @import("loop");
const lsp_server = @import("server");

const build_version = "0.0.6";

// SB0 operation codes (x8 on `svc #0`).
const OP_PROCESS_EXIT: u64 = 0x0000;
const OP_CHANNEL_SEND: u64 = 0x0601;
const OP_CHANNEL_RECEIVE: u64 = 0x0602;
const OP_DEBUG_PRINT: u64 = 0x0F00;

// SB0Error status values (returned in x1).
const STATUS_SUCCESS: u64 = 0;
const STATUS_WOULD_BLOCK: u64 = 11;

// The console channel is delegated as handle 1 (first delegated handle).
const CONSOLE_HANDLE: u64 = 1;

// SB0 trap gate. The `aarch64-sb0` target does not accept named-register
// extended-asm constraints (`"={x0}"`), so — like zpm's screencap/sb0.sig — the
// trap is a file-scope global-assembly function with the C calling convention:
// args arrive in x0.. per AAPCS; we move them into the SB0 ABI registers
// (x8=opcode, x0..x2=args), `svc #0`, and store x0/x1 results through the
// caller-provided out pointer. The out pointer (5th C arg, x4) is stashed into
// the scratch register x9 BEFORE the trap and the results are stored through
// x9 — mirroring the canonical zpm/icy SB0 trap stubs. This keeps the store
// base off the syscall's input-argument registers and never depends on a
// particular argument register surviving the trap.
const TrapResult = extern struct { value: u64 = 0, status: u64 = 0 };

extern fn slsSb0Trap(op: u64, a0: u64, a1: u64, a2: u64, out: *TrapResult) callconv(.c) void;

comptime {
    if (builtin.cpu.arch == .aarch64) {
        asm (
            \\.global slsSb0Trap
            \\.type slsSb0Trap, %function
            \\.p2align 2
            \\slsSb0Trap:
            \\  mov x9, x4
            \\  mov x8, x0
            \\  mov x0, x1
            \\  mov x1, x2
            \\  mov x2, x3
            \\  svc #0
            \\  str x0, [x9]
            \\  str x1, [x9, #8]
            \\  ret
        );
    }
}

fn trap3(op: u64, a0: u64, a1: u64, a2: u64) TrapResult {
    var out = TrapResult{};
    if (builtin.cpu.arch != .aarch64) return out;
    slsSb0Trap(op, a0, a1, a2, &out);
    return out;
}

fn processExit(code: u64) noreturn {
    _ = trap3(OP_PROCESS_EXIT, code, 0, 0);
    unreachable;
}

fn dbg(msg: []const u8) void {
    _ = trap3(OP_DEBUG_PRINT, @intFromPtr(msg.ptr), msg.len, 0);
}

// TEMP diagnostic: print "<label>=0x<hex>\n" over the debug trap so we can see
// runtime pointer/values in the QEMU log while bringing up sls on SB0.
fn dbgHex(label: []const u8, value: u64) void {
    dbg(label);
    var buf: [19]u8 = undefined;
    buf[0] = '=';
    buf[1] = '0';
    buf[2] = 'x';
    var v = value;
    var i: usize = 18;
    if (v == 0) {
        buf[3] = '0';
        buf[4] = '\n';
        _ = trap3(OP_DEBUG_PRINT, @intFromPtr(&buf[0]), 5, 0);
        return;
    }
    buf[i] = '\n';
    i -= 1;
    while (v != 0 and i >= 3) : (i -= 1) {
        const nib: u8 = @truncate(v & 0xf);
        buf[i] = if (nib < 10) '0' + nib else 'a' + (nib - 10);
        v >>= 4;
    }
    // Shift the "=0x" prefix to abut the digits.
    const digits_start = i + 1;
    _ = trap3(OP_DEBUG_PRINT, @intFromPtr(&buf[0]), 3, 0);
    _ = trap3(OP_DEBUG_PRINT, @intFromPtr(&buf[digits_start]), 19 - digits_start, 0);
}

/// I/O backend over the SB0 console channel, satisfying the @zpm/lsp loop's
/// `read`/`writeAll` interface.
const ChannelIo = struct {
    const IoError = error{Closed};

    pub fn read(_: *ChannelIo, buf: []u8) IoError!usize {
        if (buf.len == 0) return 0;
        while (true) {
            const r = trap3(OP_CHANNEL_RECEIVE, CONSOLE_HANDLE, @intFromPtr(buf.ptr), buf.len);
            if (r.status == STATUS_SUCCESS) {
                if (r.value == 0) continue;
                return @intCast(r.value);
            }
            if (r.status == STATUS_WOULD_BLOCK) continue;
            return error.Closed;
        }
    }

    pub fn writeAll(_: *ChannelIo, bytes: []const u8) IoError!void {
        var sent: usize = 0;
        while (sent < bytes.len) {
            const r = trap3(OP_CHANNEL_SEND, CONSOLE_HANDLE, @intFromPtr(bytes.ptr + sent), bytes.len - sent);
            if (r.status != STATUS_SUCCESS) return error.Closed;
            if (r.value == 0) return error.Closed;
            sent += @intCast(r.value);
        }
    }
};

// The server owns a large fixed document store; loop buffers are large too.
// Both live in static storage (the read-write / BSS segment), never on the
// stack — the native SB0X layout maps them writable and costs no file bytes.
var server_state: lsp_server.Server = .{ .info = .{ .name = "sls", .version = build_version } };
var buffers: lsp_loop.Buffers = .{};
var io: ChannelIo = .{};

export fn userMain() callconv(.c) void {
    dbg("SLS-READY: sls language server online, awaiting LSP over channel\n");
    // TEMP diagnostics: surface the runtime addresses of the static globals and
    // the loop's key buffers so we can correlate an EL0 fault address.
    dbgHex("DBG io", @intFromPtr(&io));
    dbgHex("DBG server_state", @intFromPtr(&server_state));
    dbgHex("DBG buffers", @intFromPtr(&buffers));
    dbgHex("DBG buffers.inbound", @intFromPtr(&buffers.inbound[0]));
    dbgHex("DBG buffers.chunk", @intFromPtr(&buffers.chunk[0]));
    dbgHex("DBG buffers.outbound", @intFromPtr(&buffers.outbound[0]));
    lsp_loop.run(&io, &server_state, &buffers);
    processExit(0);
}

/// SB0X process entry. `naked` so the kernel-provided register/stack contract
/// (x0=BHB, x1=HandleTable, sp=stack top) is untouched. Runs at EL0; the kernel
/// enables FP/SIMD for the process. Call the Sig-level main, then exit cleanly.
export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\ bl   %[main]
        \\ mov  x8, #0
        \\ mov  x0, #0
        \\ svc  #0
        \\ 1: wfe
        \\ b    1b
        :
        : [main] "S" (&userMain),
        : .{ .memory = true });
    unreachable;
}
