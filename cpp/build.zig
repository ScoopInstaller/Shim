const builtin = @import("builtin");
const std = @import("std");
const CrossTarget = std.Target.Query;

// Usage:
//   zig build -Dtarget=<target> -Doptimize=<optimization level>
// Supported targets:
//   x86-windows-gnu
//   x86-windows-msvc
//   x86_64-windows-gnu
//   x86_64-windows-msvc
//   aarch64-windows-gnu
//   aarch64-windows-msvc
//Supported optimization levels:
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
        }),
    });

    exe.root_module.addCSourceFiles(.{
        .root = b.path("."),
        .files = &.{"shim.cpp"},
        .flags = &.{"-std=c++20", "-fno-exceptions", "-flto"},
    });
    exe.root_module.addCSourceFiles(.{
        .root = b.path("."),
        .files = &.{"shim.rc"},
    });
    exe.root_module.linkSystemLibrary("shell32", .{});

    // Size optimizations: function sections enable GC to strip dead code
    exe.link_function_sections = true;
    exe.link_gc_sections = true;
    exe.stack_size = 65536;

    if (target.result.abi == .msvc) {
        exe.root_module.link_libc = true;
    } else {
        exe.root_module.link_libcpp = true;
        exe.subsystem = .Console;
        exe.mingw_unicode_entry_point = true;
    }

    // Install to prefix root (build.ps1 passes --prefix bin/{platform})
    const install = b.addInstallFile(exe.getEmittedBin(), "shim.exe");
    b.getInstallStep().dependOn(&install.step);
}
