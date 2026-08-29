//! Layer 1 — Blocking stdio over raw Win32 handles.
//!
//! LSP transport is a byte stream on stdin/stdout. Per the SB0 conventions we
//! avoid std runtime I/O and instead bind the three Win32 calls we need
//! (`GetStdHandle`, `ReadFile`, `WriteFile`) directly. No allocator, no
//! buffering beyond what the caller provides.

const builtin = @import("builtin");

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

pub const IoError = error{ ReadFailed, WriteFailed };

pub const Stdio = struct {
    stdin: HANDLE,
    stdout: HANDLE,

    pub fn init() Stdio {
        return .{
            .stdin = GetStdHandle(STD_INPUT_HANDLE),
            .stdout = GetStdHandle(STD_OUTPUT_HANDLE),
        };
    }

    /// Read up to `buf.len` bytes. Returns the count read; 0 means EOF.
    pub fn read(self: *Stdio, buf: []u8) IoError!usize {
        if (buf.len == 0) return 0;
        var got: DWORD = 0;
        const ok = ReadFile(self.stdin, buf.ptr, @intCast(buf.len), &got, null);
        if (ok == 0) {
            // A failed read at EOF (broken pipe) is treated as EOF, not error,
            // so the transport loop can shut down cleanly.
            return 0;
        }
        return got;
    }

    /// Write all of `data`, looping until the OS has accepted every byte.
    pub fn writeAll(self: *Stdio, data: []const u8) IoError!void {
        var written: usize = 0;
        while (written < data.len) {
            var n: DWORD = 0;
            const ok = WriteFile(
                self.stdout,
                data.ptr + written,
                @intCast(data.len - written),
                &n,
                null,
            );
            if (ok == 0 or n == 0) return error.WriteFailed;
            written += n;
        }
    }
};

comptime {
    // sls transport currently targets Windows (raw Win32 stdio). A POSIX
    // read/write backend is a straightforward addition behind this same struct.
    if (builtin.os.tag != .windows) {
        @compileError("sls stdio transport currently supports Windows only");
    }
}
