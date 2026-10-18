# Scoop-Shim Performance Benchmark

- Target: `C:\Windows\System32\whoami.exe` (built-in Windows executable)
- Tool: [hyperfine](https://github.com/sharkdp/hyperfine) 2.x
- Architecture: auto-detected (x64/x86/arm64)

## Usage

```powershell
.\benchmark.ps1
.\benchmark.ps1 -Rounds 20 -Runs 25 -Warmup 5
```

Defaults: `-Rounds 10`, `-Runs 15`, `-Warmup 5`, `-Arch auto` (x86/x64/arm64), `-CanaryTimeoutSec 30`; `-UseShell` forces the system shell, which is also used when a path contains spaces.

Edit `shims/template.shim` to change the benchmark target. `path` may be quoted and may carry a trailing `#` comment: `path = 'C:\...\tool.exe'  # note`.

## Canary and sample policy

Before timing, each shim gets one canary run with stdin closed and a
`-CanaryTimeoutSec` (default 30 s) timeout. A non-zero exit is **not** a failure: a
target that prints usage and exits 1 or 2 is a normal target and stays in the
timing set. Only the Windows loader's launch failures (`0xC0000135` missing DLL,
`0xC000007B` bad image, and the rest of that NTSTATUS family) and a timeout exclude
a shim. If no shim survives, the script fails with exit 1 rather than ranking
`direct` alone.

Below `minIqrSamples` (5) samples per candidate the IQR is withheld (`n/a` in the
table, `null` in the JSON) and no ranking is asserted - at N=1 a zero IQR would
otherwise read as "separated by more than IQR".

## Results

**Re-measure this on the machine you intend to use.** Process-creation cost is a property of the machine: load, security software and storage, and it differs by 3x between machines for identical code. Absolute milliseconds do not carry across machines. The `CPU overhead` column, which measures each shim against launching the target directly, is the only figure that does.

x64, 10 rounds x 15 runs, on one developer's machine:

| Implementation | CPU overhead vs `direct` |
| -------------- | -----------------------: |
| `direct`       |                      - |
| Rust           |             +125.0 ms |
| C++            |             +125.0 ms |
| Zig            |             +125.0 ms |
| C#             |       not measurable  |

The three native lanes land within each other's spread and cannot be ranked against each other. The C# lane is consistently the cheaper one, but on that machine it falls under the CPU timer's resolution, so the script prints `+0`: read that as "below what this benchmark can resolve", not "free". An independent interleaved measurement, taken with a stopwatch rather than hyperfine, put the C# lane 40 to 50 ms below the natives for identical work.

## Files

- `benchmark.ps1` - benchmark runner
- `shims/template.shim` - .shim content template
- `results.md` / `results.json` - last run, regenerated on every run (not tracked). `results.json` is valid JSON with no BOM, and records the per-candidate sample count, the `shuffleSeed` used for round ordering, and any candidate the canary excluded.
