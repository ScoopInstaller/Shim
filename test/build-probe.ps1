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
# Application only: a wrapper or shim would report its own exit code in place of zig's.
$zig = (Get-Command zig -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1).Source

if (-not $zig) {
    throw "zig not found as an application on PATH, and it is needed to build probe.exe. Install Zig and put it on PATH."
}

# The suite only rebuilds when probe.exe is missing or older, so remove it before the compile.
if (Test-Path $exe) { Remove-Item $exe -Force }
$buildStart = Get-Date

# Arguments are passed as an array rather than inline: PowerShell reads a bare
# -Wl,/subsystem:console as a parameter, not as an argument to zig.
# Compile to a process-unique name then move: lanes may run this concurrently.
$tmp = Join-Path $PSScriptRoot "probe.$PID.tmp.exe"
$ccArgs = @(
    'cc', '-O2', '-s', '-target', 'x86-windows-msvc',
    '-nodefaultlibs', '-lkernel32',
    '-Wl,/subsystem:console', '-Wl,-e,probe_entry',
    $src, '-o', $tmp
)

& $zig @ccArgs
if ($LASTEXITCODE -ne 0) {
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    throw "zig cc failed with exit code $LASTEXITCODE"
}
if (-not (Test-Path $tmp)) {
    throw "zig cc reported success but produced no output at $tmp"
}
if ((Get-Item $tmp).LastWriteTime -lt $buildStart) {
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    throw "Stale output: $tmp was not rebuilt by this run"
}
Move-Item -Path $tmp -Destination $exe -Force

Write-Host "Built $exe" -ForegroundColor DarkGray
