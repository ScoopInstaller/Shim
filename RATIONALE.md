# Design Rationale

Why the shim is shaped this way, and the traps that shaped it. For the file format itself, see [README.md](README.md); for per-language conventions, see [AGENTS.md](AGENTS.md).

## What the shim is

A launcher, not a wrapper. It reads a small text file, prepares a process, spawns it, waits, and exits with the child's code. Everything it does exists to make that invisible: no configuration of its own, no output of its own, no behavior the user has to learn twice.

Two consequences run through the whole design.

**Nothing may be in the way.** The shim holds the console while the child runs, so anything the shim prints or reacts to lands between the user and the program they asked for. That is why errors go directly to the stderr handle -- `WriteConsoleW` when it is a console, UTF-8 via `WriteFile` otherwise -- and never through stdio: a block-buffered stream would hold the shim's diagnostic until exit and print it *after* everything the child had already said. A pure-ASCII fragment may go through either writer, because both render it identically, which is why the rust and zig lanes bypass the routing for a few literals.

**There is no runtime to install and nothing to clean up.** The shim is one source file per lane compiled to a single executable. Direct Win32 calls, no wrapper library, no helper process.

## Four implementations

Each lane is an independent implementation in its own language, with no code shared between them -- duplicated build scripts and version files included, on purpose, so that working on one lane never requires touching another. The shared test suite is the only thing holding them together.

That makes parity across the four the hard constraint. Anything observable has to be specified rather than left to emerge, because emerging means differing somewhere. It is also why a rule that looks arbitrary usually has a real input behind it: getting it wrong costs four behaviors, not one.

## The launch pipeline

1. Read the shim file and classify every line.
2. Apply the environment overrides to the shim's *own* environment.
3. Create the child suspended, put it in a job object, resume it.
4. Wait for it and exit with its code.

Step 2 happens before step 3 for two reasons: `CreateProcessW` with a null environment inherits the shim's, so the overrides have to be in place first; and a `path` given as a bare name is then resolved against the overridden `PATH` rather than the inherited one. The elevated launch path takes the same environment, so nothing differs between the two.

Arguments come from two places -- the `args` field and the shim's own command line -- so the command line has to be rebuilt rather than appended to, and the user's arguments re-quoted on the way. `QuoteArg` implements the `CreateProcessW` rules for exactly that reason: the child must see the arguments the user typed, not a re-parse of them.

`CommandLineToArgvW` returns a signed count, and a negative value is a failed parse, so every lane clamps it before using it as a capacity or loop bound. Each lane's `version` file is the source of truth: the build validates it and packs the resource's numeric and string versions from it, with the Rust lane overriding `winres`'s Cargo.toml default so the two cannot drift apart.

**Every shim carries a `longPathAware` manifest.** Windows only lets a process hand a path beyond `MAX_PATH` to `CreateProcessW` if that process opts in, and the opt-in is a manifest rather than anything in the code. The resource has to be written as type `24` by number: a cross-compiling `llvm-rc` does not resolve the `RT_MANIFEST` symbol and produces a *named* resource called `RT_MANIFEST` instead, which carries the manifest's bytes and is ignored by the loader. Nothing fails, and searching the binary for the manifest finds it. The manifest also carries the console-allocation policy (see Console behavior); the suite's probe reads the resource by ID and type *number*, which makes the named-resource trap observable rather than silent. The Rust lane embeds that manifest through `winres`, which is unmaintained; replacing it changes how the manifest lands in the binary, so the swap has to keep the manifest-presence test (#66) watching it.

## Process lifetime

The shim is not supposed to outlive its job, and the child is not supposed to outlive the shim.

**A job object ties them together.** `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` means the child dies when the shim does, so a closed console window does not leave an orphaned process behind. `JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK` scopes that to the *direct* child: a process the tool deliberately detaches, or a server it spawns, is its own business. Owning the whole tree would break exactly the tools a launcher exists to run.

**The child is created suspended.** It has to be in the job before it can spawn anything of its own. Without `CREATE_SUSPENDED` there is a window between creation and job assignment in which the child can start a grandchild, and that grandchild escapes the job. This holds for the `CreateProcessW` path only; `ShellExecuteExW` has no suspended option, so the elevated path and its `ERROR_ELEVATION_REQUIRED` retry keep that window open (see Elevation).

**A job that could not be created is not fatal** -- every lane reports each job-object failure (create, set limits, assign) and runs ungoverned, and the resume-failure branch then terminates the child directly, since a child that never resumes would sit suspended holding its image until the shim exits.

**The console belongs to the child.** The shim swallows every console control event and returns `TRUE`. The user is interacting with the program the shim launched, so Ctrl+C has to reach it and not the shim -- and if the shim died on Ctrl+C, `KILL_ON_JOB_CLOSE` would take the child down with it. The handler is installed *before* the spawn, which closes the remaining window where a Ctrl event would kill the shim and the child with it.

**The exit code is forwarded unmangled**, including values above 255 and the `0xC0000005` family, so a caller can match on a specific crash code. Only an internal failure produces exit 1.

**Rust buys size with `panic = "abort"`** (see rust/README), which sends a panic down the fast-fail path instead of the exit-1 path above; shim.rs therefore has to stay panic-free -- no `unwrap`, `expect` or `panic!`, and no indexing that can go out of bounds.

## Console behavior

A GUI-subsystem shim would flash a console window on every launch, so the shim calls `FreeConsole` when its own PE subsystem is `IMAGE_SUBSYSTEM_WINDOWS_GUI`. If that same shim is given arguments, it is being used as a command-line tool, so it calls `AttachConsole(ATTACH_PARENT_PROCESS)` instead and the target's output has somewhere to go. That decision belongs to the launch path alone -- nothing downstream re-attaches, because a failed `CONOUT$` open *is* the policy for the no-argument case, not a problem to work around. The check reads the PE header, which lives in the module's first page, so an `e_lfanew` outside it is a bogus offset rather than a malformed image.

The standard handles are seeded from the shim's own only where the creator left a slot empty, and the `CONIN$`/`CONOUT$` fallback only fires when the creator passed a null stream under `STARTF_USESTDHANDLES` -- which is what Go's `os/exec` does whenever only some of the three streams are set. Both blocks are inert for a creator that omits `STARTF_USESTDHANDLES` entirely, because `CreateProcessW` then ignores the seeded handles and the child resolves its own. That is why they read as load-bearing and mostly are not: a defect in either one stays invisible until something passes a null stream.

**`CREATE_NO_WINDOW` does not survive a second creation.** A console target created with no console to attach to is given a fresh one, and that one has a window -- so a host that spawns the shim detached, where the `CREATE_NO_WINDOW` it passed was ignored beside the `DETACHED_PROCESS` it also set, would get a window flashed on every call. The shim therefore passes the flag on only when it has no console of its own. The probe is `GetConsoleProcessList` over a real one-element buffer -- a null list with a count of 0 is documented misuse that returns 0 regardless -- because the answer is what separates "nothing to share" from "something to share". `GetConsoleWindow` cannot make that separation: it is null both with no console and with a windowless one, and a windowless console must still be shared, not replaced. The flag is conditional for the same reason: passing it unconditionally would take a target that *could* have shared the shim's console and hand it its own. The host that exposed this calls Node's `spawn` with `detached: true`, `windowsHide: true` and every stream piped, which is the shape `probe create --detached --stdin` exists to express.

A GUI-subsystem shim given no arguments reaches the flag by a second route: `FreeConsole` leaves it with no console either, so its target now gets a windowless console where it used to get a visible one. That is the intent -- the rule above is that a GUI-subsystem shim must not flash a console -- and no shipped binary is affected, because every lane builds a console-subsystem shim. The route is unreachable by test: any target that reports its state has arguments, and arguments take the `AttachConsole` branch instead.

**The manifest decides whether the shim holds a console at all.** `consoleAllocationPolicy=detached` leaves a launch with nothing to inherit console-less instead of giving it a visible allocated console -- the Start-Menu-shortcut and Explorer shapes, where a GUI-app target used to flash a window. That state is exactly the one the conditional `CREATE_NO_WINDOW` above already handles. Terminal launches are untouched: the policy governs only the nothing-to-inherit case. Only Windows 11 24H2 (build 26100) and Server 2025 honour the entry; older Windows ignores it. The accepted cost, the same one kiennq/scoop-better-shimexe PR #23 took: a CLI app launched through a shortcut no longer shows a console, and a broken `.shim`'s error text from Explorer is no longer visible.

## Elevation

`elevate` goes through `ShellExecuteExW`, not `CreateProcessW`: it is the only way to get a UAC consent dialog. That call takes `params` rather than a command line, which is why the two are built separately. The child still joins the job object, so its lifetime is governed the same way once it does -- but not from the first instant, because it was already running when `AssignProcessToJobObject` was called. It takes no creation flags, so an elevated launch from a console-less creator still opens one.

## The shim file

### Reading it

**Lines are decoded one at a time, strictly.** A line that is not valid UTF-8 is reported as `Shim: invalid UTF-8 line in shim file` and dropped; the rest of the file still loads. Converting the whole file in one call is simpler and *wrong*: it replaces the bad bytes with U+FFFD, producing an environment variable whose name the user can neither type nor reference. A variable you cannot name is indistinguishable from a bug. The file is sized with `GetFileSizeEx`: `GetFileSize`'s `INVALID_FILE_SIZE` is also a legitimate 4GB-1 size, and `ReadFile` cannot take a larger count anyway.

**A byte order mark is skipped off the front of the raw bytes**, before lines are split out, rather than by checking whether a decoded line is the first one. A BOM only ever appears at byte 0, so tracking "is this the first line" would be state the format never needs -- and state that four implementations would have to agree on.

**Line endings are LF and CRLF.** Every implementation splits on `\n` and drops a trailing `\r` as whitespace.

**The set of characters that count as whitespace is fixed.** A line holding only whitespace is a blank line, so the set decides whether such a line is ignored or treated as a fatal one. It is the full 25-code-point Unicode White_Space set, and every lane has to agree on it exactly: a set that is too small turns a blank line into a fatal one in some implementations and not others.

### Line format

The separator is the **first** `=`, and spaces around it are optional, so `path = app.exe`, `path=app.exe` and `path =app.exe` all mean the same thing. Splitting on the first `=` leaves the value free to contain more `=`, which matters for `args` -- `--flag=a=b` must survive intact.

The line is right-trimmed before it is split, so trailing spaces in a value are eaten -- and have to be, because a trailing space would otherwise defeat the double-quote unquote test on a `path` value. The key is trimmed on both sides and the value on the left, so a misindented key still works.

**A line that is not blank, a comment, or a field is fatal.** The shim reports the line and the shim's own path, then exits 1 without starting anything. A shim file has no legitimate content beyond fields and comments, so such a line means the file is broken -- and the worst outcome for a launcher is to ignore the breakage and run a half-configured program. Failing loudly costs one visible error instead of a mystery.

The check runs while the file is being read, the one place that sees every line. It cannot live in either of the later expansion passes: the one that resolves the target `path` stops as soon as it finds it, so it would miss a bad line further down; the one that reads every field would report the same line twice.

### Two passes over the fields

`%~dp0` means the **shim's own directory** inside `path`, and the **target's directory** everywhere else. The target's directory is not known until `path` has been resolved, so the first pass finds and absolutises `path` and the second expands every other field against it. That is the only reason the parser needs two passes, and it is why `%~dp0` means two different things in the same file. The target's directory is what `GetFullPathNameW` answers for the resolved `path`; when that call fails, the shim reports it and falls back to the input with its last component dropped, because expanding `%~dp0` into a value that still ends in the target's file name puts a path where a directory belongs.

### The `env:` prefix

Reserved keys are matched case-insensitively, so `PATH = x` is the `path` field: it overwrites the target executable instead of the `PATH` variable. There is no way to override `PATH` otherwise, and the same would be true of every field added later. `env:` forces the key to be an environment variable name; the prefix is stripped case-insensitively and the remainder is used verbatim. It never reaches the reserved-key table, so no field can shadow it and adding one later cannot break a shim that already uses it. Reserved keys and the `env:` prefix fold ASCII `A-Z`/`a-z` only, because matching through a Unicode case table would make the format depend on the runtime's tables.

### Traps

Each of these was a real bug at least once.

1. **Strip the prefix constant, never a literal length.** Cutting `env:` itself means the length and the comparison cannot drift apart; a hardcoded length silently truncates variable names.
2. **Strip in the key dispatch, not in the line parser.** The first expansion pass scans for `path` alone to resolve the target's directory. A strip in the parser hands it `env:path` instead, and the shim launches whatever that points at.
3. **Share the value pipeline.** An `env:` value goes through the same expansion and unquoting as any other. A second code path for it will drift, and it will only ever fail for the new syntax.
4. **The prefix guard must accept the prefix as the whole key.** A stricter guard makes the empty-name check unreachable, and `env:` then quietly defines a junk variable instead of saying anything.
5. **A bare `env:` is not fatal.** It names no variable, so the line is reported and skipped and the target still starts. That is a different failure from a malformed line, and merging the two turns a typo into an outage.

### Expansion

All `%VAR%` in a value expand when the file is read, against the environment the shim was started in. Every value therefore sees the same starting environment, which makes a shim file order-independent -- and means a value cannot reference a variable the shim itself defines. Expanding as each line was applied instead would make the file's meaning depend on line order.

`args` is the exception and is passed through unexpanded, so the child can expand `%VAR%` itself against the environment it actually receives.

## Errors

A syntax error in the shim file is fatal: the shim reports it, exits 1, and never starts the target. A problem with one line -- an undecodable line, an `env:` key with no name, a variable the platform refuses -- is reported and that line is skipped. Nothing else stops the launch. The error channel is allocation-free -- a diagnostic is what is left when something has already gone wrong, so a failed allocation would take the report down with it; the cpp lane writes through a segmented fixed stack buffer, which is why no wide character is split.
