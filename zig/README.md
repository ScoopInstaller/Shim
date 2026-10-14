# Zig Shim Development Guide

Shim file format and usage: [../README.md](../README.md). Design rationale: [../RATIONALE.md](../RATIONALE.md).

## Overview

Pure Zig implementation of the Scoop shim, statically linked, zero runtime dependencies. Supports x86, x64, and arm64.

## Prerequisites

- **Zig 0.17.0+** -- required for building

## Build

```pwsh
cd zig

# Single target
.\build.ps1 -Target x64

# All targets
.\build.ps1

# Debug build
.\build.ps1 -Target x64 -Configuration Debug

# Output: bin/{x86|x64|arm64}/shim.exe
```

## Test

```pwsh
..\test\run-tests.ps1 -ShimExe bin\x64\shim.exe
```

## Conventions

- A custom `wWinMainCRTStartup` entry point, not `std.start` or `pub fn main()`
- `.toBool()` on `windows.BOOL` return values, never `@intFromEnum(...) != 0`
- Split sentinel constants by what they mean even when the values are identical (`INVALID_FILE_SIZE` vs `INFINITE`, both `maxInt(DWORD)`)
- `pub` only on a type another module actually imports
- An OR-able bitmask parameter is declared as `DWORD` and passed named `u32` constants such as `GENERIC_READ`; mutually exclusive parameters may use `enum(u32)`
