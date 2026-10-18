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
constexpr std::wstring_view c_envPrefix = L"env:"sv;
constexpr wchar_t c_keyValueSeparator = L'=';

// iswspace() drags in the UCRT wide-ctype table (large under static CRT).

[[nodiscard]] constexpr bool IsWS(wchar_t c) noexcept
{
    return c == L' ' || c == L'\t' || c == L'\n' || c == L'\r' || c == L'\v' || c == L'\f' || c == 0x0085 || c == 0x00A0 || c == 0x1680 ||
           (c >= 0x2000 && c <= 0x200A) || c == 0x2028 || c == 0x2029 || c == 0x202F || c == 0x205F || c == 0x3000;
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

// WriteConsoleW fails on redirected handles, so route by file type; stdio deliberately, see RATIONALE.md.
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

[[nodiscard]] bool IsGuiSubsystem() noexcept;

// GUI/redirected launches can yield null or INVALID_HANDLE_VALUE std handles.
// Console policy lives in wmain; a detached GUI shim has no console, so the opens below fail.
inline void EnsureStandardHandles(STARTUPINFOW& si) noexcept
{
    // Handles must be inheritable or the child never receives them.
    SECURITY_ATTRIBUTES sa {sizeof(SECURITY_ATTRIBUTES), nullptr, TRUE};

    // GetStartupInfoW reports 0 std handles unless the creator set STARTF_USESTDHANDLES; a fresh CONOUT$ handle is not equivalent to the console's.
    auto seed = [](HANDLE& h, DWORD which) noexcept {
        if (h == nullptr || h == INVALID_HANDLE_VALUE)
        {
            HANDLE real = GetStdHandle(which);
            if (real != nullptr && real != INVALID_HANDLE_VALUE)
            {
                h = real;
            }
        }
    };
    seed(si.hStdInput, STD_INPUT_HANDLE);
    seed(si.hStdOutput, STD_OUTPUT_HANDLE);
    seed(si.hStdError, STD_ERROR_HANDLE);

    bool replaced = false;
    auto ensure = [&](HANDLE& h, const wchar_t* name, DWORD access, DWORD share) noexcept {
        if (h == nullptr || h == INVALID_HANDLE_VALUE)
        {
            h = CreateFileW(name, access, share, &sa, OPEN_EXISTING, 0, nullptr);
            if (h == INVALID_HANDLE_VALUE) [[unlikely]]
            {
                h = nullptr;
            }
            else
            {
                replaced = true;
            }
        }
    };
    ensure(si.hStdInput, L"CONIN$", GENERIC_READ, FILE_SHARE_READ);
    ensure(si.hStdOutput, L"CONOUT$", GENERIC_WRITE, FILE_SHARE_WRITE);
    ensure(si.hStdError, L"CONOUT$", GENERIC_WRITE, FILE_SHARE_WRITE);

    if (replaced)
    {
        si.dwFlags |= STARTF_USESTDHANDLES;
    }

    // Handles are intentionally never closed: they live for the process lifetime.
}

inline void ReportShimFileError(const wchar_t* action, const wchar_t* file, DWORD err)
{
    std::wstring msg = L"Shim: ";
    msg += action;
    msg += L": '";
    msg += file;
    msg += L"'";
    WriteErrorW(msg.c_str());
    WriteErrorSys(err);
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

[[nodiscard]] bool IEquals(std::wstring_view a, std::wstring_view b) noexcept
{
    return a.size() == b.size() && CompareStringOrdinal(a.data(), static_cast<int>(a.size()), b.data(), static_cast<int>(b.size()), TRUE) == CSTR_EQUAL;
}

void StripPrefixIgnoreCase(std::wstring_view& name, std::wstring_view prefix) noexcept
{
    if (name.size() < prefix.size())
        return;

    const int n = static_cast<int>(prefix.size());
    if (CompareStringOrdinal(name.data(), n, prefix.data(), n, TRUE) == CSTR_EQUAL)
        name.remove_prefix(prefix.size());
}

[[nodiscard]] size_t IFind(std::wstring_view hay, std::wstring_view needle, size_t from) noexcept
{
    if (needle.empty() || from >= hay.size())
        return std::wstring_view::npos;

    const int idx =
        FindStringOrdinal(FIND_FROMSTART, hay.data() + from, static_cast<int>(hay.size() - from), needle.data(), static_cast<int>(needle.size()), TRUE);
    return idx < 0 ? std::wstring_view::npos : from + static_cast<size_t>(idx);
}

void NormalizeArgsInPlace(std::wstring& args, std::wstring_view curDir)
{
    auto pos = IFind(args, c_dirPlaceholder, 0);
    if (pos == std::wstring::npos) [[likely]]
        return;

    // %~dp0 in batch always includes trailing backslash
    std::wstring replacement(curDir);
    if (replacement.empty() || (replacement.back() != L'\\' && replacement.back() != L'/'))
    {
        replacement += L'\\';
    }

    while (pos != std::wstring::npos)
    {
        args.replace(pos, c_dirPlaceholder.size(), replacement);
        pos = IFind(args, c_dirPlaceholder, pos + replacement.size());
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

[[nodiscard]] std::wstring JoinQuoted(const std::vector<std::wstring>& parts, const std::wstring_view prefix)
{
    std::wstring out(prefix);
    for (size_t i = 0; i < parts.size(); ++i)
    {
        if (i > 0 || !prefix.empty())
            out += L' ';
        out += QuoteArg(parts[i]);
    }
    return out;
}

[[nodiscard]] std::wstring BuildCommandLine(const std::wstring& exePath, const std::vector<std::wstring>& args) { return JoinQuoted(args, QuoteArg(exePath)); }

[[nodiscard]] std::wstring BuildParams(const std::vector<std::wstring>& args) { return JoinQuoted(args, {}); }

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

    // PE headers live in the first page, so an e_lfanew outside it is a bogus offset.
    if (dosHeader->e_lfanew <= 0 || dosHeader->e_lfanew >= 0x1000) [[unlikely]]
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

[[nodiscard]] bool ParseBool(std::wstring_view value) noexcept { return IEquals(value, L"true"sv) || IEquals(value, L"yes"sv) || value == L"1"sv; }

// ExpandEnvironmentStringsW requires null-terminated input; unknown %VAR% stays as-is.
[[nodiscard]] std::wstring ExpandEnvVars(std::wstring_view input)
{
    if (input.empty()) [[unlikely]]
        return {};

    std::wstring inputStr(input);

    auto reportFailure = [&inputStr]() {
        WriteErrorW(L"Shim: Could not expand environment variables in '");
        WriteErrorW(inputStr.c_str());
        WriteErrorW(L"'");
        WriteErrorSys(GetLastError());
    };

    DWORD required = ExpandEnvironmentStringsW(inputStr.c_str(), nullptr, 0);
    if (required == 0) [[unlikely]]
    {
        reportFailure();
        return inputStr;
    }

    std::wstring result(required - 1, L'\0');
    DWORD actual = ExpandEnvironmentStringsW(inputStr.c_str(), result.data(), required);
    if (actual == 0 || actual > required) [[unlikely]]
    {
        reportFailure();
        return inputStr;
    }

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

// Fallback after GetFullPathNameW fails: drop the last component, so %~dp0 is a directory.
[[nodiscard]] std::wstring ResolveFailedDir(const std::wstring& toResolve, DWORD err)
{
    WriteErrorW(L"Shim: Could not resolve path '");
    WriteErrorW(toResolve.c_str());
    WriteErrorW(L"'");
    WriteErrorSys(err);

    const size_t sep = toResolve.find_last_of(L"\\/");
    std::wstring dir = (sep == std::wstring::npos) ? toResolve : toResolve.substr(0, sep);
    if (dir.empty() || (dir.back() != L'\\' && dir.back() != L'/'))
        dir += L'\\';
    return dir;
}

// Returns the directory portion (trailing backslash) of the absolute form of `path`.
[[nodiscard]] std::wstring ResolveAgainstBase(std::wstring_view path, std::wstring_view baseDir)
{
    std::wstring toResolve;
    if ((path.size() >= 2 && path[1] == L':') || (!path.empty() && (path[0] == L'\\' || path[0] == L'/')))
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

    std::wstring resolvedStr;
    size_t dirLen;
    if (len == 0 || len >= MAX_PATH) [[unlikely]]
    {
        // Two-call sizing: len > MAX_PATH is the required buffer size (incl. null).
        DWORD required = (len >= MAX_PATH) ? len : GetFullPathNameW(toResolve.c_str(), 0, nullptr, nullptr);
        if (required == 0) [[unlikely]]
            return ResolveFailedDir(toResolve, GetLastError());

        std::vector<wchar_t> big(required);
        DWORD len2 = GetFullPathNameW(toResolve.c_str(), required, big.data(), &filePart);
        if (len2 == 0 || len2 >= required) [[unlikely]]
            return ResolveFailedDir(toResolve, GetLastError());
        resolvedStr.assign(big.data());
        dirLen = (filePart != nullptr) ? static_cast<size_t>(filePart - big.data()) : resolvedStr.size();
    }
    else
    {
        resolvedStr.assign(resolved.data());
        dirLen = (filePart != nullptr) ? static_cast<size_t>(filePart - resolved.data()) : resolvedStr.size();
    }
    if (dirLen > 0 && (resolvedStr[dirLen - 1] == L'\\' || resolvedStr[dirLen - 1] == L'/'))
        return resolvedStr.substr(0, dirLen);

    return resolvedStr.substr(0, dirLen) + L'\\';
}

enum class LineKind
{
    Blank,
    Field,
    Malformed
};

[[nodiscard]] LineKind ClassifyShimLine(std::wstring_view line, std::pair<std::wstring_view, std::wstring_view>& out) noexcept
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

    out = {};
    auto first = skipWS(line);
    if (first >= line.size() || line[first] == L'#' || line[first] == L';')
        return LineKind::Blank;
    if (line.substr(first).starts_with(L"//"))
        return LineKind::Blank;

    auto sepPos = line.find(c_keyValueSeparator);
    if (sepPos == std::wstring_view::npos)
        return LineKind::Malformed;

    const auto nameRaw = line.substr(0, sepPos);
    const auto valueRaw = line.substr(sepPos + 1);

    auto nameStart = skipWS(nameRaw);
    auto nameEnd = rskipWS(nameRaw);
    if (nameStart >= nameEnd)
        return LineKind::Malformed; // "= value" has no key
    auto name = nameRaw.substr(nameStart, nameEnd - nameStart);

    auto valueStart = skipWS(valueRaw);
    out = {name, (valueStart >= valueRaw.size()) ? L""sv : valueRaw.substr(valueStart)};

    return LineKind::Field;
}

[[nodiscard]] ShimInfo GetShimInfo()
{
    std::vector<wchar_t> filename(MAX_PATH + 2);
    DWORD capacity = static_cast<DWORD>(filename.size());
    DWORD filenameSize = GetModuleFileNameW(nullptr, filename.data(), capacity);

    if (filenameSize == 0) [[unlikely]]
    {
        WriteErrorW(L"Shim: The filename of the program could not be determined");
        WriteErrorSys(GetLastError());
        return {};
    }

    // Truncation returns the required size: grow and retry, capped at the path limit.
    constexpr DWORD maxModulePath = 32768;
    while (filenameSize >= capacity && capacity < maxModulePath) [[unlikely]]
    {
        DWORD want = capacity * 4;
        if (want > maxModulePath)
            want = maxModulePath;
        // Room for the ".exe" -> "shim" overwrite plus its null terminator.
        filename.resize(want + 2);
        capacity = want;
        filenameSize = GetModuleFileNameW(nullptr, filename.data(), capacity);
        if (filenameSize == 0) [[unlikely]]
        {
            WriteErrorW(L"Shim: The filename of the program could not be determined");
            WriteErrorSys(GetLastError());
            return {};
        }
    }

    if (filenameSize >= capacity) [[unlikely]]
    {
        std::wstring msg = L"Shim: The filename of the program is too long to handle: '";
        msg += std::wstring_view(filename.data(), filenameSize);
        msg += L"'.\n";
        WriteErrorW(msg.c_str());
        return {};
    }

    // Only replace the extension of the file name, not a dot in a parent directory.
    {
        std::wstring shimPath(filename.data(), filenameSize);
        size_t compStart = shimPath.find_last_of(L"\\/");
        compStart = (compStart == std::wstring::npos) ? 0 : compStart + 1;
        const size_t dot = shimPath.rfind(L'.');
        if (dot != std::wstring::npos && dot >= compStart)
            shimPath.replace(dot, std::wstring::npos, L".shim");
        else
            shimPath += L".shim";

        filenameSize = static_cast<DWORD>(shimPath.size());
        filename.assign(shimPath.begin(), shimPath.end());
        filename.push_back(L'\0');
    }

    // Raw ReadFile instead of stdio: the CRT's FILE machinery and ccs=UTF-8 decoder
    // are dead weight under a static CRT, and _wfopen_s reports errno instead of a
    // usable Win32 error code.
    UniqueHandle shimFile(CreateFileW(filename.data(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr));
    if (!shimFile || shimFile.get() == INVALID_HANDLE_VALUE) [[unlikely]]
    {
        ReportShimFileError(L"Cannot open shim file for read", filename.data(), GetLastError());
        return {};
    }

    const DWORD fileSize = GetFileSize(shimFile.get(), nullptr);
    std::vector<char> raw(fileSize == INVALID_FILE_SIZE ? 0 : fileSize);
    DWORD bytesRead = 0;
    bool readOk = true;
    DWORD readErr = ERROR_READ_FAULT;
    if (fileSize > 0)
    {
        readOk = ReadFile(shimFile.get(), raw.data(), fileSize, &bytesRead, nullptr) != FALSE;
        readErr = readOk ? ERROR_READ_FAULT : GetLastError();
        // Short read: the file shrank between the size query and ReadFile, so GetLastError() is 0.
        if (readOk && bytesRead != fileSize)
            readOk = false;
    }
    if (!readOk) [[unlikely]]
    {
        ReportShimFileError(L"Cannot read shim file", filename.data(), readErr);
        return {};
    }

    // Strict: a line that is not valid UTF-8 is dropped, not decoded into U+FFFD.
    constexpr std::string_view c_bomUtf8 = "\xEF\xBB\xBF"sv;
    size_t bytePos = (raw.size() >= c_bomUtf8.size() && std::string_view {raw.data(), c_bomUtf8.size()} == c_bomUtf8) ? c_bomUtf8.size() : 0;

    std::vector<std::wstring> decoded;
    decoded.reserve(8);
    while (bytePos < raw.size())
    {
        size_t lineEnd = bytePos;
        while (lineEnd < raw.size() && raw[lineEnd] != '\n')
            ++lineEnd;
        const char* lineData = raw.data() + bytePos;
        const int lineBytes = static_cast<int>(lineEnd - bytePos);
        bytePos = lineEnd + 1;

        if (lineBytes == 0)
            continue;

        const int wideLen = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, lineData, lineBytes, nullptr, 0);
        if (wideLen == 0)
        {
            WriteErrorW(L"Shim: invalid UTF-8 line in shim file\n");
            continue;
        }
        std::wstring line(static_cast<size_t>(wideLen), L'\0');
        MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, lineData, lineBytes, line.data(), wideLen);

        // Classified here, not in a pass: only this loop sees every line.
        std::pair<std::wstring_view, std::wstring_view> field;
        if (ClassifyShimLine(TrimTrailingWhitespace(line), field) == LineKind::Malformed)
        {
            std::wstring msg = L"Shim: malformed line '";
            msg += TrimTrailingWhitespace(line);
            msg += L"' in shim file '";
            msg += filename.data();
            msg += L"': expected 'key = value'.\n";
            WriteErrorW(msg.c_str());
            return {};
        }

        decoded.push_back(std::move(line));
    }

    const std::wstring_view curDir = GetDirectory({filename.data(), filenameSize});

    // %~dp0 means the *target* exe directory, not the shim's own. Pass 1 resolves
    // path to absolute so pass 2 can expand %~dp0 against the right base. A path
    // value may itself use %~dp0, which there refers to the shim's own directory.
    std::wstring targetDir {curDir};
    for (const auto& rawLine : decoded)
    {
        std::pair<std::wstring_view, std::wstring_view> field;
        if (ClassifyShimLine(TrimTrailingWhitespace(rawLine), field) != LineKind::Field || !IEquals(field.first, c_pathPrefix))
            continue;

        std::wstring pathVal(field.second);
        NormalizeArgsInPlace(pathVal, curDir);
        std::wstring expanded = ExpandAndUnquote(pathVal);
        targetDir = ResolveAgainstBase(expanded, curDir);
        break;
    }

    ShimInfo info;
    for (const auto& rawLine : decoded)
    {
        std::pair<std::wstring_view, std::wstring_view> field;
        if (ClassifyShimLine(TrimTrailingWhitespace(rawLine), field) != LineKind::Field)
            continue;

        const auto& [name, value] = field;

        if (IEquals(name, c_pathPrefix))
        {
            if (!info.path)
            {
                std::wstring pathVal(value);
                NormalizeArgsInPlace(pathVal, curDir);
                info.path = ExpandAndUnquote(pathVal);
            }
        }
        else if (IEquals(name, c_argsPrefix))
        {
            std::wstring argsStr(value);
            NormalizeArgsInPlace(argsStr, targetDir);

            if (!argsStr.empty())
            {
                int shimArgc = 0;
                LPWSTR* shimArgv = CommandLineToArgvW(argsStr.c_str(), &shimArgc);
                if (shimArgv && shimArgc > 0)
                {
                    for (int i = 0; i < shimArgc; ++i)
                    {
                        info.args.emplace_back(shimArgv[i]);
                    }
                    LocalFree(shimArgv);
                }
            }
        }
        else if (IEquals(name, c_cwdPrefix) || IEquals(name, c_workdirPrefix))
        {
            std::wstring cwdVal(value);
            NormalizeArgsInPlace(cwdVal, targetDir);
            info.cwd = ExpandAndUnquote(cwdVal);
        }
        else if (IEquals(name, c_elevatePrefix) || IEquals(name, c_runasPrefix))
        {
            info.elevate = ParseBool(value);
        }
        else
        {

            std::wstring_view envName = name;
            StripPrefixIgnoreCase(envName, c_envPrefix);
            if (envName.empty())
            {
                WriteErrorW(L"Shim: empty variable name after 'env:' in shim file\n");
                continue;
            }

            std::wstring envVal(value);
            NormalizeArgsInPlace(envVal, targetDir);
            info.envVars.emplace_back(std::wstring(envName), ExpandAndUnquote(envVal));
        }
    }

    if (!info.path || info.path->empty())
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
    if (jobHandle && result.process && !AssignProcessToJobObject(jobHandle, result.process.get())) [[unlikely]]
    {
        WriteErrorW(L"Shim: Could not assign process to job object");
        WriteErrorSys(GetLastError());
    }

    return result;
}

[[nodiscard]] ProcessResult MakeProcess(const ShimInfo& info, HANDLE jobHandle)
{
    ProcessResult result;

    if (!info.path || info.path->empty()) [[unlikely]]
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

    if (info.elevate) [[unlikely]]
        return LaunchElevated(path, BuildParams(info.args), cwd, jobHandle);

    STARTUPINFOW si {};
    si.cb = sizeof(si);
    GetStartupInfoW(&si);
    EnsureStandardHandles(si);

    PROCESS_INFORMATION pi {};

    // SUSPENDED: the child must join the job object before it can spawn its own children.
    // Without the flag a console-less shim gives a console target a fresh windowed console.
    // GetConsoleProcessList, not GetConsoleWindow: NULL also means a windowless console.
    DWORD consolePid = 0;
    DWORD creationFlags = CREATE_SUSPENDED;
    if (GetConsoleProcessList(&consolePid, 1) == 0)
        creationFlags |= CREATE_NO_WINDOW;

    if (CreateProcessW(nullptr, cmd.data(), nullptr, nullptr, TRUE, creationFlags, nullptr, cwd, &si, &pi)) [[likely]]
    {
        result.thread.reset(pi.hThread);
        result.process.reset(pi.hProcess);

        if (jobHandle && !AssignProcessToJobObject(jobHandle, pi.hProcess)) [[unlikely]]
        {
            WriteErrorW(L"Shim: Could not assign process to job object");
            WriteErrorSys(GetLastError());
        }

        // A failed resume leaves the child suspended while the shim waits on it forever.
        if (ResumeThread(result.thread.get()) == static_cast<DWORD>(-1)) [[unlikely]]
        {
            const DWORD resumeErr = GetLastError();
            WriteErrorW(L"Shim: Could not resume suspended process");
            WriteErrorSys(resumeErr);
            // No job to end when CreateJobObjectW failed, so terminate the child itself.
            if (jobHandle)
                TerminateJobObject(jobHandle, 1);
            else
                TerminateProcess(result.process.get(), 1);
            result.thread.reset();
            result.process.reset();
        }
    }
    else
    {
        const DWORD err = GetLastError();
        // Target manifest requires elevation: retry through ShellExecuteExW.
        if (err == ERROR_ELEVATION_REQUIRED)
            return LaunchElevated(path, BuildParams(info.args), cwd, jobHandle);

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

    {
        int userArgc = 0;
        LPWSTR* userArgv = CommandLineToArgvW(GetCommandLineW(), &userArgc);
        if (userArgv && userArgc > 0)
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

    UniqueHandle jobHandle(CreateJobObjectW(nullptr, nullptr));
    if (jobHandle) [[likely]]
    {
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION jeli {};
        jeli.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK;
        if (!SetInformationJobObject(jobHandle.get(), JobObjectExtendedLimitInformation, &jeli, sizeof(jeli))) [[unlikely]]
        {
            WriteErrorW(L"Shim: Could not set job object limits");
            WriteErrorSys(GetLastError());
        }
    }
    else [[unlikely]]
    {
        WriteErrorW(L"Shim: Could not create job object");
        WriteErrorSys(GetLastError());
    }

    // Before spawn: a Ctrl event in the gap would kill the shim and
    // KILL_ON_JOB_CLOSE would take the child down with it.
    SetConsoleCtrlHandler(CtrlHandler, TRUE);

    auto [processHandle, threadHandle] = MakeProcess(info, jobHandle.get());

    if (!processHandle) [[unlikely]]
    {
        return 1;
    }

    if (WaitForSingleObject(processHandle.get(), INFINITE) == WAIT_FAILED) [[unlikely]]
    {
        WriteErrorW(L"Shim: Could not wait for process to exit");
        WriteErrorSys(GetLastError());
        return 1;
    }

    DWORD exitCode = 1;
    if (!GetExitCodeProcess(processHandle.get(), &exitCode)) [[unlikely]]
    {
        WriteErrorW(L"Shim: Could not get child exit code");
        WriteErrorSys(GetLastError());
        exitCode = 1;
    }

    return static_cast<int>(exitCode);
}
