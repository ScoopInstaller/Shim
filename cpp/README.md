# C++ Shim Development Guide

Shim file format and usage: [../README.md](../README.md). Design rationale: [../DESIGN.md](../DESIGN.md).

## Overview

Native C++ shim, statically linked, zero runtime dependencies. Supports x86, x64, and arm64.

## Prerequisites

| Tool | Local dev | CI (GHA) |
|------|-----------|----------|
| **Zig 0.17.0** | Required | |
| **MSBuild + VC++** | | Pre-installed on `windows-latest` |

`build.ps1` auto-detects (`-Tool Auto`): with VS -> MSBuild; without -> Zig.

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

## Conventions

- C++20, built through Zig's C++ frontend rather than MSBuild in the default workflow
- `wstring_view` for parsing; never pass `.data()` to a C string function (`_wcsicmp`, `wcscmp`, ...), because a view is not null-terminated
- `[[nodiscard]]` on every function that returns a value
- `[[likely]]` / `[[unlikely]]` on branches whose outcome is known
