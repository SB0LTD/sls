//! Shared LSP transport loop.
//!
//! The read/frame/dispatch/respond cycle, factored out so every platform runs
//! the *same* server over whatever byte pipe it has. The loop is generic over
//! an I/O backend and never allocates — the caller owns all buffers.
//!
//! An I/O backend is any value with:
//!   - `read(self, buf: []u8) IoErr!usize` — fill up to buf.len bytes; 0 = EOF
//!   - `writeAll(self, bytes: []const u8) IoErr!void`
//!
//! Hosted builds pass `platform/stdio.sig`'s `Stdio` (Win32/POSIX); the SB0
//! bare-metal image passes a PL011-UART backend. Same protocol code either way.

const message = @import("message");
const server_mod = @import("server");

/// Fixed transport buffers. Sized to hold one full LSP message (a large
/// didOpen plus headers) with margin, and a response body of similar size.
pub const INBOUND_CAP = 512 * 1024;
pub const OUTBOUND_CAP = 512 * 1024;
pub const CHUNK_CAP = 64 * 1024;

/// The buffers a `run` call needs. Kept in a struct so callers can place it in
/// static storage (it is large) rather than on the stack.
pub const Buffers = struct {
    inbound: [INBOUND_CAP]u8 = undefined,
    outbound: [OUTBOUND_CAP]u8 = undefined,
    chunk: [CHUNK_CAP]u8 = undefined,
};

/// Run the LSP session to completion (until `exit` or EOF). Generic over the
/// I/O backend `io` (a pointer to any value exposing `read`/`writeAll`).
pub fn run(io: anytype, srv: *server_mod.Server, bufs: *Buffers) void {
    var filled: usize = 0; // bytes currently buffered in `inbound`

    while (true) {
        // Drain as many complete frames as are already buffered.
        while (true) {
            const frame = message.readFrame(bufs.inbound[0..filled]) catch |err| switch (err) {
                error.Incomplete => break,
                // Malformed framing: drop the buffer and resync.
                error.MissingContentLength, error.Malformed => {
                    filled = 0;
                    break;
                },
            };

            const msg = message.parse(frame.body);
            const result = srv.handle(msg, &bufs.outbound);
            switch (result.outcome) {
                .respond => sendFramed(io, result.body),
                .none => {},
                .exit => return,
            }

            // Shift any trailing bytes (start of the next frame) to the front.
            const remaining = filled - frame.consumed;
            if (remaining > 0) {
                copyForwards(bufs.inbound[0..remaining], bufs.inbound[frame.consumed..filled]);
            }
            filled = remaining;
        }

        // Need more bytes.
        const n = io.read(&bufs.chunk) catch return;
        if (n == 0) return; // EOF
        if (filled + n > INBOUND_CAP) {
            // Oversized message beyond our capacity: reset to stay alive.
            filled = 0;
            continue;
        }
        @memcpy(bufs.inbound[filled .. filled + n], bufs.chunk[0..n]);
        filled += n;
    }
}

/// Frame a response body with its Content-Length header and write both.
pub fn sendFramed(io: anytype, body: []const u8) void {
    if (body.len == 0) return;
    var header_buf: [64]u8 = undefined;
    const header = message.writeHeader(&header_buf, body.len) catch return;
    io.writeAll(header) catch return;
    io.writeAll(body) catch return;
}

/// Overlap-safe forward copy (avoids depending on std for the SB0 build).
fn copyForwards(dst: []u8, src: []const u8) void {
    var i: usize = 0;
    while (i < src.len) : (i += 1) dst[i] = src[i];
}
