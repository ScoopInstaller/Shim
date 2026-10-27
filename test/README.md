# Test Suite

One suite, four implementations. Every test runs against all four lanes, which is what keeps them behaving identically.

Add a test in the same change as the behavior it covers, in every lane.

## Running

```pwsh
pwsh -File test/run-tests.ps1 -ShimExe cpp/bin/x64/shim.exe
```

From a lane directory the path is `..\test\run-tests.ps1`. CI runs the suite for x86 and x64 on every PR touching `<lang>/**` or `test/**`.

## Native probe

`probe.c` exists because the things the suite needs cannot be done faithfully from PowerShell --
most of all, a native target reports exactly what a real `.exe` child receives, where a batch target only measures `cmd.exe`'s `%*` re-expansion and PowerShell 7 reverts to Legacy quoting for `.cmd`. Every test target is the probe, with two deliberate exceptions: a single test still points at a `.cmd` file, because that is the only thing guarding the shim's ability to launch a batch target at all, and Scoop never produces such a pairing; and the "Direct-child-only lifecycle" test points at `powershell.exe`, because observing whether the shim kills a child's descendants needs a child that spawns one. What each mode does is documented in `probe.c` itself.

`probe.exe` is built from `probe.c`, not tracked: a tracked binary can drift away from the source it came from, and every lane that runs the suite needs the same bytes. Locally the suite builds it when it is missing or older than `probe.c`; CI builds it once and hands every lane the same file. Build it by hand with `build-probe.ps1`, which is the single place the `zig cc` line lives:

```
pwsh -File test\build-probe.ps1
```

It is x86 on purpose: it runs on x86, x64 and arm64 Windows and can create an x64 or arm64 child, so one binary covers every lane.

## What the suite cannot reach

The suite is the only check that the four lanes agree, so its blind spots are worth naming:

- **A failed `ResumeThread`.** Nothing can make the shim's resume fail on demand, so a lane that discards the return value still passes everything and a lane that does not handle it hangs instead of exiting. The branch also terminates the child directly when `CreateJobObjectW` failed earlier, where there is no job to end and a never-resumed child would stay suspended. All of it is by inspection rather than by test.
- **Every other post-spawn Win32 failure.** `CreateJobObjectW`, `SetInformationJobObject`, `AssignProcessToJobObject`, `WaitForSingleObject` and `GetExitCodeProcess` cannot be made to fail on demand. All four lanes report the three job failures and run ungoverned, and force exit 1 on a failed wait or exit-code query -- by inspection rather than by test, so a lane that skips a check reports nothing or a wrong code.
- **Degenerate input to the Win32 readers.** A negative `argc` from `CommandLineToArgvW` (trusted for a capacity or a loop bound) and an `e_lfanew` outside the module's first page are both rejected in all four lanes, though no input can produce either. Defense in depth, verified by review rather than by test.
- **A failed environment expansion.** No input makes `ExpandEnvironmentStringsW` fail: an oversized result returns the required size rather than an error, and an unknown `%VAR%` is copied through. All four lanes report the value and fall back to it unexpanded, but by inspection rather than by test.
- **Target paths beyond `MAX_PATH`.** All four shims resolve them and all four carry a `longPathAware` manifest, but launching an image that deep fails on some Windows installations regardless of the shim, so a test would assert the platform rather than the shim. The "path longer than MAX_PATH" test walks the `GetFullPathNameW` growth path to a clean create error; that call's failure branch (a `path` past 32767 characters) and the directory its fallback hands back are verified by review rather than by test.
- **The shim's own path beyond `MAX_PATH`.** All four resolve it with a growing `GetModuleFileNameW` buffer, but the same launch limit applies, so this is verified by review rather than by test.
- **A non-ASCII drive colon in `path`.** A value whose first character is not ASCII but whose second is `:` cannot be classified by observation: the path is invalid on Windows, so no lane can be seen resolving it. Verified by review rather than by test.
- **A creator that passes a null stream in more than one position.** `probe create --null-out` covers stdout; a creator that nulls stderr as well is not exercised.
- **The elevated launch path.** `elevate = true` is only exercised when the runner itself is elevated; the check runs before the shim, so an ordinary run prints a skip and counts as a pass without raising a UAC dialog. On any ordinary run the `ShellExecuteExW` plumbing, the elevated exit-code forwarding and the UAC-cancel branch are entirely unexercised.
- **The console state the suite reads.** When the shim holds a console, the target inherits it and its `GetConsoleWindow` answers for the runner's console -- vacuous under ConPTY, a false failure when the runner has a window. The suite therefore reads the console state from the console-less creators, where the console the target ends up with is the one the shim decided. The one test that needs a *new* console to have a window needs an environment where a newly allocated console really gets one; a session-0 agent may not provide it, and the test then fails loudly rather than passing vacuously.
- **The console a GUI-subsystem shim hands its target.** The conditional `CREATE_NO_WINDOW` is only reachable from a GUI-subsystem shim when the no-`args` `FreeConsole()` branch leaves it console-less, and any target that reports something has `args`, which sends the shim down `AttachConsole` where the flag is correctly not applied. The outcome is then the runner's own console -- vacuous under ConPTY, a false failure when it has a window -- so the branch is verified by review rather than by test.
- **Case folding beyond ASCII.** The suite pins the boundary with one key -- `argſ` (U+017F, long s) must stay an environment variable, which fails a lane that folds with a full case map (`ToLowerInvariant` maps U+017F to `s`, where `CompareStringOrdinal` leaves it alone). Past that the lanes' tables differ -- cpp and zig fold through `CompareStringOrdinal` (Latin-1 and Greek pairs too), cs and rust fold A-Z/a-z only -- and no character distinguishes them because every folded non-ASCII code point lands outside the reserved-key set, so the difference is verified by review rather than by test.
- **The manifest's runtime effect.** `consoleAllocationPolicy=detached` is honoured only by Windows 11 24H2 (build 26100) and Server 2025, so the one test that needs it -- the creator that hands the child a usable stdout without naming the standard handles -- is skipped below that build. The suite covers the resource existing as type 24 by number with ID 1 and carrying both settings; the effect itself is verified by review rather than by test.

When you add behaviour that lands in one of these places, add it here in the same commit. Commit messages carry a title only, so this list is the record. A lane that skips the check the others perform is exactly the failure this repository cannot detect on its own.

## Writing a test

Tests live in `test/run-tests.ps1` and use two helpers: `Invoke-ShimTest` for a console shim, and
`Invoke-GuiShimTest` for one whose PE subsystem has been patched to GUI.

Each test is a single call:

- `-Setup` -- scriptblock receiving the temp directory it created. Put the batch files and the `.shim` content there.
- `-RunArgs` -- optional, passed to the shim as command-line arguments.
- `-Assert` -- scriptblock receiving `@{Output; ExitCode; TestDir; Elapsed}` from both helpers; a field an assertion reads is always present, so a helper that stopped supplying one would fail the assertion instead of quietly passing it. Return a hashtable with `Pass` and `Message`.

Numbering is automatic. Never renumber by hand.

A terminating error anywhere in a test -- `-Setup`, the shim invocation, or `-Assert` -- is reported as that test's `[FAIL]` with the exception message, and the suite continues: one broken test must not hide every test after it.
