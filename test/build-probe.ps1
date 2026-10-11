# Builds probe.exe from probe.c.
#
# The probe is a test fixture rather than a shipped artefact, so it is built
# instead of tracked: a tracked binary can drift away from the source it came
# from, and every lane that runs the suite needs the same bytes. Both the suite
# and CI call this so the command lives in one place.
#
# x86 on purpose, so it runs under WOW64 on x64 and arm64 Windows -- see
# test/README.md.
$ErrorActionPreference = 'Stop'

$src = Join-Path $PSScriptRoot 'probe.c'
$exe = Join-Path $PSScriptRoot 'probe.exe'
$zig = (Get-Command zig -ErrorAction SilentlyContinue).Source

if (-not $zig) {
    throw "zig not found, and it is needed to build probe.exe. Install Zig and put it on PATH."
}

# Arguments are passed as an array rather than inline: PowerShell reads a bare
# -Wl,/subsystem:console as a parameter, not as an argument to zig.
$ccArgs = @(
    'cc', '-O2', '-s', '-target', 'x86-windows-msvc',
    '-nodefaultlibs', '-lkernel32',
    '-Wl,/subsystem:console', '-Wl,-e,probe_entry',
    $src, '-o', $exe
)

& $zig @ccArgs
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $exe)) {
    throw "zig cc failed with exit code $LASTEXITCODE"
}

Write-Host "Built $exe" -ForegroundColor DarkGray
