# BubiBoyLite Windows ビルドスクリプト。
# CI もこのスクリプトを呼ぶ（scripts 以外にビルドコマンドを二重管理しない）。

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
Set-Location $ProjectRoot

if (-not (Get-Command odin -ErrorAction SilentlyContinue)) {
    Write-Host "Error: odin コマンドが見つかりません。'mise install' を実行してください。"
    exit 1
}

$Debug = $false
$RunTest = $false

foreach ($arg in $args) {
    switch ($arg) {
        "--debug" { $Debug = $true }
        "--test"  { $RunTest = $true }
        default {
            Write-Host "Error: 不明な引数です: $arg"
            exit 1
        }
    }
}

if ($Debug) {
    $BuildFlags = @("-collection:bbl=src", "-out:bbl.exe", "-debug")
} else {
    $BuildFlags = @("-collection:bbl=src", "-out:bbl.exe", "-o:speed")
}

Write-Host "=== BubiBoyLite Windows build ==="
Write-Host "odin build src/app $($BuildFlags -join ' ')"
& odin build src/app @BuildFlags
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

if ($RunTest) {
    Write-Host "=== odin test tests ==="
    & odin test tests -collection:bbl=src
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

Write-Host "Build complete: $ProjectRoot\bbl.exe"
