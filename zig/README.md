# Zig Shim — Development Guide

For shim file format and usage, see [../README.md](../README.md).

## Overview

Pure Zig implementation of the Scoop shim, statically linked, zero runtime dependencies. Supports x86, x64, and arm64.

## Prerequisites

- **Zig 0.16.0+** — required for building

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
