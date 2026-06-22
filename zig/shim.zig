// SPDX-License-Identifier: MIT
// Scoop shim — Zig implementation

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

const SEE_MASK_NOCLOSEPROCESS = 0x00000040;

const CTRL_C_EVENT = 0;
const CTRL_BREAK_EVENT = 1;
const CTRL_CLOSE_EVENT = 2;
const CTRL_LOGOFF_EVENT = 5;
const CTRL_SHUTDOWN_EVENT = 6;

/// Compile-time UTF-8 → WCHAR literal.
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

/// Write byte message to stderr.
fn writeError(msg: []const u8) void {
    const hErr = GetStdHandle(STD_ERROR_HANDLE) orelse return;
    var written: DWORD = 0;
    _ = WriteFile(hErr, msg.ptr, @intCast(msg.len), &written, null);
}

/// Write WCHAR message to stderr (for console).
fn writeErrorW(msg: []const WCHAR) void {
    const hErr = GetStdHandle(STD_ERROR_HANDLE) orelse return;
    var written: DWORD = 0;
    _ = WriteConsoleW(hErr, msg.ptr, @intCast(msg.len), &written, null);
}

/// Open CONIN$/CONOUT$ to ensure stdin/stdout/stderr are valid handles.
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

/// Return the parent directory of `exe` (strip trailing filename component).
fn getDirectory(exe: []const WCHAR) []const WCHAR {
    if (std.mem.lastIndexOfScalar(WCHAR, exe, '\\')) |pos| {
        return exe[0..pos];
    }
    if (std.mem.lastIndexOfScalar(WCHAR, exe, '/')) |pos| {
        return exe[0..pos];
    }
    return exe;
}

/// Check if a WCHAR is Unicode whitespace
fn isWS(ch: WCHAR) bool {
    return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r' or
        ch == 0x00A0 or ch == 0x1680 or
        (ch >= 0x2000 and ch <= 0x200A) or ch == 0x2028 or ch == 0x2029 or
        ch == 0x202F or ch == 0x205F or ch == 0x3000;
}

/// Trim trailing whitespace from a WCHAR slice.
fn trimTrailingWhitespace(sv: []const WCHAR) []const WCHAR {
    var end = sv.len;
    while (end > 0 and isWS(sv[end - 1])) end -= 1;
    return sv[0..end];
}

/// Replace `%~dp0` placeholder in `args` with `curDir`, shifting content in-place.
/// Returns the new length of the slice.
fn normalizeArgs(args: []WCHAR, curDir: []const WCHAR) usize {
    const placeholder = w("%~dp0");
    if (std.mem.indexOf(WCHAR, args, placeholder)) |pos| {
        var replacement_len = curDir.len;
        const needs_slash = replacement_len == 0 or
            (curDir[replacement_len - 1] != '\\' and curDir[replacement_len - 1] != '/');
        if (needs_slash) replacement_len += 1;

        const after_pos = pos + placeholder.len;
        const shift = replacement_len - placeholder.len;
        const new_len = args.len + shift;

        if (shift > 0) {
            std.mem.copyBackwards(WCHAR, args[after_pos + shift .. new_len], args[after_pos..args.len]);
        } else {
            std.mem.copyForwards(WCHAR, args[after_pos + shift .. args.len + shift], args[after_pos..args.len]);
        }

        std.mem.copyForwards(WCHAR, args[pos .. pos + curDir.len], curDir);
        if (needs_slash) args[pos + curDir.len] = '\\';

        return new_len;
    }
    return args.len;
}

/// Quote a single argument per Windows CreateProcessW quoting rules.
/// Caller owns the returned slice.
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

/// Build a properly quoted command line (null-terminated) from path and args.
/// Caller owns the returned slice.
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

/// Parse a command line string into individual arguments using CommandLineToArgvW.
/// Caller owns the returned slice and each element.
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

/// Detect GUI subsystem via PE header of the current module.
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

/// Parse a boolean value from WCHAR (accepts true/1/yes, case-insensitive).
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

/// Expand `%VAR%` references via ExpandEnvironmentStringsW.
/// Caller owns the returned slice.
fn expandEnvVars(allocator: std.mem.Allocator, input: []const WCHAR) ![]WCHAR {
    const input_z = try allocator.alloc(WCHAR, input.len + 1);
    defer allocator.free(input_z);
    @memcpy(input_z[0..input.len], input);
    input_z[input.len] = 0;
    const required = ExpandEnvironmentStringsW(input_z[0..input.len :0].ptr, null, 0);
    if (required == 0) return try allocator.dupe(WCHAR, input);
    var buf = try allocator.alloc(WCHAR, required);
    defer allocator.free(buf);
    const actual = ExpandEnvironmentStringsW(input_z[0..input.len :0].ptr, buf.ptr, required);
    if (actual == 0 or actual > required) return try allocator.dupe(WCHAR, input);
    return try allocator.dupe(WCHAR, buf[0 .. actual - 1]);
}

/// Expand environment variables in `input`, then strip surrounding double quotes.
/// Returns a newly allocated slice (caller must free).
fn expandEnvVarsAndUnquote(allocator: std.mem.Allocator, input: []const WCHAR) ![]WCHAR {
    const expanded = try expandEnvVars(allocator, input);
    var unquoted = expanded;
    if (unquoted.len >= 2 and unquoted[0] == '"' and unquoted[unquoted.len - 1] == '"') {
        unquoted = unquoted[1 .. unquoted.len - 1];
    }
    if (unquoted.ptr == expanded.ptr and unquoted.len == expanded.len) {
        return expanded;
    }
    const result = try allocator.alloc(WCHAR, unquoted.len);
    @memcpy(result, unquoted);
    allocator.free(expanded);
    return result;
}

const ShimInfo = struct {
    path: ?[]WCHAR = null,
    args: std.ArrayListUnmanaged([]const WCHAR) = .empty,
    cwd: ?[]WCHAR = null,
    elevate: bool = false,
    env_vars: std.ArrayListUnmanaged(struct { name: []WCHAR, value: []WCHAR }) = .empty,
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

/// Skip past line-ending characters (\n / \r) starting at `line_end`.
fn skipLineEndings(buf: []const u8, line_end: usize) usize {
    var pos = line_end + 1;
    while (pos < buf.len and (buf[pos] == '\n' or buf[pos] == '\r')) : (pos += 1) {}
    return pos;
}

/// Trim leading whitespace from a WCHAR slice.
fn trimLeadingWhitespace(sv: []const WCHAR) []const WCHAR {
    var start: usize = 0;
    while (start < sv.len and isWS(sv[start])) : (start += 1) {}
    return sv[start..];
}

/// Parse a single `key = value` line from a .shim file.
/// Returns null for empty/comment lines.
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

/// Resolve `path` against `baseDir`: if relative, join with `baseDir`; then normalize via GetFullPathNameW.
/// Returns the **directory** portion of the resolved path (trailing backslash appended).
/// Caller owns the returned slice.
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
    // Ensure trailing backslash
    if (dir_len > 0 and (resolved_buf[dir_len - 1] == '\\' or resolved_buf[dir_len - 1] == '/')) {
        return try allocator.dupe(WCHAR, resolved_buf[0..dir_len]);
    }
    const result = try allocator.alloc(WCHAR, dir_len + 1);
    @memcpy(result[0..dir_len], resolved_buf[0..dir_len]);
    result[dir_len] = '\\';
    return result;
}

/// Read and parse the .shim file, returning all fields.
fn getShimInfo(allocator: std.mem.Allocator) !ShimInfo {
    var info = ShimInfo.init(allocator);
    errdefer info.deinit();

    var filename: [windows.MAX_PATH + 2:0]WCHAR = undefined;
    const filename_size = GetModuleFileNameW(null, &filename, windows.MAX_PATH);
    if (filename_size >= windows.MAX_PATH) {
        writeError("Shim: The filename of the program is too long to handle.\n");
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
        writeError("Cannot open shim file for read.\n");
        return error.FileNotFound;
    }
    defer windows.CloseHandle(file_handle);

    const cur_dir = getDirectory(filename[0..filename_size]);

    const file_size = GetFileSize(file_handle, null);
    if (file_size == INFINITE) {
        writeError("Cannot get shim file size.\n");
        return error.FileReadError;
    }

    var file_buf = try allocator.alloc(u8, @intCast(file_size));
    defer allocator.free(file_buf);

    var bytes_read: DWORD = 0;
    if (!ReadFile(file_handle, file_buf.ptr, file_size, &bytes_read, null).toBool() or bytes_read != file_size) {
        writeError("Cannot read shim file.\n");
        return error.FileReadError;
    }

    // Pass 1: find `path` field → compute targetDir (for %~dp0 expansion)
    var targetDir: []const WCHAR = cur_dir;
    var targetDirAllocated = false;
    defer if (targetDirAllocated) allocator.free(@constCast(targetDir));
    {
        var lw: [1 << 14]WCHAR = undefined;
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
    // Pass 2: parse all fields
    var lw2: [1 << 14]WCHAR = undefined;
    var first2 = true;
    var lpos: usize = 0;
    while (lpos < bytes_read) {
        var le2 = lpos;
        while (le2 < bytes_read and file_buf[le2] != '\n' and file_buf[le2] != '\r') le2 += 1;
        if (le2 > lpos) {
            const chunk2 = file_buf[lpos..le2];
            const wlen2 = std.unicode.utf8ToUtf16Le(&lw2, chunk2) catch {
                lpos = skipLineEndings(file_buf, le2);
                continue;
            };
            var pl2 = trimTrailingWhitespace(lw2[0..wlen2]);
            if (first2 and pl2.len > 0 and pl2[0] == 0xFEFF) pl2 = pl2[1..];
            first2 = false;
            const parsed = parseShimLine(pl2);
            if (parsed == null) {
                lpos = skipLineEndings(file_buf, le2);
                continue;
            }
            const name = parsed.?.name;
            const value = parsed.?.value;

            if (std.mem.eql(WCHAR, name, w("path"))) {
                // Store path unquoted; buildCmdLine will quote as needed
                const unquoted = try expandEnvVarsAndUnquote(allocator, value);
                // Ensure null-terminated
                const null_term = try allocator.alloc(WCHAR, unquoted.len + 1);
                @memcpy(null_term[0..unquoted.len], unquoted);
                null_term[unquoted.len] = 0;
                allocator.free(unquoted);
                info.path = null_term[0..unquoted.len];
            } else if (std.mem.eql(WCHAR, name, w("args"))) {
                // Normalize %~dp0, parse into individual args, then re-encode with proper quoting
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
                // Allocate enough space for %~dp0 replacement
                const max_len = value.len + targetDir.len;
                const cwd_copy = try allocator.alloc(WCHAR, max_len);
                @memcpy(cwd_copy[0..value.len], value);
                const new_len = normalizeArgs(cwd_copy[0..value.len], targetDir);
                const unquoted = try expandEnvVarsAndUnquote(allocator, cwd_copy[0..new_len]);
                allocator.free(cwd_copy);
                // Ensure null-terminated
                const null_term = try allocator.alloc(WCHAR, unquoted.len + 1);
                @memcpy(null_term[0..unquoted.len], unquoted);
                null_term[unquoted.len] = 0;
                allocator.free(unquoted);
                info.cwd = null_term[0..unquoted.len];
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

            // Move to next line
            lpos = skipLineEndings(file_buf, le2);
        }
    }

    return info;
}

/// Ctrl-C / Ctrl-Break handler — swallow the event so the child process handles it.
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

/// Create the child process: set env vars, build command line, optionally elevate, assign to job object.
fn makeProcess(allocator: std.mem.Allocator, info: *const ShimInfo, job_handle: ?HANDLE) !ProcessResult {
    var result = ProcessResult{};

    const path = info.path orelse return result;
    const args = info.args.items;
    const cwd = if (info.cwd) |c| c else null;

    for (info.env_vars.items) |ev| {
        const name_z = try allocator.alloc(WCHAR, ev.name.len + 1);
        defer allocator.free(name_z);
        @memcpy(name_z[0..ev.name.len], ev.name);
        name_z[ev.name.len] = 0;

        const value_z = try allocator.alloc(WCHAR, ev.value.len + 1);
        defer allocator.free(value_z);
        @memcpy(value_z[0..ev.value.len], ev.value);
        value_z[ev.value.len] = 0;

        if (!SetEnvironmentVariableW(name_z[0..ev.name.len :0].ptr, value_z[0..ev.value.len :0].ptr).toBool()) {
            writeError("Shim: Could not set environment variable.\n");
        }
    }

    const cmd = try buildCmdLine(allocator, path, args);
    defer allocator.free(cmd);

    var si: windows.STARTUPINFOW = std.mem.zeroes(windows.STARTUPINFOW);
    si.cb = @sizeOf(windows.STARTUPINFOW);
    GetStartupInfoW(&si);
    ensureStandardHandles(&si);

    const path_z = try allocator.alloc(WCHAR, path.len + 1);
    defer allocator.free(path_z);
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;

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

    if (info.elevate) {
        var sei: SHELLEXECUTEINFOW = std.mem.zeroes(SHELLEXECUTEINFOW);
        sei.cbSize = @sizeOf(SHELLEXECUTEINFOW);
        sei.fMask = SEE_MASK_NOCLOSEPROCESS;
        sei.lpFile = @ptrCast(path_z.ptr);
        sei.lpParameters = if (args.len > 0) @ptrCast(args_z.ptr) else null;
        sei.lpDirectory = if (cwd) |c| @ptrCast(c.ptr) else null;
        sei.lpVerb = w("runas");
        sei.nShow = SW_SHOW;

        if (!ShellExecuteExW(&sei).toBool()) {
            writeError("Shim: Unable to create elevated process.\n");
            return result;
        }
        result.process = sei.hProcess;
        if (job_handle) |jh| {
            if (result.process) |ph| {
                _ = AssignProcessToJobObject(jh, ph);
            }
        }
        _ = SetConsoleCtrlHandler(ctrlHandler, .TRUE);
        return result;
    }

    var pi: windows.PROCESS.INFORMATION = undefined;
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
            var sei: SHELLEXECUTEINFOW = std.mem.zeroes(SHELLEXECUTEINFOW);
            sei.cbSize = @sizeOf(SHELLEXECUTEINFOW);
            sei.fMask = SEE_MASK_NOCLOSEPROCESS;
            sei.lpFile = @ptrCast(path_z.ptr);
            sei.lpParameters = if (args.len > 0) @ptrCast(args_z.ptr) else null;
            sei.lpDirectory = if (cwd) |c| @ptrCast(c.ptr) else null;
            sei.lpVerb = w("runas");
            sei.nShow = SW_SHOW;

            if (!ShellExecuteExW(&sei).toBool()) {
                writeError("Shim: Unable to create elevated process.\n");
                return result;
            }
            result.process = sei.hProcess;
            if (job_handle) |jh| {
                if (result.process) |ph| {
                    _ = AssignProcessToJobObject(jh, ph);
                }
            }
        } else {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Shim: Could not create process (error {}).\n", .{err}) catch "Shim: Could not create process.\n";
            writeError(msg);
            return result;
        }
    }

    _ = SetConsoleCtrlHandler(ctrlHandler, .TRUE);
    return result;
}

/// Custom CRT entry point — bypasses std.start runtime initialization
pub export fn wWinMainCRTStartup() callconv(.winapi) void {
    const code = shimMain() catch 1;
    ExitProcess(code);
}

/// Main logic: parse .shim file, merge user args, create child process, relay exit code.
fn shimMain() !u8 {
    const allocator = std.heap.page_allocator;

    var info = try getShimInfo(allocator);
    defer info.deinit();

    if (info.path == null) {
        writeError("Could not read shim file.\n");
        return 1;
    }

    // Parse user args from runtime command line, append after shim args
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

    // GUI shim: if no user args, detach console; otherwise attach parent console for CLI output
    if (isGuiSubsystem()) {
        const has_args = info.args.items.len > 0;
        if (!has_args) {
            _ = FreeConsole();
        } else {
            _ = AttachConsole(ATTACH_PARENT_PROCESS);
        }
    }

    // Create job object
    const job_handle = CreateJobObjectW(null, null);
    if (job_handle) |jh| {
        var jeli: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std.mem.zeroes(JOBOBJECT_EXTENDED_LIMIT_INFORMATION);
        jeli.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK;
        _ = SetInformationJobObject(jh, JobObjectExtendedLimitInformation, &jeli, @sizeOf(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
    }

    const proc_result = try makeProcess(allocator, &info, job_handle);
    const process_handle = proc_result.process orelse return 1;

    // Wait for process
    _ = WaitForSingleObject(process_handle, INFINITE);

    var exit_code: DWORD = 1;
    _ = GetExitCodeProcess(process_handle, &exit_code);

    return @intCast(exit_code);
}
