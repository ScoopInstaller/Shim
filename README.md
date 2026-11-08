# Shim

![C#](https://img.shields.io/badge/dynamic/regex?url=https://raw.githubusercontent.com/ScoopInstaller/Shim/refs/heads/main/cs/version&search=%5B%5Cd.%5D%2B&logo=dotnet&label=C#) ![C++](https://img.shields.io/badge/dynamic/regex?url=https://raw.githubusercontent.com/ScoopInstaller/Shim/refs/heads/main/cpp/version&search=%5B%5Cd.%5D%2B&logo=cplusplus&label=C++) ![Rust](https://img.shields.io/badge/dynamic/regex?url=https://raw.githubusercontent.com/ScoopInstaller/Shim/refs/heads/main/rust/version&search=%5B%5Cd.%5D%2B&logo=rust&label=Rust) ![Zig](https://img.shields.io/badge/dynamic/regex?url=https://raw.githubusercontent.com/ScoopInstaller/Shim/refs/heads/main/zig/version&search=%5B%5Cd.%5D%2B&logo=zig&label=Zig)

A tiny, fast launcher for [Scoop](https://scoop.sh), the Windows command-line installer. It reads a small `.shim` file, starts the tool it points to, and stays out of the way.

Four independent implementations -- C#, C++, Rust, and Zig -- with identical behavior.

## Quick start

```pwsh
New-Item -Path test.shim -Value 'path = C:\Windows\System32\calc.exe'
Copy-Item -Path .\cpp\bin\x64\shim.exe -Destination .\test.exe
.\test.exe
```

`test.exe` reads `test.shim` from the same directory. The file is found by replacing the executable's extension with `.shim`, or appending `.shim` when the name has none.

## Shim file

```text
path = C:\Apps\tool.exe
args = --quiet
env:APP_CACHE_DIR = %~dp0cache
env!:PATH = %PATH%;%~dp0
```

- `path` is required. `args`, `cwd`, and `elevate` are optional.
- `env:NAME` sets a default; an external value wins.
- `env!:NAME` forces a value. Use it for PATH changes or deliberate isolation.
- `%~dp0` means the shim's directory in `path`, and the target's directory elsewhere.

The shim waits for the child and forwards its exit code. See [SPEC.md](SPEC.md) for the full format and rules.

## Self-description

An unpaired `shim.exe` can report itself:

```pwsh
.\shim.exe --version
```

```text
shim <version> (<impl>)
Features: cwd env env-force expand dp0 elevate
```

Only the canonical, unpaired `shim.exe` answers. A shim with a `.shim` file passes its arguments to the target.

## Implementations

| Implementation | `impl` | Build Tool |      x86 |      x64 |    arm64 |
| -------------- | ------ | ---------- | -------: | -------: | -------: |
| C#             | `cs`   | dotnet     |  22.5 KB |  22.0 KB |  22.0 KB |
| C++            | `cpp`  | Zig        | 121.0 KB | 145.5 KB | 137.0 KB |
| C++            | `cpp`  | MSBuild    | 125.5 KB | 147.0 KB | 129.0 KB |
| Rust           | `rust` | Cargo      | 115.5 KB | 133.0 KB | 128.5 KB |
| Zig            | `zig`  | Zig        |  87.5 KB |  75.0 KB |  24.5 KB |

`impl` is the token reported by self-description. Sizes are the current build output.

## Documentation

- Specification: [SPEC.md](SPEC.md)
- Design rationale: [RATIONALE.md](RATIONALE.md)
- Agent workflow: [AGENTS.md](AGENTS.md)
- C# developer guide: [cs/README.md](cs/README.md)
- C++ developer guide: [cpp/README.md](cpp/README.md)
- Rust developer guide: [rust/README.md](rust/README.md)
- Zig developer guide: [zig/README.md](zig/README.md)
- Test suite: [test/run-tests.ps1](test/run-tests.ps1)
- Test guide: [test/README.md](test/README.md)
- Startup cost: [benchmark/README.md](benchmark/README.md)

## Special Thanks

This repository builds on these earlier implementations:

- **[71/scoop-better-shimexe](https://github.com/71/scoop-better-shimexe)** -- C implementation that solved Ctrl+C passthrough and dropped the .NET startup cost.
- **[kiennq/scoop-better-shimexe](https://github.com/kiennq/scoop-better-shimexe)** -- C++ fork of 71's, adding MSBuild support and the `cwd` field to the shim format.
- **[zoritle/rshim](https://github.com/zoritle/rshim)** -- Rust implementation, memory safety and UTF-8 BOM handling.
- **[svercl/zshim](https://github.com/svercl/zshim)** -- Zig port, showed a shim can be built with no runtime dependency.

## License

This project is dual-licensed under the [Unlicense](UNLICENSE) or the [MIT License](LICENSE).

You may choose either license.
