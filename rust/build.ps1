#Requires -Version 7

<#
.SYNOPSIS
    Build shim.exe using cargo.
.PARAMETER Target
    Target architecture: x86, x64, arm64. Default: all.
.PARAMETER Configuration
    Build configuration: Debug, Release. Default: Release.
#>
param(
  [ValidateSet('x86', 'x64', 'arm64')]
  [string] $Target,
  [ValidateSet('Debug', 'Release')]
  [string] $Configuration = 'Release'
)

$ErrorActionPreference = 'Stop'

$targetMap = @{
  'x86'   = 'i686-pc-windows-msvc'
  'x64'   = 'x86_64-pc-windows-msvc'
  'arm64' = 'aarch64-pc-windows-msvc'
}

function Invoke-Build {
  param([string]$Target)

  $rustTarget = $targetMap[$Target]
  Write-Host "Cargo: $rustTarget ($Configuration)" -ForegroundColor Cyan

  Push-Location $PSScriptRoot
  try {
    if ($Configuration -eq 'Release') {
      & cargo build --release --target $rustTarget
    } else {
      & cargo build --target $rustTarget
    }
    if ($LASTEXITCODE -ne 0) { throw "cargo build failed" }
  }
  finally { Pop-Location }

  $profile = if ($Configuration -eq 'Release') { 'release' } else { 'debug' }
  $src = Join-Path $PSScriptRoot "target\$rustTarget\$profile\shim.exe"
  if (-not (Test-Path $src)) { throw "Output not found: $src" }

  $dstDir = Join-Path $PSScriptRoot "bin\$Target"
  New-Item -ItemType Directory -Force -Path $dstDir | Out-Null
  Copy-Item $src (Join-Path $dstDir 'shim.exe') -Force

  $exe = Join-Path $dstDir 'shim.exe'
  if (-not (Test-Path $exe)) { throw "Copy failed: $exe" }
}

# Clean bin, build
$binDir = Join-Path $PSScriptRoot 'bin'
Remove-Item -Path $binDir -Recurse -Force -ErrorAction SilentlyContinue

if ($Target) { Invoke-Build $Target }
else { foreach ($t in @('x86', 'x64', 'arm64')) { Invoke-Build $t } }

Write-Host "Done: $binDir" -ForegroundColor Green
