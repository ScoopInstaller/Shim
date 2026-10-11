# Rust Shim Development Guide

Shim file format and usage: [../README.md](../README.md). Design rationale: [../DESIGN.md](../DESIGN.md).

## Overview

Native Rust shim using `windows-sys` raw FFI bindings, statically linked, zero runtime dependencies. Supports x86, x64, and arm64.

## Prerequisites

| Tool | Required |
|------|----------|
| **Rust** (stable, MSVC toolchain) | yes |
| **cargo** | yes |

Additional targets: `rustup target add i686-pc-windows-msvc x86_64-pc-windows-msvc aarch64-pc-windows-msvc`

## Build

```pwsh
cd rust

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

## Binary size optimization

| Setting | Value | Purpose |
|---------|-------|---------|
| `opt-level` | `"z"` | Aggressive size optimization |
| `codegen-units` | `1` | Single codegen unit for maximum optimization |
| `lto` | `"fat"` | Whole-program link-time optimization |
| `panic` | `"abort"` | No unwinding overhead |
| `strip` | `true` | Remove debug symbols |

Uses `windows-sys` (raw FFI bindings) instead of `windows` crate -- smaller binary, faster compilation, no COM/WinRT overhead.

## Conventions

- `windows-sys`, not the `windows` crate
- Raw FFI bindings, no safe wrappers
- `unsafe` confined to the FFI call itself
