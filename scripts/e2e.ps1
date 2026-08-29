#!/usr/bin/env pwsh
# Cross-platform end-to-end LSP conformance test for sls.
#
# Runs on PowerShell Core (pwsh) on Windows, Linux, and macOS. Spawns the real
# built sls binary, drives a full LSP session over stdio, parses the
# Content-Length framing, and strictly asserts every response. Exits non-zero on
# any failure so CI fails loudly.
#
# Usage: pwsh scripts/e2e.ps1 [-Exe <path-to-sls>]
[CmdletBinding()]
param(
    [string]$Exe
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# ── Locate the built binary ──────────────────────────────────────────────────
$root = Split-Path $PSScriptRoot -Parent
if (-not $Exe) {
    # Prefer the platform-native binary name.
    if ($IsWindows) {
        $candidates = @((Join-Path $root "sig-out/bin/sls.exe"), (Join-Path $root "sig-out/bin/sls"))
    } else {
        $candidates = @((Join-Path $root "sig-out/bin/sls"), (Join-Path $root "sig-out/bin/sls.exe"))
    }
    $Exe = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $Exe -or -not (Test-Path $Exe)) {
    Write-Error "sls binary not found (looked in sig-out/bin). Build first: sig build"
    exit 1
}
Write-Host "e2e: driving $Exe"

# ── LSP framing helpers ──────────────────────────────────────────────────────
function New-Frame([string]$json) {
    $len = [System.Text.Encoding]::UTF8.GetByteCount($json)
    return "Content-Length: $len`r`n`r`n$json"
}

# Parse a raw byte string into a list of JSON bodies by walking Content-Length
# headers (does not rely on regex or pretty-printing).
function Read-Frames([byte[]]$bytes) {
    $bodies = New-Object System.Collections.Generic.List[string]
    $ascii = [System.Text.Encoding]::ASCII
    $pos = 0
    while ($pos -lt $bytes.Length) {
        # Find header terminator \r\n\r\n starting at $pos.
        $sep = -1
        for ($i = $pos; $i -le $bytes.Length - 4; $i++) {
            if ($bytes[$i] -eq 13 -and $bytes[$i+1] -eq 10 -and $bytes[$i+2] -eq 13 -and $bytes[$i+3] -eq 10) { $sep = $i; break }
        }
        if ($sep -lt 0) { break }
        $header = $ascii.GetString($bytes, $pos, $sep - $pos)
        $len = 0
        foreach ($line in ($header -split "`r`n")) {
            if ($line -match '(?i)^content-length:\s*(\d+)\s*$') { $len = [int]$Matches[1] }
        }
        $bodyStart = $sep + 4
        if ($len -le 0 -or $bodyStart + $len -gt $bytes.Length) { break }
        $bodies.Add([System.Text.Encoding]::UTF8.GetString($bytes, $bodyStart, $len)) | Out-Null
        $pos = $bodyStart + $len
    }
    return $bodies
}

# ── Build the session ────────────────────────────────────────────────────────
$srcText = 'const std = @import(\"std\");\npub fn main() void {}\npub const Point = struct { x: i32 };\nvar counter: u32 = 0;'
$messages = @(
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}',
    '{"jsonrpc":"2.0","method":"initialized","params":{}}',
    ('{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///demo.sig","languageId":"sig","version":1,"text":"' + $srcText + '"}}}'),
    '{"jsonrpc":"2.0","id":2,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///demo.sig"}}}',
    '{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///demo.sig","version":2},"contentChanges":[{"text":"pub fn changed() void {}"}]}}',
    '{"jsonrpc":"2.0","id":3,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///demo.sig"}}}',
    '{"jsonrpc":"2.0","method":"textDocument/didClose","params":{"textDocument":{"uri":"file:///demo.sig"}}}',
    '{"jsonrpc":"2.0","id":4,"method":"shutdown","params":null}',
    '{"jsonrpc":"2.0","method":"exit","params":null}'
)
$payload = ($messages | ForEach-Object { New-Frame $_ }) -join ""

# ── Run the server, capturing raw stdout bytes ───────────────────────────────
$psi = [System.Diagnostics.ProcessStartInfo]::new()
$psi.FileName = $Exe
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.UseShellExecute = $false
$psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8

$proc = [System.Diagnostics.Process]::Start($psi)
$inBytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
$proc.StandardInput.BaseStream.Write($inBytes, 0, $inBytes.Length)
$proc.StandardInput.BaseStream.Flush()
$proc.StandardInput.Close()

$outText = $proc.StandardOutput.ReadToEnd()
if (-not $proc.WaitForExit(10000)) { $proc.Kill(); Write-Error "sls did not exit within 10s"; exit 1 }

$outBytes = [System.Text.Encoding]::UTF8.GetBytes($outText)
$frames = Read-Frames $outBytes

# ── Assertions ───────────────────────────────────────────────────────────────
$failures = New-Object System.Collections.Generic.List[string]
function Check([bool]$cond, [string]$msg) { if (-not $cond) { $failures.Add($msg) | Out-Null } else { Write-Host "  ok: $msg" } }

Write-Host "e2e: received $($frames.Count) framed responses"
Check ($frames.Count -ge 4) "at least 4 framed responses (initialize, 2x documentSymbol, shutdown)"

# Index responses by id where present.
$byId = @{}
foreach ($f in $frames) {
    if ($f -match '"id"\s*:\s*(\d+)') { $byId[[int]$Matches[1]] = $f }
}

# initialize (id 1)
$init = if ($byId.ContainsKey(1)) { $byId[1] } else { "" }
Check ($init -match '"documentSymbolProvider"\s*:\s*true') "initialize advertises documentSymbolProvider"
Check ($init -match '"textDocumentSync"\s*:\s*1') "initialize advertises full textDocumentSync"
Check ($init -match '"name"\s*:\s*"sls"') "initialize serverInfo.name is sls"
Check ($init -match '"version"\s*:\s*"\d+\.\d+\.\d+"') "initialize serverInfo.version is semver"

# documentSymbol #1 (id 2): full outline of the opened document
$ds1 = if ($byId.ContainsKey(2)) { $byId[2] } else { "" }
Check ($ds1 -match '"name":"std"')     "documentSymbol includes std"
Check ($ds1 -match '"name":"main"')    "documentSymbol includes main"
Check ($ds1 -match '"name":"Point"')   "documentSymbol includes Point"
Check ($ds1 -match '"name":"counter"') "documentSymbol includes counter"
Check ($ds1 -match '"kind":12')        "documentSymbol has a Function kind"
Check ($ds1 -match '"kind":23')        "documentSymbol has a Struct kind"
Check ($ds1 -match '"line":1')         "documentSymbol carries line positions"

# documentSymbol #2 (id 3): after didChange full-sync, only 'changed' remains
$ds2 = if ($byId.ContainsKey(3)) { $byId[3] } else { "" }
Check ($ds2 -match '"name":"changed"') "documentSymbol reflects didChange (changed present)"
Check ($ds2 -notmatch '"name":"Point"') "documentSymbol reflects didChange (Point gone)"

# shutdown (id 4)
$sd = if ($byId.ContainsKey(4)) { $byId[4] } else { "" }
Check ($sd -match '"result"\s*:\s*null') "shutdown returns result:null"

# clean process exit
Check ($proc.ExitCode -eq 0) "server exited cleanly after 'exit' (code $($proc.ExitCode))"

# ── Verdict ──────────────────────────────────────────────────────────────────
if ($failures.Count -gt 0) {
    Write-Host ""
    Write-Host "E2E FAILED ($($failures.Count) checks):" -ForegroundColor Red
    foreach ($m in $failures) { Write-Host "  FAIL: $m" -ForegroundColor Red }
    Write-Host ""
    Write-Host "----- raw server output -----"
    Write-Host $outText
    exit 1
}
Write-Host ""
Write-Host "E2E OK — sls language server verified on $([System.Runtime.InteropServices.RuntimeInformation]::OSDescription)" -ForegroundColor Green
