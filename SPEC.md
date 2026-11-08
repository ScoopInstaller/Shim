# Scoop Shim Specification

**Status:** Normative.
**Spec-Version:** 1.0
**Normative language:** The key words MUST, MUST NOT, SHOULD, SHOULD NOT, and MAY are to be interpreted as described in RFC 2119.

## 1. Scope

This document defines the observable behavior of a Scoop shim on Windows. A shim is an executable that reads a paired `<name>.shim` file, launches the executable named by that file, waits for it, and exits with its status.

This document does not define:

- Scoop's package-manager policy or when Scoop creates a shim;
- an implementation language, build system, binary size, or source layout;
- the exact wording of diagnostics;
- behavior of a `.shim` file outside the fields defined here.

A **producer** is a program that writes `.shim` files. A **consumer** is a program that reads the shim's self-description. Scoop may act as both.

**Versioning.** `Spec-Version` is a `MAJOR.MINOR` version. Bump the major for an incompatible change to required behavior or the self-description format; bump the minor for an additive contract change, including a new optional `Features` token. Editorial changes do not change the version. External implementations SHOULD state the `Spec-Version` they target.

## 2. Part 1 -- Required behavior

### 2.1 Identity and pairing

A shim reads its configuration from a file beside it:

- take the executable's own path;
- replace the extension of the final path component with `.shim`;
- if the final component has no dot, append `.shim`.

A dot in a parent directory is not an extension. The executable's base name, with its extension removed, is the **shim name**.

The canonical tool executable is `shim.exe`; only this name reserves arguments (§2.6). A shim renamed to `<command>.exe` passes every argument to the target.

If the paired `.shim` does not exist, the shim MUST report a diagnostic to stderr and exit 1 without starting a target. Any other open or read failure MUST also be reported and exit 1.

### 2.2 File encoding and syntax

The `.shim` file MUST be read as UTF-8, with or without a UTF-8 BOM. ASCII is valid UTF-8. Line endings may be LF or CRLF.

Each line is one of:

- **blank** -- only whitespace; ignored;
- **comment** -- the first non-whitespace characters are `#`, `;`, or `//`; ignored;
- **field** -- `key = value`, where the separator is the first `=`; the key is trimmed of surrounding whitespace and the value of leading whitespace;
- **malformed** -- anything else.

Whitespace for these rules is the Unicode White_Space set, not a locale-dependent whitespace table.

The line is right-trimmed before it is split, so a value cannot end in whitespace.

A field line with no key (`= value`) is malformed. A malformed line is fatal: the shim MUST report it, exit 1, and MUST NOT start the target.

A non-fatal line error -- invalid UTF-8, a bare `env:`/`env!:` when the feature is advertised, or a platform-rejected variable -- MUST be reported and that line skipped; the rest of the file loads and the target still starts.

Field names are matched ASCII case-insensitively. `args` appends in file order; every scalar key takes its last value.

### 2.3 Required fields

#### `path`

`path` is required and names the target executable.

- Wrapping double quotes are stripped after expansion.
- A value beginning with `\` or `/` MUST be rejected.
- A value whose first two characters are an ASCII drive letter and `:` is passed to the platform as written.
- A relative value is passed to the platform as written; the platform's executable search order applies. The shim MUST NOT prepend its own directory. The search starts with the shim's own directory and includes the current directory; a bare name also searches `PATH`.
- An empty `path` is equivalent to a missing `path`.

A `.shim` file with no `path` MUST be rejected with a diagnostic and exit 1.

#### `args`

A shim MUST support `args`. The field is optional in the file.

- Repeated `args` keys append in file order.
- The value is parsed with Windows command-line rules: quotes group arguments, and the backslash-before-quote rules apply.
- The caller's arguments are appended after the `args` values.
- `%VAR%` is not expanded in `args`; the child sees what it would have received from a direct command line.
- An empty `args` value contributes nothing.

### 2.4 Launch and exit

The shim MUST:

- launch the target named by `path`;
- append the caller's arguments after the `args` values, re-quoted according to Windows command-line rules;
- wait for the target to exit;
- exit with the target's exit code unchanged, including values above 255 and NTSTATUS crash codes;
- use exit 1 only for an internal failure.

On a successful launch the shim MUST NOT write to stdout or stderr.

The shim SHOULD keep the direct child within its lifetime where the platform allows; a child's deliberate detach and its descendants are out of scope. If the platform refuses that tie, the shim MAY run ungoverned but SHOULD report the failure.

The shim SHOULD be able to handle paths longer than `MAX_PATH` where the platform permits.

The shim MUST NOT terminate on a console control event that the child is meant to handle.

### 2.5 Errors and exit codes

Diagnostics MUST go to stderr. A missing or malformed `.shim` and an internal failure exit 1; a non-fatal line error is reported and skipped. The target's exit code is forwarded exactly, and a successful launch produces no shim output. Diagnostic wording is not normative.

### 2.6 Self-description

The canonical `shim.exe` MUST implement self-description for the unpaired case.

The shim enters self-description mode only when all of the following hold:

- the executable's shim name is `shim`, compared ASCII case-insensitively;
- no user argument is present, or exactly one user argument is present and it is `--version` or `-v`, compared case-sensitively;
- the paired `shim.shim` does not exist.

In that mode the shim MUST write exactly two ASCII lines to stdout and exit 0:

```text
shim <version> (<impl>)
Features: [<feature> ...]
```

- `<version>` matches `N[.N[.N[.N]]]` and MUST NOT carry a `v` prefix.
- `<impl>` matches `[a-z0-9-]+` and identifies the implementation. It does not participate in feature detection.
- The `Features:` line is defined in §4. The square brackets in the code block denote optional repetition, not literal characters.
- There is exactly one space after `shim`, one before `(`, and one after `Features:` if a token follows.
- There is no trailing whitespace.
- The line ending is LF.
- The exit code is 0.

If `shim.shim` exists or the shim name is not `shim`, normal shim behavior applies. If the paired file is missing but the argument is not one of the accepted forms, normal behavior applies and reports the missing file. If the paired file exists but cannot be read, normal error handling applies; the shim MUST NOT print self-description.

## 3. Part 2 -- Optional features

A shim MAY implement any subset of the features in this part. It MUST advertise exactly the set it implements in `Features:` (§4). A producer MUST NOT emit syntax for a feature the target shim does not advertise.

For `cwd` and environment values, `%VAR%` and `%~dp0` expand only when `expand` and `dp0` are advertised; otherwise they are literal.

### 3.1 `cwd`

**Token:** `cwd`

**Fields:** `cwd`, `workdir` (ASCII case-insensitive; the last value wins).

The value sets the target's working directory. Wrapping double quotes are stripped. A relative value is resolved by the platform against the shim's current directory. The shim does not create the directory.

### 3.2 `env`

**Token:** `env`

**Fields:** any key that is not one of `path`, `args`, `cwd`, `workdir`, `elevate`, `runas`, and is not prefixed with `env!:`. An optional `env:` prefix is matched ASCII case-insensitively and stripped; the remainder is the variable name.

The key names an environment variable and the value is its default. A default is applied only when the variable has no value at the time the line is applied. An external value or an earlier assignment counts; an absent or empty value counts as unset. Wrapping double quotes are stripped. A bare `env:` names no variable: it MUST be reported and skipped.

Environment assignments are applied in file order; a later line observes the value set by an earlier line.

#### 3.2.1 `env-force`

**Token:** `env-force`

**Fields:** `env!:NAME` (prefix matched ASCII case-insensitively; the remainder is the variable name verbatim).

A force line always sets `NAME`, including an empty value. Wrapping double quotes are stripped and `expand`/`dp0` apply as in `env`. A bare `env!:` names no variable: it MUST be reported and skipped.

`PATH` normally has a value; use `env!:PATH` to replace or extend it. `env:PATH` is a default and normally does not apply.

### 3.3 `elevate`

**Token:** `elevate`

**Fields:** `elevate`, `runas` (ASCII case-insensitive; the last value wins).

The value requests UAC elevation for the target. The ASCII case-insensitive values `true`, `1`, and `yes` are true; every other value is false.

An elevated launch goes through the platform's elevation API and may not establish the child-lifetime tie before the child starts. This is a known limitation; the shim still reports an elevation failure and exits 1.

### 3.4 `expand`

**Token:** `expand`

When advertised, `%VAR%` expands in `path`, `cwd`, and environment-override values. Unknown variables are preserved as written. Expansion uses the environment the shim was started in; a value cannot reference a variable the same file defines. `args` is never expanded.

If `expand` is not advertised, `%VAR%` is literal.

### 3.5 `dp0`

**Token:** `dp0`

When advertised, `%~dp0` expands to a directory with a trailing backslash, at every occurrence:

- in `path`: the shim's own directory;
- in `args`, `cwd`, and environment-override values: the target executable's directory.

`args` is the one field that expands `%~dp0` but not `%VAR%`.

If `dp0` is not advertised, `%~dp0` is literal.

## 4. Capability advertisement

The second line of §2.6 is:

```text
Features: <feature> [<feature> ...]
```

- The literal prefix is `Features:`, followed by one space when at least one token is present.
- Tokens are separated by one or more spaces.
- A token matches `[a-z][a-z0-9-]*`.
- The line contains no duplicate token.
- The line is present even when the set is empty; in that case it is exactly `Features:`.
- Token order is not significant. Consumers MUST treat the line as a set.
- The recommended order is `cwd env env-force expand dp0 elevate`.
- A consumer MUST ignore unknown tokens.
- Adding a token is backward-compatible. Removing or renaming a token is a breaking change.
- A shim MUST NOT advertise a feature it does not implement.

`Features:` lists optional features only; Part 1 behavior is not repeated. UTF-8 decoding and exit-code forwarding are required; child-lifetime behavior and long-path support are SHOULD-level.

## 5. Conformance

A shim conforms when it satisfies Part 1 and its `Features:` line accurately reflects Part 2.

The repository test suite is one executable check of this specification. See [test/README.md](test/README.md) for how to run it and for the behaviors it cannot reach. A shim may conform without using this suite if it satisfies the normative requirements.
