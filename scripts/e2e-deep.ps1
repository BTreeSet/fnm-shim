# Deep end-to-end test for fnm-shim on Windows.
#
# Mirror of `scripts/e2e-deep.sh`. Drives the shim through real Vite + npx
# workflows that the basic `e2e.ps1` does not cover:
#
#   [A] npm create vite@latest myapp -- --template vanilla
#   [B] npm install (full lifecycle, postinstall scripts)
#   [C] npm run build  (must produce dist/index.html)
#   [D] npx vite --version (local node_modules\.bin entry)
#   [E] npx -y -p typescript@latest tsc --version (remote fetch)
#   [F] Exit-code 42 must propagate through `npm run` end-to-end.
#
# This Windows variant is specifically valuable because it exercises the
# `.cmd` extension resolution path in src/os/exec.rs. A regression there
# (e.g. spawning bare `npm` instead of `npm.cmd`) would manifest here as
# a CreateProcess failure mid-pipeline, even though `npm -v` continues to
# work in the basic e2e.
#
# ISOLATION CAVEAT
# ----------------
# Unprivileged filesystem sandboxing is NOT practical on Windows without
# Hyper-V / Windows Sandbox. This script provides env-var redirection only
# (USERPROFILE / APPDATA / TEMP / etc. all point inside $SandboxRoot), but
# any package that hard-codes absolute paths (C:\Users\..., registry,
# drivers, scheduled tasks) can still touch the host.
#
# By default this script REFUSES to run unless one of the following holds:
#   * Environment variable CI=true (you are on an ephemeral CI runner).
#   * Running inside Windows Sandbox (WDAGUtilityAccount).
#   * `-AllowUnsafe` was passed (operator explicitly accepted the risk).
# Recommended developer flow: run inside Windows Sandbox or a throwaway VM.
#
# GITHUB ACTIONS SECRET HYGIENE
# -----------------------------
# The child process env block is fully cleared via
# `ProcessStartInfo.EnvironmentVariables.Clear()` and re-populated from a
# tight allowlist below. The following GHA-injected variables are
# DELIBERATELY excluded and MUST NOT be added back:
#
#   GITHUB_TOKEN                       (if surfaced as env)
#   ACTIONS_RUNTIME_TOKEN              (artifacts + cache; very dangerous)
#   ACTIONS_RUNTIME_URL
#   ACTIONS_CACHE_URL / _RESULTS_URL
#   ACTIONS_ID_TOKEN_REQUEST_TOKEN     (OIDC; cloud-pivot dangerous)
#   ACTIONS_ID_TOKEN_REQUEST_URL
#   NODE_AUTH_TOKEN / NPM_TOKEN        (npm registry push)
#   RUNNER_TOKEN / RUNNER_*            (runner self-registration)
#
# The workload includes a runtime assertion that none of these vars are
# present inside the sandbox before any third-party code runs.

[CmdletBinding()]
param(
    [switch]$AllowUnsafe
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Log($msg)  { Write-Host "==> $msg" }
function Fail($msg) { Write-Error "FATAL: $msg"; exit 1 }

# --- Safety gate ----------------------------------------------------------
$inCi             = ($Env:CI -eq 'true')
$inWindowsSandbox = ($Env:USERNAME -eq 'WDAGUtilityAccount') -or `
                    (Test-Path 'C:\Users\WDAGUtilityAccount' -ErrorAction SilentlyContinue)
if (-not ($AllowUnsafe -or $inCi -or $inWindowsSandbox)) {
    Fail @"
Refusing to run deep e2e tests on a non-ephemeral Windows host.
`npm install`/`npx` execute arbitrary third-party postinstall scripts;
without Hyper-V isolation those scripts can write anywhere your user can.

Acceptable execution contexts (in order of safety):
  1. Windows Sandbox (WSB)   - strongest, fully throwaway VM
  2. A disposable Hyper-V VM
  3. CI runner (CI=true env)
  4. -AllowUnsafe             - you explicitly accept the risk

Re-run with one of the above set.
"@
}

$Root = (Resolve-Path "$PSScriptRoot\..").Path
Set-Location $Root

Log 'building fnm-shim (release)'
cargo build --release --bin fnm-shim
if ($LASTEXITCODE -ne 0) { Fail 'cargo build failed' }

$Shim = Join-Path $Root 'target\release\fnm-shim.exe'
if (-not (Test-Path $Shim)) { Fail "shim missing: $Shim" }

if (-not (Get-Command fnm -ErrorAction SilentlyContinue)) { Fail 'fnm not on PATH' }

if (-not $Env:FNM_DIR) { $Env:FNM_DIR = Join-Path $Env:APPDATA 'fnm' }
New-Item -ItemType Directory -Force -Path $Env:FNM_DIR | Out-Null
fnm env --use-on-cd --shell powershell | Out-String | Invoke-Expression

# Ensure a default is set on the host before sandboxing.
$DefaultAlias = Join-Path $Env:FNM_DIR 'aliases\default'
if (-not (Test-Path $DefaultAlias)) {
    Log 'no fnm default set; installing 20 and pinning as default'
    fnm install 20
    fnm default 20
}

# Sandbox root (under repo target/ so it is on the same drive as the shim
# — NTFS hardlinks cannot cross volumes).
$SandboxRoot = Join-Path $Root ("target\e2e-deep-" + [Guid]::NewGuid().ToString('N'))
foreach ($sub in @('home', 'work', 'tmp', 'appdata', 'localappdata', 'npm-cache')) {
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $SandboxRoot $sub)
}

# Multicall shim dir (hardlinks, not symlinks — symlinks need admin on Win).
$ShimBin = Join-Path $SandboxRoot 'shim-bin'
$null = New-Item -ItemType Directory -Path $ShimBin
foreach ($name in @('node.exe', 'npm.exe', 'npx.exe')) {
    $null = New-Item -ItemType HardLink -Path (Join-Path $ShimBin $name) -Value $Shim
}

# Workload script — runs as a child PowerShell with a scrubbed env.
$Workload = Join-Path $SandboxRoot 'workload.ps1'
$WorkloadBody = @'
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Step($msg) { Write-Host "---- $msg" }
function Fail($msg) { Write-Error "FAIL: $msg"; exit 1 }

Step 'verifying secret-env scrubbing'
# These MUST NOT survive the ProcessStartInfo allowlist. If any are present,
# the sandbox plumbing has regressed and we refuse to run third-party code.
$forbidden = @(
    'GITHUB_TOKEN', 'ACTIONS_RUNTIME_TOKEN', 'ACTIONS_RUNTIME_URL',
    'ACTIONS_CACHE_URL', 'ACTIONS_RESULTS_URL',
    'ACTIONS_ID_TOKEN_REQUEST_TOKEN', 'ACTIONS_ID_TOKEN_REQUEST_URL',
    'NODE_AUTH_TOKEN', 'NPM_TOKEN', 'RUNNER_TOKEN'
)
foreach ($v in $forbidden) {
    $val = [Environment]::GetEnvironmentVariable($v)
    if (-not [string]::IsNullOrEmpty($val)) {
        Fail "env leak: `$$v is set inside the sandbox"
    }
}
Write-Host '    OK: no CI secret env vars leaked into the sandbox'

Step 'tool versions (via shim)'
node -v
npm -v
npx --version

Step '[A] npm create vite@latest myapp -- --template vanilla'
Set-Location $Env:WORKDIR
npm create --yes vite@latest myapp -- --template vanilla
if ($LASTEXITCODE -ne 0) { Fail "npm create vite failed: $LASTEXITCODE" }
if (-not (Test-Path 'myapp\package.json')) { Fail 'vite scaffold missing package.json' }

Step '[B] npm install'
Set-Location (Join-Path $Env:WORKDIR 'myapp')
npm install
if ($LASTEXITCODE -ne 0) { Fail "npm install failed: $LASTEXITCODE" }

Step '[C] npm run build'
npm run build
if ($LASTEXITCODE -ne 0) { Fail "npm run build failed: $LASTEXITCODE" }
if (-not (Test-Path 'dist\index.html')) { Fail 'dist\index.html missing' }
Write-Host '    OK: dist\index.html produced'

Step '[D] npx vite --version (local bin)'
$viteOut = (& npx vite --version) | Out-String
$viteOut = $viteOut.Trim()
Write-Host "    $viteOut"
if ($viteOut -notmatch '^vite/') { Fail "unexpected npx vite output: $viteOut" }

Step '[E] npx -y -p typescript@latest tsc --version'
Set-Location $Env:WORKDIR
$tscOut = (& npx -y -p typescript@latest tsc --version) | Out-String
$tscOut = $tscOut.Trim()
Write-Host "    $tscOut"
if ($tscOut -notmatch '^Version\s') { Fail "unexpected tsc output: $tscOut" }

Step '[F] exit-code fidelity through npm script'
$ec = Join-Path $Env:WORKDIR 'ec'
$null = New-Item -ItemType Directory -Force -Path $ec
Set-Location $ec
# IMPORTANT: build package.json via ConvertTo-Json rather than a nested
# here-string. PowerShell here-strings cannot nest — an inner `'@` at the
# start of a line would terminate the OUTER here-string that wraps this
# whole workload body, mis-parsing everything that follows.
$pkgObj = [ordered]@{
    name    = 'ec-test'
    version = '0.0.0'
    private = $true
    scripts = [ordered]@{
        boom = 'node -e "process.exit(42)"'
    }
}
$pkgJson = $pkgObj | ConvertTo-Json -Depth 5
Set-Content -Path package.json -Value $pkgJson -Encoding ascii
& npm run boom --silent
$got = $LASTEXITCODE
if ($got -ne 42) { Fail "expected exit 42 through npm script, got $got" }
Write-Host '    OK: exit code 42 preserved end-to-end'

Write-Host ''
Write-Host '==> deep e2e PASSED'
'@
Set-Content -Path $Workload -Value $WorkloadBody -Encoding utf8

# Build the env-scrubbed PATH. fnm itself must remain reachable so node
# binaries under FNM_DIR can be launched by fnm-shim's resolver.
$fnmCmd = Get-Command fnm -ErrorAction Stop
$fnmDir = Split-Path -Parent $fnmCmd.Source

$sandboxPath = @(
    $ShimBin,
    $fnmDir,
    "$Env:SystemRoot\System32",
    "$Env:SystemRoot",
    "$Env:SystemRoot\System32\Wbem",
    "$Env:SystemRoot\System32\WindowsPowerShell\v1.0"
) -join ';'

$childEnv = @{
    'PATH'                       = $sandboxPath
    'PATHEXT'                    = $Env:PATHEXT
    'SystemRoot'                 = $Env:SystemRoot
    'SystemDrive'                = $Env:SystemDrive
    'ComSpec'                    = $Env:ComSpec
    'OS'                         = $Env:OS
    'PROCESSOR_ARCHITECTURE'     = $Env:PROCESSOR_ARCHITECTURE
    'NUMBER_OF_PROCESSORS'       = $Env:NUMBER_OF_PROCESSORS
    'FNM_DIR'                    = $Env:FNM_DIR
    'CI'                         = $Env:CI
    'USERPROFILE'                = (Join-Path $SandboxRoot 'home')
    'HOME'                       = (Join-Path $SandboxRoot 'home')
    'HOMEDRIVE'                  = ($SandboxRoot.Substring(0, 2))
    'HOMEPATH'                   = ((Join-Path $SandboxRoot 'home').Substring(2))
    'APPDATA'                    = (Join-Path $SandboxRoot 'appdata')
    'LOCALAPPDATA'               = (Join-Path $SandboxRoot 'localappdata')
    'TEMP'                       = (Join-Path $SandboxRoot 'tmp')
    'TMP'                        = (Join-Path $SandboxRoot 'tmp')
    'TMPDIR'                     = (Join-Path $SandboxRoot 'tmp')
    'WORKDIR'                    = (Join-Path $SandboxRoot 'work')
    'npm_config_audit'           = 'false'
    'npm_config_fund'            = 'false'
    'npm_config_update_notifier' = 'false'
    'npm_config_loglevel'        = 'warn'
    'npm_config_cache'           = (Join-Path $SandboxRoot 'npm-cache')
    'npm_config_prefix'          = (Join-Path $SandboxRoot 'npm-prefix')
}

# Resolve a PowerShell host: prefer pwsh (cross-edition), fallback to
# Windows PowerShell (powershell.exe) which is always present.
$psHost = Get-Command pwsh -ErrorAction SilentlyContinue
if ($null -eq $psHost) { $psHost = Get-Command powershell -ErrorAction Stop }

# Launch via ProcessStartInfo so we can fully replace the env block.
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $psHost.Source
$psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$Workload`""
$psi.UseShellExecute = $false
$psi.WorkingDirectory = (Join-Path $SandboxRoot 'work')

$psi.EnvironmentVariables.Clear()
foreach ($k in $childEnv.Keys) {
    if ($null -ne $childEnv[$k]) {
        $psi.EnvironmentVariables[$k] = [string]$childEnv[$k]
    }
}

$proc = [System.Diagnostics.Process]::Start($psi)
$proc.WaitForExit()
$code = $proc.ExitCode

# Best-effort cleanup; don't shadow the workload's exit code.
try { Remove-Item -Recurse -Force $SandboxRoot -ErrorAction SilentlyContinue } catch {}

if ($code -ne 0) { Fail "deep e2e workload exited $code" }
Log 'ALL DEEP E2E STEPS PASSED'
