/*
 * sls — SB0K bare-metal native image linker script.
 *
 * Produces an SB0K image (magic "SB0K", format version 1, 64-byte header, boot
 * ABI version 1) based at 0x40200000, matching the sig toolchain's
 * sb0_runner.ld contract. QEMU `-machine virt` loads the raw image at
 * 0x40200000 and resets the CPU to entry (load base + 64).
 *
 * The 64-byte SB0K header is emitted as data, immediately followed by the reset
 * code (_start from src/platform/sb0_entry.sig). A boot stack is reserved after
 * the loaded image, and BSS bounds are exported for the reset routine to zero.
 */
ENTRY(_start)

SECTIONS
{
  . = 0x40200000;
  __sb0_image_start = .;

  .sb0k :
  {
    LONG(0x4b304253)  /* "SB0K" */
    SHORT(1)          /* format version */
    SHORT(64)         /* header bytes */
    SHORT(1)          /* boot ABI version */
    SHORT(0)          /* ABI revision */
    LONG(1)           /* flags: bit 0 = fixed layout */
    QUAD(_start - __sb0_image_start)          /* entry offset */
    QUAD(__sb0_file_end - __sb0_image_start)  /* total image bytes */
    QUAD(0)           /* relocation offset (none) */
    LONG(0)           /* relocation count */
    LONG(0)           /* relocation entry bytes */
    QUAD(0)           /* build identity */
    QUAD(0x40200000)  /* preferred physical base */
  }

  .text : ALIGN(16)
  {
    KEEP(*(.text._start .text.*._start .text.*_start))
    *(.text .text.*)
  }
  .rodata : ALIGN(16) { *(.rodata .rodata.*) }
  .data   : ALIGN(16) { *(.data .data.*) }
  __sb0_file_end = .;

  .bss (NOLOAD) : ALIGN(16)
  {
    __bss_start = .;
    *(.bss .bss.* COMMON)
    . = ALIGN(16);
    __bss_end = .;
  }

  /* Boot stack: 256 KiB after BSS. Grows down from __stack_top. */
  .stack (NOLOAD) : ALIGN(16)
  {
    . += 0x40000;
    . = ALIGN(16);
    __stack_top = .;
  }

  /DISCARD/ : { *(.comment .note .note.* .eh_frame .eh_frame_hdr) }
}
