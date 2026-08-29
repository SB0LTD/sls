//! SB0 native entry point for sls (EXPERIMENTAL).
//!
//! SB0 is a freestanding AArch64 OS target: `std.start` does not export a
//! `_start` for it, there is no libc, and there is no hosted stdio. A process
//! enters at `_start` with:
//!
//!   x0 = *BootHandoffBlock   x1 = *HandleTable
//!   x2..x30 = 0              SP 16-byte aligned   PC = SB0X entry
//!
//! Console I/O is done via the SB0 trap ABI: `svc #0` with the operation code
//! in `x8`, arguments in `x0..x5`, result in `x0`, status in `x1`. This module
//! provides just enough of that ABI to run a real, booting SB0X image that
//! reports its identity and exits cleanly.
//!
//! The full LSP transport over SB0's queue/channel handles (bidirectional
//! request/response) is a tracked follow-up; SB0 input is capability-based
//! (queue_create/channel_receive), not a POSIX read. Until that lands, the SB0
//! build is a native "hello, I am sls" image proving the toolchain path works
//! end to end on our own OS.

const build_version = "0.0.3";

// SB0 operation codes (x8 on `svc #0`) — see sb0s/src/common/types.sig.
const OP_PROCESS_EXIT: u16 = 0x0000;
const OP_DEBUG_PRINT: u16 = 0x0F00;

/// Issue an SB0 trap: `svc #0` with opcode in x8 and up to two arguments in
/// x0/x1. Returns the value register (x0). Register placement is done by the
/// asm constraints, matching the SB0 trap ABI (opcode x8, args x0..x5).
inline fn trap2(op: u16, a0: usize, a1: usize) usize {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> usize),
        : [op] "{x8}" (@as(usize, op)),
          [a0] "{x0}" (a0),
          [a1] "{x1}" (a1),
        : .{ .memory = true });
}

/// Write bytes to the SB0 debug console (op 0x0F00: ptr in x0, len in x1).
fn debugPrint(bytes: []const u8) void {
    _ = trap2(OP_DEBUG_PRINT, @intFromPtr(bytes.ptr), bytes.len);
}

/// Terminate the process (op 0x0000: exit code in x0).
fn processExit(code: usize) noreturn {
    _ = trap2(OP_PROCESS_EXIT, code, 0);
    unreachable;
}

/// SB0 process entry. Named `_start` and exported so the SB0X/SB0K linker
/// script's `ENTRY(_start)` resolves. `naked` so no prologue touches the
/// SB0-provided register/stack contract before we run.
export fn _start() callconv(.naked) noreturn {
    // Hand off to the Sig-level entry. The BootHandoffBlock (x0) and
    // HandleTable (x1) are available to sb0Main via the ABI but are not yet
    // needed for the identity image.
    asm volatile (
        \\ bl %[main]
        \\ mov x8, #0
        \\ mov x0, #0
        \\ svc #0
        :
        : [main] "S" (&sb0Main),
        : .{ .memory = true });
    unreachable;
}

/// Sig-level SB0 entry: announce identity over the debug console, then exit.
export fn sb0Main() callconv(.c) void {
    debugPrint("sls " ++ build_version ++ " (Sig Language Server) — SB0 native image\n");
    debugPrint("LSP transport over SB0 channels is in progress; this image proves the native target path.\n");
    processExit(0);
}
