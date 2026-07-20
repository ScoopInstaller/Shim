#Requires -Version 7

<#
.SYNOPSIS
    Build shim.exe using Zig (preferred) or MSBuild.
.PARAMETER Target
    Target architecture: x86, x64, arm64. Default: all.
.PARAMETER Configuration
    Build configuration: Debug, Release. Default: Release.
.PARAMETER Tool
    Build tool: Zig, MSBuild, or Auto (try MSBuild first). Default: Auto.
#>
param(
  [ValidateSet('x86', 'x64', 'arm64')]
  [string] $Target,
  [ValidateSet('Debug', 'Release')]
  [string] $Configuration = 'Release',
  [ValidateSet('Zig', 'MSBuild')]
  [string] $Tool = 'Zig'
)

$ErrorActionPreference = 'Stop'

# --------------------------------------------------------------------------------
# Read version and generate .rc resource file with VERSIONINFO
function New-ShimResourceFile {
  $verFile = Join-Path $PSScriptRoot 'version'
  $rcFile  = Join-Path $PSScriptRoot 'shim.rc'
  $ver     = (Get-Content $verFile).Trim()
  $parts   = $ver.Split('.')
  while ($parts.Count -lt 4) { $parts += '0' }
  $v1, $v2, $v3, $v4 = $parts

  $rc = @"
#define VS_VERSION_INFO     1
#define VS_FFI_FILEFLAGSMASK 0x0000003FL
#define VOS_NT_WINDOWS32    0x00040004L
#define VFT_APP             0x00000001L
#define VFT2_UNKNOWN        0x00000000L

VS_VERSION_INFO VERSIONINFO
 FILEVERSION    $v1,$v2,$v3,$v4
 PRODUCTVERSION $v1,$v2,$v3,$v4
 FILEFLAGSMASK  VS_FFI_FILEFLAGSMASK
 FILEFLAGS      0
 FILEOS         VOS_NT_WINDOWS32
 FILETYPE       VFT_APP
 FILESUBTYPE    VFT2_UNKNOWN
BEGIN
  BLOCK "StringFileInfo"
  BEGIN
    BLOCK "040904b0"
    BEGIN
      VALUE "FileVersion",      "$ver"
      VALUE "ProductVersion",   "$ver"
      VALUE "ProductName",      "Scoop Shim Ex"
      VALUE "CompanyName",      "Scoop contributors"
      VALUE "LegalCopyright",   "Copyright (c) 2013-present Scoop contributors"
      VALUE "OriginalFilename", "shim.exe"
    END
  END
  BLOCK "VarFileInfo"
  BEGIN
    VALUE "Translation", 0x0409, 1200
  END
END
"@

  Set-Content -Path $rcFile -Value $rc -Encoding ASCII
  Write-Host "Generated shim.rc (version $ver)" -ForegroundColor DarkGray
}

New-ShimResourceFile

# --------------------------------------------------------------------------------
# Architecture mappings
$zigArchMap = @{ 'x86' = 'x86-windows-msvc'; 'x64' = 'x86_64-windows-msvc'; 'arm64' = 'aarch64-windows-msvc' }
$msArchMap  = @{ 'x86' = 'Win32'; 'x64' = 'x64'; 'arm64' = 'ARM64' }
$msHostArchMap = @{ 'x86' = 'x86'; 'x64' = 'amd64'; 'arm64' = 'arm64' }

function Invoke-ZigBuild {
  param([string]$Target, [string]$Configuration)
  $opt = switch ($Configuration) { 'Debug' { 'Debug' } default { 'ReleaseSmall' } }
  $zigTarget = $zigArchMap[$Target]
  Write-Host "Zig: $zigTarget ($opt)" -ForegroundColor Cyan
  Push-Location $PSScriptRoot
  try {
    $a = @('build', "-Dtarget=$zigTarget", "-Doptimize=$opt", '--prefix', "bin/$Target")
    if ($Configuration -eq 'Release') { $a += '-Dstrip=true' }
    & zig @a; if ($LASTEXITCODE -ne 0) { throw "zig failed" }
  }
  finally { Pop-Location }
}

function Invoke-MSBuild {
  param([string]$Target, [string]$Configuration)
  $msPlatform = $msArchMap[$Target]
  $msHostArch = $msHostArchMap[$Target]
  $vsPath = & "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -requires Microsoft.Component.MSBuild -property installationPath
  if (-not $vsPath) { throw "VS not found" }
  $devCmd = Join-Path $vsPath 'Common7\Tools\VsDevCmd.bat'
  if (-not (Test-Path $devCmd)) { throw "VsDevCmd.bat not found" }
  Write-Host "MSBuild: $msPlatform ($Configuration)" -ForegroundColor Cyan
  Push-Location $PSScriptRoot
  try {
    $r = cmd.exe /c "`"$devCmd`" -arch=$msHostArch -host_arch=amd64 -no_logo > nul 2>&1 && msbuild shim.vcxproj /p:Configuration=$Configuration /p:Platform=$msPlatform /p:OutDir=$PSScriptRoot\bin\$Target\ /t:Build /v:q /nologo" 2>&1
    if ($LASTEXITCODE -ne 0) { $r | ForEach-Object { Write-Host $_ -ForegroundColor Red }; throw "MSBuild failed" }
  }
  finally { Pop-Location }
}

function Invoke-Build {
  param([string]$Target)
  Write-Host "Tool: $Tool" -ForegroundColor Gray

  if ($Tool -eq 'Zig') { Invoke-ZigBuild $Target $Configuration }
  else { Invoke-MSBuild $Target $Configuration }

  $exe = Join-Path $PSScriptRoot "bin\$Target\shim.exe"
  if (-not (Test-Path $exe)) { throw "Output not found: $exe" }
}

# --------------------------------------------------------------------------------
# Clean bin directory, then build
$binDir = Join-Path $PSScriptRoot 'bin'
Remove-Item -Path $binDir -Recurse -Force -ErrorAction SilentlyContinue

if ($Target) { Invoke-Build $Target }
else { foreach ($t in @('x86', 'x64', 'arm64')) { Invoke-Build $t } }

# Cleanup generated resource files
Remove-Item -Path (Join-Path $PSScriptRoot 'shim.rc') -ErrorAction SilentlyContinue

Write-Host "Done: $binDir" -ForegroundColor Green