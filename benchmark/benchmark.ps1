# Scoop-Shim startup benchmark.
#
# Candidates run without the system shell (hyperfine's shell-words parser
# escapes backslashes, so paths use forward slashes). Each candidate gets its
# own invocation per round, in a reshuffled order - see the comment at the
# timing loop for why one invocation for all of them would be wrong. Wall and
# CPU are pooled per run, so the two medians and IQRs describe the same set of
# measurements. CPU time is reported next to wall clock because wall clock is
# unreliable on a busy machine.
#
# Requires hyperfine 2.x: the export layout is schema_version 2, where per-run
# samples live in results[].measurements[].time_wall_clock.value.
#
# Usage:
#   pwsh -File benchmark/benchmark.ps1
#   pwsh -File benchmark/benchmark.ps1 -Rounds 20 -Runs 25 -Warmup 5
param(
    [int]$Rounds = 10,
    [int]$Runs = 15,
    [int]$Warmup = 5,
    [string]$Arch = '',
    [int]$CanaryTimeoutSec = 30,
    [switch]$UseShell
)

$ErrorActionPreference = "Stop"

if ($Rounds -lt 1 -or $Runs -lt 1 -or $Warmup -lt 0 -or $CanaryTimeoutSec -lt 1) {
    Write-Host "[FAIL] -Rounds and -Runs must be >= 1, -Warmup >= 0, -CanaryTimeoutSec >= 1." -ForegroundColor Red
    exit 1
}
if ($Arch -and $Arch -notin @("x64", "x86", "arm64")) {
    Write-Host "[FAIL] unknown -Arch '$Arch'; expected x64, x86 or arm64." -ForegroundColor Red
    exit 1
}

$hf = (Get-Command hyperfine -ErrorAction SilentlyContinue).Source
if (-not $hf) {
    Write-Host "[FAIL] hyperfine not found. Install with:" -ForegroundColor Red
    Write-Host "  scoop install hyperfine" -ForegroundColor Yellow
    exit 1
}

$benchDir = $PSScriptRoot
$sd = Join-Path $benchDir "shims"
$reporoot = (Get-Item $benchDir).Parent.FullName

if (-not $Arch) {
    $Arch = switch ([System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture) {
        "X64" { "x64" }
        "X86" { "x86" }
        "Arm64" { "arm64" }
        default { "x64" }
    }
}
Write-Host "[Arch] $Arch" -ForegroundColor Cyan

# The direct baseline is whatever the template points at.
$template = Join-Path $sd "template.shim"
if (-not (Test-Path $template)) {
    Write-Host "[FAIL] template not found: $template" -ForegroundColor Red
    exit 1
}
$refExe = $null
foreach ($line in Get-Content $template) {
    # Tolerate quotes and a trailing comment: path = 'C:\...'  # note
    if ($line -match '^\s*path\s*=\s*(?<v>.+?)(?:\s+#.*)?\s*$') {
        $refExe = $Matches['v'].Trim().Trim("'`"")
        break
    }
}
if (-not $refExe -or -not (Test-Path $refExe)) {
    Write-Host "[FAIL] baseline target not found from template: $refExe" -ForegroundColor Red
    exit 1
}

# name -> source exe; shims are staged once so file state stays constant.
$impls = [ordered]@{
    "direct" = $refExe
    "Rust"   = "$reporoot\rust\bin\$Arch\shim.exe"
    "C++"    = "$reporoot\cpp\bin\$Arch\shim.exe"
    "C#"     = "$reporoot\cs\bin\$Arch\shim.exe"
    "Zig"    = "$reporoot\zig\bin\$Arch\shim.exe"
}

Write-Host "[Setup]" -ForegroundColor Cyan
$paths = [ordered]@{}
foreach ($name in $impls.Keys) {
    $src = $impls[$name]
    if ($name -eq "direct") {
        $paths[$name] = $refExe
        Write-Host "  direct  -> $refExe" -ForegroundColor Gray
        continue
    }
    if (-not (Test-Path $src)) {
        Write-Warning "$name source not found: $src"
        continue
    }
    $dest = Join-Path $sd "shim-$name.exe"
    Copy-Item $src $dest -Force
    Copy-Item $template ($dest -replace '\.exe$', '.shim') -Force
    $paths[$name] = $dest
    Write-Host ("  {0,-7} {1,6} KB" -f $name, [Math]::Round((Get-Item $dest).Length / 1KB)) -ForegroundColor Gray
}

# hyperfine's shell-words parser treats backslashes as escapes in BOTH modes, so a
# Windows path must use forward slashes either way. cmd.exe accepts them too.
$noShell = -not $UseShell
if ($noShell -and ($paths.Values | Where-Object { $_ -match '\s' })) {
    Write-Warning "A command path contains whitespace; falling back to shell mode."
    $noShell = $false
}
$commandPaths = [ordered]@{}
foreach ($name in $paths.Keys) {
    $commandPaths[$name] = $paths[$name] -replace '\\', '/'
}
Write-Host ("[Mode] {0}" -f ($(if ($noShell) { "--shell=none (direct exec)" } else { "system shell" }))) -ForegroundColor Cyan

# Canary: only loader launch failures exclude a shim; a non-zero exit is a normal target.
$launchFailures = @{
    -1073741819 = "0xC0000005 STATUS_ACCESS_VIOLATION"      # shim crashed before the target ran
    -1073741701 = "0xC000007B STATUS_INVALID_IMAGE_FORMAT"  # not a valid PE for this architecture
    -1073741515 = "0xC0000135 STATUS_DLL_NOT_FOUND"         # a dependency is missing
    -1073741511 = "0xC0000139 STATUS_ENTRYPOINT_NOT_FOUND"  # an imported export is missing
    -1073741502 = "0xC0000142 STATUS_DLL_INIT_FAILED"       # a DLL failed to initialise
}

function Test-Canary {
    param([string]$ExePath, [int]$TimeoutMs)
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $ExePath
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    # EOF on stdin; a long-lived target is killed at the timeout, not left hanging.
    $p.StandardInput.Close()
    if (-not $p.WaitForExit($TimeoutMs)) {
        $p.Kill()
        return [pscustomobject]@{ Code = $null; TimedOut = $true }
    }
    return [pscustomobject]@{ Code = $p.ExitCode; TimedOut = $false }
}

Write-Host "[Canary]" -ForegroundColor Cyan
$excluded = [ordered]@{}
foreach ($name in @($paths.Keys)) {
    if ($name -eq "direct") { continue }
    $r = Test-Canary -ExePath $paths[$name] -TimeoutMs ($CanaryTimeoutSec * 1000)
    if ($r.TimedOut) {
        Write-Warning "$name did not exit within ${CanaryTimeoutSec}s - excluded from timing"
        $excluded[$name] = "timeout after ${CanaryTimeoutSec}s"
        $paths.Remove($name)
    } elseif ($launchFailures.ContainsKey([int]$r.Code)) {
        Write-Warning "$name could not launch ($($launchFailures[[int]$r.Code])) - excluded from timing"
        $excluded[$name] = "launch failure $($launchFailures[[int]$r.Code])"
        $paths.Remove($name)
    } else {
        Write-Host ("  {0,-7} exit {1}" -f $name, $r.Code) -ForegroundColor Gray
    }
}

# No surviving candidate would leave 'direct' alone in the table with a bogus ranking note.
if (@($paths.Keys | Where-Object { $_ -ne "direct" }).Count -eq 0) {
    Write-Host "[FAIL] no shim candidate survived setup/canary for arch '$Arch' - nothing to compare against 'direct'." -ForegroundColor Red
    if ($excluded.Count) {
        Write-Host ("  excluded: " + (($excluded.GetEnumerator() | ForEach-Object { "$($_.Key) ($($_.Value))" }) -join ", ")) -ForegroundColor Yellow
    } else {
        Write-Host "  no lane binary was found under bin/$Arch; build one with its lane build script." -ForegroundColor Yellow
    }
    exit 1
}

# name -> pooled per-run samples (ms), wall and CPU from the same runs
$wall = @{}
$cpu = @{}
foreach ($name in $paths.Keys) {
    $wall[$name] = New-Object System.Collections.ArrayList
    $cpu[$name] = New-Object System.Collections.ArrayList
}

$names = @($paths.Keys)
# One hyperfine invocation per candidate per round, in a freshly shuffled order.
# hyperfine 2.x does NOT interleave: src/benchmark/scheduler.rs runs every run of
# command 1, then every run of command 2, so passing all candidates to a single
# invocation would confound measurement position with candidate identity across
# every round. Upstream issue #21 asks for interleaving and is still open.
#
# Seed the shuffle so a run is reproducible from results.json; Get-Random -SetSeed is unbiased.
$seed = [int](Get-Random -Minimum 0 -Maximum 2147483647)
# Unique per run: a failed hyperfine run cannot re-read the previous round's export.
$tmp = Join-Path $env:TEMP "shim-bench-$PID-$(New-Guid).json"
Write-Host "[Bench] $Rounds rounds x $Runs runs per candidate, warmup $Warmup once (order shuffled per round, seed $seed)" -ForegroundColor Cyan
try {
    for ($round = 1; $round -le $Rounds; $round++) {
        # Warm up once; the cold-start cost does not recur.
        $w = if ($round -eq 1) { $Warmup } else { 0 }
        $order = Get-Random -InputObject $names -Count $names.Count -SetSeed ($seed + $round)
        foreach ($name in $order) {
            $hfArgs = @("-w", "$w", "-r", "$Runs", "--export-json", $tmp, "--ignore-failure", "-n", $name)
            if ($noShell) { $hfArgs += "--shell=none" }
            $hfArgs += $commandPaths[$name]

            # Keep hyperfine's diagnostics: a failure that produces no export file is
            # otherwise indistinguishable from one that merely timed nothing.
            $hfOut = & $hf @hfArgs 2>&1
            if (-not (Test-Path $tmp)) {
                throw "hyperfine produced no export for $name in round $round`n$($hfOut -join "`n")"
            }
            $parsed = Get-Content $tmp -Raw | ConvertFrom-Json
            $entry = $parsed.results[0]
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue

            # Fail loudly rather than emitting a table of NaN: an absent array reads as
            # null and would sail through the empty check below.
            if (-not $entry -or -not $entry.measurements) {
                throw "hyperfine export for '$name' has no 'measurements' array (schema_version='$($parsed.schema_version)'). This script targets the hyperfine 2.x export layout.`n$($hfOut -join "`n")"
            }
            $samples = @($entry.measurements)
            if ($samples.Count -eq 0) {
                Write-Warning "$name produced no samples - command failed to run: $($commandPaths[$name])"
                continue
            }
            foreach ($m in $samples) {
                [void]$wall[$name].Add([double]$m.time_wall_clock.value * 1000)
                [void]$cpu[$name].Add([double]$m.time_cpu.value * 1000)
            }
        }
        Write-Host "  round $round/$Rounds" -ForegroundColor DarkGray
    }
} finally {
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
}

function Get-Quantile {
    param([double[]]$Sorted, [double]$P)
    # Linear interpolation between closest ranks (R type 7), so the even-N median is the mean.
    if ($Sorted.Count -eq 1) { return $Sorted[0] }
    $pos = ($Sorted.Count - 1) * $P
    $lo = [int][Math]::Floor($pos)
    $hi = [int][Math]::Ceiling($pos)
    if ($lo -eq $hi) { return $Sorted[$lo] }
    return $Sorted[$lo] + ($pos - $lo) * ($Sorted[$hi] - $Sorted[$lo])
}

# Below this many samples the IQR describes N, not the shim (at N=1 it reads as zero variance).
$MinIqrSamples = 5

function Get-Stat {
    param([double[]]$Values)
    $s = @($Values | Sort-Object)
    if ($s.Count -eq 0) { return [pscustomobject]@{ N = 0; Median = [double]::NaN; Iqr = [double]::NaN } }
    $median = Get-Quantile -Sorted $s -P 0.5
    $iqr = if ($s.Count -ge $MinIqrSamples) { (Get-Quantile -Sorted $s -P 0.75) - (Get-Quantile -Sorted $s -P 0.25) } else { [double]::NaN }
    return [pscustomobject]@{
        N      = $s.Count
        Median = [Math]::Round($median, 1)
        Iqr    = if ([double]::IsNaN($iqr)) { $iqr } else { [Math]::Round($iqr, 1) }
    }
}

$stats = @{}
foreach ($name in $names) {
    $w = Get-Stat @($wall[$name])
    $c = Get-Stat @($cpu[$name])
    $stats[$name] = [pscustomobject]@{ N = $c.N; Wall = $w.Median; WallIqr = $w.Iqr; Cpu = $c.Median; CpuIqr = $c.Iqr }
}

# A NaN median means no usable sample: report n/a, and never assert a ranking on it.
function Format-Cell {
    param($v)
    if ($null -eq $v -or [double]::IsNaN([double]$v)) { return "n/a" }
    return $v
}

$refCpu = $stats["direct"].Cpu
$haveRef = -not [double]::IsNaN([double]$refCpu)
if (-not $haveRef) { Write-Warning "'direct' produced no CPU samples; CPU overhead cannot be computed." }

Write-Host "`n=== Startup latency ($Rounds rounds x $Runs runs) ===`n" -ForegroundColor Cyan
Write-Host ("{0,-8} {1,5} {2,10} {3,10} {4,10} {5,10} {6,14}" -f "Shim", "N", "Wall[ms]", "WallIQR", "CPU[ms]", "CPUIQR", "CPU overhead")
foreach ($name in $names) {
    $s = $stats[$name]
    $overhead = if ($name -eq "direct" -or -not $haveRef) { "-" } else { "{0:+0.0;-0.0;0}" -f ($s.Cpu - $refCpu) }
    Write-Host ("{0,-8} {1,5} {2,10} {3,10} {4,10} {5,10} {6,14}" -f $name, $s.N, (Format-Cell $s.Wall), (Format-Cell $s.WallIqr), (Format-Cell $s.Cpu), (Format-Cell $s.CpuIqr), $overhead)
}

# Flag rankings the noise cannot resolve; below MinIqrSamples there is no IQR to compare with.
$ranked = @($names | Where-Object { $_ -ne "direct" } | Sort-Object { $stats[$_].Cpu })
if ($ranked.Count -lt 2) {
    Write-Host "Note: fewer than two candidates - no ranking to resolve." -ForegroundColor DarkGray
} elseif (@($ranked | Where-Object { [double]::IsNaN([double]$stats[$_].CpuIqr) }).Count -gt 0) {
    Write-Host "Note: fewer than $MinIqrSamples samples per candidate - IQR withheld and rankings not asserted." -ForegroundColor Yellow
} else {
    $unresolved = $false
    for ($i = 0; $i -lt $ranked.Count - 1; $i++) {
        $a = $stats[$ranked[$i]]
        $b = $stats[$ranked[$i + 1]]
        if ($b.Cpu - $a.Cpu -lt (($a.CpuIqr + $b.CpuIqr) / 2)) {
            Write-Host "Note: $($ranked[$i]) and $($ranked[$i + 1]) overlap within their IQR - not resolvable." -ForegroundColor Yellow
            $unresolved = $true
        }
    }
    if (-not $unresolved) { Write-Host "Note: all shims are separated by more than their IQR." -ForegroundColor DarkGray }
}

# --- export -------------------------------------------------------------------

# ConvertTo-Json writes a bare NaN token, which is not valid JSON; emit null instead.
function Convert-Number {
    param($v)
    if ($null -eq $v -or [double]::IsNaN([double]$v)) { return $null }
    return [Math]::Round([double]$v, 1)
}

$resultsJson = Join-Path $benchDir "results.json"
$json = [ordered]@{
    arch             = $Arch
    mode             = if ($noShell) { "shell=none" } else { "shell" }
    rounds           = $Rounds
    runs             = $Runs
    warmup           = $Warmup
    shuffleSeed      = $seed
    canaryTimeoutSec = $CanaryTimeoutSec
    minIqrSamples    = $MinIqrSamples
    baseline         = "direct"
    excluded         = @(foreach ($k in $excluded.Keys) { [ordered]@{ command = $k; reason = $excluded[$k] } })
    results          = @(foreach ($name in $names) {
            [ordered]@{
                command     = $name
                samples     = $stats[$name].N
                wallMedian  = Convert-Number $stats[$name].Wall
                wallIqr     = Convert-Number $stats[$name].WallIqr
                cpuMedian   = Convert-Number $stats[$name].Cpu
                cpuIqr      = Convert-Number $stats[$name].CpuIqr
                cpuOverhead = if ($name -eq "direct" -or -not $haveRef) { $null } else { [Math]::Round($stats[$name].Cpu - $refCpu, 1) }
            }
        })
}
# WriteAllText: Set-Content -Encoding utf8 prepends a BOM on PS5.1, which is not valid JSON.
[IO.File]::WriteAllText($resultsJson, ($json | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))

$md = @()
$md += "| Implementation | Samples | Wall median [ms] | Wall IQR | CPU median [ms] | CPU IQR | CPU overhead [ms] |"
$md += "| -------------- | ------: | ---------------: | -------: | --------------: | ------: | ----------------: |"
foreach ($name in $names) {
    $s = $stats[$name]
    $overhead = if ($name -eq "direct" -or -not $haveRef) { "-" } else { "{0:+0.0;-0.0;0}" -f ($s.Cpu - $refCpu) }
    $md += "| $name | $($s.N) | $(Format-Cell $s.Wall) | $(Format-Cell $s.WallIqr) | $(Format-Cell $s.Cpu) | $(Format-Cell $s.CpuIqr) | $overhead |"
}
$resultsMd = Join-Path $benchDir "results.md"
[IO.File]::WriteAllText($resultsMd, ($md -join [Environment]::NewLine) + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "`nResults written to:" -ForegroundColor Cyan
Write-Host "  $resultsMd"
Write-Host "  $resultsJson"
