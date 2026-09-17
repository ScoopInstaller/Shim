# Scoop-Shim Performance Benchmark

Target: `C:\Windows\System32\whoami.exe` (built-in Windows executable)
Tool: [hyperfine](https://github.com/sharkdp/hyperfine)
Architecture: auto-detected (x64/x86/arm64)
20 warmup + 50 measured runs per implementation (randomized order)

## Usage

```powershell
.\benchmark.ps1
```

Template `.shim` file at `shims/template.shim` — edit to change benchmark target.

## Results

| Command | Mean [ms] | Min [ms] | Max [ms] | Relative |
|:---|---:|---:|---:|---:|
| `direct` | 16.5 ± 3.7 | 10.3 | 25.2 | 1.00 |
| `C#` | 26.1 ± 3.5 | 20.4 | 36.1 | 1.58 ± 0.41 |
| `Zig` | 77.4 ± 3.3 | 71.6 | 88.8 | 4.70 ± 1.07 |
| `Rust` | 78.2 ± 6.8 | 68.8 | 108.0 | 4.75 ± 1.15 |
| `C++` | 80.5 ± 12.1 | 69.5 | 134.9 | 4.89 ± 1.32 |

## Files

- `shims/template.shim` — .shim content template (edit to change target)
- `benchmark.ps1` — benchmark runner
