#!/usr/bin/env bash
# Build sls for the SB0 native target (aarch64-sb0) as an SB0X userspace image.
#
# SB0 is a freestanding AArch64 OS target: no libc, no hosted stdio. The hosted
# sls server (Win32/POSIX stdio) cannot target it, so the SB0 build uses a
# dedicated native entry (src/platform/sb0_entry.sig) that talks to the SB0
# kernel through the `svc #0` trap ABI and links with the SB0X userspace layout
# (src/platform/sb0x.ld). The result is a real, structurally valid SB0X image
# (64-byte "SB0X" header + one RX segment) that announces sls's identity via the
# debug_print trap and exits cleanly.
#
# Full bidirectional LSP transport over SB0's queue/channel handles is a tracked
# follow-up; SB0 input is capability-based, not a POSIX read.
#
# Usage: scripts/build-sb0.sh <output-path.sb0x>
set -euo pipefail

OUT="${1:-sig-out/bin/sls-aarch64-sb0.sb0x}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ENTRY="$HERE/src/platform/sb0_entry.sig"
LD="$HERE/src/platform/sb0x.ld"

echo "== sls SB0X native build =="
echo "target:        aarch64-sb0"
echo "entry:         $ENTRY"
echo "linker script: $LD"
echo "output:        $OUT"

if ! command -v sig >/dev/null 2>&1; then
  echo "error: sig not on PATH" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT")"
# build-exe rejects unknown output extensions, so emit to an extensionless path
# and rename to the SB0X convention.
RAW="$(dirname "$OUT")/sls_sb0x_raw"
rm -f "$RAW" "$OUT"

sig build-exe "$ENTRY" \
  -target aarch64-sb0 \
  -mcpu=baseline \
  -OReleaseSmall \
  -fno-stack-check \
  -fno-stack-protector \
  -fno-unwind-tables \
  -fstrip \
  -ffunction-sections \
  --script "$LD" \
  -femit-bin="$RAW"

if [ ! -f "$RAW" ]; then
  echo "error: SB0X image was not produced" >&2
  exit 1
fi

# Verify the SB0X magic: bytes 0x53 0x42 0x30 0x58 ("SB0X").
magic="$(od -An -tx1 -N4 "$RAW" | tr -d ' \n')"
if [ "$magic" != "53423058" ]; then
  echo "error: output is not a valid SB0X image (leading bytes: $magic, expected 53423058)" >&2
  exit 1
fi

mv "$RAW" "$OUT"
echo "SB0X native image produced: $OUT ($(wc -c < "$OUT") bytes, magic SB0X)"
