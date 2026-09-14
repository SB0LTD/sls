#!/usr/bin/env bash
# Build sls as a native SB0X userspace image (sls.sb0x) for SB0/Nexus.
#
# The Sig compiler's SB0 link backend emits the SB0X container DIRECTLY for
# `-target aarch64-sb0` with NO linker script (a linker script would select the
# privileged SB0K kernel container instead). The backend produces the canonical
# two-segment layout — a read-execute segment (code/rodata) and a read-write
# segment (data + zero-init BSS as mem-only) — so sls's large document store
# costs no image bytes and the process can legally write its own globals.
# No ELF, no objcopy, no external packer.
#
# The LSP protocol/dispatch/analysis is the reusable @zpm/lsp code (loop +
# server + friends); modules are wired explicitly because build-exe does not
# consume build.sig.zon. Reusable modules come from the sibling zpm checkout
# (../zpm), the same path dependency build.sig.zon declares.
#
# Usage: scripts/build-sls-sb0x.sh <output-path.sb0x>
set -euo pipefail

OUT="${1:-sig-out/bin/sls.sb0x}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ZPM="$HERE/../zpm/src/core"
ZLSP="$HERE/../zpm/src/lsp"

echo "== sls SB0X userspace build =="
echo "target: aarch64-sb0 (native SB0X, no linker script)"
echo "output: $OUT"

command -v sig >/dev/null 2>&1 || { echo "error: sig not on PATH" >&2; exit 1; }
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"

# The SB0X app: the userspace entry (channel-syscall LSP I/O) + the shared LSP
# loop/server/analysis stack from zpm. No bare-metal UART, no linker script.
sig build-exe \
  -target aarch64-sb0 -mcpu=baseline -OReleaseSmall \
  -fno-stack-check -fno-stack-protector -fno-unwind-tables -fstrip -ffunction-sections \
  --dep loop --dep server -Mroot="$HERE/src/platform/sb0_sls_app.sig" \
  -Msig_mem="$ZPM/sig_mem.sig" \
  --dep sig_mem -Mjson="$ZPM/json.sig" \
  -Mjwrite="$ZLSP/jwrite.sig" \
  -Mdocument="$ZLSP/document.sig" \
  -Mposition="$ZLSP/position.sig" \
  -Msymbols="$ZLSP/symbols.sig" \
  --dep json -Mmessage="$ZLSP/message.sig" \
  --dep json --dep message --dep jwrite --dep document --dep position --dep symbols -Mserver="$ZLSP/server.sig" \
  --dep message --dep server -Mloop="$ZLSP/loop.sig" \
  -femit-bin="$OUT"

[ -s "$OUT" ] || { echo "error: SB0X image was not produced" >&2; exit 1; }

# Verify the SB0X magic: bytes 0x53 0x42 0x30 0x58 ("SB0X").
magic="$(od -An -tx1 -N4 "$OUT" | tr -d ' \n')"
if [ "$magic" != "53423058" ]; then
  echo "error: output is not a valid SB0X image (leading bytes: $magic, expected 53423058)" >&2
  exit 1
fi
echo "sls SB0X image produced: $OUT ($(wc -c < "$OUT") bytes, magic SB0X)"
