//! SB0 bare-metal entry for sls — a real SB0K image that boots under QEMU and
//! runs the full LSP server over the PL011 UART.
//!
//! This is not a stub: after reset it initialises its stack, zeroes BSS,
//! announces its identity on the serial console, and then runs the *same* LSP
//! transport loop as the hosted builds (`lsp/loop.sig`) — reading framed
//! requests from the UART and writing framed responses back. The server
//! dispatch, framing, document store, and symbol analysis are byte-for-byte the
//! same code the Windows/Linux/macOS binaries run; only the byte pipe differs.
//!
//! Boot contract (matches sig's sb0_runner.ld / QEMU `virt`): the SB0K image is
//! loaded at 0x40200000 and the CPU resets to `_start`. The linker script
//! (sb0k.ld) writes the 64-byte SB0K header ahead of the reset code.

const uart = @import("uart");
const loop = @import("loop");
const server_mod = @import("server");

const build_version = "0.0.5";

// Linker-script symbols bounding BSS and the top of the boot stack.
extern var __bss_start: u8;
extern var __bss_end: u8;
extern const __stack_top: u8;

// Static storage for the server and transport buffers — off the (small) boot
// stack. These land in BSS and are zeroed by the reset routine.
var server_state: server_mod.Server = .{};
var buffers: loop.Buffers = .{};

/// A UART-backed I/O backend exposing the same `read`/`writeAll` shape the
/// shared LSP loop expects from hosted stdio.
const UartIo = struct {
    const IoError = error{};

    pub fn read(_: *UartIo, buf: []u8) IoError!usize {
        return uart.read(buf);
    }

    pub fn writeAll(_: *UartIo, bytes: []const u8) IoError!void {
        uart.write(bytes);
    }
};

/// Reset entry. `naked` so nothing touches the CPU state before we set up the
/// stack. Kept minimal: point SP at the linker-provided stack top and branch to
/// the Sig-level entry.
export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\ adrp x0, __stack_top
        \\ add  x0, x0, :lo12:__stack_top
        \\ mov  sp, x0
        \\ // Enable FP/SIMD (CPACR_EL1.FPEN = 0b11) so vectorized code from the
        \\ // optimizer does not trap on bare metal.
        \\ mov  x1, #(3 << 20)
        \\ msr  cpacr_el1, x1
        \\ isb
        \\ bl   %[main]
        \\ b    .
        :
        : [main] "S" (&sb0Main),
        : .{ .memory = true });
    unreachable;
}

/// Sig-level SB0 entry: zero BSS, bring up the console, announce identity, then
/// serve LSP over the UART forever.
export fn sb0Main() callconv(.c) noreturn {
    zeroBss();

    uart.write("sls " ++ build_version ++ " (Sig Language Server) — SB0 native image\r\n");
    uart.write("SB0-SLS-READY\r\n");

    var io: UartIo = .{};
    loop.run(&io, &server_state, &buffers);

    // The LSP loop returns on `exit` or EOF. On bare metal, park.
    sb0Park();
}

/// On bare metal there is nowhere to exit to; report and park low-power.
fn sb0Park() noreturn {
    uart.write("SB0-SLS-EXIT\r\n");
    while (true) {
        asm volatile ("wfe");
    }
}

/// Zero the .bss section [__bss_start, __bss_end).
fn zeroBss() void {
    const start: [*]u8 = @ptrCast(&__bss_start);
    const end: [*]u8 = @ptrCast(&__bss_end);
    const len = @intFromPtr(end) - @intFromPtr(start);
    var i: usize = 0;
    while (i < len) : (i += 1) start[i] = 0;
}
