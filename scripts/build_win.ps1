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
    # 配布用: SDL2 公式配布物(devel-VC パッケージ)の SDL2.dll/SDL2.lib を使う。
    # Windows は SDL2 公式配布物に静的アーカイブが無いため、macOS/Linux/FreeBSD
    # （ソースから静的ビルド）とは異なりここだけ動的リンクになる。bbl.exe と
    # 同じフォルダに SDL2.dll を同梱して配布する
    # （BluePrint 2026-07-16 追記、ユーザー承認。docs/dev/BluePrint.md 参照）。
    & "$ScriptDir\fetch_sdl2_windows.ps1" -Architecture $Architecture
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    $Sdl2Dir = Join-Path $ProjectRoot "build\sdl2\windows-$Architecture"
    $Sdl2Dll = Join-Path $Sdl2Dir "lib\SDL2.dll"
    $Sdl2Lib = Join-Path $Sdl2Dir "lib\SDL2.lib"
    if (-not (Test-Path $Sdl2Lib)) {
        Write-Host "Error: SDL2 の取得に失敗しました: $Sdl2Lib が見つかりません"
        exit 1
    }

    # vendor:sdl2 の `foreign import lib "SDL2.lib"`（変更不可）を、公式パッケージ
    # 同梱の動的インポートライブラリへ向ける（/LIBPATH 経由。このディレクトリには
    # 他に SDL2.lib が存在しない前提なので曖昧さがない）。
    $BuildFlags += "-extra-linker-flags:/LIBPATH:`"$Sdl2Dir\lib`""
}

Write-Host "=== BubiBoyLite Windows build ==="
Write-Host "odin build src/app $($BuildFlags -join ' ')"
& odin build src/app @BuildFlags
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

if ($Release) {
    # 動的リンクのため SDL2.dll を bbl.exe と同じフォルダへ同梱する（$Sdl2Dll は
    # 上の $Release ブロックで設定済み）。
    Copy-Item -Force $Sdl2Dll (Join-Path $ProjectRoot "SDL2.dll")
}

if ($RunTest) {
    Write-Host "=== odin test tests ==="
    & odin test tests -collection:bbl=src
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

Write-Host "Build complete: $ProjectRoot\bbl.exe"
