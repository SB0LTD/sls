//! PL011 UART driver for the SB0 bare-metal image (QEMU `virt` machine).
//!
//! On SB0 there is no libc and no hosted stdio. When sls runs as a bare-metal
//! SB0K image under QEMU, its console is the ARM PL011 UART mapped at
//! 0x0900_0000 on the `virt` machine. This module is the whole I/O layer for
//! that world: blocking byte read/write over memory-mapped registers, no
//! allocator, no buffering beyond what the caller provides.
//!
//! PL011 register map (offsets from base):
//!   0x00  DR  — data register (write to transmit, read to receive)
//!   0x18  FR  — flag register: bit 4 RXFE (RX FIFO empty),
//!                              bit 5 TXFF (TX FIFO full)

/// QEMU `virt` PL011 base address.
pub const BASE: usize = 0x0900_0000;

const DR_OFFSET: usize = 0x00;
const FR_OFFSET: usize = 0x18;
const FR_RXFE: u32 = 1 << 4; // receive FIFO empty
const FR_TXFF: u32 = 1 << 5; // transmit FIFO full

inline fn reg(offset: usize) *volatile u32 {
    return @ptrFromInt(BASE + offset);
}

/// Transmit one byte, blocking while the TX FIFO is full.
pub fn putc(byte: u8) void {
    const fr = reg(FR_OFFSET);
    while (fr.* & FR_TXFF != 0) {}
    reg(DR_OFFSET).* = byte;
}

/// Write a whole slice.
pub fn write(bytes: []const u8) void {
    for (bytes) |b| putc(b);
}

/// Read one byte, blocking while the RX FIFO is empty.
pub fn getc() u8 {
    const fr = reg(FR_OFFSET);
    while (fr.* & FR_RXFE != 0) {}
    return @truncate(reg(DR_OFFSET).*);
}

/// Non-blocking receive: returns a byte if one is available, else null.
pub fn tryGetc() ?u8 {
    const fr = reg(FR_OFFSET);
    if (fr.* & FR_RXFE != 0) return null;
    return @truncate(reg(DR_OFFSET).*);
}

/// Fill `buf` with up to `buf.len` bytes, blocking for at least one byte, then
/// draining whatever is immediately available. Returns the count read (>= 1).
/// This gives the transport loop the same "read a chunk" shape as hosted stdio.
pub fn read(buf: []u8) usize {
    if (buf.len == 0) return 0;
    buf[0] = getc();
    var n: usize = 1;
    while (n < buf.len) {
        const b = tryGetc() orelse break;
        buf[n] = b;
        n += 1;
    }
    return n;
}
