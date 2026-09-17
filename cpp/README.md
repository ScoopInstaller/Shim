# C++ Shim — Development Guide

For shim file format and usage, see [../README.md](../README.md).

## Overview

Native C++ shim, statically linked, zero runtime dependencies. Supports x86, x64, and arm64.

## Prerequisites

| Tool | Local dev | CI (GHA) |
|------|-----------|----------|
| **Zig 0.16.0** | ✅ Required | — |
| **MSBuild + VC++** | — | ✅ Pre-installed on `windows-latest` |

`build.ps1` auto-detects (`-Tool Auto`): with VS → MSBuild; without → Zig.

## Build

```pwsh
cd cpp

# Single target (auto-detect tool)
.\build.ps1 -Target x64

# Explicit tool
.\build.ps1 -Target x64 -Tool Zig

# All targets
.\build.ps1

# Output: bin/{x86|x64|arm64}/shim.exe
```

## Test

```pwsh
..\test\run-tests.ps1 -ShimExe bin\x64\shim.exe
```
