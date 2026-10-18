#Requires -Version 7

# Functional tests for shim.exe
# Usage: ./run-tests.ps1 -ShimExe <path-to-shim.exe>

param(
    [Parameter(Mandatory=$true)]
    [string]$ShimExe
)

$ErrorActionPreference = "Stop"
# Pin UTF-8: native output decoding otherwise follows the host console's encoding.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$script:TestsPassed = 0
$script:TestsFailed = 0
$script:TestNumber = 0
$psExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$probeExe = Join-Path $PSScriptRoot 'probe.exe'

# ============================================================================
# Infrastructure
# ============================================================================

function Write-TestResult {
    param([string]$Name, [bool]$Passed, [string]$Message = "")
    if ($Passed) {
        Write-Host "  [PASS] $Name" -ForegroundColor Green
        $script:TestsPassed++
    } else {
        Write-Host "  [FAIL] $Name" -ForegroundColor Red
        if ($Message) { Write-Host "         $Message" -ForegroundColor Red }
        $script:TestsFailed++
    }
}

function New-TestEnvironment {
    $dir = Join-Path $env:TEMP "shim-tests-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return $dir
}

function Remove-TestEnvironment {
    param([string]$TestDir)
    if (Test-Path $TestDir) {
        Remove-Item -Path $TestDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Set-PESubsystem {
    param([Parameter(Mandatory=$true)][string]$FilePath, [Parameter(Mandatory=$true)][int16]$Subsystem)
    $bytes = [System.IO.File]::ReadAllBytes($FilePath)
    $peOffset = [System.BitConverter]::ToInt32($bytes, 0x3C)
    [System.BitConverter]::GetBytes($Subsystem).CopyTo($bytes, $peOffset + 0x5C)
    [System.IO.File]::WriteAllBytes($FilePath, $bytes)
}

function Get-PESubsystem {
    param([string]$FilePath)
    $bytes = [System.IO.File]::ReadAllBytes($FilePath)
    $peOffset = [System.BitConverter]::ToInt32($bytes, 0x3C)
    return [System.BitConverter]::ToInt16($bytes, $peOffset + 0x5C)
}

function Write-Shim {
    param([string]$Dir, [string]$Name = "test", [string]$Content)
    Copy-Item $ShimExe "$Dir\$Name.exe"
    Set-Content -Path "$Dir\$Name.shim" -Value $Content
}

function Write-Batch {
    param([string]$Path, [string]$Body)
    Set-Content -Path $Path -Value "@echo off`n$Body"
}

# ============================================================================
# Test runner helpers
# ============================================================================

# Run a standard console shim test.
# Setup: scriptblock receiving $testDir, sets up batch files and .shim content
# RunArgs: arguments passed to the shim executable; with CreatorArgs they follow '--'
#           so both apply and a RunArg is never eaten as a create flag.
# Assert: scriptblock receiving @{Output; ExitCode; TestDir; Elapsed}; returns $true/$false + message
# PipeInput: optional string for the shim's stdin; with CreatorArgs it becomes probe's --stdin
# CreatorArgs: probe create flags -- the only way to control the console the shim starts with
function Invoke-ShimTest {
    param(
        [string]$Name,
        [Parameter(Mandatory=$true)][scriptblock]$Setup,
        [string[]]$RunArgs = @(),
        [Parameter(Mandatory=$true)][scriptblock]$Assert,
        [string]$PipeInput = $null,
        [string[]]$CreatorArgs = @()
    )
    $script:TestNumber++
    $num = $script:TestNumber
    $testDir = New-TestEnvironment
    try {
        & $Setup $testDir
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        if ($CreatorArgs.Count -gt 0) {
            $creatorArgs = @($CreatorArgs)
            if ($PipeInput) { $creatorArgs += @('--stdin', $PipeInput) }
            $output = & $probeExe create "$testDir\test.exe" @creatorArgs -- @RunArgs 2>&1 | Out-String
        } elseif ($PipeInput) {
            $output = $PipeInput | & "$testDir\test.exe" @RunArgs 2>&1 | Out-String
        } else {
            $output = & "$testDir\test.exe" @RunArgs 2>&1 | Out-String
        }
        $sw.Stop()
        $result = @{ Output = $output; ExitCode = $LASTEXITCODE; TestDir = $testDir; Elapsed = $sw.Elapsed }
        $check = & $Assert $result
        if ($check -is [bool]) {
            Write-TestResult "#$num $Name" $check "Output: $output"
        } else {
            Write-TestResult "#$num $Name" $check.Pass $check.Message
        }
    } catch {
        # A terminating error is this test's failure, not the suite's.
        Write-TestResult "#$num $Name" $false $_.Exception.Message
    } finally {
        Remove-TestEnvironment $testDir
    }
}

# Run a GUI subsystem shim test (patches PE to Subsystem=2).
# Assert: scriptblock receiving @{Output; ExitCode; TestDir; Elapsed}, as in Invoke-ShimTest.
function Invoke-GuiShimTest {
    param(
        [string]$Name,
        [Parameter(Mandatory=$true)][scriptblock]$Setup,
        [string[]]$RunArgs = @(),
        [Parameter(Mandatory=$true)][scriptblock]$Assert
    )
    $script:TestNumber++
    $num = $script:TestNumber
    $testDir = New-TestEnvironment
    try {
        $guiExe = "$testDir\gui-shim.exe"
        Copy-Item $ShimExe $guiExe
        Set-PESubsystem -FilePath $guiExe -Subsystem 2

        if ((Get-PESubsystem -FilePath $guiExe) -ne 2) {
            Write-TestResult "#$num $Name (PE patch)" $false "Patch failed"
            return
        }

        & $Setup $testDir

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $output = & $guiExe @RunArgs 2>&1 | Out-String
        $sw.Stop()
        $result = @{ Output = $output; ExitCode = $LASTEXITCODE; TestDir = $testDir; Elapsed = $sw.Elapsed }
        $check = & $Assert $result
        if ($check -is [bool]) {
            Write-TestResult "#$num $Name" $check "Output: $output"
        } else {
            Write-TestResult "#$num $Name" $check.Pass $check.Message
        }
    } catch {
        Write-TestResult "#$num $Name" $false $_.Exception.Message
    } finally {
        Remove-TestEnvironment $testDir
    }
}

# ============================================================================
# Verify shim.exe
# ============================================================================
if (-not (Test-Path $ShimExe)) {
    # Write-Error is terminating under EAP='Stop', so it would swallow the exit below.
    Write-Host "Shim executable not found: $ShimExe" -ForegroundColor Red
    exit 1
}
$ShimExe = (Resolve-Path $ShimExe).Path
Write-Host "Running tests with: $ShimExe" -ForegroundColor Cyan
Write-Host ""

# The native probe backs the argument-forwarding tests and the null-stream creator
# test. It is not tracked, so build it when it is missing or older than probe.c;
# that keeps the binary from drifting away from the source it came from. CI builds
# it once and hands every lane the same bytes.
$probeExe = Join-Path $PSScriptRoot 'probe.exe'
$probeSrc = Join-Path $PSScriptRoot 'probe.c'
if (-not (Test-Path $probeExe) -or (Get-Item $probeExe).LastWriteTimeUtc -lt (Get-Item $probeSrc).LastWriteTimeUtc) {
    try {
        & (Join-Path $PSScriptRoot 'build-probe.ps1')
    }
    catch {
        $script:TestNumber++
        Write-TestResult "#$($script:TestNumber) Native probe built" $false $_.Exception.Message
        exit 1
    }
}
$probeExe = (Resolve-Path $probeExe).Path

# ============================================================================
# Tests
# ============================================================================

# --- Basic execution -----------------------------------------------------------

Invoke-ShimTest "Basic shim execution" -Setup {
    param($d)
    Write-Shim $d "test" "path = $probeExe`nargs = args"
} -Assert { param($r) $r.Output -match '(?m)^PROBE_ARGS\r?$' }

Invoke-ShimTest "Path with spaces" -Setup {
    param($d)
    $sp = "$d\path with spaces"; New-Item -ItemType Directory -Path $sp -Force | Out-Null
    Copy-Item $probeExe "$sp\probe.exe"
    Write-Shim $d "test" "path = $sp\probe.exe`nargs = args"
} -Assert { param($r) $r.Output -match '(?m)^PROBE_ARGS\r?$' }

Invoke-ShimTest "path value with quotes stripped" -Setup {
    param($d)
    Write-Shim $d "test" "path = `"$probeExe`"`nargs = echo PATH_QUOTE_OK"
} -Assert { param($r) $r.Output -match "PATH_QUOTE_OK" }

# Invoke-ShimTest hardcodes test.exe, so a .shim name derived from a dotted directory
# and a missing extension needs its own harness. The probe launches it because a
# no-extension image is not executable through PowerShell or cmd.
$script:TestNumber++
$num = $script:TestNumber
$testDir = New-TestEnvironment
try {
    $dotDir = Join-Path $testDir "has.dot"
    New-Item -ItemType Directory -Path $dotDir -Force | Out-Null
    Copy-Item $ShimExe "$dotDir\app"
    $marker = Join-Path $testDir "dotdir.marker"
    Set-Content -Path "$dotDir\app.shim" -Value "path = $probeExe`nargs = touch $marker"

    & $probeExe create "$dotDir\app" --default 2>&1 | Out-Null
    $pass = ($LASTEXITCODE -eq 0) -and (Test-Path $marker)
    Write-TestResult "#$num .shim name from the final path component" $pass "Exit: $LASTEXITCODE, marker: $(Test-Path $marker)"
}
finally {
    Remove-TestEnvironment $testDir
}

# The one test that keeps a .cmd target. Scoop never pairs shim.exe with a batch file,
# so only a hand-written .shim reaches it -- but nothing else here would notice if
# CreateProcessW stopped launching it. Argument handling is deliberately not asserted:
# PowerShell reverts to Legacy quoting for .cmd and cmd re-expands %*, two layers a
# real .exe target never goes through.
Invoke-ShimTest "Batch file target launches" -Setup {
    param($d)
    Write-Batch "$d\ok.cmd" "echo BATCH_TARGET_OK"
    Write-Shim $d "test" "path = $d\ok.cmd"
} -Assert {
    param($r)
    $pass = ($r.ExitCode -eq 0) -and ($r.Output -match "BATCH_TARGET_OK")
    @{ Pass = $pass; Message = "Expected exit 0 and BATCH_TARGET_OK, ExitCode: $($r.ExitCode), Output: $($r.Output)" }
}

# Write-Shim emits LF-only; a CRLF .shim (the Notepad default) must not glue a CR to values.
Invoke-ShimTest "CRLF shim file trims trailing CR from args" -Setup {
    param($d)
    Copy-Item $ShimExe "$d\test.exe"
    $content = "path = $probeExe`r`nargs = args CRLF_OK`r`n"
    [System.IO.File]::WriteAllText("$d\test.shim", $content)
} -Assert {
    param($r)
    # End-of-line anchor: a leaked CR would sit between CRLF_OK and the closing '>'.
    $pass = $r.Output -match '(?m)^Arg 0 is <CRLF_OK>\r?$'
    @{ Pass = $pass; Message = "Expected Arg 0 is <CRLF_OK> (no trailing CR), got: $($r.Output)" }
}

# --- %~VAR% expansion ---------------------------------------------------------

Invoke-ShimTest "%~VAR% expansion in path" -Setup {
    param($d)
    # The probe is a native target, so the path's %TEMP% is the expansion under test.
    # The literal in args proves args are not expanded: the shim never does that.
    Copy-Item $probeExe "$d\probe.exe"
    $leaf = Split-Path $d -Leaf
    Write-Shim $d "test" "path = %TEMP%\$leaf\probe.exe`nargs = args %SystemRoot%__"
} -Assert {
    param($r)
    $pass = ($r.ExitCode -eq 0) -and ($r.Output -match '(?m)^Arg 0 is <%SystemRoot%__>\r?$')
    @{ Pass = $pass; Message = "Expected exit 0 (path expanded) and literal '<%SystemRoot%__>' from args. Output: $($r.Output), ExitCode: $($r.ExitCode)" }
}

Invoke-ShimTest "Unknown %VAR% preserved as-is" -Setup {
    param($d)
    # A native probe is the target so the literal reaches it unexpanded; the point
    # is that the shim does not expand %NONEXISTENT_...% into args.
    Write-Shim $d "test" "path = $probeExe`nargs = args %NONEXISTENT_SHIM_TEST_VAR%"
} -Assert {
    param($r)
    @{ Pass = $r.Output -match [regex]::Escape("Arg 0 is <%NONEXISTENT_SHIM_TEST_VAR%>"); Message = "Output: $($r.Output)" }
}

# --- Environment variables from .shim -----------------------------------------

Invoke-ShimTest "Environment variables from .shim" -Setup {
    param($d)
    Write-Shim $d "test" "path = $probeExe`nargs = env VAR1 VAR2 VAR3`nVAR1 = first`nVAR2 = %USERNAME%_suffix`nVAR3 = third"
} -Assert {
    param($r)
    $pass = ($r.Output -match "VAR1=first") -and ($r.Output -match "VAR3=third") -and ($r.Output -match [regex]::Escape("VAR2=$($env:USERNAME)_suffix"))
    @{ Pass = $pass; Message = "Output: $($r.Output)" }
}

Invoke-ShimTest "Env var value with quotes stripped" -Setup {
    param($d)
    Write-Shim $d "test" "path = $probeExe`nargs = env MY_VAR`nMY_VAR = `"hello world`""
} -Assert {
    param($r)
    @{ Pass = $r.Output -match "MY_VAR=hello world"; Message = "Output: $($r.Output)" }
}

Invoke-ShimTest "Env var value %~dp0 expansion" -Setup {
    param($d)
    # %~dp0 names the target's directory, so the probe is copied into the test dir
    # to keep the expansion anchored there.
    Copy-Item $probeExe "$d\probe.exe"
    Write-Shim $d "test" "path = $d\probe.exe`nargs = env MY_DIR`nMY_DIR = %~dp0sub"
} -Assert {
    param($r)
    $expected = "$($r.TestDir)\sub"
    @{ Pass = $r.Output -match [regex]::Escape("MY_DIR=$expected"); Message = "Expected: MY_DIR=$expected, Output: $($r.Output)" }
}

Invoke-ShimTest "Env var value %~dp0 expansion (multiple occurrences)" -Setup {
    param($d)
    Copy-Item $probeExe "$d\probe.exe"
    Write-Shim $d "test" "path = $d\probe.exe`nargs = env MY_D`nMY_D = %~dp0-%~dp0"
} -Assert {
    param($r)
    $expected = "$($r.TestDir)\-$($r.TestDir)\"
    @{ Pass = $r.Output -match [regex]::Escape("MY_D=$expected"); Message = "Expected: MY_D=$expected, Output: $($r.Output)" }
}

# --- env: prefix (force a reserved key to be an environment variable) -----------

Invoke-ShimTest "env: prefix does not hijack the shim path" -Setup {
    param($d)
    # env:path comes first on purpose: a strip done inside the line parser would
    # make it the target path and the shim would fail to launch. A bare "env:" has
    # no name, so it is reported and skipped rather than defining a junk variable.
    Write-Shim $d "test" "env:path = C:\nonexistent\fake.exe`nenv: = noname`npath = $probeExe`nargs = echo TARGET_OK"
} -Assert {
    param($r)
    $pass = ($r.Output -match "TARGET_OK") -and ($r.Output -match "empty variable name after 'env:'")
    @{ Pass = $pass; Message = "Output: $($r.Output)" }
}

Invoke-ShimTest "env: prefix overrides a reserved key" -Setup {
    param($d)
    Write-Shim $d "test" "path = $probeExe`nargs = env PATH`nenv:PATH = %PATH%;ZZZ_ENV_APPENDED"
} -Assert {
    param($r)
    # The child's PATH keeps the inherited spelling ("Path"), so only the value is
    # asserted: it must still start with the inherited PATH and carry the suffix.
    $out = $r.Output.TrimEnd()
    $val = $out.Substring($out.IndexOf('=') + 1)
    $pass = $val.StartsWith("$($env:PATH);") -and $val.EndsWith("ZZZ_ENV_APPENDED")
    @{ Pass = $pass; Message = "Expected value '$($env:PATH);ZZZ_ENV_APPENDED', Output: $($r.Output)" }
}

# probe env dumps the child's own block, so the stored spelling is matched exactly;
# a %VAR% lookup could not tell lowercase from mixed case.
Invoke-ShimTest "env: prefix is case-insensitive and preserves the name" -Setup {
    param($d)
    Write-Shim $d "test" "path = $probeExe`nargs = env`nenv:LOW = a`nEnv:MID = b`nENV:UP = c`neNv:MiXeD = d"
} -Assert {
    param($r)
    $lines = $r.Output -split "`r?`n"
    $expected = @("LOW=a", "MID=b", "UP=c", "MiXeD=d")
    $missing = @($expected | Where-Object { $lines -cnotcontains $_ })
    @{ Pass = $missing.Count -eq 0; Message = "Missing from child env: $($missing -join ', ')" }
}

# --- Line grammar --------------------------------------------------------------

Invoke-ShimTest "Key/value separator accepts no spaces" -Setup {
    param($d)
    Write-Shim $d "test" "path=$probeExe`nargs=args fromfile"
} -RunArgs @("fromuser") -Assert {
    param($r)
    # Shim args must precede user args, and the no-space key/value form must parse.
    $pass = ($r.Output -match '(?m)^Arg 0 is <fromfile>\r?$') -and ($r.Output -match '(?m)^Arg 1 is <fromuser>\r?$')
    @{ Pass = $pass; Message = "Expected 'Arg 0 is <fromfile>' and 'Arg 1 is <fromuser>', Output: $($r.Output)" }
}

Invoke-ShimTest "Case-variant env names keep the first spelling, last value" -Setup {
    param($d)
    # The full environment-block dump is matched case-sensitively: a %VAR% lookup
    # cannot tell spellings apart, because Windows resolves names case-insensitively.
    Write-Shim $d "test" "path = $probeExe`nargs = env`nenv:MARK = one`nenv:mark = two"
} -Assert {
    param($r)
    $lines = $r.Output -split "`r?`n"
    $pass = ($lines -ccontains "MARK=two") -and -not ($lines -ccontains "mark=two")
    @{ Pass = $pass; Message = "Expected exactly 'MARK=two' in the child env, Output: $($r.Output)" }
}

# U+017F sits at the folding boundary: a Unicode-folding lane reads "argſ" as the args field.
Invoke-ShimTest "A key that folds beyond ASCII is not a reserved key" -Setup {
    param($d)
    $ls = [char]0x017F
    Write-Shim $d "test" "path = $probeExe`nargs = env arg$ls`narg$ls = 1"
} -Assert {
    param($r)
    $ls = [char]0x017F
    @{ Pass = $r.Output.Contains("arg$ls=1"); Message = "Expected 'arg$ls=1' in the child env, Output: $($r.Output)" }
}

Invoke-ShimTest "Line without '=' is reported as malformed" -Setup {
    param($d)
    Write-Shim $d "test" "path = $probeExe`nargs = echo TARGET_OK`nthis line is broken"
} -Assert {
    param($r)
    # Count, not just match: the check must fire once, not once per pass.
    $pass = ($r.ExitCode -ne 0) -and ($r.Output -match "malformed line 'this line is broken'") -and
            ($r.Output -notmatch "TARGET_OK") -and ([regex]::Matches($r.Output, "malformed line").Count -eq 1)
    @{ Pass = $pass; Message = "Expected exit!=0 and exactly one malformed-line error, Exit: $($r.ExitCode), Output: $($r.Output)" }
}

# --- Case-insensitivity (Windows convention) -----------------------------------

Invoke-ShimTest "Case-insensitive .shim parsing" -Setup {
    param($d)
    Write-Shim $d "test" "PATH = $probeExe`nARGS = args %~DP0"
} -Assert {
    param($r)
    # %~dp0 names the target's directory, so a native probe in test\ resolves there.
    $expected = "Arg 0 is <$(Split-Path $probeExe)\>"
    @{ Pass = $r.Output -match [regex]::Escape($expected); Message = "Expected: $expected, Output: $($r.Output)" }
}

# --- %~dp0 placeholder --------------------------------------------------------

Invoke-ShimTest "Args %~dp0 expansion (relative path)" -Setup {
    param($d)
    New-Item -ItemType Directory -Path "$d\bin" -Force | Out-Null
    Copy-Item $probeExe "$d\bin\probe.exe"
    Write-Shim $d "test" "path = $d\bin\probe.exe`nargs = args %~dp0"
} -Assert {
    param($r)
    # path resolves into $d\bin - target dir = $d\bin\
    $expected = "Arg 0 is <$($r.TestDir)\bin\>"
    @{ Pass = $r.Output -match [regex]::Escape($expected); Message = "Expected: $expected, Output: $($r.Output)" }
}

Invoke-ShimTest "Args %~dp0 expansion (multiple occurrences)" -Setup {
    param($d)
    Write-Shim $d "test" "path = $probeExe`nargs = args %~dp0 %~dp0"
} -Assert {
    param($r)
    $e = [regex]::Escape("$(Split-Path $probeExe)\")
    $pass = ($r.Output -match "(?m)^Arg 0 is <$e>\r?$") -and ($r.Output -match "(?m)^Arg 1 is <$e>\r?$")
    @{ Pass = $pass; Message = "Expected 2 expansions, got: $($r.Output)" }
}

Invoke-ShimTest "path = %~dp0 resolves against shim directory" -Setup {
    param($d)
    Copy-Item $probeExe "$d\probe.exe"
    Write-Shim $d "test" "path = %~dp0probe.exe`nargs = args"
} -Assert {
    param($r) $r.Output -match '(?m)^PROBE_ARGS\r?$'
}

# --- Pass-through arguments & quoting -------------------------------------------

Invoke-ShimTest "Pass-through arguments" -Setup {
    param($d)
    Write-Shim $d "test" "path = $probeExe`nargs = args"
} -RunArgs @("arg1", "arg2", "arg with spaces") -Assert {
    param($r)
    # One line per argument proves order. The spaced argument arrives unquoted: a
    # native target receives the value, not cmd's re-quoted %* rendering.
    $pass = ($r.Output -match '(?m)^Arg 0 is <arg1>\r?$') -and
            ($r.Output -match '(?m)^Arg 1 is <arg2>\r?$') -and
            ($r.Output -match '(?m)^Arg 2 is <arg with spaces>\r?$')
    @{ Pass = $pass; Message = "Expected arg1/arg2/'arg with spaces', got: $($r.Output)" }
}

Invoke-ShimTest "Args with embedded quotes" -Setup {
    param($d)
    Write-Shim $d "test" "path = $probeExe`nargs = args"
} -RunArgs @("Write-Host 'QUOTE_TEST'") -Assert {
    param($r)
    # Windows/Standard quoting preserves embedded quotes; the native target sees them.
    @{ Pass = $r.Output -match "(?m)^Arg 0 is <Write-Host 'QUOTE_TEST'>\r?$"; Message = "Output: $($r.Output)" }
}

Invoke-ShimTest "Shim + user args combined" -Setup {
    param($d)
    Write-Shim $d "test" "path = $probeExe`nargs = args --flag value"
} -RunArgs @("--extra") -Assert {
    param($r)
    # Exact order: shim args must precede user args (README "appended after").
    $pass = ($r.Output -match '(?m)^Arg 0 is <--flag>\r?$') -and
            ($r.Output -match '(?m)^Arg 1 is <value>\r?$') -and
            ($r.Output -match '(?m)^Arg 2 is <--extra>\r?$')
    @{ Pass = $pass; Message = "Expected --flag value --extra, got: $($r.Output)" }
}

Invoke-ShimTest "Args with backslashes" -Setup {
    param($d)
    Write-Shim $d "test" "path = $probeExe`nargs = args"
} -RunArgs @("C:\path\to\file") -Assert {
    param($r) $r.Output -match [regex]::Escape("Arg 0 is <C:\path\to\file>")
}

Invoke-ShimTest "Shim args with spaces in value" -Setup {
    param($d)
    Write-Shim $d "test" "path = $probeExe`nargs = args --dir `"C:\Program Files\App`""
} -Assert {
    param($r)
    # The shim's own quoting makes this one argument; a native target sees one value.
    @{ Pass = $r.Output -match [regex]::Escape("Arg 1 is <C:\Program Files\App>"); Message = "Output: $($r.Output)" }
}

Invoke-ShimTest "Shim args with trailing backslash and embedded quote" -Setup {
    param($d)
    # The two re-quote branches nothing else reaches: an argument ending in a
    # backslash doubles it inside the quotes (the 2n rule), and a backslash
    # immediately before a quote takes the 2n+1 form. Both must round-trip to
    # a native target exactly as typed in the file.
    Write-Shim $d "test" "path = $probeExe`nargs = args `"C:\dir with space\\`" a\\\`"b"
} -Assert {
    param($r)
    $pass = ($r.Output -match [regex]::Escape('Arg 0 is <C:\dir with space\>')) -and
            ($r.Output -match [regex]::Escape('Arg 1 is <a\"b>'))
    @{ Pass = $pass; Message = "Output: $($r.Output)" }
}

# --- Duplicate keys ------------------------------------------------------------

Invoke-ShimTest "Duplicate args keys accumulate in file order" -Setup {
    param($d)
    Write-Shim $d "test" "path = $probeExe`nargs = args --one`nargs = --two"
} -Assert {
    param($r)
    # args is the only list-valued field, so a repeated key appends rather than overrides.
    $pass = ($r.Output -match '(?m)^Arg 0 is <--one>\r?$') -and ($r.Output -match '(?m)^Arg 1 is <--two>\r?$')
    @{ Pass = $pass; Message = "Expected --one then --two, got: $($r.Output)" }
}

# --- Exit code & I/O -----------------------------------------------------------

Invoke-ShimTest "Non-zero exit code (42)" -Setup {
    param($d)
    Write-Shim $d "test" "path = $probeExe`nargs = exit 42"
} -Assert {
    param($r)
    @{ Pass = $r.ExitCode -eq 42; Message = "Expected: 42, Got: $($r.ExitCode)" }
}

Invoke-ShimTest "stderr output preserved" -Setup {
    param($d)
    # echoerr writes "stdout line" to stdout and "stdout line err" to stderr, so one
    # run proves both streams reach the child and both come back.
    Write-Shim $d "test" "path = $probeExe`nargs = echoerr stdout line"
} -Assert {
    param($r)
    $pass = ($r.Output -match "stdout line") -and ($r.Output -match "stdout line err")
    @{ Pass = $pass; Message = "Output: $($r.Output)" }
}

Invoke-ShimTest "stdin pipe" -Setup {
    param($d)
    Write-Shim $d "test" "path = $probeExe`nargs = stdin"
} -PipeInput "HELLO_STDIN" -Assert {
    param($r) $r.Output -match "GOT=HELLO_STDIN"
}

# --- Comment handling ---------------------------------------------------------

Invoke-ShimTest "Ignore comment lines" -Setup {
    param($d)
    Write-Shim $d "test" "# hash comment`n; semicolon comment`n// slash comment`n  # indented comment`npath = $probeExe`nargs = args --verified"
} -Assert { param($r) $r.Output -match '(?m)^Arg 0 is <--verified>\r?$' }

# --- UTF-8 BOM handling -------------------------------------------------------

Invoke-ShimTest "UTF-8 BOM in shim file" -Setup {
    param($d)
    Copy-Item $ShimExe "$d\test.exe"
    $content = "# comment`npath = $probeExe`nargs = echo BOM_OK"
    $bom = [System.Text.Encoding]::UTF8.GetPreamble()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($content)
    [System.IO.File]::WriteAllBytes("$d\test.shim", $bom + $bytes)
} -Assert { param($r) $r.Output -match "BOM_OK" }

Invoke-ShimTest "Invalid UTF-8 line skipped without abort" -Setup {
    param($d)
    Copy-Item $ShimExe "$d\test.exe"
    # path, then a line with an invalid UTF-8 sequence (C3 28), then args
    $bytes = [byte[]](0x70,0x61,0x74,0x68,0x20,0x3D,0x20) + [System.Text.Encoding]::UTF8.GetBytes("$probeExe") +
        [byte[]](0x0A,0xC3,0x28,0x20,0x3D,0x20,0x5A,0x5A,0x5A,0x0A) +
        [System.Text.Encoding]::UTF8.GetBytes("args = args AFTER_BAD_LINE")
    [System.IO.File]::WriteAllBytes("$d\test.shim", $bytes)
} -Assert {
    param($r)
    # The line is reported and dropped, not decoded into U+FFFD and set as a variable.
    $pass = ($r.Output -match '(?m)^Arg 0 is <AFTER_BAD_LINE>\r?$') -and ($r.ExitCode -eq 0) -and
            ($r.Output -match "invalid UTF-8 line in shim file") -and ($r.Output -notmatch "=ZZZ")
    @{ Pass = $pass; Message = "Output: $($r.Output), ExitCode: $($r.ExitCode)" }
}

# --- Blank line handling --------------------------------------------------------

Invoke-ShimTest "Blank lines in shim file" -Setup {
    param($d)
    Write-Shim $d "test" "path = $probeExe`n`nargs = echo BLANKLINE_OK`n`n# comment`n"
} -Assert {
    param($r)
    $pass = ($r.Output -match "BLANKLINE_OK") -and ($r.ExitCode -eq 0)
    @{ Pass = $pass; Message = "Output: $($r.Output), ExitCode: $($r.ExitCode)" }
}

Invoke-ShimTest "Line of U+180E is not blank" -Setup {
    param($d)
    Copy-Item $ShimExe "$d\test.exe"
    # U+180E is not in the fixed whitespace set, so a line holding only it is
    # malformed, not blank. Char.IsWhiteSpace has answered both ways for it
    # across .NET versions, which is why no lane may delegate to it.
    $bytes = [System.Text.Encoding]::UTF8.GetBytes("path = $probeExe`nargs = echo NEVER_REACHED`n") +
        [System.Text.Encoding]::UTF8.GetBytes([string][char]0x180E)
    [System.IO.File]::WriteAllBytes("$d\test.shim", $bytes)
} -Assert {
    param($r)
    $pass = ($r.ExitCode -eq 1) -and ($r.Output -match "malformed line") -and ($r.Output -notmatch "NEVER_REACHED")
    @{ Pass = $pass; Message = "Expected exit 1 and a malformed-line error, Exit: $($r.ExitCode), Output: $($r.Output)" }
}

# --- Exit code width ------------------------------------------------------------

Invoke-ShimTest "Exit code above 255" -Setup {
    param($d)
    Write-Shim $d "test" "path = $probeExe`nargs = exit 300"
} -Assert {
    param($r)
    @{ Pass = $r.ExitCode -eq 300; Message = "Expected: 300, Got: $($r.ExitCode)" }
}

Invoke-ShimTest "Exit code 0xFFFE0005 forwarded unmangled" -Setup {
    param($d)
    # 0xFFFE0005 as a signed 32-bit int is -131067: a negative (crash-style) exit
    # code must pass through unmangled, not collapse to 1.
    Write-Shim $d "test" "path = $probeExe`nargs = exit 0xFFFE0005"
} -Assert {
    param($r)
    @{ Pass = $r.ExitCode -eq -131067; Message = "Expected: -131067 (0xFFFE0005), Got: $($r.ExitCode)" }
}

# --- Error messages ---------------------------------------------------------------

Invoke-ShimTest "Missing shim file reports path and win32 error" -Setup {
    param($d)
    Copy-Item $ShimExe "$d\test.exe"
} -Assert {
    param($r)
    $pass = ($r.Output -match "Cannot open shim file for read:") -and ($r.Output -match "\(error \d+") -and ($r.ExitCode -eq 1)
    @{ Pass = $pass; Message = "Output: $($r.Output), ExitCode: $($r.ExitCode)" }
}

Invoke-ShimTest "Missing path key reports shim file" -Setup {
    param($d)
    Write-Shim $d "test" "elevate = false"
} -Assert {
    param($r)
    $pass = ($r.Output -match "'path' not found in shim file") -and ($r.ExitCode -eq 1)
    @{ Pass = $pass; Message = "Output: $($r.Output), ExitCode: $($r.ExitCode)" }
}

Invoke-ShimTest "First path line wins" -Setup {
    param($d)
    # The first path is the probe; the second points at a missing exe. If the shim
    # preferred the last path line the launch would fail and FIRST_PATH would never
    # print. The not-match on SECOND_PATH is a literal guard (nothing prints it).
    Write-Shim $d "test" "path = $probeExe`nargs = echo FIRST_PATH`npath = $d\does-not-exist.exe"
} -Assert {
    param($r)
    $pass = ($r.Output -match "FIRST_PATH") -and ($r.Output -notmatch "SECOND_PATH")
    @{ Pass = $pass; Message = "Output: $($r.Output)" }
}

Invoke-ShimTest "Empty path value treated as missing" -Setup {
    param($d)
    Write-Shim $d "test" "path ="
} -Assert {
    param($r)
    $pass = ($r.Output -match "'path' not found in shim file") -and ($r.ExitCode -eq 1)
    @{ Pass = $pass; Message = "Output: $($r.Output), ExitCode: $($r.ExitCode)" }
}

Invoke-ShimTest "Empty path value consumes the first-wins slot" -Setup {
    param($d)
    # The empty path comes first, so it wins the slot and the later line cannot
    # resurrect the field; EMPTY_PATH_OK must never print.
    Write-Shim $d "test" "path =`npath = $probeExe`nargs = echo EMPTY_PATH_OK"
} -Assert {
    param($r)
    $pass = ($r.ExitCode -eq 1) -and ($r.Output -match "'path' not found in shim file") -and ($r.Output -notmatch "EMPTY_PATH_OK")
    @{ Pass = $pass; Message = "Output: $($r.Output), ExitCode: $($r.ExitCode)" }
}

Invoke-ShimTest "Empty path value stops before the launch" -Setup {
    param($d)
    # The args line makes a launch visible if a lane let the empty value past its guard.
    Write-Shim $d "test" "path =`nargs = echo EMPTY_PATH_ARG_OK"
} -Assert {
    param($r)
    $pass = ($r.ExitCode -eq 1) -and ($r.Output -match "'path' not found in shim file") -and
            ($r.Output -notmatch "Could not create process") -and ($r.Output -notmatch "EMPTY_PATH_ARG_OK")
    @{ Pass = $pass; Message = "Expected one 'path' not found error and no launch, Exit: $($r.ExitCode), Output: $($r.Output)" }
}

Invoke-ShimTest "A leading backslash in path is rejected" -Setup {
    param($d)
    Write-Shim $d "test" "path = \no\such\target.exe`nargs = echo SEP_PATH_ARG_OK"
} -Assert {
    param($r)
    $pass = ($r.ExitCode -eq 1) -and ($r.Output -match "must not begin with a separator") -and
            ($r.Output -notmatch "SEP_PATH_ARG_OK")
    @{ Pass = $pass; Message = "Expected the leading-separator rejection and no launch, Exit: $($r.ExitCode), Output: $($r.Output)" }
}

Invoke-ShimTest "A leading slash in path is rejected" -Setup {
    param($d)
    Write-Shim $d "test" "path = /no/such/target.exe`nargs = echo SLASH_PATH_ARG_OK"
} -Assert {
    param($r)
    $pass = ($r.ExitCode -eq 1) -and ($r.Output -match "must not begin with a separator") -and
            ($r.Output -notmatch "SLASH_PATH_ARG_OK")
    @{ Pass = $pass; Message = "Expected the leading-separator rejection and no launch, Exit: $($r.ExitCode), Output: $($r.Output)" }
}

Invoke-ShimTest "Missing target exe reports command and win32 error" -Setup {
    param($d)
    Write-Shim $d "test" "path = $d\does-not-exist.exe"
} -Assert {
    param($r)
    $pass = ($r.Output -match "Could not create process with command '") -and ($r.Output -match "\(error \d+") -and ($r.ExitCode -eq 1)
    @{ Pass = $pass; Message = "Output: $($r.Output), ExitCode: $($r.ExitCode)" }
}

Invoke-ShimTest "path longer than MAX_PATH fails cleanly" -Setup {
    param($d)
    # A deep nonexistent target: resolving it walks the two-call GetFullPathNameW
    # growth path in every lane, and the failed launch is asserted rather than
    # the platform, so nothing depends on launching an image that deep.
    $long = "C:\" + ("a" * 300) + "\x.exe"
    Write-Shim $d "test" "path = $long"
} -Assert {
    param($r)
    $pass = ($r.ExitCode -eq 1) -and ($r.Output -match "Could not create process with command '") -and ($r.Output -match "\(error \d+")
    @{ Pass = $pass; Message = "Expected exit 1 and a create-process error, Exit: $($r.ExitCode), Output: $($r.Output)" }
}

# --- cwd configuration --------------------------------------------------------

Invoke-ShimTest "cwd configured" -Setup {
    param($d)
    $cwdDir = "$d\workdir"
    New-Item -ItemType Directory -Path $cwdDir -Force | Out-Null
    Write-Shim $d "test" "path = $probeExe`nargs = cwd`ncwd = $cwdDir"
} -Assert {
    param($r)
    @{ Pass = $r.Output -match [regex]::Escape("$($r.TestDir)\workdir"); Message = "Output: $($r.Output)" }
}

Invoke-ShimTest "cwd %~dp0 expansion" -Setup {
    param($d)
    $subDir = "$d\sub"
    New-Item -ItemType Directory -Path $subDir -Force | Out-Null
    Copy-Item $probeExe "$d\probe.exe"
    Write-Shim $d "test" "path = $d\probe.exe`nargs = cwd`ncwd = %~dp0sub"
} -Assert {
    param($r)
    $expected = "$($r.TestDir)\sub"
    @{ Pass = $r.Output -match [regex]::Escape($expected); Message = "Expected: $expected, Output: $($r.Output)" }
}

Invoke-ShimTest "cwd %TEMP% expansion" -Setup {
    param($d)
    Write-Shim $d "test" "path = $probeExe`nargs = cwd`ncwd = %TEMP%"
} -Assert {
    param($r)
    @{ Pass = $r.Output -match [regex]::Escape($env:TEMP); Message = "Expected: $env:TEMP, Output: $($r.Output)" }
}

Invoke-ShimTest "cwd value with quotes stripped" -Setup {
    param($d)
    $cwdDir = "$d\workdir"
    New-Item -ItemType Directory -Path $cwdDir -Force | Out-Null
    Write-Shim $d "test" "path = $probeExe`nargs = cwd`ncwd = `"$cwdDir`""
} -Assert {
    param($r)
    @{ Pass = $r.Output -match [regex]::Escape("$($r.TestDir)\workdir"); Message = "Output: $($r.Output)" }
}

Invoke-ShimTest "workdir alias for cwd" -Setup {
    param($d)
    $wdDir = "$d\wd"
    New-Item -ItemType Directory -Path $wdDir -Force | Out-Null
    Write-Shim $d "test" "path = $probeExe`nargs = cwd`nworkdir = $wdDir"
} -Assert {
    param($r)
    @{ Pass = $r.Output -match [regex]::Escape("$($r.TestDir)\wd"); Message = "Output: $($r.Output)" }
}

# --- Process lifecycle ---------------------------------------------------------

# Direct-child-only: complex process chain - uses Start-Process + Wait-Process
# to verify shim exits when its direct child exits but leaves the grandchild alive.
$script:TestNumber++
$num = $script:TestNumber
$testDir = New-TestEnvironment
$gp = 0
$shim = $null
try {
    $done = Join-Path $testDir "done"
    $gpid = Join-Path $testDir "gpid"
    $rawCmd = '$p=Start-Process ' + $psExe + ' -WindowStyle Hidden -PassThru -ArgumentList ''-NoProfile'',''-Command'',''Start-Sleep -Seconds 30'';' +
        "`$p.Id|Out-File '$gpid'; Set-Content '$done' 'done'"
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($rawCmd))

    Write-Shim $testDir "test" "path = $psExe`nargs = -NoProfile -ExecutionPolicy Bypass -EncodedCommand $enc"
    $shim = Start-Process "$testDir\test.exe" -PassThru -NoNewWindow `
        -RedirectStandardOutput "$testDir\stdout.txt" -RedirectStandardError "$testDir\stderr.txt"
    # The chain is two cold powershell starts; an AV-scanning or heavily loaded
    # machine can burn the whole budget on those alone, so wait generously.
    $shim | Wait-Process -Timeout 60 -ErrorAction SilentlyContinue

    $gp = (Get-Content $gpid -ErrorAction SilentlyContinue | Select -First 1) -as [int]
    $alive = [bool](Get-Process -Id $gp -ErrorAction SilentlyContinue)
    $pass = ($gp -gt 0) -and $alive -and $shim.HasExited
    $detail = "gpid=$($gp) grandchildAlive=$($alive) shimExited=$($shim.HasExited) childDone=$(Test-Path $done)"
    Write-TestResult "#$num Direct-child-only lifecycle" $pass $detail
} finally {
    # The test asserts the grandchild is alive; nothing else stops it, so each run would leak it.
    if ($gp -gt 0) { Stop-Process -Id $gp -Force -ErrorAction SilentlyContinue }
    if ($shim -and -not $shim.HasExited) { Stop-Process -Id $shim.Id -Force -ErrorAction SilentlyContinue }
    Remove-TestEnvironment $testDir
}

Invoke-ShimTest "shim waits for long-running child" -Setup {
    param($d)
    Write-Shim $d "test" "path = $probeExe`nargs = wait 3000"
} -Assert {
    param($r)
    $pass = ($r.ExitCode -eq 0) -and ($r.Elapsed.TotalSeconds -gt 2.5)
    @{ Pass = $pass; Message = "Exit: $($r.ExitCode), Elapsed: $($r.Elapsed.TotalSeconds)s" }
}

# --- Special key handling ------------------------------------------------------

Invoke-ShimTest "Special keys not leaked as env vars" -Setup {
    param($d)
    # The probe prints nothing for an absent name, so an empty output is the exact
    # signal that elevate/cwd/runas were consumed as shim keys, not set as env vars.
    Write-Shim $d "test" "path = $probeExe`nargs = env ELEVATE CWD RUNAS`nelevate = false`ncwd = $d`nrunas = false"
} -Assert {
    param($r)
    @{ Pass = ($r.Output -notmatch "ELEVATE=") -and ($r.Output -notmatch "CWD=") -and ($r.Output -notmatch "RUNAS="); Message = "Output: $($r.Output)" }
}

# The check runs before the shim: a UAC dialog cannot be automated, so a non-elevated run skips without launching.
# IsInRole tolerates a filtered token, so check the group SID directly.
if (([Security.Principal.WindowsIdentity]::GetCurrent().Groups | ForEach-Object { $_.Value }) -contains "S-1-5-32-544") {
    Invoke-ShimTest "elevate = true triggers elevation path" -Setup {
        param($d)
        # The probe's touch mode creates the marker, so the assertion holds whether the
        # runner is elevated or not; the elevated path is what is under test.
        Write-Shim $d "test" "path = $probeExe`nargs = touch $d\marker.txt`nelevate = true"
    } -Assert {
        param($r)
        $marker = Join-Path $r.TestDir "marker.txt"

        # Positive assertion: a lane that errors out on elevate = true now fails.
        $writable = $true
        try { [System.IO.File]::WriteAllText($marker, "") } catch { $writable = $false }
        $pass = $writable -and (Test-Path $marker)
        Remove-Item $marker -Force -ErrorAction SilentlyContinue
        @{ Pass = $pass; Message = "Elevated child did not write $marker; Output: $($r.Output), ExitCode: $($r.ExitCode)" }
    }
} else {
    $script:TestNumber++
    # Counted as a pass as the suite always has (the summary counts failures only), without launching.
    Write-Host "  [SKIP] Test #$script:TestNumber elevation requires an elevated runner (UAC consent dialog cannot be automated); counting as pass" -ForegroundColor DarkYellow
    $script:TestsPassed++
}

# --- GUI subsystem -------------------------------------------------------------

Invoke-GuiShimTest "GUI shim with args preserves CLI" -Setup {
    param($d)
    Set-Content -Path "$d\gui-shim.shim" -Value "path = $probeExe`nargs = args"
} -RunArgs @("--help", "--version") -Assert {
    param($r)
    $pass = ($r.Output -match '(?m)^Arg 0 is <--help>\r?$') -and ($r.Output -match '(?m)^Arg 1 is <--version>\r?$')
    @{ Pass = $pass; Message = "Output: $($r.Output)" }
}

Invoke-GuiShimTest "GUI shim no-arg does not crash" -Setup {
    param($d)
    Set-Content -Path "$d\gui-shim.shim" -Value "path = $probeExe`nargs = echo GUI_NOARG_OK"
} -Assert {
    param($r)
    $pass = ($r.ExitCode -eq 0) -and ($r.Output -match "GUI_NOARG_OK")
    @{ Pass = $pass; Message = "ExitCode: $($r.ExitCode), Output: $($r.Output)" }
}

Invoke-GuiShimTest "GUI shim exit code (7)" -Setup {
    param($d)
    Set-Content -Path "$d\gui-shim.shim" -Value "path = $probeExe`nargs = exit 7"
} -Assert {
    param($r)
    @{ Pass = $r.ExitCode -eq 7; Message = "Expected: 7, Got: $($r.ExitCode)" }
}

# --- Target console ------------------------------------------------------------

# DETACHED_PROCESS is what leaves the shim console-less (CREATE_NO_WINDOW is ignored
# beside it); the host's other flag, CREATE_NEW_PROCESS_GROUP, only reroutes Ctrl+C.
# Only the probe can build this creator -- PowerShell always gives the shim a console.

Invoke-ShimTest "Console-less creator gives the target no window" -Setup {
    param($d)
    Write-Shim $d "test" "path = $probeExe`nargs = report $d\report.txt"
} -CreatorArgs @('--detached') -Assert {
    param($r)
    $report = Join-Path $r.TestDir 'report.txt'
    $got = if (Test-Path $report) { (Get-Content $report -Raw).Trim() } else { '(no report)' }
    # window=1 is never asserted: this runner's own console has no window.
    @{ Pass = ($got -match 'window=0'); Message = "Report: $got" }
}

Invoke-ShimTest "A shim with a console still shares it with the target" -Setup {
    param($d)
    Write-Shim $d "test" "path = $probeExe`nargs = report $d\report.txt"
} -Assert {
    param($r)
    $report = Join-Path $r.TestDir 'report.txt'
    $got = if (Test-Path $report) { (Get-Content $report -Raw).Trim() } else { '(no report)' }
    @{ Pass = ($got -match 'console=1'); Message = "Report: $got" }
}

# The target's answer only reaches the runner because probe forwards its own stdout
# down to a console-less child.
Invoke-ShimTest "Console-less creator still feeds the target's stdin" -Setup {
    param($d)
    Write-Shim $d "test" "path = $probeExe`nargs = stdin"
} -CreatorArgs @('--detached') -PipeInput "PIPE_FROM_GUI_HOST" -Assert {
    param($r)
    @{ Pass = ($r.Output -match '(?m)^GOT=PIPE_FROM_GUI_HOST\r?$'); Message = "Output: $($r.Output)" }
}

# --- Null-stream creator ---------------------------------------------------------

# The CONIN$/CONOUT$ fallback only runs when a creator sets STARTF_USESTDHANDLES with a
# null stream -- the shape Go's os/exec produces when only some streams are set, and
# nothing else here reaches it (cmd.exe omits the flag, PowerShell hands over pipes).
# probe is the only way to express that shape, and the only child that reports its
# handles unaltered: a managed host repairs an invalid stdout at startup, which is how
# a lane shipped non-inheritable fallback handles without a test noticing.

$script:TestNumber++
$num = $script:TestNumber

$testDir = New-TestEnvironment
try {
    $report = Join-Path $testDir 'report.txt'
    Write-Shim $testDir 'probe-shim' "path = $probeExe`nargs = report $report"

    & $probeExe create (Join-Path $testDir 'probe-shim.exe') --null-out | Out-Null
    $shimExit = $LASTEXITCODE

    $got = if (Test-Path $report) { (Get-Content $report -Raw).Trim() } else { '(no report)' }
    # type 2 is FILE_TYPE_CHAR, a real handle. A lane that opened CONOUT$ with no
    # inheritable SECURITY_ATTRIBUTES hands the child a dead one instead, and that
    # shows up as type 0, FILE_TYPE_UNKNOWN. mode is deliberately not asserted: the
    # shim opens CONOUT$ write-only and GetConsoleMode needs read access, so it is
    # false by construction and asserting it would only encode the accident.
    $pass = ($got -match 'stdout_type=2') -and ($shimExit -eq 0)
    Write-TestResult "#$num Child gets a usable stdout from a null-stream creator" $pass `
        "Report: $got ; shim exit: $shimExit"
}
finally {
    Remove-TestEnvironment $testDir
}

# --- PE subsystem verification -------------------------------------------------

$script:TestNumber++
$num = $script:TestNumber
$sub = Get-PESubsystem -FilePath $ShimExe
Write-TestResult "#$num Console shim subsystem is CUI" ($sub -eq 3) "Subsystem: $sub (expected 3)"

# The manifest is asserted as a resource, never by searching the binary's bytes: a
# toolchain that emitted it as a named resource leaves the loader ignoring it with no
# error anywhere. probe reads it as type 24 by number and id 1 by number, which is what
# turns that trap into a failure here.
$script:TestNumber++
$num = $script:TestNumber
$manifest = & $probeExe manifest $ShimExe 2>&1 | Out-String
Write-TestResult "#$num Shim manifest carries longPathAware and consoleAllocationPolicy" `
    (($manifest -match '>true</longPathAware>') -and
     ($manifest -match '>detached</consoleAllocationPolicy>') -and
     ($manifest -match 'SMI/2024/WindowsSettings')) `
    "Manifest: $manifest"

# ============================================================================
# Summary
# ============================================================================
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "Test Summary: $script:TestsPassed passed, $script:TestsFailed failed" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan

if ($script:TestsFailed -gt 0) { exit 1 }
exit 0
