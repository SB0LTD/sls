<p align="center">
  <img src="sls-logo.png" alt="sls — Sig Language Server" width="200" />
</p>

<h1 align="center">sls</h1>

<p align="center">
  <strong>The Sig Language Server.</strong><br/>
  <sub>A native, allocator-free implementation of the Language Server Protocol for Sig.</sub>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/sig-0.4.0-2f6fe0?style=flat-square" alt="Sig 0.4.0" />
  <img src="https://img.shields.io/badge/built%20on-zpm-1e40af?style=flat-square" alt="Built on zpm" />
  <img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="License: MIT" />
  <img src="https://img.shields.io/badge/allocations-zero-111827?style=flat-square" alt="Zero allocations" />
  <img src="https://img.shields.io/badge/platforms-windows%20%7C%20linux%20%7C%20macos%20%7C%20sb0-6b7280?style=flat-square" alt="Platforms" />
</p>

<p align="center">
  <code>Zero-allocator</code> · <code>No runtime std I/O</code> · <code>Fixed-capacity</code> · <code>zpm-native</code>
</p>

---

> [!NOTE]
> **sls is a fork of [zigtools/zls](https://github.com/zigtools/zls)**, the Zig
> Language Server, rewritten for the [Sig](https://github.com/SB0LTD/sig)
> toolchain. It keeps ZLS's architecture and LSP semantics and reimplements them
> in Sig on top of [`zpm`](https://github.com/SB0LTD/zpm). Both projects are MIT
> licensed; the upstream copyright is preserved in [`LICENSE`](LICENSE) and
> [`NOTICE`](NOTICE).

## What is sls?

sls is a [Language Server Protocol](https://microsoft.github.io/language-server-protocol/)
server that gives editors IDE features — document outlines today, with hover,
go-to-definition, completion, and diagnostics on the roadmap — for Sig source
files.

Where ZLS leans on the Zig standard library's allocator, hash maps, and dynamic
JSON, sls is built to the SB0 engineering principles. Every design choice favors
predictability over convenience:

- **Zero allocator.** All storage is fixed-capacity — static document slots, a
  bounded inbound ring, and caller-provided scratch. There is no heap in any hot
  path, so memory use is known at compile time and never fragments.
- **No runtime std I/O.** The transport is raw `Content-Length`-framed bytes over
  stdio, read and written through direct OS calls — Win32 `ReadFile`/`WriteFile`
  on Windows, `read(2)`/`write(2)` on POSIX — never the buffered `std.io` stack.
- **Leans on `zpm`.** Reusable infrastructure (JSON scanning today; logging, file
  I/O, and crypto as features grow) comes from the [`zpm`](https://github.com/SB0LTD/zpm)
  package library by path dependency — never reimplemented locally.

It is also, deliberately, a worked example of a proper zpm-based Sig project: a
native `sig_build` graph, a dependency-honest `build.sig.zon`, and a strict
layer hierarchy where lower layers never import from higher ones.

## Features

| Capability                        | Status         |
|-----------------------------------|----------------|
| stdio `Content-Length` framing    | ✅ implemented |
| JSON-RPC 2.0 dispatch             | ✅ implemented |
| `initialize` / `initialized`      | ✅ implemented |
| `shutdown` / `exit`               | ✅ implemented |
| `textDocument/didOpen`            | ✅ implemented |
| `textDocument/didChange` (full)   | ✅ implemented |
| `textDocument/didClose`           | ✅ implemented |
| `textDocument/documentSymbol`     | ✅ implemented |
| Publish diagnostics               | 🚧 planned     |
| Hover / definition / completion   | 🚧 planned     |
| Rename / references               | 🚧 planned     |

The document-symbol outline is driven by a small, allocator-free Sig declaration
scanner. Semantic features (hover, go-to-definition, completion, rename) require
full Sig semantic analysis and are being layered on incrementally.

## Requirements

- **Sig `0.4.0`.** sls uses the native `sig_build` build runner; the legacy
  `std.Build` graph does not compile under 0.4.0's in-process runner.
- **[`zpm`](https://github.com/SB0LTD/zpm) as a sibling checkout.** `build.sig.zon`
  references it as a path dependency (`../zpm`).

```
parent/
├── sls/     ← this repository
└── zpm/     ← https://github.com/SB0LTD/zpm
```

## Build

```sh
sig build          # build sig-out/bin/sls
sig build run      # build and run the server
sig build test     # run the full unit-test suite
```

Cross-compile to any supported target from a single host:

```sh
sig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseFast
sig build -Dtarget=aarch64-macos    -Doptimize=ReleaseFast
sig build -Dtarget=aarch64-windows  -Doptimize=ReleaseFast
```

## Platforms

sls's only OS-specific code is the stdio transport, which has a Win32 backend
and a POSIX backend chosen at comptime. Every release is cross-compiled from a
single host and published on the [Releases](https://github.com/SB0LTD/sls/releases)
page.

| Platform | Target triple | Artifact | Status |
|----------|---------------|----------|--------|
| Windows x86_64  | `x86_64-windows`   | `sls-<ver>-x86_64-windows.zip`  | ✅ supported |
| Windows aarch64 | `aarch64-windows`  | `sls-<ver>-aarch64-windows.zip` | ✅ supported |
| Linux x86_64    | `x86_64-linux-gnu` | `sls-<ver>-x86_64-linux.tar.gz`  | ✅ supported |
| Linux aarch64   | `aarch64-linux-gnu`| `sls-<ver>-aarch64-linux.tar.gz` | ✅ supported |
| macOS x86_64    | `x86_64-macos`     | `sls-<ver>-x86_64-macos.tar.gz`  | ✅ supported |
| macOS aarch64   | `aarch64-macos`    | `sls-<ver>-aarch64-macos.tar.gz` | ✅ supported |
| **SB0 native**  | `aarch64-sb0`      | `sls-<ver>-aarch64-sb0.tar.gz` (SB0K) | ✅ bare-metal + userspace |

### SB0 native

sls runs on [SB0](https://github.com/SB0LTD/sig) — our own operating system — in
two forms, both running the **exact same LSP server** as the hosted builds (the
reusable [`@zpm/lsp`](https://github.com/SB0LTD/zpm) modules); only the byte pipe
differs:

1. **Bare-metal SB0K image.** A reset entry (`src/platform/sb0_entry.sig`) brings
   up the PL011 UART and runs the LSP loop over the serial line. The output is a
   valid SB0K container (64-byte `SB0K` header at `0x40200000`, per the Sig
   toolchain's `sb0_runner.ld` contract) that boots directly on QEMU `virt`.

2. **Native userspace process.** Under the [SB0/Nexus kernel](https://github.com/SB0LTD/nexus),
   sls runs at **EL0 as an SB0X process** and does bidirectional stdio through the
   SB0 `channel` syscalls (`channel_send` / `channel_receive` via `svc #0`) — the
   real OS I/O path, not MMIO. The kernel loads the SB0X image, delegates a
   bidirectional console `channel` handle, and the server reads framed requests
   and writes framed responses over it. The userspace app and the kernel-side
   channel syscalls live in the nexus repo (`apps/sls`, merged).

> [!NOTE]
> Both paths are proven in CI. sls's own [SB0 workflow](.github/workflows/sb0.yaml)
> boots the bare-metal SB0K image under QEMU and drives a full LSP session over
> serial. The nexus repo's `sls-userspace` workflow builds the kernel with sls
> embedded, boots it headless under QEMU, and drives a full
> `initialize → documentSymbol → shutdown` session over the channel syscalls —
> asserting the responses. Try the bare-metal path locally:
>
> ```sh
> pwsh scripts/build-sb0.ps1        # or: bash scripts/build-sb0.sh
> bash scripts/sb0-qemu-test.sh sig-out/bin/sls-aarch64-sb0.sb0k
> ```

## Try it — a real LSP session

`scripts/e2e.ps1` is a cross-platform ([PowerShell Core](https://github.com/PowerShell/PowerShell))
driver that spawns the built server, runs a full LSP session over stdio, parses
the `Content-Length` framing, and strictly asserts every response:

```sh
sig build
pwsh scripts/e2e.ps1
```

It opens a document and asks for its symbols. Given this source:

```sig
const std = @import("std");
pub fn main() void {}
pub const Point = struct { x: i32 };
```

sls replies with a `documentSymbol` result locating each declaration:

```jsonc
[
  { "name": "std",   "kind": 14, "range": { "start": { "line": 0, "character": 6  }, ... } }, // Constant
  { "name": "main",  "kind": 12, "range": { "start": { "line": 1, "character": 7  }, ... } }, // Function
  { "name": "Point", "kind": 23, "range": { "start": { "line": 2, "character": 10 }, ... } }  // Struct
]
```

## Editor setup

sls speaks LSP over stdio, so any LSP-capable editor can launch it. Point your
client at the built binary (`sig-out/bin/sls.exe`) and associate it with the
`sig` language. For example, in a Neovim `vim.lsp` config:

```lua
vim.lsp.start({
  name = "sls",
  cmd = { "C:/path/to/sls/sig-out/bin/sls.exe" },
  filetypes = { "sig" },
  root_dir = vim.fs.dirname(vim.fs.find({ "build.sig.zon" }, { upward = true })[1]),
})
```

## Architecture

The reusable LSP core lives in [`@zpm/lsp`](https://github.com/SB0LTD/zpm); sls
is the thin, platform-specific shell that wires a byte pipe to it. Lower layers
never import from higher layers.

```
@zpm/lsp   server   LSP request dispatch, lifecycle, capabilities
@zpm/lsp   loop     shared transport loop (generic over the byte pipe)
@zpm/lsp   message  Content-Length framing + JSON-RPC parse
@zpm/lsp   jwrite   allocator-free JSON writer
@zpm/lsp   document / position / symbols  — pure data + analysis
@zpm       json     shallow JSON scanning
sls        platform/  the byte pipe: Win32/POSIX stdio, or SB0 UART/channel
sls        main.sig   hosted entry — wires stdio to the @zpm/lsp loop
```

One server implementation serves every target. The byte pipe is the only
platform-specific piece: hosted stdio (Win32/POSIX), the bare-metal SB0 UART,
or the SB0 userspace channel syscalls.

## Project layout

```
sls/
├── build.sig            # native sig_build graph; consumes @zpm/lsp by path
├── build.sig.zon        # manifest — declares the ../zpm path dependency
├── scripts/
│   ├── e2e.ps1          # cross-platform end-to-end LSP session driver
│   ├── build-sb0.ps1    # SB0K bare-metal image build (Windows)
│   ├── build-sb0.sh     # SB0K bare-metal image build (Linux/CI)
│   └── sb0-qemu-test.sh # boot the SB0K image under QEMU + drive an LSP session
└── src/
    ├── main.sig             # hosted transport entry — the sole hosted I/O site
    └── platform/
        ├── stdio.sig        # blocking stdio: Win32 + POSIX backends
        ├── sb0_entry.sig    # SB0 bare-metal reset entry + UART transport
        ├── sb0_uart.sig     # PL011 UART driver (QEMU virt)
        └── sb0k.ld          # SB0K bare-metal image linker script
```

The reusable protocol/analysis modules (framing, JSON-RPC, document store,
position math, symbol scanner, dispatch, loop) now live in `@zpm/lsp` and are
unit-tested there; sls consumes them and keeps only the transport shells.

## Design constraints

Every module honors the same rules:

- No allocator — fixed arrays, ring buffers, comptime capacities, and
  caller-provided buffers only.
- No standard-library I/O at runtime — transport is direct OS calls (Win32 on
  Windows, POSIX `read`/`write` elsewhere, UART/channel syscalls on SB0).
- One job per module — reusable protocol logic lives in `@zpm/lsp`; sls holds
  only platform transport.

## Verification

sls is verified at two levels, and both run in CI:

- **Unit tests** (`sig build test`) — allocator-free `test` blocks across every
  module: document store, position/offset math, the symbol scanner, the JSON
  writer, LSP framing (partial frames, multiple messages in one buffer,
  case-insensitive and whitespace-tolerant headers, missing `Content-Length`),
  and the full server dispatch (lifecycle, document sync, `documentSymbol`,
  unknown-method errors, JSON-escape decoding).
- **End-to-end, hosted** (`scripts/e2e.ps1`) — spawns the *actual built binary*,
  drives a complete `initialize → didOpen → documentSymbol → didChange →
  documentSymbol → didClose → shutdown → exit` session over stdio, parses the
  framing, and asserts every response. The [E2E workflow](.github/workflows/e2e.yaml)
  runs this on **Windows, Linux, and macOS** runners, so each release is proven
  to actually run and speak LSP on every hosted OS — not merely to compile.
- **End-to-end, SB0** (`scripts/sb0-qemu-test.sh`) — boots the bare-metal SB0K
  image under **QEMU (`qemu-system-aarch64`)**, drives a full LSP session over
  the serial console, and asserts the responses. The
  [SB0 workflow](.github/workflows/sb0.yaml) runs this on every change, proving
  the language server runs on SB0 (aarch64) too.

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for the release history.

## Credits

sls stands on the shoulders of **[ZLS](https://github.com/zigtools/zls)** and its
contributors, whose architecture and protocol handling are the blueprint for this
project. Thank you.

## License

[MIT](LICENSE) — see [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE). The upstream ZLS
copyright is preserved alongside the sls copyright, as the MIT License requires.
