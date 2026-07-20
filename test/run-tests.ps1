#Requires -Version 7

# Functional tests for shim.exe
# Usage: ./run-tests.ps1 -ShimExe <path-to-shim.exe>

param(
    [Parameter(Mandatory=$true)]
    [string]$ShimExe
)

$ErrorActionPreference = "Stop"
$script:TestsPassed = 0
$script:TestsFailed = 0
$script:TestNumber = 0
$psExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

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
# RunArgs: arguments passed to the shim executable
# Assert: scriptblock receiving @{Output; ExitCode} returning $true/$false + message
function Invoke-ShimTest {
    param(
        [string]$Name,
        [Parameter(Mandatory=$true)][scriptblock]$Setup,
        [string[]]$RunArgs = @(),
        [Parameter(Mandatory=$true)][scriptblock]$Assert,
        [string]$PipeInput = $null
    )
    $script:TestNumber++
    $num = $script:TestNumber
    $testDir = New-TestEnvironment
    try {
        & $Setup $testDir
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        if ($PipeInput) {
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
    } finally {
        Remove-TestEnvironment $testDir
    }
}

# Run a GUI subsystem shim test (patches PE to Subsystem=2).
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

        $output = & $guiExe @RunArgs 2>&1 | Out-String
        $result = @{ Output = $output; ExitCode = $LASTEXITCODE }
        $check = & $Assert $result
        if ($check -is [bool]) {
            Write-TestResult "#$num $Name" $check "Output: $output"
        } else {
            Write-TestResult "#$num $Name" $check.Pass $check.Message
        }
    } finally {
        Remove-TestEnvironment $testDir
    }
}

# ============================================================================
# Verify shim.exe
# ============================================================================
if (-not (Test-Path $ShimExe)) {
    Write-Error "Shim executable not found: $ShimExe"
    exit 1
}
$ShimExe = (Resolve-Path $ShimExe).Path
Write-Host "Running tests with: $ShimExe" -ForegroundColor Cyan
Write-Host ""

# ============================================================================
# Tests
# ============================================================================

# --- Basic execution -----------------------------------------------------------

Invoke-ShimTest "Basic shim execution" -Setup {
    param($d)
    Write-Batch "$d\app.cmd" "echo SHIM_BASIC_OK"
    Write-Shim $d "test" "path = $d\app.cmd"
} -Assert { param($r) $r.Output -match "SHIM_BASIC_OK" }

Invoke-ShimTest "Path with spaces" -Setup {
    param($d)
    $sp = "$d\path with spaces"; New-Item -ItemType Directory -Path $sp -Force | Out-Null
    Write-Batch "$sp\app.cmd" "echo SPACES_OK"
    Write-Shim $d "test" "path = $sp\app.cmd"
} -Assert { param($r) $r.Output -match "SPACES_OK" }

# --- %~VAR% expansion ---------------------------------------------------------

Invoke-ShimTest "%~VAR% expansion in path" -Setup {
    param($d)
    Write-Shim $d "test" "path = %SystemRoot%\System32\cmd.exe`nargs = /c echo TEMP=%TEMP%"
} -Assert {
    param($r)
    @{ Pass = $r.Output -match [regex]::Escape("TEMP=$env:TEMP"); Message = "Output: $($r.Output)" }
}

Invoke-ShimTest "Unknown %VAR% preserved as-is" -Setup {
    param($d)
    Write-Batch "$d\echoargs.cmd" "echo %*"
    Write-Shim $d "test" "path = $d\echoargs.cmd`nargs = %NONEXISTENT_SHIM_TEST_VAR%"
} -Assert {
    param($r)
    @{ Pass = $r.Output -match [regex]::Escape("%NONEXISTENT_SHIM_TEST_VAR%"); Message = "Output: $($r.Output)" }
}

# --- Environment variables from .shim -----------------------------------------

Invoke-ShimTest "Environment variables from .shim" -Setup {
    param($d)
    Write-Batch "$d\echoenv.cmd" "echo VAR1=%VAR1%`necho VAR2=%VAR2%`necho VAR3=%VAR3%"
    Write-Shim $d "test" "path = $d\echoenv.cmd`nVAR1 = first`nVAR2 = %USERNAME%_suffix`nVAR3 = third"
} -Assert {
    param($r)
    $pass = ($r.Output -match "VAR1=first") -and ($r.Output -match "VAR3=third") -and ($r.Output -match "VAR2=$($env:USERNAME)_suffix")
    @{ Pass = $pass; Message = "Output: $($r.Output)" }
}

Invoke-ShimTest "Env var value with quotes stripped" -Setup {
    param($d)
    Write-Batch "$d\checkenv.cmd" "echo MY_VAR=%MY_VAR%"
    Write-Shim $d "test" "path = $d\checkenv.cmd`nMY_VAR = `"hello world`""
} -Assert {
    param($r)
    @{ Pass = $r.Output -match "MY_VAR=hello world"; Message = "Output: $($r.Output)" }
}

# --- %~dp0 placeholder --------------------------------------------------------

Invoke-ShimTest "Args %~dp0 expansion (absolute path)" -Setup {
    param($d)
    Write-Shim $d "test" "path = C:\Windows\System32\cmd.exe`nargs = /c echo %~dp0"
} -Assert {
    param($r)
    $expected = "C:\Windows\System32\"
    @{ Pass = $r.Output -match [regex]::Escape($expected); Message = "Expected: $expected, Output: $($r.Output)" }
}

Invoke-ShimTest "Args %~dp0 expansion (relative path)" -Setup {
    param($d)
    New-Item -ItemType Directory -Path "$d\bin" -Force | Out-Null
    Set-Content -Path "$d\bin\app.cmd" -Value "@echo off`necho %*"
    Write-Shim $d "test" "path = $d\bin\app.cmd`nargs = %~dp0"
} -Assert {
    param($r)
    # path resolves to $d\bin\app.cmd → target dir = $d\bin\
    $expected = "$($r.TestDir)\bin\"
    @{ Pass = $r.Output.StartsWith($expected, [StringComparison]::OrdinalIgnoreCase); Message = "Expected prefix: $expected, Output: $($r.Output)" }
}

# --- Pass-through arguments & quoting -------------------------------------------

Invoke-ShimTest "Pass-through arguments" -Setup {
    param($d)
    Write-Batch "$d\echoargs.cmd" "echo ARGS=%*"
    Write-Shim $d "test" "path = $d\echoargs.cmd"
} -RunArgs @("arg1", "arg2", "arg with spaces") -Assert {
    param($r)
    $pass = ($r.Output -match "arg1") -and ($r.Output -match "arg2") -and ($r.Output -match "arg with spaces")
    @{ Pass = $pass; Message = "Output: $($r.Output)" }
}

Invoke-ShimTest "Args with embedded quotes (PS target)" -Setup {
    param($d)
    Write-Shim $d "test" "path = $psExe`nargs = -NoProfile -Command"
} -RunArgs @("Write-Host 'QUOTE_TEST'") -Assert {
    param($r) $r.Output -match "QUOTE_TEST"
}

Invoke-ShimTest "Shim + user args combined" -Setup {
    param($d)
    Write-Batch "$d\echoargs.cmd" "echo %*"
    Write-Shim $d "test" "path = $d\echoargs.cmd`nargs = --flag value"
} -RunArgs @("--extra") -Assert {
    param($r)
    $pass = ($r.Output -match "--flag") -and ($r.Output -match "value") -and ($r.Output -match "--extra")
    @{ Pass = $pass; Message = "Output: $($r.Output)" }
}

Invoke-ShimTest "Args with backslashes" -Setup {
    param($d)
    Write-Batch "$d\echoargs.cmd" "echo %*"
    Write-Shim $d "test" "path = $d\echoargs.cmd"
} -RunArgs @("C:\path\to\file") -Assert {
    param($r) $r.Output -match 'C:\\path\\to\\file'
}

Invoke-ShimTest "Shim args with spaces in value" -Setup {
    param($d)
    Write-Batch "$d\echoargs.cmd" "echo %*"
    Write-Shim $d "test" "path = $d\echoargs.cmd`nargs = --dir `"C:\Program Files\App`""
} -Assert { param($r) $r.Output -match "Program Files" }

# --- Exit code & I/O -----------------------------------------------------------

Invoke-ShimTest "Non-zero exit code (42)" -Setup {
    param($d)
    Set-Content -Path "$d\exit42.cmd" -Value "@exit 42"
    Write-Shim $d "test" "path = $d\exit42.cmd"
} -Assert {
    param($r)
    @{ Pass = $r.ExitCode -eq 42; Message = "Expected: 42, Got: $($r.ExitCode)" }
}

Invoke-ShimTest "stderr output preserved" -Setup {
    param($d)
    Write-Batch "$d\stderr.cmd" "echo stdout line`necho stderr line 1>&2"
    Write-Shim $d "test" "path = $d\stderr.cmd"
} -Assert {
    param($r)
    $pass = ($r.Output -match "stdout line") -and ($r.Output -match "stderr line")
    @{ Pass = $pass; Message = "Output: $($r.Output)" }
}

Invoke-ShimTest "stdin pipe" -Setup {
    param($d)
    Set-Content -Path "$d\readstdin.cmd" -Value "@echo off`nset /p INPUT=`necho GOT=%INPUT%"
    Write-Shim $d "test" "path = $d\readstdin.cmd"
} -PipeInput "HELLO_STDIN" -Assert {
    param($r) $r.Output -match "GOT=HELLO_STDIN"
}

# --- Comment handling ---------------------------------------------------------

Invoke-ShimTest "Ignore comment lines" -Setup {
    param($d)
    Write-Batch "$d\echoargs.cmd" "echo ARGS=%*"
    Write-Shim $d "test" "# hash comment`n; semicolon comment`n// slash comment`n  # indented comment`npath = $d\echoargs.cmd`nargs = --verified"
} -Assert { param($r) $r.Output -match "ARGS=--verified" }

# --- UTF-8 BOM handling -------------------------------------------------------

Invoke-ShimTest "UTF-8 BOM in shim file" -Setup {
    param($d)
    Write-Batch "$d\app.cmd" "echo BOM_OK"
    Copy-Item $ShimExe "$d\test.exe"
    $content = "# comment`npath = $d\app.cmd"
    $bom = [System.Text.Encoding]::UTF8.GetPreamble()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($content)
    [System.IO.File]::WriteAllBytes("$d\test.shim", $bom + $bytes)
} -Assert { param($r) $r.Output -match "BOM_OK" }

# --- cwd configuration --------------------------------------------------------

Invoke-ShimTest "cwd configured" -Setup {
    param($d)
    $cwdDir = "$d\workdir"
    New-Item -ItemType Directory -Path $cwdDir -Force | Out-Null
    Write-Batch "$d\echocwd.cmd" "echo %CD%"
    Write-Shim $d "test" "path = $d\echocwd.cmd`ncwd = $cwdDir"
} -Assert {
    param($r)
    @{ Pass = $r.Output -match [regex]::Escape("$($r.TestDir)\workdir"); Message = "Output: $($r.Output)" }
}

Invoke-ShimTest "cwd %~dp0 expansion" -Setup {
    param($d)
    $subDir = "$d\sub"
    New-Item -ItemType Directory -Path $subDir -Force | Out-Null
    Write-Batch "$d\echocwd.cmd" "echo %CD%"
    Write-Shim $d "test" "path = $d\echocwd.cmd`ncwd = %~dp0sub"
} -Assert {
    param($r)
    $expected = "$($r.TestDir)\sub"
    @{ Pass = $r.Output -match [regex]::Escape($expected); Message = "Expected: $expected, Output: $($r.Output)" }
}

Invoke-ShimTest "cwd %TEMP% expansion" -Setup {
    param($d)
    Write-Batch "$d\echocwd.cmd" "echo %CD%"
    Write-Shim $d "test" "path = $d\echocwd.cmd`ncwd = %TEMP%"
} -Assert {
    param($r)
    @{ Pass = $r.Output -match [regex]::Escape($env:TEMP); Message = "Expected: $env:TEMP, Output: $($r.Output)" }
}

Invoke-ShimTest "cwd value with quotes stripped" -Setup {
    param($d)
    $cwdDir = "$d\workdir"
    New-Item -ItemType Directory -Path $cwdDir -Force | Out-Null
    Write-Batch "$d\echocwd.cmd" "echo %CD%"
    Write-Shim $d "test" "path = $d\echocwd.cmd`ncwd = `"$cwdDir`""
} -Assert {
    param($r)
    @{ Pass = $r.Output -match [regex]::Escape("$($r.TestDir)\workdir"); Message = "Output: $($r.Output)" }
}

Invoke-ShimTest "workdir alias for cwd" -Setup {
    param($d)
    $wdDir = "$d\wd"
    New-Item -ItemType Directory -Path $wdDir -Force | Out-Null
    Write-Batch "$d\echocwd.cmd" "echo %CD%"
    Write-Shim $d "test" "path = $d\echocwd.cmd`nworkdir = $wdDir"
} -Assert {
    param($r)
    @{ Pass = $r.Output -match [regex]::Escape("$($r.TestDir)\wd"); Message = "Output: $($r.Output)" }
}

# --- Process lifecycle ---------------------------------------------------------

# Direct-child-only: complex process chain — uses Start-Process + Wait-Process
# to verify shim exits when its direct child exits but leaves the grandchild alive.
$script:TestNumber++
$num = $script:TestNumber
$testDir = New-TestEnvironment
try {
    $done = Join-Path $testDir "done"
    $gpid = Join-Path $testDir "gpid"
    $rawCmd = '$p=Start-Process ' + $psExe + ' -WindowStyle Hidden -PassThru -ArgumentList ''-NoProfile'',''-Command'',''Start-Sleep -Seconds 30'';' +
        "`$p.Id|Out-File '$gpid'; Set-Content '$done' 'done'"
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($rawCmd))

    Write-Shim $testDir "test" "path = $psExe`nargs = -NoProfile -ExecutionPolicy Bypass -EncodedCommand $enc"
    $shim = Start-Process "$testDir\test.exe" -PassThru -NoNewWindow `
        -RedirectStandardOutput "$testDir\stdout.txt" -RedirectStandardError "$testDir\stderr.txt"
    $shim | Wait-Process -Timeout 20 -ErrorAction SilentlyContinue

    $gp = (Get-Content $gpid -ErrorAction SilentlyContinue | Select -First 1) -as [int]
    $pass = ($gp -gt 0) -and (Get-Process -Id $gp -ErrorAction SilentlyContinue) -and $shim.HasExited
    Write-TestResult "#$num Direct-child-only lifecycle" $pass
} finally {
    Remove-TestEnvironment $testDir
}

Invoke-ShimTest "shim waits for long-running child" -Setup {
    param($d)
    Set-Content -Path "$d\sleep2.cmd" -Value "@echo off`nping -n 3 127.0.0.1 > nul`necho WAITED_OK"
    Write-Shim $d "test" "path = $d\sleep2.cmd"
} -Assert {
    param($r)
    $pass = ($r.Output -match "WAITED_OK") -and ($r.Elapsed.TotalSeconds -gt 1.5)
    @{ Pass = $pass; Message = "Output: $($r.Output), Elapsed: $($r.Elapsed.TotalSeconds)s" }
}

# --- Special key handling ------------------------------------------------------

Invoke-ShimTest "Special keys not leaked as env vars" -Setup {
    param($d)
    Write-Batch "$d\checkenv.cmd" "echo ELEVATE_ENV=%elevate%`necho CWD_ENV=%cwd%"
    Write-Shim $d "test" "path = $d\checkenv.cmd`nelevate = false`ncwd = $d"
} -Assert {
    param($r)
    @{ Pass = ($r.Output -notmatch "ELEVATE_ENV=\S") -and ($r.Output -notmatch "CWD_ENV=\S"); Message = "Output: $($r.Output)" }
}

Invoke-ShimTest "runas alias not leaked as env var" -Setup {
    param($d)
    Write-Batch "$d\checkenv.cmd" "echo RUNAS_ENV=%runas%"
    Write-Shim $d "test" "path = $d\checkenv.cmd`nrunas = false"
} -Assert {
    param($r)
    @{ Pass = $r.Output -notmatch "RUNAS_ENV=\S"; Message = "Output: $($r.Output)" }
}

Invoke-ShimTest "elevate = true triggers elevation path" -Setup {
    param($d)
    Write-Batch "$d\app.cmd" "echo ELEVATE_MARKER"
    Write-Shim $d "test" "path = $d\app.cmd`nelevate = true"
} -Assert {
    param($r)
    # Elevation path (ShellExecuteExW) runs child in a separate console — output
    # never reaches this pipe. Bug path (CreateProcessW) inherits our console.
    $bugPresent = ($r.Output -match "ELEVATE_MARKER") -and ($r.ExitCode -eq 0)
    @{ Pass = -not $bugPresent; Message = "Output: $($r.Output), ExitCode: $($r.ExitCode)" }
}

# --- GUI subsystem -------------------------------------------------------------

Invoke-GuiShimTest "GUI shim with args preserves CLI" -Setup {
    param($d)
    Write-Batch "$d\echoargs.cmd" "echo ARGS=%*"
    Set-Content -Path "$d\gui-shim.shim" -Value "path = $d\echoargs.cmd"
} -RunArgs @("--help", "--version") -Assert {
    param($r) $r.Output -match "ARGS=--help --version"
}

Invoke-GuiShimTest "GUI shim no-arg does not crash" -Setup {
    param($d)
    Write-Batch "$d\simple.cmd" "echo GUI_NOARG_OK"
    Set-Content -Path "$d\gui-shim.shim" -Value "path = $d\simple.cmd"
} -Assert {
    param($r)
    @{ Pass = $r.ExitCode -eq 0; Message = "ExitCode: $($r.ExitCode)" }
}

Invoke-GuiShimTest "GUI shim exit code (7)" -Setup {
    param($d)
    Set-Content -Path "$d\exit7.cmd" -Value "@exit 7"
    Set-Content -Path "$d\gui-shim.shim" -Value "path = $d\exit7.cmd"
} -Assert {
    param($r)
    @{ Pass = $r.ExitCode -eq 7; Message = "Expected: 7, Got: $($r.ExitCode)" }
}

# --- PE subsystem verification -------------------------------------------------

$script:TestNumber++
$num = $script:TestNumber
$sub = Get-PESubsystem -FilePath $ShimExe
Write-TestResult "#$num Console shim subsystem is CUI" ($sub -eq 3) "Subsystem: $sub (expected 3)"

# ============================================================================
# Summary
# ============================================================================
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "Test Summary: $script:TestsPassed passed, $script:TestsFailed failed" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan

if ($script:TestsFailed -gt 0) { exit 1 }
exit 0
