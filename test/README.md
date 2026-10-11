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

- **The elevated launch path.** `elevate = true` is only exercised when the runner itself is elevated; otherwise the test prints a skip and counts as a pass. On any ordinary run `ShellExecuteExW` plumbing, the elevated exit-code forwarding and the UAC-cancel branch are entirely unexercised.

When you add behaviour that lands in one of these places, add it here in the same commit. Commit messages carry a title only, so this list is the record. A lane that skips the check the others perform is exactly the failure this repository cannot detect on its own.

## Writing a test

Tests live in `test/run-tests.ps1` and use two helpers: `Invoke-ShimTest` for a console shim, and
`Invoke-GuiShimTest` for one whose PE subsystem has been patched to GUI.

Each test is a single call:

- `-Setup` -- scriptblock receiving the temp directory it created. Put the batch files and the `.shim` content there.
- `-RunArgs` -- optional, passed to the shim as command-line arguments.
- `-Assert` -- scriptblock receiving `@{Output; ExitCode; TestDir; Elapsed}` from `Invoke-ShimTest`, or `@{Output; ExitCode}` from `Invoke-GuiShimTest`; a GUI assertion reading `$r.TestDir` gets `$null`. Return a hashtable with `Pass` and `Message`.

Numbering is automatic. Never renumber by hand.
