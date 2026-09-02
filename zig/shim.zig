// SPDX-License-Identifier: MIT
// Scoop shim - Zig implementation

const std = @import("std");
const windows = std.os.windows;
const kernel32 = windows.kernel32;

const FILE_CREATION_DISPOSITION = enum(u32) {
    CREATE_NEW = 1,
    CREATE_ALWAYS = 2,
    OPEN_EXISTING = 3,
    OPEN_ALWAYS = 4,
    TRUNCATE_EXISTING = 5,
};

const DWORD = windows.DWORD;
const BOOL = windows.BOOL;
const HANDLE = windows.HANDLE;
const HMODULE = windows.HMODULE;
const CHAR = windows.CHAR;
const WCHAR = windows.WCHAR;
const INFINITE: windows.DWORD = std.math.maxInt(windows.DWORD);
const INVALID_FILE_SIZE: windows.DWORD = std.math.maxInt(windows.DWORD);

const INVALID_HANDLE_VALUE = windows.INVALID_HANDLE_VALUE;

const STD_ERROR_HANDLE = @as(DWORD, @bitCast(@as(i32, -12)));

const CREATE_SUSPENDED = 0x00000004;
const SW_SHOW = 5;

const IMAGE_DOS_SIGNATURE = 0x5A4D;
const IMAGE_NT_SIGNATURE = 0x00004550;
const IMAGE_SUBSYSTEM_WINDOWS_GUI = 2;

const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
const JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK = 0x00001000;
const JobObjectExtendedLimitInformation = 9;

const ATTACH_PARENT_PROCESS = @as(i32, -1);

const ERROR_ELEVATION_REQUIRED = 740;
const ERROR_INVALID_FUNCTION = 1;

const FORMAT_MESSAGE_ALLOCATE_BUFFER = 0x00000100;
const FORMAT_MESSAGE_IGNORE_INSERTS = 0x00000200;
const FORMAT_MESSAGE_FROM_SYSTEM = 0x00001000;
const FORMAT_MESSAGE_MAX_WIDTH_MASK = 0x000000FF;

const SEE_MASK_NOCLOSEPROCESS = 0x00000040;

const CTRL_C_EVENT = 0;
const CTRL_BREAK_EVENT = 1;
const CTRL_CLOSE_EVENT = 2;
const CTRL_LOGOFF_EVENT = 5;
const CTRL_SHUTDOWN_EVENT = 6;

/// Compile-time UTF-8 -> WCHAR literal.
const w = std.unicode.utf8ToUtf16LeStringLiteral;

extern "kernel32" fn GetStdHandle(nStdHandle: DWORD) callconv(.winapi) ?HANDLE;
extern "kernel32" fn WriteFile(
    hFile: HANDLE,
    lpBuffer: [*]const u8,
    nNumberOfBytesToWrite: DWORD,
    lpNumberOfBytesWritten: ?*DWORD,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) BOOL;
extern "kernel32" fn ReadFile(
    hFile: HANDLE,
    lpBuffer: [*]u8,
    nNumberOfBytesToRead: DWORD,
    lpNumberOfBytesRead: ?*DWORD,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) BOOL;
extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
extern "kernel32" fn GetFileSize(hFile: HANDLE, lpFileSizeHigh: ?*DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn WriteConsoleW(
    hConsoleOutput: HANDLE,
    lpBuffer: [*]const WCHAR,
    nNumberOfCharsToWrite: DWORD,
    lpNumberOfCharsWritten: ?*DWORD,
    lpReserved: ?*anyopaque,
) callconv(.winapi) BOOL;
extern "kernel32" fn GetFileType(hFile: HANDLE) callconv(.winapi) DWORD;
extern "kernel32" fn GetModuleHandleW(lpModuleName: ?[*:0]const WCHAR) callconv(.winapi) ?HMODULE;
extern "kernel32" fn GetModuleFileNameW(hModule: ?HMODULE, lpFilename: [*:0]WCHAR, nSize: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn CreateFileW(
    lpFileName: [*:0]const WCHAR,
    dwDesiredAccess: windows.ACCESS_MASK,
    dwShareMode: windows.FILE.SHARE,
    lpSecurityAttributes: ?*anyopaque,
    dwCreationDisposition: FILE_CREATION_DISPOSITION,
    dwFlagsAndAttributes: DWORD,
    hTemplateFile: ?HANDLE,
) callconv(.winapi) HANDLE;
extern "kernel32" fn FreeConsole() callconv(.winapi) BOOL;
extern "kernel32" fn AttachConsole(dwProcessId: i32) callconv(.winapi) BOOL;
extern "kernel32" fn GetCommandLineW() callconv(.winapi) [*:0]const WCHAR;
extern "kernel32" fn CreateJobObjectW(lpJobAttributes: ?*anyopaque, lpName: ?[*:0]const WCHAR) callconv(.winapi) ?HANDLE;
extern "kernel32" fn SetInformationJobObject(
    hJob: HANDLE,
    JobObjectInformationClass: i32,
    lpJobObjectInformation: *const anyopaque,
    cbJobObjectInformationLength: DWORD,
) callconv(.winapi) BOOL;
extern "kernel32" fn AssignProcessToJobObject(hJob: HANDLE, hProcess: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn WaitForSingleObject(hHandle: HANDLE, dwMilliseconds: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn GetExitCodeProcess(hProcess: HANDLE, lpExitCode: *DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn ResumeThread(hThread: HANDLE) callconv(.winapi) DWORD;
extern "kernel32" fn ExitProcess(exitCode: u32) callconv(.winapi) void;
extern "shell32" fn ShellExecuteExW(lpExecInfo: *SHELLEXECUTEINFOW) callconv(.winapi) BOOL;
extern "kernel32" fn GetEnvironmentVariableW(lpName: [*:0]const WCHAR, lpBuffer: ?[*]WCHAR, nSize: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn SetEnvironmentVariableW(lpName: [*:0]const WCHAR, lpValue: ?[*:0]const WCHAR) callconv(.winapi) BOOL;
extern "shell32" fn CommandLineToArgvW(lpCmdLine: [*:0]const WCHAR, pNumArgs: *i32) callconv(.winapi) ?[*]const [*:0]const WCHAR;
extern "kernel32" fn LocalFree(hMem: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn FormatMessageW(
    dwFlags: DWORD,
    lpSource: ?*anyopaque,
    dwMessageId: DWORD,
    dwLanguageId: DWORD,
    lpBuffer: [*]WCHAR,
    nBufferSize: DWORD,
    Arguments: ?[*]?*anyopaque,
) callconv(.winapi) DWORD;
extern "kernel32" fn WideCharToMultiByte(
    codePage: DWORD,
    dwFlags: DWORD,
    lpWideCharStr: [*]const WCHAR,
    cWideCharLen: i32,
    lpMultiByteStr: ?[*]u8,
    cbMultiByte: i32,
    lpDefaultChar: ?[*]const CHAR,
    lpUsedDefaultChar: ?*BOOL,
) callconv(.winapi) i32;

const SHELLEXECUTEINFOW = extern struct {
    cbSize: DWORD,
    fMask: DWORD,
    hwnd: ?HANDLE,
    lpVerb: ?[*:0]const WCHAR,
    lpFile: ?[*:0]const WCHAR,
    lpParameters: ?[*:0]const WCHAR,
    lpDirectory: ?[*:0]const WCHAR,
    nShow: i32,
    hInstApp: ?HANDLE,
    lpIDList: ?*anyopaque,
    lpClass: ?[*:0]const WCHAR,
    hkeyClass: ?HANDLE,
    dwHotKey: DWORD,
    hMonitor: ?HANDLE,
    hProcess: ?HANDLE,
};

const JOBOBJECT_BASIC_LIMIT_INFORMATION = extern struct {
    PerProcessUserTimeLimit: u64,
    PerJobUserTimeLimit: u64,
    LimitFlags: DWORD,
    MinimumWorkingSetSize: usize,
    MaximumWorkingSetSize: usize,
    ActiveProcessLimit: DWORD,
    Affinity: usize,
    PriorityClass: DWORD,
    SchedulingClass: DWORD,
};

const IO_COUNTERS = extern struct {
    ReadOperationCount: u64,
    WriteOperationCount: u64,
    OtherOperationCount: u64,
    ReadTransferCount: u64,
    WriteTransferCount: u64,
    OtherTransferCount: u64,
};

const JOBOBJECT_EXTENDED_LIMIT_INFORMATION = extern struct {
    BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION,
    IoInfo: IO_COUNTERS,
    ProcessMemoryLimit: usize,
    JobMemoryLimit: usize,
    PeakProcessMemoryUsed: usize,
    PeakJobMemoryUsed: usize,
};

const HandlerRoutine = *const fn (DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn GetFullPathNameW(lpFileName: [*:0]const WCHAR, nBufferLength: DWORD, lpBuffer: [*:0]WCHAR, lpFilePart: ?*?*WCHAR) callconv(.winapi) DWORD;
extern "kernel32" fn ExpandEnvironmentStringsW(lpSrc: [*:0]const WCHAR, lpDst: ?[*]WCHAR, nSize: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn SetConsoleCtrlHandler(HandlerRoutine: HandlerRoutine, Add: BOOL) callconv(.winapi) BOOL;
extern "kernel32" fn GetStartupInfoW(lpStartupInfo: *windows.STARTUPINFOW) callconv(.winapi) void;

extern "kernel32" fn CreateProcessW(
    lpApplicationName: ?[*:0]const WCHAR,
    lpCommandLine: [*:0]WCHAR,
    lpProcessAttributes: ?*anyopaque,
    lpThreadAttributes: ?*anyopaque,
    bInheritHandles: BOOL,
    dwCreationFlags: DWORD,
    lpEnvironment: ?*anyopaque,
    lpCurrentDirectory: ?[*:0]const WCHAR,
    lpStartupInfo: *windows.STARTUPINFOW,
    lpProcessInformation: *windows.PROCESS.INFORMATION,
) callconv(.winapi) BOOL;

fn writeError(msg: []const u8) void {
    const hErr = GetStdHandle(STD_ERROR_HANDLE) orelse return;
    var written: DWORD = 0;
    _ = WriteFile(hErr, msg.ptr, @intCast(msg.len), &written, null);
}

fn writeErrorDec(v: u32) void {
    var buf: [10]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch return;
    writeError(s);
}

// System error text follows the OS language.
fn writeErrorSys(err: DWORD) void {
    writeError(" (error ");
    writeErrorDec(err);
    writeError(": ");
    var buf: [256]WCHAR = undefined;
    const n = FormatMessageW(
        FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS | FORMAT_MESSAGE_MAX_WIDTH_MASK,
        null,
        err,
        0,
        &buf,
        buf.len,
        null,
    );
    if (n != 0) writeErrorUtf8(trimTrailingWhitespace(buf[0..n]));
    writeError(").\n");
}

// WriteConsoleW fails on redirected handles, so route by file type.
fn writeErrorUtf8(s: []const WCHAR) void {
    if (s.len == 0) return;
    const hErr = GetStdHandle(STD_ERROR_HANDLE) orelse return;
    if (GetFileType(hErr) == 2) { // FILE_TYPE_CHAR
        var written: DWORD = 0;
        _ = WriteConsoleW(hErr, s.ptr, @intCast(s.len), &written, null);
        return;
    }
    var remaining = s;
    while (remaining.len > 0) {
        // worst case 4 UTF-8 bytes per WCHAR (surrogate pair); chunk keeps buf bounded
        const chunk = remaining[0..@min(remaining.len, 512)];
        var buf: [2048]u8 = undefined;
        const n = WideCharToMultiByte(65001, 0, chunk.ptr, @intCast(chunk.len), &buf, @intCast(buf.len), null, null);
        if (n <= 0) return;
        writeError(buf[0..@intCast(n)]);
        remaining = remaining[chunk.len..];
    }
}

// GUI/redirected launches can yield null or INVALID_HANDLE_VALUE std handles.
fn ensureStandardHandles(si: *windows.STARTUPINFOW) void {
    if (si.hStdInput == null or si.hStdInput == INVALID_HANDLE_VALUE) {
        const h = CreateFileW(w("CONIN$"), .{ .GENERIC = .{ .READ = true } }, .{ .READ = true }, null, .OPEN_EXISTING, 0, null);
        si.hStdInput = if (h != INVALID_HANDLE_VALUE) h else null;
    }
    if (si.hStdOutput == null or si.hStdOutput == INVALID_HANDLE_VALUE) {
        const h = CreateFileW(w("CONOUT$"), .{ .GENERIC = .{ .WRITE = true } }, .{ .WRITE = true }, null, .OPEN_EXISTING, 0, null);
        si.hStdOutput = if (h != INVALID_HANDLE_VALUE) h else null;
    }
    if (si.hStdError == null or si.hStdError == INVALID_HANDLE_VALUE) {
        const h = CreateFileW(w("CONOUT$"), .{ .GENERIC = .{ .WRITE = true } }, .{ .WRITE = true }, null, .OPEN_EXISTING, 0, null);
        si.hStdError = if (h != INVALID_HANDLE_VALUE) h else null;
    }
}

fn getDirectory(exe: []const WCHAR) []const WCHAR {
    if (std.mem.lastIndexOfScalar(WCHAR, exe, '\\')) |pos| {
        return exe[0..pos];
    }
    if (std.mem.lastIndexOfScalar(WCHAR, exe, '/')) |pos| {
        return exe[0..pos];
    }
    return exe;
}

// Unicode whitespace, not just ASCII.
fn isWS(ch: WCHAR) bool {
    return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r' or
        ch == 0x00A0 or ch == 0x1680 or
        (ch >= 0x2000 and ch <= 0x200A) or ch == 0x2028 or ch == 0x2029 or
        ch == 0x202F or ch == 0x205F or ch == 0x3000;
}

fn trimTrailingWhitespace(sv: []const WCHAR) []const WCHAR {
    var end = sv.len;
    while (end > 0 and isWS(sv[end - 1])) end -= 1;
    return sv[0..end];
}

/// Replace `%~dp0` in `args` in-place; returns the new length.
fn normalizeArgs(args: []WCHAR, curDir: []const WCHAR) usize {
    const placeholder = w("%~dp0");
    if (std.mem.indexOf(WCHAR, args, placeholder)) |pos| {
        var replacement_len = curDir.len;
        const needs_slash = replacement_len == 0 or
            (curDir[replacement_len - 1] != '\\' and curDir[replacement_len - 1] != '/');
        if (needs_slash) replacement_len += 1;

        const after_pos = pos + placeholder.len;
        // Signed: a drive-root target dir is shorter than the placeholder; usize would underflow.
        const shift: isize = @as(isize, @intCast(replacement_len)) - @as(isize, @intCast(placeholder.len));
        const new_len: usize = @intCast(@as(isize, @intCast(args.len)) + shift);

        if (shift > 0) {
            std.mem.copyBackwards(WCHAR, args[after_pos + @as(usize, @intCast(shift)) .. new_len], args[after_pos..args.len]);
        } else {
            const neg: usize = @intCast(-shift);
            std.mem.copyForwards(WCHAR, args[after_pos - neg .. args.len - neg], args[after_pos..args.len]);
        }

        std.mem.copyForwards(WCHAR, args[pos .. pos + curDir.len], curDir);
        if (needs_slash) args[pos + curDir.len] = '\\';

        return new_len;
    }
    return args.len;
}

/// Windows CreateProcessW quoting rules. Caller owns the result.
fn quoteArg(allocator: std.mem.Allocator, arg: []const WCHAR) ![]WCHAR {
    if (arg.len == 0) {
        const r = try allocator.alloc(WCHAR, 2);
        r[0] = '"';
        r[1] = '"';
        return r;
    }

    var needs_quoting = false;
    for (arg) |c| {
        if (c == ' ' or c == '\t' or c == '"') {
            needs_quoting = true;
            break;
        }
    }

    if (!needs_quoting) {
        return try allocator.dupe(WCHAR, arg);
    }

    var result = try std.ArrayList(WCHAR).initCapacity(allocator, arg.len + 8);
    defer result.deinit(allocator);
    result.appendAssumeCapacity('"');

    var i: usize = 0;
    while (i < arg.len) {
        if (arg[i] == '\\') {
            const bs_start = i;
            while (i < arg.len and arg[i] == '\\') : (i += 1) {}

            if (i == arg.len) {
                try result.appendNTimes(allocator, '\\', (i - bs_start) * 2);
            } else if (arg[i] == '"') {
                try result.appendNTimes(allocator, '\\', (i - bs_start) * 2 + 1);
                try result.append(allocator, '"');
                i += 1;
            } else {
                try result.appendNTimes(allocator, '\\', i - bs_start);
            }
        } else if (arg[i] == '"') {
            try result.append(allocator, '\\');
            try result.append(allocator, '"');
            i += 1;
        } else {
            try result.append(allocator, arg[i]);
            i += 1;
        }
    }

    try result.append(allocator, '"');
    return try result.toOwnedSlice(allocator);
}

/// Caller owns the result.
fn buildCmdLine(allocator: std.mem.Allocator, path: []const WCHAR, args: []const []const WCHAR) ![:0]WCHAR {
    var result = try std.ArrayList(WCHAR).initCapacity(allocator, path.len + 64);
    defer result.deinit(allocator);

    const quoted_path = try quoteArg(allocator, path);
    defer allocator.free(quoted_path);
    try result.appendSlice(allocator, quoted_path);

    for (args) |arg| {
        try result.append(allocator, ' ');
        const quoted = try quoteArg(allocator, arg);
        defer allocator.free(quoted);
        try result.appendSlice(allocator, quoted);
    }

    try result.append(allocator, 0);
    const owned = try result.toOwnedSlice(allocator);
    return owned[0 .. owned.len - 1 :0];
}

/// CommandLineToArgvW parsing. Caller owns the result and each element.
fn parseArgsFromCmdLine(allocator: std.mem.Allocator, cmdline: [:0]const WCHAR) ![][:0]WCHAR {
    if (cmdline.len == 0) return try allocator.alloc([:0]WCHAR, 0);

    var argc: i32 = 0;
    const argv = CommandLineToArgvW(cmdline.ptr, &argc) orelse
        return try allocator.alloc([:0]WCHAR, 0);
    defer _ = LocalFree(@ptrCast(@constCast(argv)));

    var result = try allocator.alloc([:0]WCHAR, @intCast(argc));
    for (0..@intCast(argc)) |idx| {
        const arg_z = argv[idx];
        const len = std.mem.len(arg_z);
        const copy = try allocator.alloc(WCHAR, len + 1);
        @memcpy(copy[0..len], arg_z[0..len]);
        copy[len] = 0;
        result[idx] = copy[0..len :0];
    }
    return result;
}

// PE headers are read directly - std does not expose image helpers.
fn isGuiSubsystem() bool {
    const hModule = GetModuleHandleW(null) orelse return false;
    const base = @as([*]u8, @ptrCast(hModule));

    const dos_sig = @as(*u16, @ptrCast(@alignCast(base))).*;
    if (dos_sig != IMAGE_DOS_SIGNATURE) return false;

    const pe_offset = @as(*u32, @ptrCast(@alignCast(base + 0x3C))).*;
    const pe_sig = @as(*u32, @ptrCast(@alignCast(base + pe_offset))).*;
    if (pe_sig != IMAGE_NT_SIGNATURE) return false;

    const subsystem = @as(*u16, @ptrCast(@alignCast(base + pe_offset + 0x5C))).*;
    return subsystem == IMAGE_SUBSYSTEM_WINDOWS_GUI;
}

fn parseBool(value: []const WCHAR) bool {
    if (value.len == 0) return false;

    var lower: [16]WCHAR = undefined;
    if (value.len > lower.len) return false;

    for (value, 0..) |c, i| {
        lower[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
    }

    const lv = lower[0..value.len];
    return std.mem.eql(WCHAR, lv, w("true")) or
        std.mem.eql(WCHAR, lv, w("1")) or
        std.mem.eql(WCHAR, lv, w("yes"));
}

/// Caller owns the result.
fn expandEnvVars(allocator: std.mem.Allocator, input: []const WCHAR) ![]WCHAR {
    const input_z = try allocator.alloc(WCHAR, input.len + 1);
    defer allocator.free(input_z);
    @memcpy(input_z[0..input.len], input);
    input_z[input.len] = 0;
    // First call gets the required size, second expands.
    const required = ExpandEnvironmentStringsW(input_z[0..input.len :0].ptr, null, 0);
    if (required == 0) return try allocator.dupe(WCHAR, input);
    var buf = try allocator.alloc(WCHAR, required);
    defer allocator.free(buf);
    const actual = ExpandEnvironmentStringsW(input_z[0..input.len :0].ptr, buf.ptr, required);
    if (actual == 0 or actual > required) return try allocator.dupe(WCHAR, input);
    return try allocator.dupe(WCHAR, buf[0 .. actual - 1]);
}

// Shim quotes are structural markers, not content - strip them after expanding.
fn expandEnvVarsAndUnquote(allocator: std.mem.Allocator, input: []const WCHAR) ![:0]WCHAR {
    const expanded = try expandEnvVars(allocator, input);
    defer allocator.free(expanded);
    var unquoted = expanded;
    if (unquoted.len >= 2 and unquoted[0] == '"' and unquoted[unquoted.len - 1] == '"') {
        unquoted = unquoted[1 .. unquoted.len - 1];
    }
    const result = try allocator.alloc(WCHAR, unquoted.len + 1);
    @memcpy(result[0..unquoted.len], unquoted);
    result[unquoted.len] = 0;
    return result[0..unquoted.len :0];
}

const ShimInfo = struct {
    path: ?[:0]WCHAR = null,
    args: std.ArrayListUnmanaged([]const WCHAR) = .empty,
    cwd: ?[:0]WCHAR = null,
    elevate: bool = false,
    env_vars: std.ArrayListUnmanaged(struct { name: []WCHAR, value: [:0]WCHAR }) = .empty,
    allocator: std.mem.Allocator = undefined,

    fn init(allocator: std.mem.Allocator) ShimInfo {
        return .{
            .allocator = allocator,
        };
    }

    fn deinit(self: *ShimInfo) void {
        if (self.path) |p| self.allocator.free(p);
        for (self.args.items) |a| {
            self.allocator.free(@constCast(a));
        }
        self.args.deinit(self.allocator);
        if (self.cwd) |c| self.allocator.free(c);
        for (self.env_vars.items) |ev| {
            self.allocator.free(ev.name);
            self.allocator.free(ev.value);
        }
        self.env_vars.deinit(self.allocator);
    }
};

fn skipLineEndings(buf: []const u8, line_end: usize) usize {
    var pos = line_end + 1;
    while (pos < buf.len and (buf[pos] == '\n' or buf[pos] == '\r')) : (pos += 1) {}
    return pos;
}

fn trimLeadingWhitespace(sv: []const WCHAR) []const WCHAR {
    var start: usize = 0;
    while (start < sv.len and isWS(sv[start])) : (start += 1) {}
    return sv[start..];
}

fn parseShimLine(line: []const WCHAR) ?struct { name: []const WCHAR, value: []const WCHAR } {
    var trimmed = trimLeadingWhitespace(trimTrailingWhitespace(line));
    if (trimmed.len == 0 or trimmed[0] == '#' or trimmed[0] == ';') return null;
    if (trimmed.len >= 2 and trimmed[0] == '/' and trimmed[1] == '/') return null;
    const sep = w(" = ");
    const pos = std.mem.indexOf(WCHAR, trimmed, sep) orelse return null;
    var name = trimmed[0..pos];
    var value = trimmed[pos + sep.len ..];
    name = trimTrailingWhitespace(name);
    name = trimLeadingWhitespace(name);
    value = trimLeadingWhitespace(value);
    value = trimTrailingWhitespace(value);
    if (name.len == 0) return null;
    return .{ .name = name, .value = value };
}

/// Returns the *directory* portion (trailing backslash), not the resolved path. Caller owns it.
fn resolveAgainstBase(allocator: std.mem.Allocator, path: []const WCHAR, baseDir: []const WCHAR) ![]WCHAR {
    const is_absolute = (path.len >= 2 and path[1] == ':') or (path.len > 0 and path[0] == '\\');
    var toResolve: []const WCHAR = undefined;
    if (is_absolute) {
        toResolve = path;
    } else {
        const combined_len = baseDir.len + 1 + path.len;
        const buf = try allocator.alloc(WCHAR, combined_len + 1);
        @memcpy(buf[0..baseDir.len], baseDir);
        buf[baseDir.len] = '\\';
        @memcpy(buf[baseDir.len + 1 .. baseDir.len + 1 + path.len], path);
        buf[combined_len] = 0;
        toResolve = buf[0..combined_len :0];
    }
    var resolved_buf: [windows.MAX_PATH + 2:0]WCHAR = undefined;
    var file_part: ?*WCHAR = null;
    const len = GetFullPathNameW(@ptrCast(toResolve.ptr), resolved_buf.len, &resolved_buf, &file_part);
    if (len == 0 or len >= resolved_buf.len) return try allocator.dupe(WCHAR, toResolve);
    const dir_len = if (file_part) |fp|
        (@intFromPtr(fp) - @intFromPtr(&resolved_buf)) / @sizeOf(WCHAR)
    else
        len;
    if (dir_len > 0 and (resolved_buf[dir_len - 1] == '\\' or resolved_buf[dir_len - 1] == '/')) {
        return try allocator.dupe(WCHAR, resolved_buf[0..dir_len]);
    }
    const result = try allocator.alloc(WCHAR, dir_len + 1);
    @memcpy(result[0..dir_len], resolved_buf[0..dir_len]);
    result[dir_len] = '\\';
    return result;
}

fn getShimInfo(allocator: std.mem.Allocator) !ShimInfo {
    var info = ShimInfo.init(allocator);
    errdefer info.deinit();

    var filename: [windows.MAX_PATH + 2:0]WCHAR = undefined;
    const filename_size = GetModuleFileNameW(null, &filename, windows.MAX_PATH);
    if (filename_size == 0 or filename_size >= windows.MAX_PATH) {
        if (filename_size == 0) {
            writeError("Shim: The filename of the program could not be determined");
            writeErrorSys(GetLastError());
        } else {
            writeError("Shim: The filename of the program is too long to handle: '");
            writeErrorUtf8(filename[0..filename_size]);
            writeError("'.\n");
        }
        return error.PathTooLong;
    }

    @memcpy(filename[filename_size - 3 .. filename_size - 3 + 4], w("shim"));
    filename[filename_size + 1] = 0;

    const file_handle = CreateFileW(
        filename[0 .. filename_size + 1 :0].ptr,
        .{ .GENERIC = .{ .READ = true } },
        .{ .READ = true },
        null,
        .OPEN_EXISTING,
        0,
        null,
    );
    if (file_handle == INVALID_HANDLE_VALUE) {
        const open_err = GetLastError();
        writeError("Shim: Cannot open shim file for read: '");
        writeErrorUtf8(filename[0 .. filename_size + 1]);
        writeError("'");
        writeErrorSys(open_err);
        return info;
    }
    defer windows.CloseHandle(file_handle);

    const cur_dir = getDirectory(filename[0..filename_size]);

    const file_size = GetFileSize(file_handle, null);
    if (file_size == INVALID_FILE_SIZE) {
        const size_err = GetLastError();
        writeError("Shim: Cannot open shim file for read: '");
        writeErrorUtf8(filename[0 .. filename_size + 1]);
        writeError("'");
        writeErrorSys(size_err);
        return info;
    }

    var file_buf = try allocator.alloc(u8, @intCast(file_size));
    defer allocator.free(file_buf);

    var bytes_read: DWORD = 0;
    if (!ReadFile(file_handle, file_buf.ptr, file_size, &bytes_read, null).toBool() or bytes_read != file_size) {
        const read_err = GetLastError();
        writeError("Shim: Cannot open shim file for read: '");
        writeErrorUtf8(filename[0 .. filename_size + 1]);
        writeError("'");
        writeErrorSys(read_err);
        return info;
    }

    // %~dp0 means the *target* exe directory, not the shim's own. Pass 1 resolves
    // path to absolute so pass 2 can expand %~dp0 against the right base.
    var targetDir: []const WCHAR = cur_dir;
    var targetDirAllocated = false;
    defer if (targetDirAllocated) allocator.free(@constCast(targetDir));
    var lw: [1 << 14]WCHAR = undefined;
    {
        var first1 = true;
        var scan: usize = 0;
        while (scan < bytes_read) {
            var le = scan;
            while (le < bytes_read and file_buf[le] != '\n' and file_buf[le] != '\r') le += 1;
            if (le > scan) {
                const u = file_buf[scan..le];
                const wlen = std.unicode.utf8ToUtf16Le(&lw, u) catch {
                    scan = skipLineEndings(file_buf, le);
                    continue;
                };
                var pl = trimTrailingWhitespace(lw[0..wlen]);
                if (first1 and pl.len > 0 and pl[0] == 0xFEFF) pl = pl[1..];
                first1 = false;
                const parsed = parseShimLine(pl);
                if (parsed == null or !std.mem.eql(WCHAR, parsed.?.name, w("path"))) {
                    scan = skipLineEndings(file_buf, le);
                    continue;
                }
                const ex = try expandEnvVarsAndUnquote(allocator, parsed.?.value);
                defer allocator.free(ex);
                const rv = try resolveAgainstBase(allocator, ex, cur_dir);
                targetDir = rv;
                targetDirAllocated = true;
                break;
            }
            scan = skipLineEndings(file_buf, le);
        }
    }
    // Second pass: expand all fields using targetDir for %~dp0.
    var first2 = true;
    var lpos: usize = 0;
    while (lpos < bytes_read) {
        var le2 = lpos;
        while (le2 < bytes_read and file_buf[le2] != '\n' and file_buf[le2] != '\r') le2 += 1;
        if (le2 > lpos) {
            const chunk2 = file_buf[lpos..le2];
            const wlen2 = std.unicode.utf8ToUtf16Le(&lw, chunk2) catch 0;
            var pl2 = trimTrailingWhitespace(lw[0..wlen2]);
            if (first2 and pl2.len > 0 and pl2[0] == 0xFEFF) pl2 = pl2[1..];
            first2 = false;
            const parsed = parseShimLine(pl2);
            if (parsed) |p| {
                const name = p.name;
                const value = p.value;

                if (std.mem.eql(WCHAR, name, w("path"))) {
                    info.path = try expandEnvVarsAndUnquote(allocator, value);
                } else if (std.mem.eql(WCHAR, name, w("args"))) {
                    // %~dp0 is replaced in-place, so the copy is sized for the expansion.
                    const max_len = value.len + targetDir.len;
                    const args_copy = try allocator.alloc(WCHAR, max_len + 1);
                    @memcpy(args_copy[0..value.len], value);
                    args_copy[value.len] = 0;
                    const new_len = normalizeArgs(args_copy[0..value.len], targetDir);
                    args_copy[new_len] = 0;

                    const normalized: [:0]WCHAR = args_copy[0..new_len :0];
                    if (normalized.len > 0) {
                        const shim_args = try parseArgsFromCmdLine(allocator, normalized);
                        defer allocator.free(shim_args);
                        for (shim_args) |arg| {
                            try info.args.append(allocator, arg);
                        }
                    }
                    allocator.free(args_copy);
                } else if (std.mem.eql(WCHAR, name, w("cwd")) or
                    std.mem.eql(WCHAR, name, w("workdir")))
                {
                    const max_len = value.len + targetDir.len;
                    const cwd_copy = try allocator.alloc(WCHAR, max_len + 1);
                    defer allocator.free(cwd_copy);
                    @memcpy(cwd_copy[0..value.len], value);
                    const new_len = normalizeArgs(cwd_copy[0..value.len], targetDir);
                    info.cwd = try expandEnvVarsAndUnquote(allocator, cwd_copy[0..new_len]);
                } else if (std.mem.eql(WCHAR, name, w("elevate")) or
                    std.mem.eql(WCHAR, name, w("runas")))
                {
                    info.elevate = parseBool(value);
                } else {
                    // Environment variable
                    const name_copy = try allocator.alloc(WCHAR, name.len);
                    @memcpy(name_copy, name);
                    const value_copy = try expandEnvVarsAndUnquote(allocator, value);
                    try info.env_vars.append(allocator, .{ .name = name_copy, .value = value_copy });
                }
            }
        }
        lpos = skipLineEndings(file_buf, le2);
    }

    if (info.path == null) {
        writeError("Shim: 'path' not found in shim file '");
        writeErrorUtf8(filename[0 .. filename_size + 1]);
        writeError("'.\n");
    }

    return info;
}

/// Ctrl-C / Ctrl-Break handler - swallow the event so the child process handles it.
fn ctrlHandler(ctrl_type: DWORD) callconv(.winapi) BOOL {
    switch (ctrl_type) {
        CTRL_C_EVENT, CTRL_BREAK_EVENT, CTRL_CLOSE_EVENT, CTRL_LOGOFF_EVENT, CTRL_SHUTDOWN_EVENT => return .TRUE,
        else => return .FALSE,
    }
}

const ProcessResult = struct {
    process: ?HANDLE = null,
    thread: ?HANDLE = null,
};

// ShellExecuteExW "runas" - the only way to trigger a UAC prompt from this process.
fn launchElevated(
    path_z: [*:0]WCHAR,
    args_z: [*:0]WCHAR,
    has_args: bool,
    cwd: ?[]const WCHAR,
    job_handle: ?HANDLE,
) ?HANDLE {
    var sei: SHELLEXECUTEINFOW = std.mem.zeroes(SHELLEXECUTEINFOW);
    sei.cbSize = @sizeOf(SHELLEXECUTEINFOW);
    sei.fMask = SEE_MASK_NOCLOSEPROCESS;
    sei.lpFile = @ptrCast(path_z);
    sei.lpParameters = if (has_args) @ptrCast(args_z) else null;
    sei.lpDirectory = if (cwd) |c| @ptrCast(c.ptr) else null;
    sei.lpVerb = w("runas");
    sei.nShow = SW_SHOW;

    if (!ShellExecuteExW(&sei).toBool()) {
        // On failure hInstApp holds an SE_ERR_* value (<=32); otherwise use GetLastError.
        var err: DWORD = 0;
        if (sei.hInstApp) |hi| {
            const v: u64 = @intFromPtr(hi);
            if (v > 0 and v <= 32) err = @intCast(v);
        }
        if (err == 0) err = GetLastError();
        if (err == 0) err = ERROR_INVALID_FUNCTION;
        writeError("Shim: Unable to create elevated process");
        writeErrorSys(err);
        return null;
    }
    if (job_handle) |jh| {
        if (sei.hProcess) |ph| {
            _ = AssignProcessToJobObject(jh, ph);
        }
    }
    return sei.hProcess;
}

fn makeProcess(allocator: std.mem.Allocator, info: *const ShimInfo, job_handle: ?HANDLE) !ProcessResult {
    var result = ProcessResult{};

    const path = info.path orelse return result;
    const args = info.args.items;
    const cwd = if (info.cwd) |c| c else null;

    // Child inherits the updated environment block, hence before CreateProcessW.
    for (info.env_vars.items) |ev| {
        const name_z = try allocator.alloc(WCHAR, ev.name.len + 1);
        defer allocator.free(name_z);
        @memcpy(name_z[0..ev.name.len], ev.name);
        name_z[ev.name.len] = 0;

        if (!SetEnvironmentVariableW(name_z[0..ev.name.len :0].ptr, ev.value.ptr).toBool()) {
            writeError("Shim: Could not set environment variable '");
            writeErrorUtf8(ev.name);
            writeError("'");
            writeErrorSys(GetLastError());
        }
    }

    const cmd = try buildCmdLine(allocator, path, args);
    defer allocator.free(cmd);

    var si: windows.STARTUPINFOW = std.mem.zeroes(windows.STARTUPINFOW);
    si.cb = @sizeOf(windows.STARTUPINFOW);
    GetStartupInfoW(&si);
    ensureStandardHandles(&si);

    const joined_args = if (args.len > 0) blk: {
        var list = try std.ArrayList(WCHAR).initCapacity(allocator, 64);
        for (args, 0..) |arg, i| {
            if (i > 0) try list.append(allocator, ' ');
            const quoted = try quoteArg(allocator, arg);
            defer allocator.free(quoted);
            try list.appendSlice(allocator, quoted);
        }
        break :blk try list.toOwnedSlice(allocator);
    } else &[_]WCHAR{};
    defer if (args.len > 0) allocator.free(joined_args);

    const args_z = try allocator.alloc(WCHAR, joined_args.len + 1);
    defer allocator.free(args_z);
    if (joined_args.len > 0) @memcpy(args_z[0..joined_args.len], joined_args);
    args_z[joined_args.len] = 0;
    const args_z_sentinel: [:0]WCHAR = args_z[0..joined_args.len :0];

    if (info.elevate) {
        result.process = launchElevated(path.ptr, args_z_sentinel.ptr, args.len > 0, cwd, job_handle);
        return result;
    }

    var pi: windows.PROCESS.INFORMATION = undefined;
    // SUSPENDED: the child must join the job object before it can spawn its own children.
    if (CreateProcessW(null, @ptrCast(@constCast(cmd.ptr)), null, null, .TRUE, CREATE_SUSPENDED, null, if (cwd) |c| @ptrCast(c.ptr) else null, &si, &pi).toBool()) {
        result.thread = pi.hThread;
        result.process = pi.hProcess;

        if (job_handle) |jh| {
            _ = AssignProcessToJobObject(jh, pi.hProcess);
        }
        _ = ResumeThread(pi.hThread);
    } else {
        const err = GetLastError();
        if (err == ERROR_ELEVATION_REQUIRED) {
            result.process = launchElevated(path.ptr, args_z_sentinel.ptr, args.len > 0, cwd, job_handle);
        } else {
            writeError("Shim: Could not create process with command '");
            writeErrorUtf8(cmd);
            writeError("'");
            writeErrorSys(err);
            return result;
        }
    }

    return result;
}

// Bypass std.start - no main(), argv, or allocator init needed.
pub export fn wWinMainCRTStartup() callconv(.winapi) void {
    const code = shimMain() catch 1;
    ExitProcess(code);
}

fn shimMain() !u32 {
    const allocator = std.heap.page_allocator;

    var info = try getShimInfo(allocator);
    defer info.deinit();

    if (info.path == null) {
        return 1;
    }

    {
        const cmd = GetCommandLineW();
        const cmd_len = std.mem.len(cmd);
        if (cmd_len > 0) {
            const cmd_copy = try allocator.alloc(WCHAR, cmd_len + 1);
            defer allocator.free(cmd_copy);
            @memcpy(cmd_copy[0..cmd_len], cmd[0..cmd_len]);
            cmd_copy[cmd_len] = 0;

            const user_args = try parseArgsFromCmdLine(allocator, cmd_copy[0..cmd_len :0]);

            if (user_args.len > 1) {
                const user_portion = user_args[1..];
                allocator.free(user_args[0]);
                for (user_portion) |arg| try info.args.append(allocator, arg);
            } else {
                for (user_args) |a| allocator.free(a);
            }
            allocator.free(user_args);
        }
    }

    // A GUI-subsystem shim would flash a console. With args it behaves as a CLI
    // tool, so it re-attaches to the parent console for output.
    if (isGuiSubsystem()) {
        const has_args = info.args.items.len > 0;
        if (!has_args) {
            _ = FreeConsole();
        } else {
            _ = AttachConsole(ATTACH_PARENT_PROCESS);
        }
    }

    // KILL_ON_JOB_CLOSE ties child lifetime to the shim.
    const job_handle = CreateJobObjectW(null, null);
    if (job_handle) |jh| {
        var jeli: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std.mem.zeroes(JOBOBJECT_EXTENDED_LIMIT_INFORMATION);
        jeli.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK;
        _ = SetInformationJobObject(jh, JobObjectExtendedLimitInformation, &jeli, @sizeOf(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
    }

    // Before spawn: a Ctrl event in the gap would kill the shim and
    // KILL_ON_JOB_CLOSE would take the child down with it.
    _ = SetConsoleCtrlHandler(ctrlHandler, .TRUE);

    const proc_result = try makeProcess(allocator, &info, job_handle);
    const process_handle = proc_result.process orelse return 1;

    _ = WaitForSingleObject(process_handle, INFINITE);

    var exit_code: DWORD = 1;
    _ = GetExitCodeProcess(process_handle, &exit_code);

    return exit_code;
}
