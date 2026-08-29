//! Layer 1 — Blocking stdio transport.
//!
//! LSP transport is a byte stream on stdin/stdout. Per the SB0 conventions we
//! avoid buffered std runtime I/O and talk to the OS directly:
//!
//!   * Windows — the three Win32 calls `GetStdHandle`, `ReadFile`, `WriteFile`.
//!   * POSIX (Linux, macOS) — `read(2)`/`write(2)` on file descriptors 0 and 1
//!     via `std.posix`, which are thin syscall wrappers, not the buffered
//!     `std.io` stack.
//!
//! Both backends live behind the same `Stdio` struct, chosen at comptime, so
//! the transport loop in main.sig is platform-agnostic. No allocator, no
//! buffering beyond what the caller provides.

const std = @import("std");
const builtin = @import("builtin");

pub const IoError = error{ ReadFailed, WriteFailed };

const is_windows = builtin.os.tag == .windows;

// ── Windows backend ─────────────────────────────────────────────────────────

const win = struct {
    const HANDLE = *anyopaque;
    const DWORD = u32;
    const BOOL = i32;

    const STD_INPUT_HANDLE: DWORD = @bitCast(@as(i32, -10));
    const STD_OUTPUT_HANDLE: DWORD = @bitCast(@as(i32, -11));

    extern "kernel32" fn GetStdHandle(nStdHandle: DWORD) callconv(.c) HANDLE;
    extern "kernel32" fn ReadFile(
        hFile: HANDLE,
        lpBuffer: [*]u8,
        nNumberOfBytesToRead: DWORD,
        lpNumberOfBytesRead: *DWORD,
        lpOverlapped: ?*anyopaque,
    ) callconv(.c) BOOL;
    extern "kernel32" fn WriteFile(
        hFile: HANDLE,
        lpBuffer: [*]const u8,
        nNumberOfBytesToWrite: DWORD,
        lpNumberOfBytesWritten: *DWORD,
        lpOverlapped: ?*anyopaque,
    ) callconv(.c) BOOL;
};

// ── Unified transport ───────────────────────────────────────────────────────

/// On Windows the handles are opaque OS handles; on POSIX they are the integer
/// file descriptors 0 (stdin) and 1 (stdout).
const InHandle = if (is_windows) win.HANDLE else std.posix.fd_t;
const OutHandle = if (is_windows) win.HANDLE else std.posix.fd_t;

pub const Stdio = struct {
    stdin: InHandle,
    stdout: OutHandle,

    pub fn init() Stdio {
        if (is_windows) {
            return .{
                .stdin = win.GetStdHandle(win.STD_INPUT_HANDLE),
                .stdout = win.GetStdHandle(win.STD_OUTPUT_HANDLE),
            };
        } else {
            return .{ .stdin = 0, .stdout = 1 };
        }
    }

    /// Read up to `buf.len` bytes. Returns the count read; 0 means EOF.
    pub fn read(self: *Stdio, buf: []u8) IoError!usize {
        if (buf.len == 0) return 0;
        if (is_windows) {
            var got: win.DWORD = 0;
            const ok = win.ReadFile(self.stdin, buf.ptr, @intCast(buf.len), &got, null);
            // A failed read at EOF (broken pipe) is treated as EOF so the
            // transport loop can shut down cleanly rather than error out.
            if (ok == 0) return 0;
            return got;
        } else {
            // std.posix.read retries on EINTR and returns 0 at EOF.
            return std.posix.read(self.stdin, buf) catch return 0;
        }
    }

    /// Write all of `data`, looping until the OS has accepted every byte.
    pub fn writeAll(self: *Stdio, data: []const u8) IoError!void {
        var written: usize = 0;
        while (written < data.len) {
            if (is_windows) {
                var n: win.DWORD = 0;
                const ok = win.WriteFile(
                    self.stdout,
                    data.ptr + written,
                    @intCast(data.len - written),
                    &n,
                    null,
                );
                if (ok == 0 or n == 0) return error.WriteFailed;
                written += n;
            } else {
                const n = posixWrite(self.stdout, data[written..]) catch return error.WriteFailed;
                if (n == 0) return error.WriteFailed;
                written += n;
            }
        }
    }
};

/// POSIX `write(2)` via the low-level system binding. `std.posix` in this Sig
/// std ships `read` but not a `write` wrapper, so we call `system.write`
/// directly and interpret errno, retrying on EINTR. Returns bytes written.
fn posixWrite(fd: std.posix.fd_t, data: []const u8) IoError!usize {
    if (data.len == 0) return 0;
    const system = std.posix.system;
    while (true) {
        const rc = system.write(fd, data.ptr, data.len);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            else => return error.WriteFailed,
        }
    }
}
