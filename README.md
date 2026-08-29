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
  <img src="https://img.shields.io/badge/platform-windows-6b7280?style=flat-square" alt="Platform: Windows" />
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
  stdio, read and written through direct Win32 `ReadFile`/`WriteFile` calls.
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

## Try it — a real LSP session

`scripts/handshake.ps1` drives the server through a full session over stdio and
verifies the responses:

```powershell
sig build
pwsh scripts/handshake.ps1
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

sls is layered; lower layers never import from higher layers.

```
Layer 2  server/     LSP request dispatch, lifecycle, capabilities
Layer 1  lsp/        JSON-RPC framing, message parsing, JSON emitting
Layer 1  platform/   raw Win32 stdio transport
Layer 1  (zpm)       json scanning (and more as features land)
Layer 0  core/       pure data — document store, position math, symbol scanner
```

State flows down (the server owns the document store and passes text into pure
analysis functions); events flow up (framed stdin bytes become parsed messages,
which the dispatcher turns into framed responses).

## Project layout

```
sls/
├── build.sig            # native sig_build graph; wires zpm by path
├── build.sig.zon        # manifest — declares the ../zpm path dependency
├── scripts/
│   └── handshake.ps1    # end-to-end LSP session driver
└── src/
    ├── main.sig             # transport loop — the sole I/O site
    ├── platform/
    │   └── stdio.sig        # blocking stdio over Win32 ReadFile/WriteFile
    ├── lsp/
    │   ├── message.sig      # Content-Length framing + JSON-RPC parsing
    │   └── jwrite.sig       # allocator-free JSON writer
    ├── core/
    │   ├── document.sig     # fixed-slot document store
    │   ├── position.sig     # UTF-16 line/character ↔ byte-offset math
    │   └── symbols.sig      # Sig declaration scanner
    └── server/
        └── server.sig       # request dispatch + lifecycle
```

## Design constraints

Every module in `src/` honors the same rules:

- No allocator — fixed arrays, ring buffers, comptime capacities, and
  caller-provided buffers only.
- No standard-library I/O at runtime — transport is pure Win32.
- One job per module — the parser does not do I/O; the drawer of bytes does not
  parse; pure logic lives in `core/`.
- Every module with logic carries inline `test` blocks, run by `sig build test`.

## Credits

sls stands on the shoulders of **[ZLS](https://github.com/zigtools/zls)** and its
contributors, whose architecture and protocol handling are the blueprint for this
project. Thank you.

## License

[MIT](LICENSE) — see [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE). The upstream ZLS
copyright is preserved alongside the sls copyright, as the MIT License requires.
