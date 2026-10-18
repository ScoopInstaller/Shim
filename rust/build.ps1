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

# The version file is the source of truth; Cargo.toml stores the package version separately.
$verFile = Join-Path $PSScriptRoot 'version'
$ver = (Get-Content $verFile -Raw).Trim()
if ($ver -notmatch '^\d+(\.\d+){0,3}$') {
  throw "Invalid version '$ver' in $verFile (expected N[.N[.N[.N]]])"
}
$toml = Get-Content (Join-Path $PSScriptRoot 'Cargo.toml') -Raw
# Match inside the [package] section only; a dependency's version line must not satisfy this.
$pkg = [regex]::Match($toml, '(?ms)^\[package\][^\n]*\n(.*?)(?=^\[|\z)')
if (-not $pkg.Success) { throw "Cargo.toml has no [package] section" }
if ($pkg.Groups[1].Value -notmatch '(?m)^\s*version\s*=\s*"' + [regex]::Escape($ver) + '"\s*$') {
  throw "Cargo.toml [package] version does not match version file ($ver). Update Cargo.toml."
}

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
  # cargo keeps a cache-hit artifact's mtime, so creation time proves this run produced it.
  if ((Get-Item $exe).CreationTime -lt $buildStart) { throw "Stale output: $exe was not rebuilt by this run" }
}

# Clean bin, build
$binDir = Join-Path $PSScriptRoot 'bin'
# Clean only the target's own output directory so sibling architectures survive.
if ($Target) {
  $targetDir = Join-Path $binDir $Target
  if (Test-Path $targetDir) { Remove-Item -Path $targetDir -Recurse -Force }
} elseif (Test-Path $binDir) {
  Remove-Item -Path $binDir -Recurse -Force
}
$buildStart = Get-Date

if ($Target) { Invoke-Build $Target }
else { foreach ($t in @('x86', 'x64', 'arm64')) { Invoke-Build $t } }

Write-Host "Done: $binDir" -ForegroundColor Green
