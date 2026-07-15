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
$Release = $false
$Architecture = "x64"

$i = 0
while ($i -lt $args.Length) {
    $arg = $args[$i]
    switch ($arg) {
        "--debug" { $Debug = $true }
        "--test"  { $RunTest = $true }
        "--release" { $Release = $true }
        "-Architecture" {
            $i++
            if ($i -ge $args.Length) {
                Write-Host "Error: -Architecture には値が必要です (x86|x64|arm64)"
                exit 1
            }
            $Architecture = $args[$i]
        }
        default {
            Write-Host "Error: 不明な引数です: $arg"
            exit 1
        }
    }
    $i++
}

if ($Architecture -notin @("x86", "x64", "arm64")) {
    Write-Host "Error: -Architecture は x86|x64|arm64 のいずれかです（検出: $Architecture）"
    exit 1
}

# アーキテクチャ名 → odin -target 文字列。
$OdinTarget = switch ($Architecture) {
    "x86" { "windows_i386" }
    "x64" { "windows_amd64" }
    "arm64" {
        # 2026-07 時点で mise.toml に固定した Odin (dev-2026-07) は windows_arm64
        # target を持たない（`odin build <pkg> -target:"?"` の一覧で確認済み。
        # darwin_amd64/arm64, linux_*, windows_i386/amd64, freebsd_* はあるが
        # windows_arm64 はない）。Odin が対応するまでこの組み合わせはビルド不可。
        # phase-10-cicd.md T10-4 の検証ログに記録（🔴）。
        Write-Host "Error: 現在の Odin (dev-2026-07) は windows_arm64 target 未対応です。BluePrint の対応表の見直しが必要か、Odin の対応を待ってください。"
        exit 1
    }
}

$BuildFlags = @("-collection:bbl=src", "-out:bbl.exe", "-target:$OdinTarget")
if ($Debug) { $BuildFlags += "-debug" } else { $BuildFlags += "-o:speed" }

if ($Release) {
    # 配布用: SDL2 を静的リンクする（architecture.md「開発=動的/配布=静的」の二段構え）。
    # 未検証（この開発環境は macOS であり MSVC/Windows を実行できない。
    # phase-10-cicd.md T10-4 の検証ログ参照）。
    & "$ScriptDir\build_sdl2_static.ps1" -Architecture $Architecture
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    $Sdl2Dir = Join-Path $ProjectRoot "build\sdl2\windows-$Architecture"
    $Sdl2StaticLib = Join-Path $Sdl2Dir "lib\SDL2-static.lib"
    if (-not (Test-Path $Sdl2StaticLib)) {
        Write-Host "Error: 静的 SDL2 のビルドに失敗しました: $Sdl2StaticLib が見つかりません"
        exit 1
    }

    # vendor:sdl2 の `foreign import lib "SDL2.lib"`（変更不可）をそのまま満たすため、
    # SDL2-static.lib を SDL2.lib という名前でコピーし、そのディレクトリだけを
    # /LIBPATH に通す（他に SDL2.lib が存在しない前提のディレクトリなので曖昧さがない）。
    $Sdl2LibAlias = Join-Path $Sdl2Dir "lib\SDL2.lib"
    Copy-Item -Force $Sdl2StaticLib $Sdl2LibAlias

    # SDL2 が依存する Windows API 群（SDL2 wiki: README-cmake / static linking 節）。
    $ExtraLinkerFlags = "/LIBPATH:`"$Sdl2Dir\lib`" winmm.lib imm32.lib version.lib setupapi.lib " +
        "ole32.lib oleaut32.lib gdi32.lib user32.lib advapi32.lib shell32.lib uuid.lib"
    $BuildFlags += "-extra-linker-flags:$ExtraLinkerFlags"
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
