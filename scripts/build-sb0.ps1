#!/usr/bin/env pwsh
# Windows/native build of the SB0K bare-metal image (mirror of build-sb0.sh).
# Usage: pwsh scripts/build-sb0.ps1 [-Out <path>]
param([string]$Out = "sig-out/bin/sls-aarch64-sb0.sb0k")

$ErrorActionPreference = "Stop"
$here = Split-Path $PSScriptRoot -Parent
$ld = Join-Path $here "src/platform/sb0k.ld"
$zpm = Join-Path $here "../zpm/src/core"
$outDir = Split-Path $Out -Parent
if (-not $outDir) { $outDir = "." }
$raw = Join-Path $outDir "sls_sb0k_raw"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
Remove-Item $raw, $Out -ErrorAction SilentlyContinue

$a = @(
  "build-exe","-target","aarch64-sb0","-mcpu=baseline","-OReleaseSmall",
  "-fno-stack-check","-fno-stack-protector","-fno-unwind-tables","-fstrip","-ffunction-sections",
  "--script","$ld",
  "--dep","uart","--dep","loop","--dep","server","-Mroot=$here/src/platform/sb0_entry.sig",
  "-Mjson=$zpm/json.sig",
  "-Mjwrite=$here/src/lsp/jwrite.sig",
  "-Mdocument=$here/src/core/document.sig",
  "-Mposition=$here/src/core/position.sig",
  "-Msymbols=$here/src/core/symbols.sig",
  "-Muart=$here/src/platform/sb0_uart.sig",
  "--dep","json","-Mmessage=$here/src/lsp/message.sig",
  "--dep","json","--dep","message","--dep","jwrite","--dep","document","--dep","position","--dep","symbols","-Mserver=$here/src/server/server.sig",
  "--dep","message","--dep","server","-Mloop=$here/src/lsp/loop.sig",
  "-femit-bin=$raw"
)
& sig @a
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $raw)) { throw "SB0K build failed" }
$bytes = [System.IO.File]::ReadAllBytes((Resolve-Path $raw))
$magic = ($bytes[0..3] | ForEach-Object { $_.ToString('x2') }) -join ''
if ($magic -ne '5342304b') { throw "not an SB0K image (magic $magic)" }
Move-Item -Force $raw $Out
Write-Host "SB0K native image produced: $Out ($($bytes.Length) bytes, magic SB0K)"
