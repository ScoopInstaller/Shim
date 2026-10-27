/*
 * probe -- raw Win32 helper for the shim test suite.
 *
 * Jobs a scripting host cannot do faithfully:
 *
 *   report <file>              Report the standard handles this process was given.
 *                              A managed host (pwsh, .NET) repairs an invalid
 *                              stdout handle during startup, which hides exactly
 *                              the defect these tests exist to catch. Nothing in
 *                              this mode touches stdio except to read its state.
 *                              Writes one line: stdout_valid= stdout_type=
 *                              stdout_is_console= [stdout_inherit=] stdout_write=
 *                              console= window=, where 2 is FILE_TYPE_CHAR.
 *                              console= is GetConsoleProcessList != 0 and window=
 *                              is GetConsoleWindow() != NULL: a windowless console
 *                              is still a console, so the two differ.
 *
 *   manifest <exe>             Write <exe>'s embedded manifest, raw UTF-8, to
 *                              stdout. The image is mapped as data, which runs
 *                              nothing and reads either architecture, and the
 *                              resource is looked up as type 24 by number and ID
 *                              1 by number. That numeric lookup is the point: a
 *                              cross-compiling toolchain that emitted the manifest
 *                              as a *named* resource -- which the loader ignores
 *                              without any error -- makes this lookup fail instead.
 *                              One stderr line and a distinct non-zero exit when
 *                              the image or the resource is absent, so a missing
 *                              manifest reads as a failure, not as empty output.
 *
 *   create <exe> [--null-out|--default] [--detached] [--inherit] [--stdin <text>] [-- <args>...]
 *                              Launch <exe> as a creator. --null-out sets
 *                              STARTF_USESTDHANDLES while passing stdout as NULL
 *                              and stdin/stderr as pipes, which is the shape Go's
 *                              os/exec produces when only some streams are set --
 *                              and the only shape that reaches the shim's
 *                              CONIN$/CONOUT$ fallback. --default passes no
 *                              STARTF_USESTDHANDLES at all, so a console
 *                              application resolves the console's own handles. A
 *                              console is allocated first, so the outcome does not
 *                              depend on what the runner happens to have.
 *                              --detached adds DETACHED_PROCESS, which leaves the
 *                              child with no console at all -- the state a GUI
 *                              host's detached windowless spawn produces.
 *                              --inherit hands the child this process's own
 *                              standard handles, marked inheritable, and sets no
 *                              STARTF_USESTDHANDLES. This process frees its console
 *                              first, so the child has none to inherit either: the
 *                              shape a console-less creator with a usable stdout
 *                              produces.
 *                              --stdin <text> pipes <text> to the child's stdin,
 *                              newline appended when it lacks one, and pipes all
 *                              three streams. stdout/stderr are probe's own
 *                              handles, so a console-less child's output still
 *                              reaches the runner, and no stream is nulled so
 *                              the CONIN$/CONOUT$ fallback stays inert. It
 *                              contradicts --null-out; the pair exits 5.
 *                              Every argument after -- is re-quoted per the MS
 *                              command-line rules, so a spaced argument survives.
 *
 *   args <arg>...              One "Arg N is <value>" line per argument, index
 *                              zero-based, value UTF-8 and unescaped, after a
 *                              PROBE_ARGS line. The child of a shim under test is
 *                              an .exe, so this reports the argv a real native
 *                              target would parse; a batch target would only
 *                              measure cmd's %* re-expansion.
 *
 *   env [name...]              With no name, dump the child's environment block,
 *                              one NAME=VALUE per entry, block order, LF. With
 *                              names, print NAME=VALUE for each that exists, a
 *                              present-but-empty variable as NAME=, and nothing
 *                              for one that does not exist. Reads the block
 *                              directly, so the stored spelling of a name
 *                              survives while lookup stays case-insensitive as
 *                              Windows is.
 *
 *   cwd                        Print GetCurrentDirectoryW's result.
 *   echo <text...>             Print the arguments joined by single spaces.
 *   echoerr <text...>          Print <text> to stdout and "<text> err" to
 *                              stderr, so one run proves both streams passed.
 *   exit [code]                ExitProcess; code is decimal or 0x hex, default 0.
 *   stdin                      Print "GOT=<line>" for one line read from stdin.
 *   wait <ms>                  Sleep, then exit 0.
 *   touch <file>               Create or truncate the file, exit 0.
 *
 * Built with no C runtime at all, which also keeps the probe honest: nothing
 * here can quietly repair a handle. The only import is KERNEL32.dll. Rebuild
 * command: test/README.md.
 */

#include <windows.h>

#define MAX_ARGS 64
#define CMD_MAX 4096
#define REPORT_MAX 256
#define ARGS_BUF 16384
#define LINE_MAX 4096

static int g_argc;
static wchar_t *g_argv[MAX_ARGS];

/* The few string primitives this file needs; the CRT is not linked in. */
static int wlen(const wchar_t *s)
{
    int n = 0;
    while (s[n]) n++;
    return n;
}

static int weq(const wchar_t *a, const wchar_t *b)
{
    while (*a && *a == *b) { a++; b++; }
    return *a == *b;
}

/* Splits our own command line the way the C runtime and CommandLineToArgvW do, so
 * "args" reports the argv a native child would parse. A quoted run keeps its spaces;
 * 2n backslashes before a quote collapse to n backslashes and toggle quoting, while
 * 2n+1 collapse to n backslashes and a literal quote. Stripping the structural quotes
 * in place is why this cannot just mark token boundaries: "a b" must become a b. */
static void parse_cmdline(void)
{
    wchar_t *p = GetCommandLineW();

    while (*p && g_argc < MAX_ARGS) {
        while (*p == L' ' || *p == L'\t') p++;
        if (!*p) break;

        wchar_t *start = p;
        wchar_t *out = p;
        int inQuotes = 0;

        while (*p) {
            if (*p == L'\\') {
                int n = 0;
                while (*p == L'\\') { n++; p++; }
                if (*p == L'"') {
                    for (int i = 0; i < n / 2; i++) *out++ = L'\\';
                    if (n & 1) { *out++ = L'"'; p++; }
                    else { inQuotes = !inQuotes; p++; }
                } else {
                    for (int i = 0; i < n; i++) *out++ = L'\\';
                }
            } else if (*p == L'"') {
                inQuotes = !inQuotes;
                p++;
            } else if (!inQuotes && (*p == L' ' || *p == L'\t')) {
                break;
            } else {
                *out++ = *p++;
            }
        }

        /* Terminates the token in place. The terminator has to stay, or every token
         * runs on into the next argument -- but then the scan pointer is sitting
         * on that terminator, so it has to step over it rather than re-read it as
         * the end of the line. */
        wchar_t over = *p;
        *out = 0;
        g_argv[g_argc++] = start;
        if (over == 0) break;
        p++;
    }
}

static int arg_is(int index, const wchar_t *what)
{
    return index < g_argc && weq(g_argv[index], what);
}

static char *put_str(char *p, const char *s)
{
    while (*s) *p++ = *s++;
    return p;
}

static char *put_num(char *p, unsigned long v)
{
    char tmp[12];
    int n = 0;

    if (v == 0) {
        *p++ = '0';
        return p;
    }
    while (v) {
        tmp[n++] = (char)(L'0' + (v % 10));
        v /= 10;
    }
    while (n) *p++ = tmp[--n];
    return p;
}

static void report(const wchar_t *path)
{
    char line[REPORT_MAX];

    HANDLE h = GetStdHandle(STD_OUTPUT_HANDLE);
    unsigned long type = GetFileType(h);
    DWORD mode = 0;
    DWORD flags = 0;
    int isConsole = GetConsoleMode(h, &mode) ? 1 : 0;
    int haveFlags = GetHandleInformation(h, &flags) ? 1 : 0;
    int valid = (h != NULL && h != INVALID_HANDLE_VALUE) ? 1 : 0;
    int writable = WriteFile(h, "", 0, NULL, NULL) ? 1 : 0;

    /* GetConsoleProcessList needs a real buffer: a NULL list with count 0 is
     * documented misuse and returns 0 with ERROR_INVALID_PARAMETER regardless of
     * whether a console is attached. GetConsoleWindow cannot stand in for this,
     * because it is NULL both with no console and with a windowless one. */
    DWORD consolePid = 0;
    int hasConsole = GetConsoleProcessList(&consolePid, 1) != 0;
    int hasWindow = GetConsoleWindow() != NULL ? 1 : 0;

    char *p = line;
    p = put_str(p, "stdout_valid=");
    p = put_num(p, (unsigned long)valid);
    p = put_str(p, " stdout_type=");
    p = put_num(p, type);
    p = put_str(p, " stdout_is_console=");
    p = put_num(p, (unsigned long)isConsole);
    if (haveFlags) {
        p = put_str(p, " stdout_inherit=");
        p = put_num(p, (unsigned long)(flags & 1));
    }
    p = put_str(p, " stdout_write=");
    p = put_num(p, (unsigned long)writable);
    p = put_str(p, " console=");
    p = put_num(p, (unsigned long)hasConsole);
    p = put_str(p, " window=");
    p = put_num(p, (unsigned long)hasWindow);
    *p++ = '\n';

    HANDLE f = CreateFileW(path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (f == INVALID_HANDLE_VALUE) return;
    DWORD written = 0;
    WriteFile(f, line, (DWORD)(p - line), &written, NULL);
    CloseHandle(f);
}

/* Prints "Arg N is <value>" for g_argv[first..], matching PowerShell's TestExe: the
 * mode token is not counted, so the first value after it is Arg 0. UTF-8 because an
 * argument may carry non-ASCII; WriteFile because a pipe is not a console. */
static void print_args(int first)
{
    static char buf[ARGS_BUF];
    HANDLE h = GetStdHandle(STD_OUTPUT_HANDLE);
    DWORD written = 0;

    static const char header[] = "PROBE_ARGS\n";
    WriteFile(h, header, (DWORD)(sizeof(header) - 1), &written, NULL);

    for (int i = first; i < g_argc; i++) {
        char *p = buf;
        p = put_str(p, "Arg ");
        p = put_num(p, (unsigned long)(i - first));
        p = put_str(p, " is <");

        /* Leave room for the closing '>' and '\n'; an over-long argument truncates
         * rather than walking off buf, which cannot happen for a command line that
         * reached this process at all. */
        int room = (int)sizeof(buf) - (int)(p - buf) - 2;
        int cb = WideCharToMultiByte(CP_UTF8, 0, g_argv[i], wlen(g_argv[i]), p, room, NULL, NULL);
        if (cb > 0) p += cb;
        *p++ = '>';
        *p++ = '\n';
        WriteFile(h, buf, (DWORD)(p - buf), &written, NULL);
    }
}

static void write_out(HANDLE h, const char *buf, int len)
{
    DWORD n = 0;
    WriteFile(h, buf, (DWORD)len, &n, NULL);
}

static char *put_utf8(char *p, int room, const wchar_t *s)
{
    int cb;

    /* Callers pass whatever room is left, which can reach zero. */
    if (room <= 0) return p;
    cb = WideCharToMultiByte(CP_UTF8, 0, s, wlen(s), p, room, NULL, NULL);
    return cb > 0 ? p + cb : p;
}

/* echo / echoerr: the arguments after the mode joined by single spaces. The
 * suffix is how echoerr writes the same payload plus " err" to the other stream. */
static void print_join(HANDLE h, int first, const char *suffix)
{
    static char buf[ARGS_BUF];
    char *p = buf;

    for (int i = first; i < g_argc; i++) {
        if (i > first) *p++ = ' ';
        p = put_utf8(p, (int)sizeof(buf) - (int)(p - buf) - 8, g_argv[i]);
    }
    if (suffix) p = put_str(p, suffix);
    *p++ = '\n';
    write_out(h, buf, (int)(p - buf));
}

static void print_cwd(void)
{
    wchar_t dir[LINE_MAX];
    char buf[LINE_MAX];
    DWORD n = GetCurrentDirectoryW(LINE_MAX, dir);
    char *p = buf;

    if (n > 0) p = put_utf8(p, (int)sizeof(buf) - 2, dir);
    *p++ = '\n';
    write_out(GetStdHandle(STD_OUTPUT_HANDLE), buf, (int)(p - buf));
}

static wchar_t lower(wchar_t c)
{
    return (c >= L'A' && c <= L'Z') ? (wchar_t)(c + 32) : c;
}

/* A name exactly as long as the entry's name, compared case-insensitively. */
static int name_matches(const wchar_t *entry, int len, const wchar_t *name)
{
    int i = 0;
    for (; i < len && name[i]; i++)
        if (lower(entry[i]) != lower(name[i])) return 0;
    return i == len && name[i] == 0;
}

static void print_env_entry(HANDLE h, const wchar_t *entry)
{
    static char buf[ARGS_BUF];
    char *p = put_utf8(buf, (int)sizeof(buf) - 2, entry);
    *p++ = '\n';
    write_out(h, buf, (int)(p - buf));
}

/* env [name...]: walks GetEnvironmentStringsW rather than GetEnvironmentVariableW so
 * the stored spelling survives -- lookup is case-insensitive either way, but the
 * printed name must be the one that was set. Present-but-empty prints NAME=; absent
 * prints nothing. Entries are NUL-separated, the block ends on an empty entry. */
static void print_env(int first)
{
    wchar_t *block = GetEnvironmentStringsW();
    HANDLE h = GetStdHandle(STD_OUTPUT_HANDLE);

    if (!block) return;

    if (first >= g_argc) {
        for (wchar_t *e = block; *e; e += wlen(e) + 1)
            print_env_entry(h, e);
    } else {
        for (int i = first; i < g_argc; i++) {
            for (wchar_t *e = block; *e; e += wlen(e) + 1) {
                const wchar_t *eq = e;
                while (*eq && *eq != L'=') eq++;
                if (*eq == L'=' && name_matches(e, (int)(eq - e), g_argv[i])) {
                    print_env_entry(h, e);
                    break;
                }
            }
        }
    }
    FreeEnvironmentStringsW(block);
}

static unsigned long parse_uint(const wchar_t *s)
{
    unsigned long v = 0;
    int base = 10;

    if (s[0] == L'0' && (s[1] == L'x' || s[1] == L'X')) { base = 16; s += 2; }
    for (; *s; s++) {
        int d;
        if (*s >= L'0' && *s <= L'9') d = *s - L'0';
        else if (base == 16 && lower(*s) >= L'a' && lower(*s) <= L'f') d = lower(*s) - L'a' + 10;
        else break;
        v = v * base + (unsigned long)d;
    }
    return v;
}

static void do_stdin(void)
{
    static char line[LINE_MAX];
    static char buf[LINE_MAX + 8];
    HANDLE h = GetStdHandle(STD_INPUT_HANDLE);
    int n = 0;
    char c;
    DWORD r = 0;

    while (ReadFile(h, &c, 1, &r, NULL) && r == 1) {
        if (c == '\n') break;
        if (n < (int)sizeof(line)) line[n++] = c;
    }
    if (n > 0 && line[n - 1] == '\r') n--;

    char *p = put_str(buf, "GOT=");
    for (int i = 0; i < n; i++) *p++ = line[i];
    *p++ = '\n';
    write_out(GetStdHandle(STD_OUTPUT_HANDLE), buf, (int)(p - buf));
}

static void do_touch(const wchar_t *path)
{
    HANDLE f = CreateFileW(path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (f != INVALID_HANDLE_VALUE) CloseHandle(f);
}

/* Global so the command line does not land on the stack. */
static wchar_t g_cmd[CMD_MAX];

/* Quote one argument the way CommandLineToArgvW parses it back (parse_cmdline run backwards). */
static void append_arg(int *len, const wchar_t *s)
{
    g_cmd[(*len)++] = L'"';
    for (const wchar_t *q = s; *q; q++) {
        int n = 0;

        while (*q == L'\\') { n++; q++; }
        if (!*q) {
            for (int i = 0; i < 2 * n; i++) g_cmd[(*len)++] = L'\\';
            break;
        }
        if (*q == L'"') {
            for (int i = 0; i < 2 * n + 1; i++) g_cmd[(*len)++] = L'\\';
        } else {
            for (int i = 0; i < n; i++) g_cmd[(*len)++] = L'\\';
        }
        g_cmd[(*len)++] = *q;
    }
    g_cmd[(*len)++] = L'"';
}

static int create(const wchar_t *exe, int nullOut, int detached, int inheritStdio, const wchar_t *stdinText, int firstArg)
{
    int len = 0;

    if (wlen(exe) + 3 >= CMD_MAX) return 2;
    g_cmd[len++] = L'"';
    for (const wchar_t *s = exe; *s; s++) g_cmd[len++] = *s;
    g_cmd[len++] = L'"';
    g_cmd[len] = 0;

    for (int i = firstArg; i < g_argc; i++) {
        /* Quoting may double the argument; the budget has to assume it does. */
        int need = len + 2 * wlen(g_argv[i]) + 4;
        if (need >= CMD_MAX) return 2;
        g_cmd[len++] = L' ';
        append_arg(&len, g_argv[i]);
        g_cmd[len] = 0;
    }

    /* AllocConsole fails harmlessly when a console is already attached, which is
     * the case when the suite runs from an interactive terminal. */
    AllocConsole();

    SECURITY_ATTRIBUTES sa;
    sa.nLength = sizeof(sa);
    sa.lpSecurityDescriptor = NULL;
    sa.bInheritHandle = TRUE;

    STARTUPINFOW si;
    si.cb = sizeof(si);
    si.lpReserved = NULL;
    si.lpDesktop = NULL;
    si.lpTitle = NULL;
    si.dwX = 0;
    si.dwY = 0;
    si.dwXSize = 0;
    si.dwYSize = 0;
    si.dwXCountChars = 0;
    si.dwYCountChars = 0;
    si.dwFillAttribute = 0;
    si.dwFlags = 0;
    si.wShowWindow = 0;
    si.cbReserved2 = 0;
    si.lpReserved2 = NULL;
    si.hStdInput = NULL;
    si.hStdOutput = NULL;
    si.hStdError = NULL;

    HANDLE inRd = NULL, inWr = NULL, erRd = NULL, erWr = NULL;
    BOOL inherit = FALSE;

    if (stdinText) {
        /* Closing the write end gives the child EOF; the read end may stay open,
         * this process exits right after the child does. */
        static char feed[ARGS_BUF];
        int cb = WideCharToMultiByte(CP_UTF8, 0, stdinText, wlen(stdinText), feed,
                                     (int)sizeof(feed) - 2, NULL, NULL);
        DWORD wrote = 0;

        if (cb < 0) cb = 0;
        if (cb == 0 || feed[cb - 1] != '\n') feed[cb++] = '\n';

        if (!CreatePipe(&inRd, &inWr, &sa, 0)) return 3;
        SetHandleInformation(inWr, HANDLE_FLAG_INHERIT, 0);
        WriteFile(inWr, feed, (DWORD)cb, &wrote, NULL);
        CloseHandle(inWr);
        inWr = NULL;

        /* A handle probe inherited is not automatically inheritable by probe's child. */
        SetHandleInformation(GetStdHandle(STD_OUTPUT_HANDLE), HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT);
        SetHandleInformation(GetStdHandle(STD_ERROR_HANDLE), HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT);

        si.dwFlags = STARTF_USESTDHANDLES;
        si.hStdInput = inRd;
        si.hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE);
        si.hStdError = GetStdHandle(STD_ERROR_HANDLE);
        inherit = TRUE;
    } else if (nullOut) {
        if (!CreatePipe(&inRd, &inWr, &sa, 0)) return 3;
        if (!CreatePipe(&erRd, &erWr, &sa, 0)) return 3;
        SetHandleInformation(inWr, HANDLE_FLAG_INHERIT, 0);
        SetHandleInformation(erRd, HANDLE_FLAG_INHERIT, 0);
        si.dwFlags = STARTF_USESTDHANDLES;
        si.hStdInput = inRd;
        si.hStdOutput = NULL; /* the case under test */
        si.hStdError = erWr;
        inherit = TRUE;
    } else if (inheritStdio) {
        /* The child inherits this process's standard handles and the startup info
         * says nothing about them. The console goes first, so the child has none
         * to inherit either -- DETACHED_PROCESS would do that too, but it also
         * drops the inherited handles, which is the half of the shape under test. */
        FreeConsole();
        SetHandleInformation(GetStdHandle(STD_INPUT_HANDLE), HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT);
        SetHandleInformation(GetStdHandle(STD_OUTPUT_HANDLE), HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT);
        SetHandleInformation(GetStdHandle(STD_ERROR_HANDLE), HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT);
        inherit = TRUE;
    }

    PROCESS_INFORMATION pi;
    DWORD flags = detached ? DETACHED_PROCESS : 0;
    BOOL started = CreateProcessW(exe, g_cmd, NULL, NULL, inherit, flags, NULL, NULL, &si, &pi);

    /* Close probe's pipe ends: stdin sees EOF, a full stderr pipe fails a write not a deadlock. */
    if (inWr) CloseHandle(inWr);
    if (erRd) CloseHandle(erRd);
    if (!started) return 4;

    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD code = 1;
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return (int)code;
}

/* Exit 5, so a bad flag combination is told apart from the usage fallthrough's arity error. */
static void usage_error(const char *msg)
{
    DWORD n = 0;
    WriteFile(GetStdHandle(STD_ERROR_HANDLE), msg, lstrlenA(msg), &n, NULL);
    ExitProcess(5);
}

/* The manifest's own failure exit: 6, apart from the usage fallthrough's 1 and
 * usage_error's 5. */
static void manifest_error(const char *msg)
{
    DWORD n = 0;
    WriteFile(GetStdHandle(STD_ERROR_HANDLE), msg, lstrlenA(msg), &n, NULL);
    ExitProcess(6);
}

/* manifest <exe>: dump the embedded manifest resource, raw. Mapping as data runs
 * nothing and is architecture-agnostic. Type 24 and ID 1 both by number, never by
 * a resolved symbol: an llvm-rc that named the resource leaves the loader ignoring
 * it with no error anywhere, and this lookup is what turns that into a visible
 * failure (RATIONALE.md). */
static void print_manifest(const wchar_t *path)
{
    HMODULE h = LoadLibraryExW(path, NULL, LOAD_LIBRARY_AS_DATAFILE);
    DWORD written = 0;

    if (!h) manifest_error("probe: cannot map the image\n");
    HRSRC res = FindResourceW(h, MAKEINTRESOURCEW(1), MAKEINTRESOURCEW(24));
    if (!res) manifest_error("probe: no manifest resource (type 24, id 1)\n");
    HGLOBAL data = LoadResource(h, res);
    if (!data) manifest_error("probe: cannot load the manifest resource\n");
    const void *bytes = LockResource(data);
    DWORD size = SizeofResource(h, res);
    if (!bytes || size == 0) manifest_error("probe: empty manifest resource\n");
    WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), bytes, size, &written, NULL);
}

void __stdcall probe_entry(void)
{
    parse_cmdline();

    if (arg_is(1, L"report") && g_argc >= 3) {
        report(g_argv[2]);
        ExitProcess(0);
    }

    if (arg_is(1, L"manifest") && g_argc >= 3) {
        print_manifest(g_argv[2]);
        ExitProcess(0);
    }

    if (arg_is(1, L"create") && g_argc >= 3) {
        int i = 3;
        int nullOut = 0;
        int detached = 0;
        int inheritStdio = 0;
        const wchar_t *stdinText = NULL;

        /* Flags are order-independent so a test can pair --detached with either
         * stdio shape without depending on argument order. */
        for (;;) {
            if (arg_is(i, L"--null-out")) { nullOut = 1; i++; }
            else if (arg_is(i, L"--default")) { i++; }
            else if (arg_is(i, L"--detached")) { detached = 1; i++; }
            else if (arg_is(i, L"--inherit")) { inheritStdio = 1; i++; }
            else if (arg_is(i, L"--stdin")) {
                if (i + 1 >= g_argc) usage_error("probe: --stdin needs the text to feed\n");
                stdinText = g_argv[i + 1];
                i += 2;
            }
            else break;
        }

        /* Letting either win would report a shape the creator never built. */
        if (stdinText && nullOut) usage_error("probe: --stdin cannot be combined with --null-out\n");
        /* --inherit builds the one shape with no STARTF_USESTDHANDLES at all. */
        if (inheritStdio && (stdinText || nullOut)) usage_error("probe: --inherit cannot be combined with --stdin or --null-out\n");

        if (arg_is(i, L"--")) i++;

        ExitProcess((UINT)create(g_argv[2], nullOut, detached, inheritStdio, stdinText, i));
    }

    if (arg_is(1, L"args")) {
        print_args(2);
        ExitProcess(0);
    }

    if (arg_is(1, L"env")) {
        print_env(2);
        ExitProcess(0);
    }

    if (arg_is(1, L"cwd")) {
        print_cwd();
        ExitProcess(0);
    }

    if (arg_is(1, L"echo")) {
        print_join(GetStdHandle(STD_OUTPUT_HANDLE), 2, NULL);
        ExitProcess(0);
    }

    if (arg_is(1, L"echoerr")) {
        print_join(GetStdHandle(STD_OUTPUT_HANDLE), 2, NULL);
        print_join(GetStdHandle(STD_ERROR_HANDLE), 2, " err");
        ExitProcess(0);
    }

    if (arg_is(1, L"exit")) {
        ExitProcess(g_argc >= 3 ? (UINT)parse_uint(g_argv[2]) : 0);
    }

    if (arg_is(1, L"stdin")) {
        do_stdin();
        ExitProcess(0);
    }

    if (arg_is(1, L"wait") && g_argc >= 3) {
        Sleep((DWORD)parse_uint(g_argv[2]));
        ExitProcess(0);
    }

    if (arg_is(1, L"touch") && g_argc >= 3) {
        do_touch(g_argv[2]);
        ExitProcess(0);
    }

    static const wchar_t usage[] =
        L"usage: probe report <file>\n"
        L"       probe manifest <exe>\n"
        L"       probe create <exe> [--null-out|--default] [--detached] [--inherit] [--stdin <text>] [-- args...]\n"
        L"       probe args <arg>...\n"
        L"       probe env [name...] | cwd | echo|echoerr <text...>\n"
        L"       probe exit [code] | stdin | wait <ms> | touch <file>\n";
    DWORD n = 0;
    WriteFile(GetStdHandle(STD_ERROR_HANDLE), usage, (DWORD)(sizeof(usage) - sizeof(wchar_t)), &n, NULL);
    ExitProcess(1);
}
