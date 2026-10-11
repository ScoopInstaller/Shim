# Design Notes

Why the shim is shaped this way, and the traps that shaped it. For the file format itself, see [README.md](README.md); for per-language conventions, see [AGENTS.md](AGENTS.md).

## What the shim is

A launcher, not a wrapper. It reads a small text file, prepares a process, spawns it, waits, and exits with the child's code. Everything it does exists to make that invisible: no configuration of its own, no output of its own, no behavior the user has to learn twice.

Two consequences run through the whole design.

**Nothing may be in the way.** The shim holds the console while the child runs, so anything the shim prints or reacts to lands between the user and the program they asked for. That is why errors go directly to the stderr handle -- `WriteConsoleW` when it is a console, UTF-8 via `WriteFile` otherwise -- and never through stdio: a block-buffered stream would hold the shim's diagnostic until exit and print it *after* everything the child had already said, putting the message in the wrong place in the transcript. A pure-ASCII fragment may go through either writer, because both render it identically, which is why the rust and zig lanes bypass the routing for a few literals.

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

## Process lifetime

The shim is not supposed to outlive its job, and the child is not supposed to outlive the shim.

**A job object ties them together.** `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` means the child dies when the shim does, so a closed console window does not leave an orphaned process behind. `JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK` scopes that to the *direct* child: a process the tool deliberately detaches, or a server it spawns, is its own business. Owning the whole tree would break exactly the tools a launcher exists to run.

**The child is created suspended.** It has to be in the job before it can spawn anything of its own. Without `CREATE_SUSPENDED` there is a window between creation and job assignment in which the child can start a grandchild, and that grandchild escapes the job. This holds for the `CreateProcessW` path only. `ShellExecuteExW` has no suspended option, so an elevated child is already running when it joins the job and that window is open there; the retry after `ERROR_ELEVATION_REQUIRED` launches the same way.

**The console belongs to the child.** The shim swallows every console control event and returns `TRUE`. The user is interacting with the program the shim launched, so Ctrl+C has to reach it and not the shim -- and if the shim died on Ctrl+C, `KILL_ON_JOB_CLOSE` would take the child down with it. The handler is installed *before* the spawn, which closes the remaining window where a Ctrl event would kill the shim and the child with it.

**The exit code is forwarded unmangled**, including values above 255 and the `0xC0000005` family, so a caller can match on a specific crash code. Only an internal failure produces exit 1.

## Console behavior

A GUI-subsystem shim would flash a console window on every launch, so the shim calls `FreeConsole` when its own PE subsystem is `IMAGE_SUBSYSTEM_WINDOWS_GUI`. If that same shim is given arguments, it is being used as a command-line tool, so it calls `AttachConsole(ATTACH_PARENT_PROCESS)` instead and the target's output has somewhere to go. That decision belongs to the launch path alone -- nothing downstream re-attaches, because a failed `CONOUT$` open *is* the policy for the no-argument case, not a problem to work around.

The standard handles are seeded from the shim's own only where the creator left a slot empty, and the `CONIN$`/`CONOUT$` fallback only fires when the creator passed a null stream under `STARTF_USESTDHANDLES` -- which is what Go's `os/exec` does whenever only some of the three streams are set. Both blocks are inert for a creator that omits `STARTF_USESTDHANDLES` entirely, because `CreateProcessW` then ignores the seeded handles and the child resolves its own. That is why they read as load-bearing and mostly are not: a defect in either one stays invisible until something passes a null stream.

## Elevation

`elevate` goes through `ShellExecuteExW`, not `CreateProcessW`: it is the only way to get a UAC consent dialog. That call takes `params` rather than a command line, which is why the two are built separately. The child still joins the job object, so its lifetime is governed the same way once it does -- but not from the first instant, because it was already running when `AssignProcessToJobObject` was called.

## The shim file

### Reading it

**Line endings are LF and CRLF.** Every implementation splits on `\n` and drops a trailing `\r` as whitespace.

### Two passes over the fields

`%~dp0` means the **shim's own directory** inside `path`, and the **target's directory** everywhere else. The target's directory is not known until `path` has been resolved, so the first pass finds and absolutises `path` and the second expands every other field against it. That is the only reason the parser needs two passes, and it is why `%~dp0` means two different things in the same file.

### Expansion

All `%VAR%` in a value expand when the file is read, against the environment the shim was started in. Every value therefore sees the same starting environment, which makes a shim file order-independent -- and means a value cannot reference a variable the shim itself defines. Expanding as each line was applied instead would make the file's meaning depend on line order.

`args` is the exception and is passed through unexpanded, so the child can expand `%VAR%` itself against the environment it actually receives.
