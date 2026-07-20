#Requires -Version 7

<#
.SYNOPSIS
    Build shim.exe using Zig.
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

$zigArchMap = @{ 'x86' = 'x86-windows-msvc'; 'x64' = 'x86_64-windows-msvc'; 'arm64' = 'aarch64-windows-msvc' }

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

function Invoke-Build {
  param([string]$Target)

  $zigTarget = $zigArchMap[$Target]
  $opt = if ($Configuration -eq 'Release') { 'ReleaseSmall' } else { 'Debug' }
  Write-Host "Zig: $zigTarget ($opt)" -ForegroundColor Cyan

  Push-Location $PSScriptRoot
  try {
    $a = @('build', "-Dtarget=$zigTarget", "-Doptimize=$opt", '--prefix', "bin/$Target")
    if ($Configuration -eq 'Release') { $a += '-Dstrip=true' }
    & zig @a; if ($LASTEXITCODE -ne 0) { throw "zig failed" }
  }
  finally { Pop-Location }

  $exe = Join-Path $PSScriptRoot "bin\$Target\shim.exe"
  if (-not (Test-Path $exe)) { throw "Output not found: $exe" }
}

# Clean bin directory
$binDir = Join-Path $PSScriptRoot 'bin'
Remove-Item -Path $binDir -Recurse -Force -ErrorAction SilentlyContinue

if ($Target) { Invoke-Build $Target }
else { foreach ($t in @('x86', 'x64', 'arm64')) { Invoke-Build $t } }

# Cleanup generated resource files
Remove-Item -Path (Join-Path $PSScriptRoot 'shim.rc') -ErrorAction SilentlyContinue

Write-Host "Done: $binDir" -ForegroundColor Green