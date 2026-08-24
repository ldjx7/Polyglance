# Build Polyglance Rust C-ABI core library for Windows
$ErrorActionPreference = "Stop"

Write-Host "==> Compiling polyglance-cabi Rust DLL..." -ForegroundColor Cyan
cargo build --release -p polyglance-cabi

$targetDll = "target/release/polyglance_cabi.dll"
if (-not (Test-Path $targetDll)) {
    $targetDll = "target/x86_64-pc-windows-msvc/release/polyglance_cabi.dll"
}

Write-Host "==> Polyglance C-ABI core built successfully." -ForegroundColor Green
