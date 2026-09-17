# Scoop-Shim Performance Benchmark
param(
    [int]$Warmup = 20,
    [int]$Runs = 50
)

$ErrorActionPreference = "Stop"

# Locate hyperfine dynamically
$hf = (Get-Command hyperfine -ErrorAction SilentlyContinue).Source
if (-not $hf) {
    Write-Host "[FAIL] hyperfine not found. Install with:" -ForegroundColor Red
    Write-Host "  scoop install hyperfine" -ForegroundColor Yellow
    exit 1
}

$benchDir = $PSScriptRoot
$sd = Join-Path $benchDir "shims"
$reporoot = (Get-Item $benchDir).Parent.FullName

# Auto-detect architecture
$arch = switch ([System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture) {
    "X64"   { "x64" }
    "X86"   { "x86" }
    "Arm64" { "arm64" }
    default { "x64" }
}
Write-Host "[Arch] $arch" -ForegroundColor Cyan

# Shim definitions: name, relative bin path under each lang dir
$shims = @(
    @{N="Rust"; Dest="rust";  Src="$reporoot\rust\bin\$arch\shim.exe"}
    @{N="C++";  Dest="cpp";   Src="$reporoot\cpp\bin\$arch\shim.exe"}
    @{N="C#";   Dest="cs";    Src="$reporoot\cs\bin\$arch\shim.exe"}
    @{N="Zig";  Dest="zig";   Src="$reporoot\zig\bin\$arch\shim.exe"}
)

# Template from shims/template — also source of baseline target path
$template = Join-Path $sd "template.shim"
switch -Regex (Get-Content $template) {
    '^path\s*=\s*(.+)' { $refExe = $Matches[1].Trim(); break }
}

Write-Host "[Setup]" -ForegroundColor Cyan
foreach ($s in $shims) {
    if (-not (Test-Path $s.Src)) {
        Write-Warning "$($s.N) source not found: $($s.Src)"
        continue
    }

    $exe = Join-Path $sd "shim-$($s.Dest).exe"
    Copy-Item $s.Src $exe -Force

    $shimFile = $exe -replace '\.exe$', '.shim'
    Copy-Item $template $shimFile -Force

    $p = [Diagnostics.Process]::Start((
        New-Object Diagnostics.ProcessStartInfo $exe -Property @{
            UseShellExecute=$false; CreateNoWindow=$true
        }
    ))
    $p.WaitForExit()
    $ec = $p.ExitCode
    $p.Dispose()

    $size = (Get-Item $exe).Length
    $status = if ($ec -eq 0) { 'ok' } else { "exit=$ec" }
    Write-Host "  $($s.N): $( [Math]::Round($size/1KB) )KB  $status" -ForegroundColor Gray
}

# Build hyperfine args (randomized order to avoid cache bias)
$order = $shims | Sort-Object { Get-Random }
$resultsMd   = Join-Path $benchDir "results.md"
$resultsJson = Join-Path $benchDir "results.json"

$hfArgs = @(
    "-w", "$Warmup"; "-r", "$Runs"
    "--time-unit", "millisecond"
    "--sort", "mean-time"
    "--export-markdown", $resultsMd
    "--export-json", $resultsJson
    "--ignore-failure"
    "--reference", $refExe; "--reference-name", "direct"
)

foreach ($s in $order) {
    $exe = Join-Path $sd "shim-$($s.Dest).exe"
    $hfArgs += "--command-name"; $hfArgs += $s.N
    $hfArgs += $exe
}

Write-Host "[Bench] hyperfine -w $Warmup -r $Runs (order randomized)" -ForegroundColor Cyan
& $hf $hfArgs 2>&1

# Post-process: compute absolute extra time vs direct
if (Test-Path $resultsJson) {
    $json = Get-Content $resultsJson -Raw | ConvertFrom-Json
    $refResult = $json.results | Where-Object { $_.command -eq 'direct' }

    if ($refResult) {
        $refMeanMs = $refResult.mean * 1000

        Write-Host "`n=== Extra time vs direct ===`n" -ForegroundColor Cyan
        Write-Host ("{0,-10} {1,10} {2,10}  {3}" -f "Shim", "Mean(ms)", "Extra(ms)", "× slower")
        Write-Host ("{0,-10} {1,10:F1} {2,10}  {3}" -f "direct", $refMeanMs, "—", "baseline") -ForegroundColor Green

        foreach ($r in $json.results | Sort-Object mean) {
            if ($r.command -eq 'direct') { continue }
            $meanMs = $r.mean * 1000
            $extraMs = $meanMs - $refMeanMs
            $ratio = $meanMs / $refMeanMs
            $extraStr = if ($extraMs -ge 0) { "+{0:F1}" -f $extraMs } else { "{0:F1}" -f $extraMs }
            Write-Host ("{0,-10} {1,10:F1} {2,10}  {3,6:F2}×" -f $r.command, $meanMs, $extraStr, $ratio)
        }
    }
}

if (Test-Path $resultsMd) {
    Write-Host "`n$(Get-Content $resultsMd -Raw)" -ForegroundColor Green
}
Write-Host "[Done] $resultsMd" -ForegroundColor Cyan
