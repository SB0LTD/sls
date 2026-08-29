/*
 * sls — SB0X native userspace image linker script (EXPERIMENTAL).
 *
 * Lays out an SB0X userspace image: a fixed 64-byte header (magic "SB0X",
 * format version 1, ABI version 1) followed by one 40-byte RX segment
 * descriptor and the program text. Mirrors the SB0X container emitted by the
 * Sig toolchain's linker (compiler/backend/linker.sig emitSb0NativeExecutable)
 * and the classic sb0x_loader contract (64-byte header, 40-byte segments,
 * max 8 segments).
 *
 * Entry is _start (src/platform/sb0_entry.sig), which follows the SB0 process
 * entry ABI: x0 = *BootHandoffBlock, x1 = *HandleTable.
 */
ENTRY(_start)

SECTIONS
{
  . = 0;
  __sb0x_image_start = .;

  .sb0x_header :
  {
    LONG(0x58304253)  /* "SB0X" */
    BYTE(1)           /* format version */
    BYTE(0)           /* flags */
    SHORT(1)          /* ABI version */
    QUAD(_start - __sb0x_text_start)          /* entry offset within segment 0 */
    SHORT(1)          /* segment count */
    SHORT(0)          /* reserved */
    LONG(0)           /* tls template offset */
    LONG(0)           /* tls template size */
    LONG(0)           /* tls bss size */
    QUAD(0)           /* image mem size (loader-computed; 0 = derive) */
    QUAD(0x10000)     /* default stack size (64 KiB) */
    QUAD(0)           /* reserved (16 bytes) */
    QUAD(0)
  }

  /* Segment 0 descriptor: 40 bytes, RX text. */
  .sb0x_seg0 :
  {
    QUAD(__sb0x_text_start - __sb0x_image_start)  /* file_offset */
    QUAD(0)                                       /* vaddr_offset */
    QUAD(__sb0x_text_end - __sb0x_text_start)     /* file_size */
    QUAD(__sb0x_text_end - __sb0x_text_start)     /* mem_size */
    LONG(5)                                       /* flags: readable | executable */
    LONG(0)                                       /* padding */
  }

  __sb0x_text_start = .;
  .text : ALIGN(16)
  {
    KEEP(*(.text._start .text.*._start .text.*_start))
    *(.text .text.*)
  }
  .rodata : ALIGN(16) { *(.rodata .rodata.*) }
  .data : ALIGN(16) { *(.data .data.*) }
  __sb0x_text_end = .;

  .bss (NOLOAD) : ALIGN(16)
  {
    __bss_start = .;
    *(.bss .bss.* COMMON)
    __bss_end = .;
  }
  /DISCARD/ : { *(.comment .note .note.* .eh_frame .eh_frame_hdr) }
}
