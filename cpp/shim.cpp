// SPDX-License-Identifier: MIT
// Scoop shim - C++20 implementation

#pragma comment(lib, "SHELL32.LIB")

#include <windows.h>
#include <shellapi.h>

#include <array>
#include <cstring>
#include <cwchar>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#ifndef ERROR_ELEVATION_REQUIRED
#define ERROR_ELEVATION_REQUIRED 740
#endif

using namespace std::string_view_literals;

// A plain function with WINAPI linkage is required by SetConsoleCtrlHandler.
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

constexpr std::wstring_view c_dirPlaceholder = L"%~dp0"sv;
constexpr std::wstring_view c_pathPrefix = L"path"sv;
constexpr std::wstring_view c_argsPrefix = L"args"sv;
constexpr std::wstring_view c_cwdPrefix = L"cwd"sv;
constexpr std::wstring_view c_workdirPrefix = L"workdir"sv;
constexpr std::wstring_view c_elevatePrefix = L"elevate"sv;
constexpr std::wstring_view c_runasPrefix = L"runas"sv;
constexpr std::wstring_view c_separator = L" = "sv;

// iswspace() drags in the UCRT wide-ctype table (large under static CRT).
// Match the Zig lane's explicit Unicode-whitespace set instead of calling the CRT.
[[nodiscard]] constexpr bool IsWS(wchar_t c) noexcept
{
    return c == L' ' || c == L'\t' || c == L'\n' || c == L'\r' || c == L'\v' || c == L'\f' || c == 0x00A0 || c == 0x1680 || (c >= 0x2000 && c <= 0x200A) ||
           c == 0x2028 || c == 0x2029 || c == 0x202F || c == 0x205F || c == 0x3000;
}

using EnvVarList = std::vector<std::pair<std::wstring, std::wstring>>;

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

// Write to stderr, bypassing stdio buffering; WriteConsoleW only works on consoles,
// so redirected pipes get UTF-8 via WriteFile.
inline void WriteErrorW(const wchar_t* msg) noexcept
{
    HANDLE hErr = GetStdHandle(STD_ERROR_HANDLE);
    if (hErr == nullptr || hErr == INVALID_HANDLE_VALUE)
    {
        return;
    }

    const size_t len = wcslen(msg);
    if (GetFileType(hErr) == FILE_TYPE_CHAR)
    {
        DWORD written;
        WriteConsoleW(hErr, msg, static_cast<DWORD>(len), &written, nullptr);
        return;
    }

    const int cb = WideCharToMultiByte(CP_UTF8, 0, msg, static_cast<int>(len), nullptr, 0, nullptr, nullptr);
    if (cb > 0)
    {
        std::vector<char> buf(static_cast<size_t>(cb));
        WideCharToMultiByte(CP_UTF8, 0, msg, static_cast<int>(len), buf.data(), cb, nullptr, nullptr);
        DWORD written;
        WriteFile(hErr, buf.data(), static_cast<DWORD>(cb), &written, nullptr);
    }
}

// System error text follows the OS language.
inline void WriteErrorSys(DWORD err)
{
    wchar_t num[11] {};
    DWORD v = err;
    int i = 10;
    do
    {
        num[--i] = static_cast<wchar_t>(L'0' + v % 10);
        v /= 10;
    } while (v && i > 0);
    WriteErrorW(L" (error ");
    WriteErrorW(num + i);
    WriteErrorW(L": ");

    wchar_t buf[256];
    DWORD n = FormatMessageW(
        FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS | FORMAT_MESSAGE_MAX_WIDTH_MASK,
        nullptr,
        err,
        0,
        buf,
        static_cast<DWORD>(sizeof(buf) / sizeof(buf[0])),
        nullptr);
    if (n != 0)
    {
        while (n > 0 && IsWS(buf[n - 1]))
            --n;
        buf[n] = L'\0';
        WriteErrorW(buf);
    }
    WriteErrorW(L").\n");
}

// GUI/redirected launches can yield null or INVALID_HANDLE_VALUE std handles.
inline void EnsureStandardHandles(STARTUPINFOW& si) noexcept
{
    auto ensure = [](HANDLE& h, const wchar_t* name, DWORD access, DWORD share) noexcept {
        if (h == nullptr || h == INVALID_HANDLE_VALUE)
        {
            h = CreateFileW(name, access, share, nullptr, OPEN_EXISTING, 0, nullptr);
            if (h == INVALID_HANDLE_VALUE)
            {
                h = nullptr;
            }
        }
    };
    ensure(si.hStdInput, L"CONIN$", GENERIC_READ, FILE_SHARE_READ);
    ensure(si.hStdOutput, L"CONOUT$", GENERIC_WRITE, FILE_SHARE_WRITE);
    ensure(si.hStdError, L"CONOUT$", GENERIC_WRITE, FILE_SHARE_WRITE);
}

[[nodiscard]] constexpr std::wstring_view GetDirectory(std::wstring_view exe) noexcept
{
    if (auto pos = exe.find_last_of(L"\\/"); pos != std::wstring_view::npos)
    {
        return exe.substr(0, pos);
    }
    return exe;
}

[[nodiscard]] std::wstring_view TrimTrailingWhitespace(std::wstring_view sv) noexcept
{
    while (!sv.empty() && IsWS(sv.back()))
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

// Windows CreateProcessW argument quoting rules.
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
                result.append((i - bsStart) * 2, L'\\');
            }
            else if (arg[i] == L'"')
            {
                result.append((i - bsStart) * 2 + 1, L'\\');
                result += L'"';
                ++i;
            }
            else
            {
                result.append(i - bsStart, L'\\');
            }
        }
        else if (arg[i] == L'"')
        {
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

// No exe prefix - ShellExecuteExW takes parameters separately from the file.
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

[[nodiscard]] bool ParseBool(std::wstring_view value) noexcept
{
    // _wcsnicmp compares exactly N chars - safe on non-null-terminated views
    return (value.size() == 4 && _wcsnicmp(value.data(), L"true", 4) == 0) || (value.size() == 1 && value[0] == L'1') ||
           (value.size() == 3 && _wcsnicmp(value.data(), L"yes", 3) == 0);
}

// ExpandEnvironmentStringsW requires null-terminated input; unknown %VAR% stays as-is.
[[nodiscard]] std::wstring ExpandEnvVars(std::wstring_view input)
{
    if (input.empty()) [[unlikely]]
        return {};

    std::wstring inputStr(input);

    // First call gets the required size, second expands.
    DWORD required = ExpandEnvironmentStringsW(inputStr.c_str(), nullptr, 0);
    if (required == 0) [[unlikely]]
        return inputStr;

    std::wstring result(required - 1, L'\0');
    DWORD actual = ExpandEnvironmentStringsW(inputStr.c_str(), result.data(), required);
    if (actual == 0 || actual > required) [[unlikely]]
        return inputStr;

    result.resize(actual - 1);
    return result;
}

// Shim quotes are structural markers, not content - strip them to avoid double-quoting later.
[[nodiscard]] std::wstring ExpandAndUnquote(std::wstring_view value)
{
    std::wstring expanded = ExpandEnvVars(value);
    if (expanded.size() >= 2 && expanded.front() == L'"' && expanded.back() == L'"')
    {
        expanded = expanded.substr(1, expanded.size() - 2);
    }
    return expanded;
}

// Returns the directory portion (trailing backslash) of the absolute form of `path`.
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

    if (dirLen > 0 && (resolved[dirLen - 1] == L'\\' || resolved[dirLen - 1] == L'/'))
        return std::wstring(resolved.data(), dirLen);

    return std::wstring(resolved.data(), dirLen) + L'\\';
}

[[nodiscard]] std::optional<std::pair<std::wstring_view, std::wstring_view>> ParseShimLine(std::wstring_view line) noexcept
{
    auto skipWS = [](std::wstring_view s, size_t start = 0) -> size_t {
        while (start < s.size() && IsWS(s[start]))
            ++start;
        return start;
    };
    auto rskipWS = [](std::wstring_view s) -> size_t {
        size_t i = s.size();
        while (i > 0 && IsWS(s[i - 1]))
            --i;
        return i;
    };

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
    std::array<wchar_t, MAX_PATH + 2> filename {};
    const auto filenameSize = GetModuleFileNameW(nullptr, filename.data(), MAX_PATH);

    if (filenameSize == 0) [[unlikely]]
    {
        WriteErrorW(L"Shim: The filename of the program could not be determined");
        WriteErrorSys(GetLastError());
        return {};
    }

    if (filenameSize >= MAX_PATH) [[unlikely]]
    {
        std::wstring msg = L"Shim: The filename of the program is too long to handle: '";
        msg += std::wstring_view(filename.data(), filenameSize);
        msg += L"'.\n";
        WriteErrorW(msg.c_str());
        return {};
    }

    // Overwrite the ".exe" suffix in place with "shim" (4 chars + null).
    std::wmemcpy(filename.data() + filenameSize - 3, L"shim", 4);
    filename[filenameSize + 1] = L'\0';

    // Raw ReadFile instead of stdio: the CRT's FILE machinery and ccs=UTF-8 decoder
    // are dead weight under a static CRT, and _wfopen_s reports errno instead of a
    // usable Win32 error code.
    UniqueHandle shimFile(CreateFileW(filename.data(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr));
    if (!shimFile || shimFile.get() == INVALID_HANDLE_VALUE) [[unlikely]]
    {
        const DWORD openErr = GetLastError();
        std::wstring msg = L"Shim: Cannot open shim file for read: '";
        msg += filename.data();
        msg += L"'";
        WriteErrorW(msg.c_str());
        WriteErrorSys(openErr);
        return {};
    }

    const DWORD fileSize = GetFileSize(shimFile.get(), nullptr);
    std::vector<char> raw(fileSize == INVALID_FILE_SIZE ? 0 : fileSize);
    DWORD bytesRead = 0;
    if (fileSize == INVALID_FILE_SIZE || (fileSize > 0 && (!ReadFile(shimFile.get(), raw.data(), fileSize, &bytesRead, nullptr) || bytesRead != fileSize)))
        [[unlikely]]
    {
        const DWORD readErr = GetLastError();
        std::wstring msg = L"Shim: Cannot open shim file for read: '";
        msg += filename.data();
        msg += L"'";
        WriteErrorW(msg.c_str());
        WriteErrorSys(readErr);
        return {};
    }

    // UTF-8 -> UTF-16. Invalid bytes map to U+FFFD and reading continues; the CRT's
    // ccs=UTF-8 stream would instead abort fgetws at the first bad sequence.
    std::vector<wchar_t> text;
    if (bytesRead > 0)
    {
        const int wideLen = MultiByteToWideChar(CP_UTF8, 0, raw.data(), static_cast<int>(bytesRead), nullptr, 0);
        text.resize(static_cast<size_t>(wideLen));
        MultiByteToWideChar(CP_UTF8, 0, raw.data(), static_cast<int>(bytesRead), text.data(), wideLen);
        if (!text.empty() && text[0] == 0xFEFF) // ccs=UTF-8 consumed the BOM; do the same
            text.erase(text.begin());
    }

    std::vector<std::wstring> allLines;
    std::wstring_view tv(text.data(), text.size());
    size_t pos = 0;
    while (pos < tv.size())
    {
        auto nl = tv.find(L'\n', pos);
        if (nl == std::wstring_view::npos)
            nl = tv.size();
        allLines.emplace_back(tv.substr(pos, nl - pos));
        pos = nl + 1;
    }

    const std::wstring_view curDir = GetDirectory({filename.data(), filenameSize});

    // %~dp0 means the *target* exe directory, not the shim's own. Pass 1 resolves
    // path to absolute so pass 2 can expand %~dp0 against the right base.
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

    // Second pass: expand all fields using targetDir for %~dp0.
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

    if (!info.path)
    {
        std::wstring msg = L"Shim: 'path' not found in shim file '";
        msg += filename.data();
        msg += L"'.\n";
        WriteErrorW(msg.c_str());
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
        // On failure hInstApp holds an SE_ERR_* value (<=32); otherwise use GetLastError.
        DWORD err = static_cast<DWORD>(reinterpret_cast<INT_PTR>(sei.hInstApp));
        if (err > 32)
            err = GetLastError();
        if (err == 0)
            err = ERROR_INVALID_FUNCTION;
        WriteErrorW(L"Shim: Unable to create elevated process");
        WriteErrorSys(err);
        return result;
    }

    result.process.reset(sei.hProcess);
    if (jobHandle && result.process)
        AssignProcessToJobObject(jobHandle, result.process.get());

    return result;
}

[[nodiscard]] ProcessResult MakeProcess(const ShimInfo& info, HANDLE jobHandle)
{
    ProcessResult result;

    if (!info.path) [[unlikely]]
        return result;

    // Child inherits the updated environment block, hence before CreateProcessW.
    for (const auto& [name, value] : info.envVars)
    {
        if (!SetEnvironmentVariableW(name.c_str(), value.c_str())) [[unlikely]]
        {
            std::wstring msg = L"Shim: Could not set environment variable '";
            msg += name;
            msg += L"'";
            WriteErrorW(msg.c_str());
            WriteErrorSys(GetLastError());
        }
    }

    const auto& path = *info.path;
    const auto* cwd = info.cwd ? info.cwd->c_str() : nullptr;
    std::wstring cmd = BuildCommandLine(path, info.args);
    std::wstring params = BuildParams(info.args);

    if (info.elevate) [[unlikely]]
        return LaunchElevated(path, params, cwd, jobHandle);

    STARTUPINFOW si {};
    si.cb = sizeof(si);
    GetStartupInfoW(&si);
    EnsureStandardHandles(si);

    PROCESS_INFORMATION pi {};

    // SUSPENDED: the child must join the job object before it can spawn its own children.
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
        // Target manifest requires elevation: retry through ShellExecuteExW.
        if (err == ERROR_ELEVATION_REQUIRED)
            return LaunchElevated(path, params, cwd, jobHandle);

        std::wstring msg = L"Shim: Could not create process with command '";
        msg += cmd;
        msg += L"'";
        WriteErrorW(msg.c_str());
        WriteErrorSys(err);
        return result;
    }

    return result;
}

} // anonymous namespace

int wmain(int argc, wchar_t* argv[])
{
    auto info = GetShimInfo();

    if (!info.path) [[unlikely]]
    {
        return 1;
    }

    // CommandLineToArgvW splits the raw command line; argv[0] is the shim itself.
    {
        int userArgc = 0;
        LPWSTR* userArgv = CommandLineToArgvW(GetCommandLineW(), &userArgc);
        if (userArgv)
        {
            for (int i = 1; i < userArgc; ++i)
            {
                info.args.emplace_back(userArgv[i]);
            }
            LocalFree(userArgv);
        }
    }

    // A GUI-subsystem shim would otherwise flash a console window. With args it
    // behaves as a CLI tool, so it re-attaches to the parent console for output.
    if (IsGuiSubsystem())
    {
        if (argc <= 1 && info.args.empty())
        {
            FreeConsole();
        }
        else
        {
            AttachConsole(ATTACH_PARENT_PROCESS);
        }
    }

    // KILL_ON_JOB_CLOSE ties child lifetime to the shim.
    UniqueHandle jobHandle(CreateJobObjectW(nullptr, nullptr));
    if (jobHandle) [[likely]]
    {
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION jeli {};
        jeli.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK;
        SetInformationJobObject(jobHandle.get(), JobObjectExtendedLimitInformation, &jeli, sizeof(jeli));
    }

    // Before spawn: a Ctrl event in the gap would kill the shim and
    // KILL_ON_JOB_CLOSE would take the child down with it.
    SetConsoleCtrlHandler(CtrlHandler, TRUE);

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
