#!/usr/bin/env bash
# EXPERIMENTAL: attempt to build sls for the SB0 native target (aarch64-sb0).
#
# SB0 is a freestanding AArch64 target with no libc and no hosted stdio. The
# Sig toolchain's SB0 code generation and userspace runtime (svc #0 trap ABI,
# SB0X loader) are still in progress, so this build is not expected to produce
# a working binary yet. The script is best-effort: it prints what it attempts
# and always exits 0 so it can run in a release pipeline without failing it.
#
# The moment SB0 userspace codegen lands, this path produces a real
# sls-<version>-aarch64-sb0 image using the committed sb0_native.ld script.
#
# Usage: scripts/build-sb0.sh <output-path>
set -uo pipefail

OUT="${1:-sig-out/bin/sls.sb0x}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
LD="$HERE/src/platform/sb0_native.ld"

echo "== sls SB0 native build (experimental) =="
echo "target: aarch64-sb0"
echo "linker script: $LD"
echo "output: $OUT"

if ! command -v sig >/dev/null 2>&1; then
  echo "sig not on PATH; skipping SB0 build."
  exit 0
fi

mkdir -p "$(dirname "$OUT")"
# build-exe rejects unknown output extensions, so emit to an extensionless
# path and rename to the SB0X convention on success.
RAW_OUT="$(dirname "$OUT")/sls_sb0_raw"

# The proven SB0 link path uses build-exe with the SB0 linker script and
# freestanding flags (no libc, no stack protector/unwind tables).
set -x
sig build-exe "$HERE/src/main.sig" \
  -target aarch64-sb0 \
  -mcpu=baseline \
  -OReleaseFast \
  -fno-stack-check \
  -fno-stack-protector \
  -fno-unwind-tables \
  -fstrip \
  -ffunction-sections \
  --script "$LD" \
  -femit-bin="$RAW_OUT" 2>&1
status=$?
set +x

if [ "$status" -eq 0 ] && [ -f "$RAW_OUT" ]; then
  mv "$RAW_OUT" "$OUT"
  echo "SB0 native image produced: $OUT"
  # Verify the SB0K magic (0x4b304253 little-endian = bytes 53 42 30 4b).
  magic="$(od -An -tx1 -N4 "$OUT" | tr -d ' \n')"
  echo "leading bytes: $magic (expect 5342304b for SB0K)"
  exit 0
fi

echo "SB0 native build did not produce a usable image (expected while SB0 codegen is WIP)."
echo "This is non-fatal: hosted targets are unaffected."
exit 0
