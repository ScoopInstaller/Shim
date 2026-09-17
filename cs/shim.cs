// SPDX-License-Identifier: MIT
// Scoop shim - C# implementation

using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace Scoop
{
    public class Program
    {
        const int ERROR_ELEVATION_REQUIRED = 740;

        // --- P/Invoke: Process ---

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct STARTUPINFO
        {
            public int cb;
            public IntPtr lpReserved;
            public IntPtr lpDesktop;
            public IntPtr lpTitle;
            public int dwX, dwY, dwXSize, dwYSize;
            public int dwXCountChars, dwYCountChars, dwFillAttribute;
            public int dwFlags;
            public short wShowWindow;
            public short cbReserved2;
            public IntPtr lpReserved2;
            public IntPtr hStdInput, hStdOutput, hStdError;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct PROCESS_INFORMATION
        {
            public IntPtr hProcess, hThread;
            public int dwProcessId, dwThreadId;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct JOBOBJECT_BASIC_LIMIT_INFORMATION
        {
            public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
            public uint LimitFlags;
            public IntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public IntPtr Affinity;
            public uint PriorityClass, SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct IO_COUNTERS
        {
            public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
            public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
        {
            public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
            public IO_COUNTERS IoInfo;
            public IntPtr ProcessMemoryLimit, JobMemoryLimit;
            public IntPtr PeakProcessMemoryUsed, PeakJobMemoryUsed;
        }

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern bool CreateProcessW(
            string? lpApplicationName, StringBuilder lpCommandLine,
            IntPtr lpProcessAttributes, IntPtr lpThreadAttributes,
            bool bInheritHandles, uint dwCreationFlags,
            IntPtr lpEnvironment, string? lpCurrentDirectory,
            ref STARTUPINFO lpStartupInfo,
            out PROCESS_INFORMATION lpProcessInformation);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        static extern bool CloseHandle(IntPtr hObject);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern uint GetModuleFileNameW(IntPtr hModule, StringBuilder lpFilename, int nSize);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        static extern bool GetExitCodeProcess(IntPtr hProcess, out uint lpExitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern uint ResumeThread(IntPtr hThread);

        // --- P/Invoke: Job Object ---

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern IntPtr CreateJobObjectW(IntPtr lpJobAttributes, string? lpName);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        static extern bool SetInformationJobObject(
            IntPtr hJob, int JobObjectInfoClass,
            ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION lpJobObjectInfo,
            uint cbJobObjectInfoLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        static extern bool AssignProcessToJobObject(IntPtr hJob, IntPtr hProcess);

        // --- P/Invoke: Console ---

        delegate bool HandlerRoutine(uint dwCtrlType);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        static extern bool SetConsoleCtrlHandler(HandlerRoutine handler, [MarshalAs(UnmanagedType.Bool)] bool add);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        static extern bool FreeConsole();

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        static extern bool AttachConsole(int dwProcessId);

        // --- P/Invoke: Handles ---

        [StructLayout(LayoutKind.Sequential)]
        struct SECURITY_ATTRIBUTES
        {
            public int nLength;
            public IntPtr lpSecurityDescriptor;
            public int bInheritHandle;
        }

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern IntPtr CreateFileW(
            string lpFileName, uint dwDesiredAccess, uint dwShareMode,
            ref SECURITY_ATTRIBUTES lpSecurityAttributes, uint dwCreationDisposition,
            uint dwFlagsAndAttributes, IntPtr hTemplateFile);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        static extern IntPtr GetModuleHandleW(string? lpModuleName);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern void GetStartupInfoW(ref STARTUPINFO lpStartupInfo);

        [DllImport("shell32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern IntPtr CommandLineToArgvW(string lpCmdLine, out int pNumArgs);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern IntPtr LocalFree(IntPtr hMem);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern uint GetFullPathNameW(string lpFileName, uint nBufferLength, StringBuilder lpBuffer, IntPtr lpFilePart);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        [return: MarshalAs(UnmanagedType.Bool)]
        static extern bool SetEnvironmentVariableW(string lpName, string lpValue);

        // --- Constants ---

        const uint CREATE_SUSPENDED = 0x00000004;
        const uint INFINITE = 0xFFFFFFFF;
        const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
        const uint JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK = 0x00001000;
        const int JobObjectExtendedLimitInformation = 9;
        const int ATTACH_PARENT_PROCESS = -1;

        const uint GENERIC_READ = 0x80000000;
        const uint GENERIC_WRITE = 0x40000000;
        const uint FILE_SHARE_READ = 0x00000001;
        const uint FILE_SHARE_WRITE = 0x00000002;
        const uint OPEN_EXISTING = 3;
        const uint STARTF_USESTDHANDLES = 0x00000100;

        const ushort IMAGE_DOS_SIGNATURE = 0x5A4D;
        const uint IMAGE_NT_SIGNATURE = 0x00004550;
        const ushort IMAGE_SUBSYSTEM_WINDOWS_GUI = 2;

        static readonly IntPtr INVALID_HANDLE_VALUE = new IntPtr(-1);
        static readonly HandlerRoutine s_ctrlHandler = CtrlHandler;

        static bool CtrlHandler(uint ctrlType)
        {
            switch (ctrlType)
            {
                case 0: // CTRL_C_EVENT
                case 1: // CTRL_BREAK_EVENT
                case 2: // CTRL_CLOSE_EVENT
                case 5: // CTRL_LOGOFF_EVENT
                case 6: // CTRL_SHUTDOWN_EVENT
                    return true;
                default:
                    return false;
            }
        }

        // --- ShimInfo ---

        class ShimInfo
        {
            public string? Path;
            public List<string> Args = new List<string>();
            public string? Cwd;
            public bool Elevate;
            public Dictionary<string, string> EnvVars = new Dictionary<string, string>();
        }

        // --- Helpers ---

        // Win32Exception.Message renders the system error text in the OS language.
        static void ReportShimError(string context, uint error)
        {
            Console.Error.WriteLine($"Shim: {context} (error {error}: {new Win32Exception((int)error).Message}).");
        }

        static string GetModulePath()
        {
            var sb = new StringBuilder(260);
            uint len = GetModuleFileNameW(IntPtr.Zero, sb, sb.Capacity);
            if (len == 0)
            {
                ReportShimError("The filename of the program could not be determined", (uint)Marshal.GetLastWin32Error());
                return null!;
            }
            if (len >= sb.Capacity)
            {
                var truncated = sb.ToString(0, Math.Min((int)len, sb.Length));
                Console.Error.WriteLine($"Shim: The filename of the program is too long to handle: '{truncated}'.");
                return null!;
            }
            return sb.ToString(0, (int)len);
        }

        static bool IsGuiSubsystem()
        {
            try
            {
                var hModule = GetModuleHandleW(null);
                if (hModule == IntPtr.Zero) return false;

                var dosMagic = (ushort)Marshal.ReadInt16(hModule);
                if (dosMagic != IMAGE_DOS_SIGNATURE) return false;

                var peOffset = Marshal.ReadInt32(hModule, 0x3C);
                var peBase = hModule + peOffset;

                var peSignature = (uint)Marshal.ReadInt32(peBase);
                if (peSignature != IMAGE_NT_SIGNATURE) return false;

                var subsystem = (ushort)Marshal.ReadInt16(peBase, 0x5C);
                return subsystem == IMAGE_SUBSYSTEM_WINDOWS_GUI;
            }
            catch
            {
                return false;
            }
        }

        static bool ParseBool(string value)
        {
            if (string.IsNullOrEmpty(value)) return false;
            var lower = value.Trim().ToLowerInvariant();
            return lower == "true" || lower == "1" || lower == "yes";
        }

        static string ExpandEnvVars(string input)
        {
            if (string.IsNullOrEmpty(input)) return input;
            return Environment.ExpandEnvironmentVariables(input);
        }

        static string ExpandAndUnquote(string value)
        {
            string expanded = ExpandEnvVars(value);
            if (expanded.Length >= 2 && expanded[0] == '"' && expanded[expanded.Length - 1] == '"')
                expanded = expanded.Substring(1, expanded.Length - 2);
            return expanded;
        }

        static string ResolveAgainstBase(string path, string baseDir)
        {
            // Rooted only when the drive is absolute ("C:\...") or a leading
            // separator. Path.IsPathRooted would wrongly accept drive-relative
            // forms like "C:app".
            bool rooted = (path.Length >= 2 && path[1] == ':')
                || (path.Length > 0 && (path[0] == '\\' || path[0] == '/'));

            string toResolve = rooted ? path : baseDir + "\\" + path;

            int cap = 260;
            for (; ; )
            {
                var sb = new StringBuilder(cap);
                uint len = GetFullPathNameW(toResolve, (uint)sb.Capacity, sb, IntPtr.Zero);
                if (len == 0)
                    return toResolve + "\\"; // target-based fallback on failure
                if (len >= sb.Capacity)
                {
                    cap = (int)len + 1; // required size returned on overflow
                    continue;
                }

                var fullPath = sb.ToString(0, (int)len);
                int dirLen = fullPath.LastIndexOf('\\');
                if (dirLen < 0) dirLen = fullPath.LastIndexOf('/');
                if (dirLen < 0) return fullPath + "\\";
                if (dirLen + 1 == fullPath.Length) return fullPath;
                return fullPath.Substring(0, dirLen + 1);
            }
        }

        static string NormalizeArgs(string args, string curDir)
        {
            if (string.IsNullOrEmpty(args)) return args;

            string replacement = curDir;
            if (replacement.Length > 0 && replacement[replacement.Length - 1] != '\\' && replacement[replacement.Length - 1] != '/')
                replacement += "\\";

            int pos = 0;
            while ((pos = args.IndexOf("%~dp0", pos, StringComparison.Ordinal)) >= 0)
            {
                args = args.Remove(pos, 5).Insert(pos, replacement);
                pos += replacement.Length;
            }
            return args;
        }

        static string QuoteArg(string arg)
        {
            if (arg.Length == 0) return "\"\"";

            bool needsQuoting = false;
            foreach (char c in arg)
            {
                if (c == ' ' || c == '\t' || c == '"')
                {
                    needsQuoting = true;
                    break;
                }
            }

            if (!needsQuoting) return arg;

            var result = new StringBuilder(arg.Length + 8);
            result.Append('"');

            int i = 0;
            while (i < arg.Length)
            {
                if (arg[i] == '\\')
                {
                    int bsStart = i;
                    while (i < arg.Length && arg[i] == '\\') i++;

                    if (i == arg.Length)
                    {
                        result.Append('\\', (i - bsStart) * 2);
                    }
                    else if (arg[i] == '"')
                    {
                        result.Append('\\', (i - bsStart) * 2 + 1);
                        result.Append('"');
                        i++;
                    }
                    else
                    {
                        result.Append('\\', i - bsStart);
                    }
                }
                else if (arg[i] == '"')
                {
                    result.Append("\\\"");
                    i++;
                }
                else
                {
                    result.Append(arg[i]);
                    i++;
                }
            }

            result.Append('"');
            return result.ToString();
        }

        static string BuildCommandLine(string exePath, List<string> args)
        {
            var cmd = new StringBuilder();
            cmd.Append(QuoteArg(exePath));
            foreach (var arg in args)
            {
                cmd.Append(' ');
                cmd.Append(QuoteArg(arg));
            }
            return cmd.ToString();
        }

        // No exe prefix - elevated launch takes parameters separately from the file.
        static string BuildParams(List<string> args)
        {
            var sb = new StringBuilder();
            for (int i = 0; i < args.Count; i++)
            {
                if (i > 0) sb.Append(' ');
                sb.Append(QuoteArg(args[i]));
            }
            return sb.ToString();
        }

        static List<string> ParseArgsFromCmdLine(string cmdLine)
        {
            var result = new List<string>();
            if (string.IsNullOrEmpty(cmdLine)) return result;

            IntPtr argvPtr = CommandLineToArgvW(cmdLine, out int argc);
            if (argvPtr == IntPtr.Zero) return result;

            try
            {
                for (int i = 0; i < argc; i++)
                {
                    IntPtr argPtr = Marshal.ReadIntPtr(argvPtr, i * IntPtr.Size);
                    result.Add(Marshal.PtrToStringUni(argPtr) ?? "");
                }
            }
            finally
            {
                LocalFree(argvPtr);
            }

            return result;
        }

        static bool TryParseLine(string rawLine, out string? key, out string? value)
        {
            key = null; value = null;
            var line = rawLine.TrimEnd();

            var trimmed = line.TrimStart();
            if (trimmed.Length == 0 || trimmed[0] == '#' || trimmed[0] == ';' || trimmed.StartsWith("//"))
                return false;

            int sepPos = line.IndexOf(" = ", StringComparison.Ordinal);
            if (sepPos < 0) return false;

            key = line.Substring(0, sepPos).Trim();
            if (string.IsNullOrEmpty(key)) { key = null; return false; }

            value = line.Substring(sepPos + 3).TrimStart();
            return true;
        }

        static void EnsureStandardHandles(ref STARTUPINFO si)
        {
            // GUI launches have no console; attach to the parent console so the
            // CON*$ opens below succeed. Failure is fine (no parent console).
            if (IsGuiSubsystem())
                AttachConsole(ATTACH_PARENT_PROCESS);

            var sa = new SECURITY_ATTRIBUTES();
            sa.nLength = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES));
            sa.lpSecurityDescriptor = IntPtr.Zero;
            sa.bInheritHandle = 1;

            if (si.hStdInput == IntPtr.Zero || si.hStdInput == INVALID_HANDLE_VALUE)
            {
                si.hStdInput = CreateFileW("CONIN$", GENERIC_READ, FILE_SHARE_READ, ref sa, OPEN_EXISTING, 0, IntPtr.Zero);
                if (si.hStdInput == INVALID_HANDLE_VALUE) si.hStdInput = IntPtr.Zero;
            }
            if (si.hStdOutput == IntPtr.Zero || si.hStdOutput == INVALID_HANDLE_VALUE)
            {
                si.hStdOutput = CreateFileW("CONOUT$", GENERIC_WRITE, FILE_SHARE_WRITE, ref sa, OPEN_EXISTING, 0, IntPtr.Zero);
                if (si.hStdOutput == INVALID_HANDLE_VALUE) si.hStdOutput = IntPtr.Zero;
            }
            if (si.hStdError == IntPtr.Zero || si.hStdError == INVALID_HANDLE_VALUE)
            {
                si.hStdError = CreateFileW("CONOUT$", GENERIC_WRITE, FILE_SHARE_WRITE, ref sa, OPEN_EXISTING, 0, IntPtr.Zero);
                if (si.hStdError == INVALID_HANDLE_VALUE) si.hStdError = IntPtr.Zero;
            }

            si.dwFlags |= (int)STARTF_USESTDHANDLES;
            // Handles live for the process lifetime - do not close.
        }

        // --- Config parsing ---

        static ShimInfo ParseShimInfo()
        {
            var exePath = GetModulePath();
            if (string.IsNullOrEmpty(exePath)) return new ShimInfo();
            var dir = "";
            int sep = Math.Max(exePath.LastIndexOf('\\'), exePath.LastIndexOf('/'));
            if (sep >= 0) dir = exePath.Substring(0, sep);

            int dot = exePath.LastIndexOf('.');
            var configPath = (dot >= 0 ? exePath.Substring(0, dot) : exePath) + ".shim";

            string[] lines;
            try
            {
                lines = File.ReadAllLines(configPath);
            }
            catch (Exception ex)
            {
                uint err = (uint)(ex.HResult & 0xFFFF);
                ReportShimError($"Cannot open shim file for read: '{configPath}'", err);
                return new ShimInfo();
            }

            // %~dp0 means the *target* exe directory, not the shim's own. Pass 1 resolves
            // path to absolute so pass 2 can expand %~dp0 against the right base.
            var targetDir = dir;
            foreach (var rawLine in lines)
            {
                if (!TryParseLine(rawLine, out var key, out var value) || key != "path")
                    continue;

                // %~dp0 in the path field refers to the shim's own dir.
                var expanded = ExpandAndUnquote(NormalizeArgs(value!, dir));
                targetDir = ResolveAgainstBase(expanded, dir);
                break;
            }

            var info = new ShimInfo();

            foreach (var rawLine in lines)
            {
                if (!TryParseLine(rawLine, out var key, out var value)) continue;

                if (key == "path")
                {
                    // First path wins; %~dp0 here means the shim's own dir.
                    if (info.Path == null)
                    {
                        var pv = ExpandAndUnquote(NormalizeArgs(value!, dir));
                        if (!string.IsNullOrEmpty(pv))
                            info.Path = pv;
                    }
                }
                else if (key == "args")
                {
                    string normalized = NormalizeArgs(value!, targetDir);
                    if (!string.IsNullOrEmpty(normalized))
                        info.Args = ParseArgsFromCmdLine(normalized);
                }
                else if (key == "cwd" || key == "workdir")
                {
                    info.Cwd = ExpandAndUnquote(NormalizeArgs(value!, targetDir));
                }
                else if (key == "elevate" || key == "runas")
                {
                    info.Elevate = ParseBool(value!);
                }
                else
                {
                    info.EnvVars[key!] = ExpandAndUnquote(NormalizeArgs(value!, targetDir));
                }
            }

            if (info.Path == null)
                Console.Error.WriteLine($"Shim: 'path' not found in shim file '{configPath}'.");

            return info;
        }
        static int LaunchProcess(ShimInfo info, IntPtr jobHandle)
        {
            if (string.IsNullOrEmpty(info.Path)) return -1;

            foreach (var kv in info.EnvVars)
            {
                if (!SetEnvironmentVariableW(kv.Key, kv.Value))
                {
                    ReportShimError($"Could not set environment variable '{kv.Key}'", (uint)Marshal.GetLastWin32Error());
                }
            }

            string path = info.Path!;

            string cmd = BuildCommandLine(path, info.Args);

            var si = new STARTUPINFO();
            si.cb = Marshal.SizeOf(typeof(STARTUPINFO));
            GetStartupInfoW(ref si);

            EnsureStandardHandles(ref si);

            if (info.Elevate)
            {
                return LaunchElevated(path, BuildParams(info.Args), info.Cwd, jobHandle);
            }

            PROCESS_INFORMATION pi;
            if (CreateProcessW(null, new StringBuilder(cmd), IntPtr.Zero, IntPtr.Zero,
                true, CREATE_SUSPENDED, IntPtr.Zero, info.Cwd,
                ref si, out pi))
            {
                if (jobHandle != IntPtr.Zero)
                    AssignProcessToJobObject(jobHandle, pi.hProcess);

                ResumeThread(pi.hThread);

                CloseHandle(pi.hThread);

                return WaitAndGetExitCode(pi.hProcess);
            }

            int error = Marshal.GetLastWin32Error();
            if (error == ERROR_ELEVATION_REQUIRED)
            {
                return LaunchElevated(path, BuildParams(info.Args), info.Cwd, jobHandle);
            }

            ReportShimError($"Could not create process with command '{cmd}'", (uint)error);
            return 1;
        }

        static int LaunchElevated(string path, string params_, string? cwd, IntPtr jobHandle)
        {
            var psi = new ProcessStartInfo
            {
                FileName = path,
                Arguments = params_,
                UseShellExecute = true,
                Verb = "runas"
            };

            if (!string.IsNullOrEmpty(cwd))
                psi.WorkingDirectory = cwd;

            try
            {
                var process = Process.Start(psi);
                if (process is null)
                {
                    // Process.Start returned null without a reliable last-error;
                    // report a fixed code like cpp (ERROR_INVALID_FUNCTION = 1).
                    ReportShimError("Unable to create elevated process", 1);
                    return 1;
                }

                if (jobHandle != IntPtr.Zero)
                    AssignProcessToJobObject(jobHandle, process.Handle);

                process.WaitForExit();
                int exitCode = process.ExitCode;
                process.Close();
                return exitCode;
            }
            catch (Win32Exception ex)
            {
                ReportShimError("Unable to create elevated process", (uint)ex.NativeErrorCode);
                return 1;
            }
        }

        static int WaitAndGetExitCode(IntPtr hProcess)
        {
            WaitForSingleObject(hProcess, INFINITE);

            // Init to 1 so a failed query yields 1, not 0 (mirrors cpp).
            uint exitCode = 1;
            GetExitCodeProcess(hProcess, out exitCode);
            CloseHandle(hProcess);

            return (int)exitCode;
        }

        // --- Main ---

        static int Main(string[] args)
        {
            var info = ParseShimInfo();

            if (string.IsNullOrEmpty(info.Path))
            {
                return 1;
            }

            // CommandLineToArgvW splits the raw command line; argv[0] is the shim itself.
            var runtimeArgs = ParseArgsFromCmdLine(Environment.CommandLine);
            for (int i = 1; i < runtimeArgs.Count; i++)
            {
                info.Args.Add(runtimeArgs[i]);
            }

            if (IsGuiSubsystem())
            {
                if (args.Length == 0 && info.Args.Count == 0)
                {
                    FreeConsole();
                }
                else
                {
                    AttachConsole(ATTACH_PARENT_PROCESS);
                }
            }

            IntPtr jobHandle = CreateJobObjectW(IntPtr.Zero, null);
            if (jobHandle != IntPtr.Zero && jobHandle != INVALID_HANDLE_VALUE)
            {
                var jeli = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
                jeli.BasicLimitInformation.LimitFlags =
                    JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK;
                SetInformationJobObject(jobHandle, JobObjectExtendedLimitInformation,
                    ref jeli, (uint)Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION)));
            }

            // Before spawn: a Ctrl event in the gap would kill the shim and
            // KILL_ON_JOB_CLOSE would take the child down with it.
            SetConsoleCtrlHandler(s_ctrlHandler, true);

            int exitCode = LaunchProcess(info, jobHandle);

            // Return the raw exit code (>= 0x80000000 must survive the int round-trip).
            return exitCode;
        }
    }
}
