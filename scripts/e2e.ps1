# End-to-end validation of fnm-shim on Windows runners.
# Mirrors scripts/e2e.sh step-for-step using PowerShell + .cmd shims.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = Resolve-Path "$PSScriptRoot\.."
Set-Location $Root

Write-Host "==> Building fnm-shim (release)"
cargo build --release --bin fnm-shim
if ($LASTEXITCODE -ne 0) { throw "cargo build failed" }

$Shim = Join-Path $Root 'target\release\fnm-shim.exe'
if (-not (Test-Path $Shim)) { throw "shim binary missing: $Shim" }

Write-Host "==> Verifying fnm is available"
if (-not (Get-Command fnm -ErrorAction SilentlyContinue)) {
    throw "fnm not on PATH"
}

if (-not $Env:FNM_DIR) {
    $Env:FNM_DIR = Join-Path $Env:APPDATA 'fnm'
}
New-Item -ItemType Directory -Force -Path $Env:FNM_DIR | Out-Null

# Initialize fnm in this PowerShell session.
fnm env --use-on-cd --shell powershell | Out-String | Invoke-Expression

Write-Host "==> fnm install 18 / 20"
fnm install 18
fnm install 20

Write-Host "==> fnm default 18"
fnm default 18

# Clear cache to verify fresh creation path.
$CachePath = Join-Path $Env:TEMP 'fnm-shim-cache.json'
if (Test-Path $CachePath) { Remove-Item $CachePath -Force }

$ShimBin = Join-Path $Root ("target\e2e-shim-bin-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $ShimBin | Out-Null
# Hardlinks on Windows do not require admin and behave like multicall entries.
# IMPORTANT: NTFS hardlinks cannot cross volumes, so $ShimBin MUST live on the
# same drive as $Shim. We anchor it under `target/` to guarantee that — the
# system %TEMP% is frequently on a different drive on GitHub Actions runners
# (workspace on D:, %TEMP% on C:).
New-Item -ItemType HardLink -Path (Join-Path $ShimBin 'node.exe')         -Value $Shim | Out-Null
New-Item -ItemType HardLink -Path (Join-Path $ShimBin 'npm.exe')          -Value $Shim | Out-Null
New-Item -ItemType HardLink -Path (Join-Path $ShimBin 'npx.exe')          -Value $Shim | Out-Null
New-Item -ItemType HardLink -Path (Join-Path $ShimBin 'invalid-shim.exe') -Value $Shim | Out-Null

$Env:PATH = "$ShimBin;$Env:PATH"

Write-Host "==> [3] node -v (expect v18.*)"
$NodeV = & node -v
Write-Host "    got: $NodeV"
if ($NodeV -notmatch '^v18\.') { throw "expected v18.*, got $NodeV" }

Write-Host "==> [4] npm -v"
$NpmV = & npm -v
Write-Host "    got: $NpmV"
if ([string]::IsNullOrWhiteSpace($NpmV)) { throw "empty npm version" }

Write-Host "==> [5] fnm default 20 -> node -v should be v20.*"
fnm default 20
$NodeV2 = & node -v
Write-Host "    got: $NodeV2"
if ($NodeV2 -notmatch '^v20\.') { throw "expected v20.*, got $NodeV2 (cache not invalidated)" }

Write-Host "==> [6] invalid-shim must fail with clear error"
$ErrOut = & (Join-Path $ShimBin 'invalid-shim.exe') 2>&1
$ErrCode = $LASTEXITCODE
Write-Host "    exit=$ErrCode output=$ErrOut"
if ($ErrCode -eq 0) { throw "invalid-shim returned 0" }
if ($ErrOut -notmatch 'unsupported invocation') { throw "missing 'unsupported invocation' message" }

Write-Host "==> ALL E2E STEPS PASSED"
