#!/usr/bin/env bash
# Build sls for the SB0 native target (aarch64-sb0) as a bare-metal SB0K image.
#
# SB0 is a freestanding AArch64 OS target: no libc, no hosted stdio. The SB0
# build uses a dedicated bare-metal entry (src/platform/sb0_entry.sig) that
# brings up the PL011 UART and runs the *same* LSP server as the hosted builds
# over that UART. It links with the SB0K image layout (src/platform/sb0k.ld):
# a 64-byte "SB0K" header at 0x40200000 followed by the reset code, exactly the
# shape QEMU `-machine virt` boots.
#
# Usage: scripts/build-sb0.sh <output-path.sb0k>
set -euo pipefail

OUT="${1:-sig-out/bin/sls-aarch64-sb0.sb0k}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
LD="$HERE/src/platform/sb0k.ld"
ZPM="$HERE/../zpm/src/core"
ZLSP="$HERE/../zpm/src/lsp"   # reusable @zpm/lsp modules

echo "== sls SB0K bare-metal build =="
echo "target:        aarch64-sb0"
echo "linker script: $LD"
echo "output:        $OUT"

if ! command -v sig >/dev/null 2>&1; then
  echo "error: sig not on PATH" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT")"
RAW="$(dirname "$OUT")/sls_sb0k_raw"
rm -f "$RAW" "$OUT"

# The SB0 image is a multi-module program: the bare-metal entry + UART, the
# shared LSP loop, and the full server/analysis stack. Modules are wired
# explicitly because build-exe does not consume build.sig.zon.
sig build-exe \
  -target aarch64-sb0 -mcpu=baseline -OReleaseSmall \
  -fno-stack-check -fno-stack-protector -fno-unwind-tables -fstrip -ffunction-sections \
  --script "$LD" \
  --dep uart --dep loop --dep server -Mroot="$HERE/src/platform/sb0_entry.sig" \
  -Mjson="$ZPM/json.sig" \
  -Mjwrite="$ZLSP/jwrite.sig" \
  -Mdocument="$ZLSP/document.sig" \
  -Mposition="$ZLSP/position.sig" \
  -Msymbols="$ZLSP/symbols.sig" \
  -Muart="$HERE/src/platform/sb0_uart.sig" \
  --dep json -Mmessage="$ZLSP/message.sig" \
  --dep json --dep message --dep jwrite --dep document --dep position --dep symbols -Mserver="$ZLSP/server.sig" \
  --dep message --dep server -Mloop="$ZLSP/loop.sig" \
  -femit-bin="$RAW"

if [ ! -f "$RAW" ]; then
  echo "error: SB0K image was not produced" >&2
  exit 1
fi

# Verify the SB0K magic: bytes 0x53 0x42 0x30 0x4b ("SB0K").
magic="$(od -An -tx1 -N4 "$RAW" | tr -d ' \n')"
if [ "$magic" != "5342304b" ]; then
  echo "error: output is not a valid SB0K image (leading bytes: $magic, expected 5342304b)" >&2
  exit 1
fi

mv "$RAW" "$OUT"
echo "SB0K native image produced: $OUT ($(wc -c < "$OUT") bytes, magic SB0K)"
