# Changelog

All notable changes to sls are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and sls aims to follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.0.6] - 2026-08-31 — SB0 userspace + @zpm/lsp

### Added
- **sls runs as a native SB0 userspace process.** Beyond the bare-metal SB0K
  image (0.0.5), the full LSP server now runs at **EL0 as an SB0X process under
  the SB0/Nexus kernel**, doing bidirectional stdio over the SB0 `channel`
  syscalls (`channel_send` / `channel_receive`, `svc #0`). This required
  implementing the kernel-side byte-stream console path in
  [nexus](https://github.com/SB0LTD/nexus) (merged) — `channel_read`/
  `channel_write` trap backends, a PL011 RX path, and a `launchStdio` that
  delegates a bidirectional console `channel` handle to the process. Verified in
  CI: the kernel boots headless, launches the sls SB0X image, and a full
  `initialize → didOpen → documentSymbol → shutdown → exit` session is driven
  over the channel and asserted.

### Changed
- **The LSP protocol core moved to [`@zpm/lsp`](https://github.com/SB0LTD/zpm).**
  The framing, JSON-RPC parsing/emitting, document store, position math, symbol
  scanner, request dispatch, and transport loop are now reusable zpm modules;
  sls consumes them by path dependency and keeps only the hosted transport entry
  and platform stdio. One implementation now serves the hosted binaries, the
  bare-metal SB0K image, and the SB0 userspace process.
- The server name/version reported in `initialize` is configured by sls via the
  new `ServerInfo` on `@zpm/lsp`'s server.

## [0.0.5] - 2026-08-29 — Runs on SB0

### Added
- **The full LSP server runs on SB0.** The SB0 build is now a bare-metal SB0K
  image that boots under QEMU and serves LSP over the PL011 UART — not an
  identity stub. A dedicated reset entry (`src/platform/sb0_entry.sig`) sets up
  the stack, zeroes BSS, enables FP/SIMD, brings up the UART
  (`src/platform/sb0_uart.sig`), and then runs the **same** server dispatch,
  framing, document store, and symbol analysis the hosted binaries run.
- **Shared transport loop** (`src/lsp/loop.sig`) — the read/frame/dispatch/
  respond cycle is factored out and generic over the byte pipe, so the hosted
  (Win32/POSIX stdio) and SB0 (UART) builds share identical protocol code.
- **SB0-in-QEMU CI** — the [SB0 workflow](.github/workflows/sb0.yaml) installs
  `qemu-system-aarch64`, builds the SB0K image, boots it on the QEMU `virt`
  machine, drives a full LSP session over the serial line, and asserts the
  `initialize`/`documentSymbol`/`shutdown` responses. The release also
  boot-verifies the SB0 image before publishing it.
- The SB0 artifact is now a bootable `.sb0k` image (`sls-<ver>-aarch64-sb0.tar.gz`).

### Changed
- SB0 promoted from an identity image (0.0.3/0.0.4) to a booting, LSP-serving
  image. The `svc #0` identity path is superseded by the UART transport.

### Notes
- The SB0 transport is UART-based (bare metal). Running sls as a hosted SB0
  *userspace* process over the kernel's queue/channel handles — under a booted
  SB0 kernel — remains a possible future refinement.

## [0.0.4] - 2026-08-29 — Verified everywhere

### Added
- **Cross-platform end-to-end verification.** `scripts/e2e.ps1` is a portable
  (PowerShell Core) driver that spawns the real built server, runs a full LSP
  session over stdio (`initialize → didOpen → documentSymbol → didChange →
  documentSymbol → didClose → shutdown → exit`), parses the `Content-Length`
  framing, and strictly asserts every response — including that `didChange`
  full-sync is reflected in a subsequent `documentSymbol`.
- **E2E CI matrix.** A new `E2E` workflow runs the driver against the
  release-built binary on **Windows, Linux, and macOS**, proving the server
  actually runs and speaks LSP on every supported OS, not just that it compiles.
- **Deeper protocol unit tests.** Framing edge cases (empty input, partial
  frames, multiple messages in one buffer, extra headers, tabs/trailing spaces,
  missing `Content-Length`, `id: 0`), and server behaviours (`didClose`,
  full lifecycle sequence, multi-line symbol ranges, tolerance of requests
  before `initialize`).

### Changed
- Replaced the Windows-only `scripts/handshake.ps1` with the cross-platform
  `scripts/e2e.ps1`.

## [0.0.3] - 2026-08-29 — SB0 native

### Added
- **Real SB0 native image.** sls now builds a genuine, structurally valid
  **SB0X** userspace image for `aarch64-sb0` — our own OS — promoted from the
  experimental placeholder in 0.0.2. Because SB0 is freestanding (no libc, no
  hosted stdio), the SB0 build does not use the Win32/POSIX transport; a
  dedicated native entry (`src/platform/sb0_entry.sig`) talks to the SB0 kernel
  through the `svc #0` trap ABI (operation code in `x8`, arguments in
  `x0..x5`) and links with the SB0X userspace layout (`src/platform/sb0x.ld`).
  The image carries the 64-byte `SB0X` header + one RX segment and follows the
  SB0 process-entry contract (`x0 = *BootHandoffBlock`, `x1 = *HandleTable`).
- The SB0X artifact (`sls-<ver>-aarch64-sb0.tar.gz`) is now a first-class
  release asset with its own checksum, and CI builds and validates it (SB0X
  magic) on every run.

### Notes
- The SB0X image announces sls's identity via the `debug_print` trap and exits;
  it proves the native SB0 target path end to end. Full bidirectional LSP
  transport over SB0's queue/channel handles (SB0 input is capability-based, not
  a POSIX read) is the next step for the SB0 build.

## [0.0.2] - 2026-08-29 — Multiplatform

### Added
- **Cross-platform stdio transport.** The LSP byte transport now has a POSIX
  backend (`read(2)`/`write(2)` on fds 0/1) alongside the existing Win32
  (`ReadFile`/`WriteFile`) backend, selected at comptime. The transport loop in
  `main.sig` is unchanged and platform-agnostic.
- **Six release targets, cross-compiled from a single host:**
  - Windows — `x86_64`, `aarch64`
  - Linux — `x86_64`, `aarch64`
  - macOS — `x86_64`, `aarch64`
- **SB0 native target (experimental).** `aarch64-sb0` is now a first-class,
  declared build target with a committed SB0K linker script
  (`src/platform/sb0_native.ld`) and a best-effort build script
  (`scripts/build-sb0.sh`). See _Known limitations_ below.
- **Multi-platform release pipeline.** The release workflow builds every target
  on one Linux runner, packages each (`.zip` for Windows, `.tar.gz` for Unix),
  emits a combined `SHA256SUMS.txt`, and attaches them to the GitHub Release.
- **CI cross-compile matrix.** CI builds and tests natively on Linux and then
  cross-compiles all release targets to catch platform regressions early.

### Changed
- CI and release steps now fail the job on any non-zero build or test exit;
  previously a failing `sig build test` in a combined step could be masked.
- README documents all supported platforms with a downloads table and honest
  status for the experimental SB0 target.

### Known limitations
- SB0 native was wired as an experimental target but did not yet produce a
  working image in this release. **Superseded by 0.0.3**, which builds a real
  SB0X native image via the `svc #0` trap ABI.

## [0.0.1] - 2026-08-29 — Initial release

### Added
- First release of sls, the Sig Language Server — a fork of
  [zigtools/zls](https://github.com/zigtools/zls) rewritten for the Sig toolchain
  and built on [zpm](https://github.com/SB0LTD/zpm).
- Allocator-free LSP server over stdio:
  - `Content-Length` message framing and JSON-RPC 2.0 dispatch.
  - Lifecycle: `initialize`, `initialized`, `shutdown`, `exit`.
  - Document sync: `textDocument/didOpen`, `didChange` (full), `didClose`.
  - `textDocument/documentSymbol`, backed by a zero-allocation Sig declaration
    scanner.
- Native `sig_build` graph and a dependency-honest `build.sig.zon` consuming
  zpm by path dependency.
- MIT licensed, with the upstream ZLS copyright preserved.

[0.0.6]: https://github.com/SB0LTD/sls/releases/tag/v0.0.6
[0.0.5]: https://github.com/SB0LTD/sls/releases/tag/v0.0.5
[0.0.4]: https://github.com/SB0LTD/sls/releases/tag/v0.0.4
[0.0.3]: https://github.com/SB0LTD/sls/releases/tag/v0.0.3
[0.0.2]: https://github.com/SB0LTD/sls/releases/tag/v0.0.2
[0.0.1]: https://github.com/SB0LTD/sls/releases/tag/v0.0.1
