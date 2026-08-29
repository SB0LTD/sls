#!/usr/bin/env bash
# Boot the sls SB0K image under QEMU and prove the LSP server runs on SB0.
#
# Loads the bare-metal SB0K image at 0x40200000 on the QEMU `virt` machine,
# feeds a full framed LSP session on the serial line, and asserts the framed
# responses (initialize capabilities, documentSymbol outline, shutdown) appear
# on serial output. Mirrors sig/ci/test-sb0-runner.sh boot mechanics.
#
# Usage: scripts/sb0-qemu-test.sh <image.sb0k>
set -uo pipefail

IMG="${1:?usage: sb0-qemu-test.sh <image.sb0k>}"
QEMU="${SB0_QEMU:-$(command -v qemu-system-aarch64 || true)}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [ ! -x "$QEMU" ]; then
  echo "error: qemu-system-aarch64 not found" >&2
  exit 1
fi
if [ ! -f "$IMG" ]; then
  echo "error: image not found: $IMG" >&2
  exit 1
fi

# Verify SB0K magic before booting.
magic="$(od -An -tx1 -N4 "$IMG" | tr -d ' \n')"
if [ "$magic" != "5342304b" ]; then
  echo "error: not an SB0K image (magic $magic)" >&2
  exit 1
fi

# Build a framed LSP session.
frame() { printf 'Content-Length: %s\r\n\r\n%s' "$(printf '%s' "$1" | wc -c)" "$1"; }
SRC='const std = @import(\"std\");\npub fn main() void {}\npub const Point = struct { x: i32 };'
{
  frame '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
  frame '{"jsonrpc":"2.0","method":"initialized"}'
  frame "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///d.sig\",\"version\":1,\"text\":\"$SRC\"}}}"
  frame '{"jsonrpc":"2.0","id":2,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///d.sig"}}}'
  frame '{"jsonrpc":"2.0","id":3,"method":"shutdown"}'
  frame '{"jsonrpc":"2.0","method":"exit"}'
} > "$TMP/session.bin"

echo "sb0-qemu: booting $IMG ($(wc -c < "$IMG") bytes)"
set +e
timeout 20s "$QEMU" \
  -machine virt -cpu cortex-a57 -m 128M \
  -display none -monitor none -serial stdio -no-reboot \
  -device "loader,file=$IMG,addr=0x40200000,force-raw=on" \
  -device "loader,addr=0x40200040,cpu-num=0" \
  < "$TMP/session.bin" > "$TMP/serial.txt" 2>"$TMP/qemu.err"
status=$?
set -e

echo "----- serial output -----"
cat "$TMP/serial.txt"
echo "-------------------------"

fail=0
assert() { if grep -Fq "$1" "$TMP/serial.txt"; then echo "  ok: $2"; else echo "  FAIL: $2"; fail=1; fi; }

assert 'SB0-SLS-READY' "SB0 image booted and UART is up"
assert '"documentSymbolProvider":true' "initialize advertises documentSymbolProvider"
assert '"name":"sls"' "serverInfo.name is sls"
assert '"name":"std"' "documentSymbol includes std"
assert '"name":"main"' "documentSymbol includes main"
assert '"name":"Point"' "documentSymbol includes Point"
assert '"kind":12' "documentSymbol has a Function kind"
assert '"result":null' "shutdown returns result:null"

# The image parks after 'exit', so QEMU is killed by timeout (124). Any other
# non-zero status means it faulted/rebooted.
if [ "$status" -ne 124 ] && [ "$status" -ne 0 ]; then
  echo "  note: qemu exit status $status"
fi

if [ "$fail" -ne 0 ]; then
  echo "SB0 QEMU E2E FAILED" >&2
  cat "$TMP/qemu.err" >&2
  exit 1
fi
echo "SB0 QEMU E2E OK — the sls LSP server runs on SB0 (aarch64) under QEMU"
