// SPDX-License-Identifier: MIT
// Scoop shim - C# implementation

using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;

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

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern IntPtr CreateFileW(
            string lpFileName, uint dwDesiredAccess, uint dwShareMode,
            IntPtr lpSecurityAttributes, uint dwCreationDisposition,
            uint dwFlagsAndAttributes, IntPtr hTemplateFile);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        static extern IntPtr GetModuleHandleW(string? lpModuleName);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern void GetStartupInfoW(out STARTUPINFO lpStartupInfo);

        [DllImport("shell32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern IntPtr CommandLineToArgvW(string lpCmdLine, out int pNumArgs);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern IntPtr LocalFree(IntPtr hMem);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern uint GetFullPathNameW(string lpFileName, uint nBufferLength, StringBuilder lpBuffer, IntPtr lpFilePart);

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

        static string GetModulePath()
        {
            var sb = new StringBuilder(260);
            uint len = GetModuleFileNameW(IntPtr.Zero, sb, sb.Capacity);
            if (len == 0) throw new Win32Exception();
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

        static string NormalizeArgs(string args, string curDir)
        {
            if (string.IsNullOrEmpty(args)) return args;
            int pos = args.IndexOf("%~dp0", StringComparison.Ordinal);
            if (pos < 0) return args;

            string replacement = curDir;
            if (replacement.Length > 0 && replacement[replacement.Length - 1] != '\\' && replacement[replacement.Length - 1] != '/')
                replacement += "\\";

            return args.Remove(pos, 5).Insert(pos, replacement);
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

        /// Parse a raw .shim file line. Returns true if line has a valid key=value pair.
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
            if (si.hStdInput == IntPtr.Zero || si.hStdInput == INVALID_HANDLE_VALUE)
            {
                si.hStdInput = CreateFileW("CONIN$", GENERIC_READ, FILE_SHARE_READ, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
                if (si.hStdInput == INVALID_HANDLE_VALUE) si.hStdInput = IntPtr.Zero;
            }
            if (si.hStdOutput == IntPtr.Zero || si.hStdOutput == INVALID_HANDLE_VALUE)
            {
                si.hStdOutput = CreateFileW("CONOUT$", GENERIC_WRITE, FILE_SHARE_WRITE, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
                if (si.hStdOutput == INVALID_HANDLE_VALUE) si.hStdOutput = IntPtr.Zero;
            }
            if (si.hStdError == IntPtr.Zero || si.hStdError == INVALID_HANDLE_VALUE)
            {
                si.hStdError = CreateFileW("CONOUT$", GENERIC_WRITE, FILE_SHARE_WRITE, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
                if (si.hStdError == INVALID_HANDLE_VALUE) si.hStdError = IntPtr.Zero;
            }
        }

        // --- Config parsing ---

        static ShimInfo ParseShimInfo()
        {
            // Get filename of current executable
            var exePath = GetModulePath();
            var dir = "";
            int sep = Math.Max(exePath.LastIndexOf('\\'), exePath.LastIndexOf('/'));
            if (sep >= 0) dir = exePath.Substring(0, sep);

            // Replace .exe with .shim
            var configPath = exePath.Substring(0, exePath.Length - 4) + ".shim";

            if (!File.Exists(configPath))
            {
                var name = System.IO.Path.GetFileNameWithoutExtension(exePath);
                Console.Error.WriteLine($"Couldn't find {name}.shim in {dir}");
                return new ShimInfo();
            }

            var lines = File.ReadAllLines(configPath);

            // First pass: find path, resolve to absolute, compute targetDir.
            // %~dp0 expands to the directory containing the target executable,
            // resolved relative to the shim's own directory.
            var targetDir = dir;
            foreach (var rawLine in lines)
            {
                if (!TryParseLine(rawLine, out var key, out var value) || key != "path")
                    continue;

                var expanded = ExpandAndUnquote(value!);

                var combined = System.IO.Path.IsPathRooted(expanded)
                    ? expanded
                    : dir + "\\" + expanded;
                var sb = new StringBuilder(260);
                uint len = GetFullPathNameW(combined, (uint)sb.Capacity, sb, IntPtr.Zero);
                if (len == 0) { targetDir = dir; break; }

                var fullPath = sb.ToString(0, (int)len);
                var dirLen = fullPath.LastIndexOf('\\');
                if (dirLen < 0) dirLen = fullPath.LastIndexOf('/');
                if (dirLen < 0) dirLen = (int)len;
                targetDir = fullPath.Substring(0, dirLen + 1);
                break;
            }

            var info = new ShimInfo();

            foreach (var rawLine in lines)
            {
                if (!TryParseLine(rawLine, out var key, out var value)) continue;

                if (key == "path")
                {
                    info.Path = ExpandAndUnquote(value!);
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
                    info.EnvVars[key!] = ExpandAndUnquote(value!);
                }
            }

            return info;
        }
        static int LaunchProcess(ShimInfo info, IntPtr jobHandle)
        {
            if (string.IsNullOrEmpty(info.Path)) return -1;

            foreach (var kv in info.EnvVars)
            {
                try
                {
                    Environment.SetEnvironmentVariable(kv.Key, kv.Value);
                }
                catch (Exception ex)
                {
                    Console.Error.WriteLine($"Shim: Could not set environment variable '{kv.Key}': {ex.Message}");
                }
            }

            string path = info.Path!;

            // Build properly quoted command line from individual arguments
            string cmd = BuildCommandLine(path, info.Args);
            string params_ = string.Join(" ", info.Args.Select(QuoteArg));

            var si = new STARTUPINFO();
            si.cb = Marshal.SizeOf(typeof(STARTUPINFO));
            GetStartupInfoW(out si);

            EnsureStandardHandles(ref si);

            if (info.Elevate)
            {
                return LaunchElevated(path, params_, info.Cwd, jobHandle);
            }

            PROCESS_INFORMATION pi;
            if (CreateProcessW(null, new StringBuilder(cmd), IntPtr.Zero, IntPtr.Zero,
                true, CREATE_SUSPENDED, IntPtr.Zero, info.Cwd,
                ref si, out pi))
            {
                if (jobHandle != IntPtr.Zero)
                    AssignProcessToJobObject(jobHandle, pi.hProcess);

                ResumeThread(pi.hThread);

                SetConsoleCtrlHandler(s_ctrlHandler, true);
                CloseHandle(pi.hThread);

                return WaitAndGetExitCode(pi.hProcess);
            }

            int error = Marshal.GetLastWin32Error();
            if (error == ERROR_ELEVATION_REQUIRED)
            {
                return LaunchElevated(path, params_, info.Cwd, jobHandle);
            }

            Console.Error.WriteLine($"Shim: Could not create process with command '{cmd}'.");
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
                    Console.Error.WriteLine("Shim: Unable to create elevated process.");
                    return 1;
                }

                if (jobHandle != IntPtr.Zero)
                    AssignProcessToJobObject(jobHandle, process.Handle);

                SetConsoleCtrlHandler(s_ctrlHandler, true);

                process.WaitForExit();
                int exitCode = process.ExitCode;
                process.Close();
                return exitCode;
            }
            catch (Win32Exception)
            {
                Console.Error.WriteLine("Shim: Unable to create elevated process.");
                return 1;
            }
        }

        static int WaitAndGetExitCode(IntPtr hProcess)
        {
            WaitForSingleObject(hProcess, INFINITE);

            GetExitCodeProcess(hProcess, out uint exitCode);
            CloseHandle(hProcess);

            return (int)exitCode;
        }

        // --- Main ---

        static int Main(string[] args)
        {
            var info = ParseShimInfo();

            if (string.IsNullOrEmpty(info.Path))
            {
                Console.Error.WriteLine("Could not read shim file.");
                return 1;
            }

            // Append user arguments from runtime argv (skip argv[0])
            string[] runtimeArgs = Environment.GetCommandLineArgs();
            for (int i = 1; i < runtimeArgs.Length; i++)
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

            int exitCode = LaunchProcess(info, jobHandle);

            if (exitCode < 0)
                return 1;

            return exitCode;
        }
    }
}
