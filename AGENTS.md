# AGENTS.md

## The one rule

The four lanes are independent implementations that must behave identically. A change to the `.shim` format or the parser lands in **all four** in the same change, and `test/run-tests.ps1` is the only thing that checks it. Correct in three lanes and missing in the fourth is broken, not partial.

## Before you change anything

| Question | Read |
| -------- | ---- |
| What is valid in a `.shim` file, what errors, what expands | [README.md](README.md) |
| Why the shim is shaped this way, and which traps are load-bearing | [DESIGN.md](DESIGN.md) |
| How to build and test one lane, and its language conventions | [`cpp/`](cpp/README.md) / [`cs/`](cs/README.md) / [`rust/`](rust/README.md) / [`zig/`](zig/README.md) |
| How to run and write a test | [test/README.md](test/README.md) |
| How to measure startup cost | [benchmark/README.md](benchmark/README.md) |

Do not restate a rule from those documents here -- this file routes. If one of them is wrong, fix it there. Update a document in the same commit as the change that makes it untrue. Touch `DESIGN.md` whenever a design decision or one of its traps changes: the code shows what the shim does, only that file records why.

## Build & test

Per lane: [`cpp/README.md`](cpp/README.md), [`cs/README.md`](cs/README.md), [`rust/README.md`](rust/README.md), [`zig/README.md`](zig/README.md). Shared suite: [test/README.md](test/README.md). Every build and test command, the output layout, and what CI runs are documented there.

## Verifying a cross-lane change

The one rule is a requirement, not a description. Build every lane you touched and run the suite against all four before committing -- `test/run-tests.ps1` is the only thing that checks parity, so a change verified against one lane is not verified at all.

"The other lanes do this too" is an assumption to test, not a fact. Divergence here has twice hidden in the lanes with less code and fewer comments, and both times reading one lane and generalising is what missed it.

The other half: no test covering a behaviour is not evidence the lanes agree on it. [test/README.md](test/README.md) lists what the suite cannot reach.

A behaviour fix goes in its own commit, ahead of any cleanup in the same area, so a lane can be brought back into line by reverting one commit rather than by hand.

## Definition of done

Every lane builds, and every lane reports 0 failed. No lane is skipped because its change looked equivalent.

## Working in this repository

- `zig/build.ps1` does not surface the compiler's diagnostics; it throws `zig failed`. Run `zig build` from the lane directory to see the real error.
- The cs lane compiles ahead of time: an `extern` without `[DllImport]` builds clean and then fails when the process starts, so a red suite with no compiler error is that mistake until proven otherwise.
- Do not check a property of a binary by searching its bytes. Version information is UTF-16, a manifest is UTF-8, and a resource can carry the right content at the wrong type. `Get-PESubsystem` in `test/run-tests.ps1` and `test/probe` are the tools for asking; enumerate the resource, do not grep.

## Repository layout

Each lane is self-contained. Build scripts, version files and resource generation are duplicated across lanes on purpose. Why that is the shape rather than a shared library is in [DESIGN.md](DESIGN.md).

## Commit style

Conventional commits: `feat(cpp):`, `fix(rust):`, `test:`, `docs:`, `chore:`, etc. Scope is the language lane, or `test`/`ci`/`docs` for cross-cutting changes. One line, capitalised after the type, no body. The history is the record of what changed; a change that needs explaining is a change that needs a comment, a test, or a line in `DESIGN.md`.
