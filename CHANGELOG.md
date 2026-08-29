# Changelog

All notable changes to sls are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and sls aims to follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
- **SB0 native is experimental and does not yet produce a working binary.** SB0
  is a freestanding AArch64 target with no libc and no hosted stdio; the Sig
  toolchain's SB0 code generation and userspace runtime (the `svc #0` trap ABI
  and SB0X loader) are still in progress. sls is a hosted stdio program, so it
  cannot link a working SB0 image today (the SB0 link path expects a freestanding
  `_start` and a syscall-based I/O layer that does not exist yet). The target is
  wired and documented so it lights up the moment SB0 userspace support lands;
  the release pipeline attempts it non-fatally and never blocks the hosted
  artifacts on it.

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

[0.0.2]: https://github.com/SB0LTD/sls/releases/tag/v0.0.2
[0.0.1]: https://github.com/SB0LTD/sls/releases/tag/v0.0.1
