#Requires -Version 7

<#
.SYNOPSIS
    Build shim.exe using dotnet publish.
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

$ridMap = @{ 'x86' = 'win-x86'; 'x64' = 'win-x64'; 'arm64' = 'win-arm64' }

# Generate AssemblyInfo.cs with VERSIONINFO-compatible attributes
# (omits AssemblyTitle so FileDescription stays empty, matching cpp/zig/rust)
function New-AssemblyInfo {
  $verFile = Join-Path $PSScriptRoot 'version'
  $outDir  = Join-Path $PSScriptRoot 'Properties'
  $outFile = Join-Path $outDir 'AssemblyInfo.cs'
  $ver     = (Get-Content $verFile).Trim()

  New-Item -ItemType Directory -Force -Path $outDir | Out-Null

  $content = @"
using System.Reflection;

[assembly: AssemblyVersion("$ver")]
[assembly: AssemblyFileVersion("$ver")]
[assembly: AssemblyInformationalVersion("$ver")]
[assembly: AssemblyCompany("Scoop contributors")]
[assembly: AssemblyProduct("Scoop Shim Ex")]
[assembly: AssemblyCopyright("Copyright (c) 2013-present Scoop contributors")]

"@
  Set-Content -Path $outFile -Value $content -Encoding ASCII
  Write-Host "Generated AssemblyInfo.cs (version $ver)" -ForegroundColor DarkGray
}

function Invoke-Build {
  param([string]$Target)

  New-AssemblyInfo

  $rid = $ridMap[$Target]
  Write-Host "Publishing shim for $Target ($rid, $Configuration)..." -ForegroundColor Cyan
  & dotnet publish (Join-Path $PSScriptRoot 'shim.csproj') -c $Configuration -r $rid --self-contained false --nologo "-p:PublishDir=bin\$Target"
  if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed" }
  $exe = Join-Path $PSScriptRoot "bin\$Target\shim.exe"
  if (-not (Test-Path $exe)) { throw "Output not found: $exe" }
}

# Clean bin, build
$binDir = Join-Path $PSScriptRoot 'bin'
Remove-Item -Path $binDir -Recurse -Force -ErrorAction SilentlyContinue

if ($Target) { Invoke-Build $Target }
else { foreach ($t in @('x86', 'x64', 'arm64')) { Invoke-Build $t } }

# Cleanup generated AssemblyInfo.cs
Remove-Item -Path (Join-Path $PSScriptRoot 'Properties\AssemblyInfo.cs') -ErrorAction SilentlyContinue

Write-Host "Done: $binDir" -ForegroundColor Green