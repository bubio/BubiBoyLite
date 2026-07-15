# SDL2 をソースから静的ビルドし、build/sdl2/windows-<arch>/ にキャッシュする。
# scripts/build_win.ps1 --release から呼ばれる。
# 未検証（このプロジェクトの開発環境は macOS で、Windows/MSVC を実行できない。
# phase-10-cicd.md T10-4 の検証ログ参照）。

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("x86", "x64")]
    [string]$Architecture
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir

# バージョンをピン止め（scripts/build_sdl2_static.sh と同じ SDL2 リリース）。
$Sdl2Version = "2.30.9"
$Sdl2Url = "https://github.com/libsdl-org/SDL/releases/download/release-$Sdl2Version/SDL2-$Sdl2Version.tar.gz"

$CacheDir = Join-Path $ProjectRoot "build\sdl2\windows-$Architecture"
$SrcRoot = Join-Path $ProjectRoot "build\sdl2\src"
$SrcDir = Join-Path $SrcRoot "SDL2-$Sdl2Version"
$BuildDir = Join-Path $ProjectRoot "build\sdl2\build-windows-$Architecture"

if (Test-Path (Join-Path $CacheDir "lib\SDL2-static.lib")) {
    Write-Host "build_sdl2_static.ps1: キャッシュ済み、スキップ: $CacheDir"
    exit 0
}

New-Item -ItemType Directory -Force -Path $SrcRoot | Out-Null

if (-not (Test-Path $SrcDir)) {
    $Tarball = Join-Path $SrcRoot "SDL2-$Sdl2Version.tar.gz"
    if (-not (Test-Path $Tarball)) {
        Write-Host "build_sdl2_static.ps1: SDL2 $Sdl2Version を取得中..."
        Invoke-WebRequest -Uri $Sdl2Url -OutFile $Tarball
    }
    tar -xzf $Tarball -C $SrcRoot
}

if (Test-Path $BuildDir) {
    Remove-Item -Recurse -Force $BuildDir
}
New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null

$CmakeArch = if ($Architecture -eq "x86") { "Win32" } else { "x64" }

Write-Host "build_sdl2_static.ps1: cmake configure (windows/$Architecture, -A $CmakeArch)"
# -DSDL_FORCE_STATIC_VCRT=ON: MSVC ランタイムも静的リンクし、配布物が
# vcruntime*.dll に依存しないようにする（BluePrint「単一実行ファイル」要件）。
cmake -S $SrcDir -B $BuildDir -A $CmakeArch `
    -DCMAKE_INSTALL_PREFIX="$CacheDir" `
    -DSDL_STATIC=ON `
    -DSDL_SHARED=OFF `
    -DSDL_TEST=OFF `
    -DSDL_FORCE_STATIC_VCRT=ON
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "build_sdl2_static.ps1: build"
cmake --build $BuildDir --config Release -j
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "build_sdl2_static.ps1: install -> $CacheDir"
cmake --install $BuildDir --config Release
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

if (-not (Test-Path (Join-Path $CacheDir "lib\SDL2-static.lib"))) {
    Write-Host "build_sdl2_static.ps1: Error: SDL2-static.lib が生成されませんでした"
    exit 1
}

Write-Host "build_sdl2_static.ps1: 完了: $CacheDir\lib\SDL2-static.lib"
