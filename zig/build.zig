const builtin = @import("builtin");
const std = @import("std");
const CrossTarget = std.Target.Query;

// Usage:
//   zig build -Dtarget=<target> -Doptimize=<optimization level>
// Supported targets:
//   x86-windows-msvc
//   x86_64-windows-msvc
//   aarch64-windows-msvc
// Supported optimization levels:
//   Debug
//   ReleaseSafe
//   ReleaseFast
//   ReleaseSmall

const required_version = std.SemanticVersion.parse("0.16.0") catch unreachable;
const compatible = builtin.zig_version.order(required_version) != .lt;

pub fn build(b: *std.Build) void {
    if (!compatible) {
        std.log.err("Unsupported Zig compiler version", .{});
        return;
    }

    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{ .default_target = CrossTarget{
        .os_tag = .windows,
        .cpu_arch = .x86_64,
        .abi = .msvc,
    } });
    const strip = b.option(bool, "strip", "Strip debug symbols from the executable") orelse false;

    if (target.result.os.tag != .windows) {
        std.log.err("Non-Windows target is not supported", .{});
        return;
    }

    const exe = b.addExecutable(.{
        .name = "shim",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .root_source_file = b.path("shim.zig"),
            .single_threaded = true,
            .error_tracing = false,
        }),
    });

    // Disable runtime safety checks for smaller binary
    exe.root_module.omit_frame_pointer = true;

    // Reduce stack reservation from default 1MB to 64KB
    exe.stack_size = 65536;

    exe.root_module.addCSourceFiles(.{
        .root = b.path("."),
        .files = &.{"shim.rc"},
    });

    exe.root_module.linkSystemLibrary("shell32", .{});

    // Install to prefix root (build.ps1 passes --prefix bin/{platform})
    const install = b.addInstallFile(exe.getEmittedBin(), "shim.exe");
    b.getInstallStep().dependOn(&install.step);
}
