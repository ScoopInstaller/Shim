# C# Shim — Development Guide

For shim file format and usage, see [../README.md](../README.md).

## Overview

C# shim targeting .NET Framework 4.5 (pre-installed on Windows 8+). Supports x86, x64, and arm64.

## Prerequisites

- .NET SDK (for `dotnet publish`)

## Build

```pwsh
cd cs

# Single target
.\build.ps1 -Target x64

# All targets
.\build.ps1

# Output: bin/{x86|x64|arm64}/shim.exe
```

## Test

```pwsh
..\test\run-tests.ps1 -ShimExe bin\x64\shim.exe
```
