/*
 * sls — SB0 native image linker script (EXPERIMENTAL).
 *
 * Lays out an SB0K native image: a fixed 64-byte SB0K header (magic "SB0K",
 * format version 1, 64-byte header, boot ABI version 1) followed by the reset
 * entry and sections, based at 0x40200000. Mirrors the sig toolchain's
 * sb0_runner.ld contract.
 *
 * NOTE: SB0 is a freestanding AArch64 target with no libc and no hosted stdio.
 * A hosted stdio program like sls cannot yet link through this script into a
 * working userspace binary — SB0 code generation and the SB0 userspace runtime
 * (svc #0 trap ABI, SB0X loader) are still in progress in the Sig toolchain.
 * This script is committed so the SB0 target is first-class in the build the
 * moment that support lands.
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
  .data : ALIGN(16) { *(.data .data.*) }
  __sb0_file_end = .;
  .bss (NOLOAD) : ALIGN(16)
  {
    __bss_start = .;
    *(.bss .bss.* COMMON)
    __bss_end = .;
  }
  /DISCARD/ : { *(.comment .note .note.* .eh_frame .eh_frame_hdr) }
}
