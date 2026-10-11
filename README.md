# Shim

![C#](https://img.shields.io/badge/dynamic/regex?url=https://raw.githubusercontent.com/ScoopInstaller/Shim/refs/heads/main/cs/version&search=%5B%5Cd.%5D%2B&logo=dotnet&label=C#) ![C++](https://img.shields.io/badge/dynamic/regex?url=https://raw.githubusercontent.com/ScoopInstaller/Shim/refs/heads/main/cpp/version&search=%5B%5Cd.%5D%2B&logo=cplusplus&label=C++) ![Rust](https://img.shields.io/badge/dynamic/regex?url=https://raw.githubusercontent.com/ScoopInstaller/Shim/refs/heads/main/rust/version&search=%5B%5Cd.%5D%2B&logo=rust&label=Rust) ![Zig](https://img.shields.io/badge/dynamic/regex?url=https://raw.githubusercontent.com/ScoopInstaller/Shim/refs/heads/main/zig/version&search=%5B%5Cd.%5D%2B&logo=zig&label=Zig)

A small program that launches the executable specified in its paired `<name>.shim` file. A helper for [Scoop](https://scoop.sh), the Windows command-line installer.

## Shim File Format

```text
path = <path to executable>
args = <arguments>
cwd = <working directory>
elevate = true|false|1|0|yes|no
NAME = <environment variable override>
```

### File Encoding

The file is read as UTF-8, with or without a byte order mark; plain ASCII is fine. Line endings may be LF or CRLF.

### Line Format

A field is `key = value`, where the separator is the **first** `=` and spaces around it are optional -- `path = app.exe` and `path=app.exe` are the same field. The key is trimmed of surrounding whitespace, the value of leading whitespace. Any line that is not blank, a comment, or a field is a broken shim: the shim reports the offending line and exits with code 1 without starting the target.

### Comments

Lines whose first non-whitespace characters are `#`, `;`, or `//`, as well as blank lines, are ignored.

### Fields

| Field               | Description                                             |
| ------------------- | ------------------------------------------------------- |
| `path`              | **(Required)** Path to the target executable            |
| `args`              | Arguments passed to the target                          |
| `cwd` (`workdir`)   | Working directory for the target process                |
| `elevate` (`runas`) | Request UAC elevation. Truthy values: `true`, `1`, `yes` |
| Any other name      | Environment variable set for the target process         |

### Value Quoting

Values may be wrapped in double quotes (e.g. `path = "C:\Program Files\app.exe"`) or left unquoted. In `path`, `cwd` and environment overrides the wrapping quotes are stripped after expansion; in `args` there is no unquoting, because the value is parsed with command-line rules, so quotes group arguments and the backslash-before-quote rules apply.

### Variable Expansion

- `%ENV%` -- Expands environment variables in `path`, `cwd`, and environment override values; in `args` the value is passed through unchanged so the child process can expand `%VAR%` itself. Unknown variables (e.g. `%NONEXISTENT_VAR%`) are preserved as-is. Values are expanded when the shim file is read, so a value cannot reference a variable the shim itself defines.
- `%~dp0` — In `path`, expands against the **shim's own directory** (the target is unknown at that point). In `args`, `cwd`, and environment override values, expands to the **directory containing the target executable** with a trailing backslash. All occurrences in a value are replaced. Duplicate `path` keys: the first one wins.

### Argument Parsing

User-provided runtime arguments are appended after those defined in `args`.

### Environment Variables

Any line whose key is not `path`, `args`, `cwd`, `workdir`, `elevate`, or `runas` is an environment variable override for the child process. To set one of those names as a variable rather than as the field, prefix the key with `env:`:

```text
path = %~dp0tool.exe
env:PATH = %PATH%;%~dp0
```

The prefix is stripped case-insensitively and the remainder is the variable name verbatim. Duplicate names: the last definition wins.

### Exit Codes

The shim waits for the child process to finish and forwards its exit code, including large values (e.g. crash codes like `0xC0000005`) unmangled. If the shim fails internally, it exits with code 1.

## Usage

```pwsh
New-Item -Path test.shim -Value 'path = C:\Windows\System32\calc.exe'
Copy-Item -Path .\cpp\bin\x64\shim.exe -Destination .\test.exe
.\test.exe
```

## Implementations

- **C#** — .NET Framework 4.5 (CLR).
- **C++** — Native executable with no runtime dependencies. Zig build (default).
- **Rust** — Native executable using `windows-sys` raw FFI bindings. Cargo build.
- **Zig** — Native executable using custom `wWinMainCRTStartup` entry. Zig build only.

All implementations share the same `.shim` format.

## Binary Size

| Implementation | Build Tool |      x86 |      x64 |    arm64 |
| -------------- | ---------- | -------: | -------: | -------: |
| C#             | dotnet     |  17.5 KB |  17.0 KB |  17.0 KB |
| C++            | Zig        | 117.0 KB | 141.0 KB | 132.5 KB |
| C++            | MSBuild    | 116.0 KB | 140.5 KB | 123.0 KB |
| Rust           | Cargo      | 113.0 KB | 130.5 KB | 126.5 KB |
| Zig            | Zig        |  85.5 KB |  68.5 KB |  21.0 KB |

## Development

- C# developer guide: [`cs/README.md`](cs/README.md)
- C++ developer guide: [`cpp/README.md`](cpp/README.md)
- Rust developer guide: [`rust/README.md`](rust/README.md)
- Zig developer guide: [`zig/README.md`](zig/README.md)
- Design rationale: [`DESIGN.md`](DESIGN.md)
- Agent conventions: [`AGENTS.md`](AGENTS.md)
- Test suite: [`test/run-tests.ps1`](test/run-tests.ps1)
- Test guide: [`test/README.md`](test/README.md)
- Startup cost: [`benchmark/README.md`](benchmark/README.md)
- Tag-based release routing:
  - `cs/v<version>` → C# release lane
  - `cpp/v<version>` → C++ release lane
  - `rust/v<version>` → Rust release lane
  - `zig/v<version>` → Zig release lane

All `build.ps1` scripts accept `-Target x86|x64|arm64` and `-Configuration Debug|Release` (default Release). Output is written to `bin/{Target}/shim.exe`.

## Special Thanks

This repository builds on these earlier implementations:

- **[71/scoop-better-shimexe](https://github.com/71/scoop-better-shimexe)** -- C implementation that solved Ctrl+C passthrough and dropped the .NET startup cost.

- **[kiennq/scoop-better-shimexe](https://github.com/kiennq/scoop-better-shimexe)** -- C++ fork of 71's, adding MSBuild support and the `cwd` field to the shim format.

- **[zoritle/rshim](https://github.com/zoritle/rshim)** -- Rust implementation, memory safety and UTF-8 BOM handling.

- **[svercl/zshim](https://github.com/svercl/zshim)** -- Zig port, showed a shim can be built with no runtime dependency.

## License

This project is dual-licensed under the [Unlicense](UNLICENSE) or the [MIT License](LICENSE).

You may choose either license.
