# SDL2 公式配布物（devel-VC パッケージ）から SDL2.dll/SDL2.lib を取得し、
# build/sdl2/windows-<arch>/lib/ にキャッシュする。scripts/build_win.ps1 --release から呼ばれる。
#
# Windows は SDL2 公式配布物に静的アーカイブが無く動的ライブラリ(SDL2.dll)のみのため、
# macOS/Linux/FreeBSD（ソースから静的ビルド）とは異なりここでは公式ビルド済みパッケージを
# そのまま使う。配布物は bbl.exe と SDL2.dll を同梱する形になる
# （BluePrint 2026-07-16 追記、ユーザー承認。docs/dev/BluePrint.md「静的リンク」節の例外）。

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("x86", "x64")]
    [string]$Architecture
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir

# バージョンをピン止め（https://github.com/libsdl-org/SDL/releases/tag/release-2.32.10）。
$Sdl2Version = "2.32.10"
$Sdl2Url = "https://github.com/libsdl-org/SDL/releases/download/release-$Sdl2Version/SDL2-devel-$Sdl2Version-VC.zip"

$CacheDir = Join-Path $ProjectRoot "build\sdl2\windows-$Architecture"
$DownloadDir = Join-Path $ProjectRoot "build\sdl2\src"
$ZipPath = Join-Path $DownloadDir "SDL2-devel-$Sdl2Version-VC.zip"
# devel-VC パッケージの ZIP はトップレベルに SDL2-<version>/ を含むため、
# $DownloadDir 直下に展開すればそのまま SDL2-<version>/lib/<x86|x64>/ が現れる
# （余分な親フォルダは無い。実機確認済み: Expand-Archive でこのレイアウトになる）。
$ExtractedDir = Join-Path $DownloadDir "SDL2-$Sdl2Version"

if ((Test-Path (Join-Path $CacheDir "lib\SDL2.dll")) -and (Test-Path (Join-Path $CacheDir "lib\SDL2.lib"))) {
    Write-Host "fetch_sdl2_windows.ps1: キャッシュ済み、スキップ: $CacheDir"
    exit 0
}

New-Item -ItemType Directory -Force -Path $DownloadDir | Out-Null

if (-not (Test-Path $ZipPath)) {
    Write-Host "fetch_sdl2_windows.ps1: SDL2 $Sdl2Version (VC devel) を取得中..."
    Invoke-WebRequest -Uri $Sdl2Url -OutFile $ZipPath
}

if (-not (Test-Path $ExtractedDir)) {
    Expand-Archive -Path $ZipPath -DestinationPath $DownloadDir -Force
}

$SrcLibDir = Join-Path $ExtractedDir "lib\$Architecture"
if (-not (Test-Path $SrcLibDir)) {
    Write-Host "fetch_sdl2_windows.ps1: Error: $SrcLibDir が見つかりません（VC devel パッケージのレイアウトが変わった可能性）"
    exit 1
}

New-Item -ItemType Directory -Force -Path (Join-Path $CacheDir "lib") | Out-Null
Copy-Item -Force (Join-Path $SrcLibDir "SDL2.dll") (Join-Path $CacheDir "lib\SDL2.dll")
Copy-Item -Force (Join-Path $SrcLibDir "SDL2.lib") (Join-Path $CacheDir "lib\SDL2.lib")
Copy-Item -Force (Join-Path $SrcLibDir "SDL2main.lib") (Join-Path $CacheDir "lib\SDL2main.lib")

Write-Host "fetch_sdl2_windows.ps1: 完了: $CacheDir\lib\SDL2.dll / SDL2.lib"
