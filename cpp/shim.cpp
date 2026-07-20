// SPDX-License-Identifier: MIT
// Scoop shim - C++20 implementation

#ifdef _MSC_VER
#include <corecrt_wstdio.h>
#endif
#pragma comment(lib, "SHELL32.LIB")

#include <windows.h>
#include <shellapi.h>

#include <array>
#include <cstring>
#include <cwchar>
#include <cwctype>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#ifndef ERROR_ELEVATION_REQUIRED
#define ERROR_ELEVATION_REQUIRED 740
#endif

using namespace std::string_view_literals;

// Console control handler - must be a regular function with WINAPI calling convention
BOOL WINAPI CtrlHandler(DWORD ctrlType) noexcept
{
    switch (ctrlType)
    {
    case CTRL_C_EVENT:
    case CTRL_BREAK_EVENT:
    case CTRL_CLOSE_EVENT:
    case CTRL_LOGOFF_EVENT:
    case CTRL_SHUTDOWN_EVENT:
        return TRUE;
    default:
        return FALSE;
    }
}

namespace {

// Compile-time constants
constexpr std::wstring_view c_dirPlaceholder = L"%~dp0"sv;
constexpr std::wstring_view c_pathPrefix = L"path"sv;
constexpr std::wstring_view c_argsPrefix = L"args"sv;
constexpr std::wstring_view c_cwdPrefix = L"cwd"sv;
constexpr std::wstring_view c_workdirPrefix = L"workdir"sv;
constexpr std::wstring_view c_elevatePrefix = L"elevate"sv;
constexpr std::wstring_view c_runasPrefix = L"runas"sv;
constexpr std::wstring_view c_separator = L" = "sv;

// Environment variable storage
using EnvVarList = std::vector<std::pair<std::wstring, std::wstring>>;

// RAII handle wrapper with minimal overhead
struct HandleDeleter
{
    using pointer = HANDLE;
    void operator()(HANDLE h) const noexcept
    {
        if (h && h != INVALID_HANDLE_VALUE)
        {
            CloseHandle(h);
        }
    }
};
using UniqueHandle = std::unique_ptr<HANDLE, HandleDeleter>;

// RAII file wrapper
struct FileDeleter
{
    void operator()(FILE* fp) const noexcept
    {
        if (fp)
        {
            fclose(fp);
        }
    }
};
using UniqueFile = std::unique_ptr<FILE, FileDeleter>;

struct ShimInfo
{
    std::optional<std::wstring> path;
    std::vector<std::wstring> args;
    std::optional<std::wstring> cwd;
    EnvVarList envVars;
    bool elevate = false;
};

struct ProcessResult
{
    UniqueHandle process;
    UniqueHandle thread;
};

// Fast error output - avoids stdio buffering overhead
inline void WriteError(const char* msg) noexcept
{
    HANDLE hErr = GetStdHandle(STD_ERROR_HANDLE);
    if (hErr != INVALID_HANDLE_VALUE)
    {
        DWORD written;
        WriteFile(hErr, msg, static_cast<DWORD>(strlen(msg)), &written, nullptr);
    }
}

inline void WriteErrorW(const wchar_t* msg) noexcept
{
    HANDLE hErr = GetStdHandle(STD_ERROR_HANDLE);
    if (hErr != INVALID_HANDLE_VALUE)
    {
        DWORD written;
        WriteConsoleW(hErr, msg, static_cast<DWORD>(wcslen(msg)), &written, nullptr);
    }
}

// Ensure standard handles are valid; open fallback console handles if needed
inline void EnsureStandardHandles(STARTUPINFOW& si) noexcept
{
    // Check stdin
    if (si.hStdInput == nullptr || si.hStdInput == INVALID_HANDLE_VALUE)
    {
        si.hStdInput = CreateFileW(L"CONIN$", GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, 0, nullptr);
        if (si.hStdInput == INVALID_HANDLE_VALUE)
        {
            si.hStdInput = nullptr;
        }
    }

    // Check stdout
    if (si.hStdOutput == nullptr || si.hStdOutput == INVALID_HANDLE_VALUE)
    {
        si.hStdOutput = CreateFileW(L"CONOUT$", GENERIC_WRITE, FILE_SHARE_WRITE, nullptr, OPEN_EXISTING, 0, nullptr);
        if (si.hStdOutput == INVALID_HANDLE_VALUE)
        {
            si.hStdOutput = nullptr;
        }
    }

    // Check stderr
    if (si.hStdError == nullptr || si.hStdError == INVALID_HANDLE_VALUE)
    {
        si.hStdError = CreateFileW(L"CONOUT$", GENERIC_WRITE, FILE_SHARE_WRITE, nullptr, OPEN_EXISTING, 0, nullptr);
        if (si.hStdError == INVALID_HANDLE_VALUE)
        {
            si.hStdError = nullptr;
        }
    }
}

[[nodiscard]] constexpr std::wstring_view GetDirectory(std::wstring_view exe) noexcept
{
    if (auto pos = exe.find_last_of(L"\\/"); pos != std::wstring_view::npos)
    {
        return exe.substr(0, pos);
    }
    return exe;
}

// Trim trailing whitespace (spaces, tabs, CR, LF)
[[nodiscard]] std::wstring_view TrimTrailingWhitespace(std::wstring_view sv) noexcept
{
    while (!sv.empty() && iswspace(sv.back()))
        sv.remove_suffix(1);
    return sv;
}

void NormalizeArgsInPlace(std::wstring& args, std::wstring_view curDir)
{
    if (auto pos = args.find(c_dirPlaceholder); pos != std::wstring::npos) [[unlikely]]
    {
        // %~dp0 in batch always includes trailing backslash
        std::wstring replacement(curDir);
        if (replacement.empty() || (replacement.back() != L'\\' && replacement.back() != L'/'))
        {
            replacement += L'\\';
        }
        args.replace(pos, c_dirPlaceholder.size(), replacement);
    }
}

// Quote a single argument per Windows CreateProcessW quoting rules:
// - Arguments containing spaces, tabs, quotes, or empty are wrapped in double quotes
// - Backslashes before a quote character are doubled
// - Trailing backslashes inside a quoted argument are doubled
[[nodiscard]] std::wstring QuoteArg(std::wstring_view arg)
{
    if (arg.empty())
        return L"\"\"";

    bool needsQuoting = false;
    for (wchar_t c : arg)
    {
        if (c == L' ' || c == L'\t' || c == L'"')
        {
            needsQuoting = true;
            break;
        }
    }

    if (!needsQuoting)
        return std::wstring(arg);

    std::wstring result;
    result.reserve(arg.size() + 8);
    result += L'"';

    size_t i = 0;
    while (i < arg.size())
    {
        if (arg[i] == L'\\')
        {
            size_t bsStart = i;
            while (i < arg.size() && arg[i] == L'\\')
                ++i;

            if (i == arg.size())
            {
                // Trailing backslashes: double them (before closing quote)
                result.append((i - bsStart) * 2, L'\\');
            }
            else if (arg[i] == L'"')
            {
                // Backslashes before quote: double + 1 to escape the quote
                result.append((i - bsStart) * 2 + 1, L'\\');
                result += L'"';
                ++i;
            }
            else
            {
                // Backslashes not before quote: literal
                result.append(i - bsStart, L'\\');
            }
        }
        else if (arg[i] == L'"')
        {
            // Lone quote: escape with backslash
            result += L"\\\"";
            ++i;
        }
        else
        {
            result += arg[i];
            ++i;
        }
    }

    result += L'"';
    return result;
}

// Build a properly quoted command line from individual arguments
[[nodiscard]] std::wstring BuildCommandLine(const std::wstring& exePath, const std::vector<std::wstring>& args)
{
    std::wstring cmd = QuoteArg(exePath);
    for (const auto& arg : args)
    {
        cmd += L' ';
        cmd += QuoteArg(arg);
    }
    return cmd;
}

// Build a quoted parameter string from arguments (no exe prefix, for ShellExecuteExW)
[[nodiscard]] std::wstring BuildParams(const std::vector<std::wstring>& args)
{
    std::wstring params;
    for (size_t i = 0; i < args.size(); ++i)
    {
        if (i > 0)
            params += L' ';
        params += QuoteArg(args[i]);
    }
    return params;
}

// Check if current executable is a GUI subsystem binary
[[nodiscard]] bool IsGuiSubsystem() noexcept
{
    HMODULE hModule = GetModuleHandleW(nullptr);
    if (!hModule) [[unlikely]]
    {
        return false;
    }

    const auto* dosHeader = reinterpret_cast<const IMAGE_DOS_HEADER*>(hModule);
    if (dosHeader->e_magic != IMAGE_DOS_SIGNATURE) [[unlikely]]
    {
        return false;
    }

    const auto* ntHeaders = reinterpret_cast<const IMAGE_NT_HEADERS*>(reinterpret_cast<const BYTE*>(hModule) + dosHeader->e_lfanew);
    if (ntHeaders->Signature != IMAGE_NT_SIGNATURE) [[unlikely]]
    {
        return false;
    }

    return ntHeaders->OptionalHeader.Subsystem == IMAGE_SUBSYSTEM_WINDOWS_GUI;
}

// Parse boolean-like value: "true", "1", "yes" -> true
[[nodiscard]] bool ParseBool(std::wstring_view value) noexcept
{
    // _wcsnicmp compares exactly N chars — safe on non-null-terminated views
    return (value.size() == 4 && _wcsnicmp(value.data(), L"true", 4) == 0) || (value.size() == 1 && value[0] == L'1') ||
           (value.size() == 3 && _wcsnicmp(value.data(), L"yes", 3) == 0);
}

// Expand %ENV_VAR% references using Windows native API
[[nodiscard]] std::wstring ExpandEnvVars(std::wstring_view input)
{
    if (input.empty()) [[unlikely]]
        return {};

    // ExpandEnvironmentStringsW requires null-terminated input
    std::wstring inputStr(input);

    // First call: get required buffer size (includes null terminator)
    DWORD required = ExpandEnvironmentStringsW(inputStr.c_str(), nullptr, 0);
    if (required == 0) [[unlikely]]
        return inputStr;

    // Second call: expand into buffer
    std::wstring result(required - 1, L'\0');
    DWORD actual = ExpandEnvironmentStringsW(inputStr.c_str(), result.data(), required);
    if (actual == 0 || actual > required) [[unlikely]]
        return inputStr;

    result.resize(actual - 1);
    return result;
}

// Combine ExpandEnvVars with quote stripping.
// Shims use quotes around values as structural markers (not content),
// so stripping them after expansion prevents double-quoting in BuildCommandLine.
[[nodiscard]] std::wstring ExpandAndUnquote(std::wstring_view value)
{
    std::wstring expanded = ExpandEnvVars(value);
    if (expanded.size() >= 2 && expanded.front() == L'"' && expanded.back() == L'"')
    {
        expanded = expanded.substr(1, expanded.size() - 2);
    }
    return expanded;
}

// Resolve a path against a base directory, returning the **directory** portion
// of the absolute form (with trailing backslash).
[[nodiscard]] std::wstring ResolveAgainstBase(std::wstring_view path, std::wstring_view baseDir)
{
    std::wstring toResolve;
    if ((path.size() >= 2 && path[1] == L':') || (!path.empty() && path[0] == L'\\'))
    {
        toResolve = path;
    }
    else
    {
        toResolve.reserve(baseDir.size() + 1 + path.size());
        toResolve.append(baseDir);
        toResolve.push_back(L'\\');
        toResolve.append(path);
    }

    std::array<wchar_t, MAX_PATH + 2> resolved {};
    wchar_t* filePart = nullptr;
    DWORD len = GetFullPathNameW(toResolve.c_str(), MAX_PATH, resolved.data(), &filePart);
    if (len == 0 || len >= MAX_PATH) [[unlikely]]
    {
        toResolve.push_back(L'\\');
        return toResolve;
    }

    size_t dirLen = (filePart != nullptr) ? static_cast<size_t>(filePart - resolved.data()) : len;

    // Ensure trailing backslash
    if (dirLen > 0 && (resolved[dirLen - 1] == L'\\' || resolved[dirLen - 1] == L'/'))
        return std::wstring(resolved.data(), dirLen);

    return std::wstring(resolved.data(), dirLen) + L'\\';
}

// Parse a trimmed .shim line into (name, value) pair.
// Returns nullopt for empty lines, comments, or lines without " = " separator.
[[nodiscard]] std::optional<std::pair<std::wstring_view, std::wstring_view>> ParseShimLine(std::wstring_view line) noexcept
{
    // Skip leading whitespace (any Unicode whitespace, not just ASCII)
    auto skipWS = [](std::wstring_view s, size_t start = 0) -> size_t {
        while (start < s.size() && iswspace(s[start]))
            ++start;
        return start;
    };
    auto rskipWS = [](std::wstring_view s) -> size_t {
        size_t i = s.size();
        while (i > 0 && iswspace(s[i - 1]))
            --i;
        return i;
    };

    // Skip comments
    auto first = skipWS(line);
    if (first >= line.size() || line[first] == L'#' || line[first] == L';')
        return std::nullopt;
    if (line.substr(first).starts_with(L"//"))
        return std::nullopt;

    auto sepPos = line.find(c_separator);
    if (sepPos == std::wstring_view::npos)
        return std::nullopt;

    const auto nameRaw = line.substr(0, sepPos);
    const auto valueRaw = line.substr(sepPos + c_separator.size());

    auto nameStart = skipWS(nameRaw);
    auto nameEnd = rskipWS(nameRaw);
    if (nameStart >= nameEnd)
        return std::nullopt;
    auto name = nameRaw.substr(nameStart, nameEnd - nameStart);
    if (name.empty())
        return std::nullopt;

    auto valueStart = skipWS(valueRaw);
    auto value = (valueStart >= valueRaw.size()) ? L""sv : valueRaw.substr(valueStart);

    return std::pair {name, value};
}

[[nodiscard]] ShimInfo GetShimInfo()
{
    // Get filename of current executable
    std::array<wchar_t, MAX_PATH + 2> filename {};
    const auto filenameSize = GetModuleFileNameW(nullptr, filename.data(), MAX_PATH);

    if (filenameSize >= MAX_PATH) [[unlikely]]
    {
        WriteError("Shim: The filename of the program is too long to handle.\n");
        return {};
    }

    // Replace .exe with .shim
    std::wmemcpy(filename.data() + filenameSize - 3, L"shim", 4);
    filename[filenameSize + 1] = L'\0';

    FILE* fp = nullptr;
    if (_wfopen_s(&fp, filename.data(), L"r,ccs=UTF-8") != 0) [[unlikely]]
    {
        WriteError("Cannot open shim file for read.\n");
        return {};
    }
    UniqueFile shimFile(fp);

    // Read all lines into memory (shim files are small, typically < 20 lines)
    std::array<wchar_t, 1 << 14> linebuf {};
    std::vector<std::wstring> allLines;
    while (std::fgetws(linebuf.data(), static_cast<int>(linebuf.size()), shimFile.get()))
    {
        allLines.emplace_back(linebuf.data());
    }

    const std::wstring_view curDir = GetDirectory({filename.data(), filenameSize});

    // First pass: find path, resolve to absolute, compute targetDir.
    // %~dp0 expands to the directory containing the target executable,
    // resolved relative to the shim's own directory.
    std::wstring targetDir {curDir};
    for (const auto& rawLine : allLines)
    {
        auto line = TrimTrailingWhitespace(rawLine);
        auto parsed = ParseShimLine(line);
        if (!parsed || parsed->first != c_pathPrefix)
            continue;

        std::wstring expanded = ExpandAndUnquote(parsed->second);
        targetDir = ResolveAgainstBase(expanded, curDir);
        break;
    }

    // Second pass: parse all fields with targetDir for %~dp0
    ShimInfo info;
    for (const auto& rawLine : allLines)
    {
        auto line = TrimTrailingWhitespace(rawLine);
        auto parsed = ParseShimLine(line);
        if (!parsed)
            continue;

        const auto& [name, value] = *parsed;

        if (name == c_pathPrefix)
        {
            info.path = ExpandAndUnquote(value);
        }
        else if (name == c_argsPrefix)
        {
            std::wstring argsStr(value);
            NormalizeArgsInPlace(argsStr, targetDir);

            if (!argsStr.empty())
            {
                int shimArgc = 0;
                LPWSTR* shimArgv = CommandLineToArgvW(argsStr.c_str(), &shimArgc);
                if (shimArgv)
                {
                    for (int i = 0; i < shimArgc; ++i)
                    {
                        info.args.emplace_back(shimArgv[i]);
                    }
                    LocalFree(shimArgv);
                }
            }
        }
        else if (name == c_cwdPrefix || name == c_workdirPrefix)
        {
            std::wstring cwdVal(value);
            NormalizeArgsInPlace(cwdVal, targetDir);
            info.cwd = ExpandAndUnquote(cwdVal);
        }
        else if (name == c_elevatePrefix || name == c_runasPrefix)
        {
            info.elevate = ParseBool(value);
        }
        else
        {
            info.envVars.emplace_back(std::wstring(name), ExpandAndUnquote(value));
        }
    }

    return info;
}

[[nodiscard]] ProcessResult LaunchElevated(const std::wstring& path, const std::wstring& params, const wchar_t* cwd, HANDLE jobHandle) noexcept
{
    ProcessResult result;

    SHELLEXECUTEINFOW sei {};
    sei.cbSize = sizeof(sei);
    sei.fMask = SEE_MASK_NOCLOSEPROCESS;
    sei.lpFile = path.c_str();
    sei.lpParameters = params.empty() ? nullptr : params.c_str();
    sei.lpDirectory = cwd;
    sei.lpVerb = L"runas";
    sei.nShow = SW_SHOW;

    if (!ShellExecuteExW(&sei))
    {
        WriteError("Shim: Unable to create elevated process.\n");
        return result;
    }

    result.process.reset(sei.hProcess);
    if (jobHandle && result.process)
        AssignProcessToJobObject(jobHandle, result.process.get());

    SetConsoleCtrlHandler(CtrlHandler, TRUE);
    return result;
}

[[nodiscard]] ProcessResult MakeProcess(const ShimInfo& info, HANDLE jobHandle)
{
    ProcessResult result;

    if (!info.path) [[unlikely]]
        return result;

    // Set environment variables before creating process
    for (const auto& [name, value] : info.envVars)
    {
        if (_wputenv_s(name.c_str(), value.c_str()) != 0) [[unlikely]]
        {
            WriteError("Shim: Could not set environment variable '");
            WriteErrorW(name.c_str());
            WriteError("'.\n");
        }
    }

    const auto& path = *info.path;
    const auto* cwd = info.cwd ? info.cwd->c_str() : nullptr;
    std::wstring cmd = BuildCommandLine(path, info.args);
    std::wstring params = BuildParams(info.args);

    // Explicit elevation
    if (info.elevate) [[unlikely]]
        return LaunchElevated(path, params, cwd, jobHandle);

    STARTUPINFOW si {};
    si.cb = sizeof(si);
    GetStartupInfoW(&si);
    EnsureStandardHandles(si);

    PROCESS_INFORMATION pi {};

    if (CreateProcessW(nullptr, cmd.data(), nullptr, nullptr, TRUE, CREATE_SUSPENDED, nullptr, cwd, &si, &pi)) [[likely]]
    {
        result.thread.reset(pi.hThread);
        result.process.reset(pi.hProcess);

        if (jobHandle)
            AssignProcessToJobObject(jobHandle, pi.hProcess);

        ResumeThread(result.thread.get());
    }
    else
    {
        const DWORD err = GetLastError();
        if (err == ERROR_ELEVATION_REQUIRED)
            return LaunchElevated(path, params, cwd, jobHandle);

        WriteError("Shim: Could not create process with command '");
        WriteErrorW(cmd.c_str());
        WriteError("'.\n");
        return result;
    }

    SetConsoleCtrlHandler(CtrlHandler, TRUE);

    return result;
}

} // anonymous namespace

int wmain(int argc, wchar_t* argv[])
{
    auto info = GetShimInfo();

    if (!info.path) [[unlikely]]
    {
        WriteError("Could not read shim file.\n");
        return 1;
    }

    // Parse user arguments from runtime argv using CommandLineToArgvW
    {
        int userArgc = 0;
        LPWSTR* userArgv = CommandLineToArgvW(GetCommandLineW(), &userArgc);
        if (userArgv)
        {
            // Skip argv[0] (the executable name)
            for (int i = 1; i < userArgc; ++i)
            {
                info.args.emplace_back(userArgv[i]);
            }
            LocalFree(userArgv);
        }
    }

    // GUI shim: handle console attach/detach based on user args
    // Console shim: always use console path (no action needed)
    if (IsGuiSubsystem())
    {
        if (argc <= 1 && info.args.empty())
        {
            // No user args: GUI fast path, no console flash
            FreeConsole();
        }
        else
        {
            // User args present: attach to parent console for CLI output
            AttachConsole(ATTACH_PARENT_PROCESS);
        }
    }

    // Create job object to ensure child termination with parent
    UniqueHandle jobHandle(CreateJobObjectW(nullptr, nullptr));
    if (jobHandle) [[likely]]
    {
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION jeli {};
        jeli.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK;
        SetInformationJobObject(jobHandle.get(), JobObjectExtendedLimitInformation, &jeli, sizeof(jeli));
    }

    auto [processHandle, threadHandle] = MakeProcess(info, jobHandle.get());

    if (!processHandle) [[unlikely]]
    {
        return 1;
    }

    WaitForSingleObject(processHandle.get(), INFINITE);

    DWORD exitCode = 1;
    GetExitCodeProcess(processHandle.get(), &exitCode);

    return static_cast<int>(exitCode);
}
