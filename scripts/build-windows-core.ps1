# Build Polyglance Rust C-ABI core library for Windows
$ErrorActionPreference = "Continue"

Write-Host "==> Compiling polyglance-cabi Rust DLL..." -ForegroundColor Cyan
cmd.exe /c "cargo build --release -p polyglance-cabi 2>&1" | Write-Host

$targetDll = "target/release/polyglance_cabi.dll"
if (-not (Test-Path $targetDll)) {
    $targetDll = "target/x86_64-pc-windows-msvc/release/polyglance_cabi.dll"
}

Write-Host "==> Polyglance C-ABI core built successfully." -ForegroundColor Green
