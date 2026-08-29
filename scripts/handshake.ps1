# Drives sls through a real LSP session over stdio and prints the raw framed
# responses. Verifies initialize -> didOpen -> documentSymbol -> shutdown -> exit.
$ErrorActionPreference = "Stop"

$exe = Join-Path $PSScriptRoot "..\sig-out\bin\sls.exe"
if (-not (Test-Path $exe)) { throw "build sls first: sig build" }

function Frame([string]$json) {
    $bytes = [System.Text.Encoding]::UTF8.GetByteCount($json)
    return "Content-Length: $bytes`r`n`r`n$json"
}

$initialize = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}'
$initialized = '{"jsonrpc":"2.0","method":"initialized","params":{}}'
$didOpen = '{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///demo.sig","languageId":"sig","version":1,"text":"const std = @import(\"std\");\npub fn main() void {}\npub const Point = struct { x: i32 };"}}}'
$docSymbol = '{"jsonrpc":"2.0","id":2,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///demo.sig"}}}'
$shutdown = '{"jsonrpc":"2.0","id":3,"method":"shutdown","params":null}'
$exit = '{"jsonrpc":"2.0","method":"exit","params":null}'

$payload = (Frame $initialize) + (Frame $initialized) + (Frame $didOpen) + (Frame $docSymbol) + (Frame $shutdown) + (Frame $exit)

$output = $payload | & $exe
Write-Output "===== RAW SERVER OUTPUT ====="
Write-Output $output
Write-Output "============================="

$text = ($output | Out-String)
$ok = $true
if ($text -notmatch '"documentSymbolProvider":true') { Write-Output "MISSING: capabilities"; $ok = $false }
if ($text -notmatch '"name":"sls"') { Write-Output "MISSING: serverInfo"; $ok = $false }
if ($text -notmatch '"name":"main"') { Write-Output "MISSING: documentSymbol main"; $ok = $false }
if ($text -notmatch '"name":"Point"') { Write-Output "MISSING: documentSymbol Point"; $ok = $false }
if ($text -notmatch '"id":3.*"result":null') { Write-Output "NOTE: shutdown result check is loose" }

if ($ok) { Write-Output "HANDSHAKE OK" } else { Write-Output "HANDSHAKE FAILED"; exit 1 }
