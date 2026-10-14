# C# Shim Development Guide

Shim file format and usage: [../README.md](../README.md). Design rationale: [../RATIONALE.md](../RATIONALE.md).

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

## Conventions

- .NET Framework 4.5 target
- P/Invoke for all Win32 calls
- `GenerateAssemblyInfo=false` in the csproj, with a hand-written `AssemblyInfo.cs` generated at build time. It omits `AssemblyTitle` so `FileDescription` stays empty, matching the other lanes
