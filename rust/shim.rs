// SPDX-License-Identifier: MIT
// Scoop shim - Rust implementation

use std::ffi::OsStr;
use std::fs::File;
use std::io::{BufRead, BufReader};
use std::os::windows::ffi::OsStrExt;

use windows_sys::core::BOOL;
use windows_sys::Win32::Foundation::{
    CloseHandle, GetLastError, LocalFree, GENERIC_READ, GENERIC_WRITE, HANDLE,
};
use windows_sys::Win32::Storage::FileSystem::{
    CreateFileW, GetFileType, GetFullPathNameW, WriteFile, FILE_SHARE_MODE, FILE_TYPE_CHAR,
    OPEN_EXISTING,
};
use windows_sys::Win32::System::Console::{
    AttachConsole, FreeConsole, GetStdHandle, SetConsoleCtrlHandler, WriteConsoleW,
    STD_ERROR_HANDLE,
};
use windows_sys::Win32::System::Diagnostics::Debug::{
    FormatMessageW, FORMAT_MESSAGE_FROM_SYSTEM, FORMAT_MESSAGE_IGNORE_INSERTS,
};
use windows_sys::Win32::System::Environment::{ExpandEnvironmentStringsW, SetEnvironmentVariableW};
use windows_sys::Win32::System::JobObjects::{
    AssignProcessToJobObject, CreateJobObjectW, SetInformationJobObject,
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
    JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK,
};
use windows_sys::Win32::System::LibraryLoader::{GetModuleFileNameW, GetModuleHandleW};
use windows_sys::Win32::System::Threading::{
    CreateProcessW, GetExitCodeProcess, GetStartupInfoW, ResumeThread, WaitForSingleObject,
    CREATE_SUSPENDED, INFINITE, PROCESS_INFORMATION, STARTUPINFOW,
};
use windows_sys::Win32::UI::Shell::{
    CommandLineToArgvW, ShellExecuteExW, SEE_MASK_NOCLOSEPROCESS, SHELLEXECUTEINFOW,
};
use windows_sys::Win32::UI::WindowsAndMessaging::SW_SHOW;

const ERROR_ELEVATION_REQUIRED: u32 = 740;
const IMAGE_DOS_SIGNATURE: u16 = 0x5A4D;
const IMAGE_NT_SIGNATURE: u32 = 0x0000_4550;
const IMAGE_SUBSYSTEM_WINDOWS_GUI: u16 = 2;
const ATTACH_PARENT_PROCESS: u32 = 0xFFFF_FFFF;
const JOB_OBJECT_EXTENDED_LIMIT_INFORMATION_CLASS: i32 = 9;
const NULL_HANDLE: HANDLE = std::ptr::null_mut();
const INVALID_HANDLE: HANDLE = -1isize as *mut _;

const FILE_SHARE_READ: FILE_SHARE_MODE = 1;
const FILE_SHARE_WRITE: FILE_SHARE_MODE = 2;

const DIR_PLACEHOLDER: &str = "%~dp0";

struct ShimInfo {
    path: Option<String>,
    args: Vec<String>,
    cwd: Option<String>,
    env_vars: Vec<(String, String)>,
    elevate: bool,
}

unsafe fn write_error_bytes(msg: &[u8]) {
    let h: HANDLE = GetStdHandle(STD_ERROR_HANDLE);
    if h != NULL_HANDLE && h != INVALID_HANDLE {
        let mut written: u32 = 0;
        WriteFile(
            h,
            msg.as_ptr(),
            msg.len() as u32,
            &mut written,
            std::ptr::null_mut(),
        );
    }
}

// WriteConsoleW fails on redirected handles, so route by file type.
unsafe fn write_error_wide(msg: &[u16]) {
    if msg.is_empty() {
        return;
    }
    let h: HANDLE = GetStdHandle(STD_ERROR_HANDLE);
    if h == NULL_HANDLE || h == INVALID_HANDLE {
        return;
    }
    if GetFileType(h) == FILE_TYPE_CHAR {
        let mut written: u32 = 0;
        WriteConsoleW(
            h,
            msg.as_ptr(),
            msg.len() as u32,
            &mut written,
            std::ptr::null_mut(),
        );
        return;
    }
    write_error_bytes(&String::from_utf16_lossy(msg).into_bytes());
}

// System error text follows the OS language.
unsafe fn write_error_sys(err: u32) {
    write_error_bytes(format!(" (error {err}: ").as_bytes());
    let mut buf = [0u16; 256];
    let n = FormatMessageW(
        FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS | 255,
        std::ptr::null(),
        err,
        0,
        buf.as_mut_ptr(),
        buf.len() as u32,
        std::ptr::null(),
    );
    if n > 0 {
        let msg = &buf[..n as usize];
        let end = msg
            .iter()
            .rposition(|c| !matches!(*c, 0x20 | 0x09 | 0x0D | 0x0A))
            .map_or(0, |i| i + 1);
        write_error_wide(&msg[..end]);
    }
    write_error_bytes(b").\n");
}

unsafe fn write_error_ctx(context: &str, err: u32) {
    write_error_wide(&to_wide(&format!("Shim: {context}")));
    write_error_sys(err);
}

fn to_wide_null(s: &str) -> Vec<u16> {
    OsStr::new(s)
        .encode_wide()
        .chain(std::iter::once(0))
        .collect()
}

fn to_wide(s: &str) -> Vec<u16> {
    OsStr::new(s).encode_wide().collect()
}

fn get_shim_dir() -> String {
    unsafe {
        let mut buf = [0u16; 261];
        let len = GetModuleFileNameW(GetModuleHandleW(std::ptr::null()), buf.as_mut_ptr(), 260);
        if len == 0 || len >= 260 {
            return String::new();
        }
        let path = String::from_utf16_lossy(&buf[..len as usize]);
        match path.rfind(['\\', '/']) {
            Some(pos) => path[..pos].to_string(),
            None => path,
        }
    }
}

fn get_shim_path() -> Option<String> {
    unsafe {
        let mut buf = [0u16; 261];
        let len = GetModuleFileNameW(GetModuleHandleW(std::ptr::null()), buf.as_mut_ptr(), 260);
        if len == 0 {
            write_error_ctx(
                "The filename of the program could not be determined",
                GetLastError(),
            );
            return None;
        }
        if len >= 260 {
            write_error_wide(&to_wide(&format!(
                "Shim: The filename of the program is too long to handle: '{}'.\n",
                String::from_utf16_lossy(&buf[..len as usize])
            )));
            return None;
        }
        let mut path = String::from_utf16_lossy(&buf[..len as usize]);
        match path.rfind('.') {
            Some(dot) => {
                path.truncate(dot);
                path.push_str(".shim");
            }
            None => path.push_str(".shim"),
        }
        Some(path)
    }
}

// PE headers are read directly - no image-helper dependency in windows-sys.
unsafe fn is_gui_subsystem() -> bool {
    let h = GetModuleHandleW(std::ptr::null());
    if h == NULL_HANDLE {
        return false;
    }
    let base = h as *const u8;

    let dos_sig = *(base as *const u16);
    if dos_sig != IMAGE_DOS_SIGNATURE {
        return false;
    }

    let pe_offset = *(base.add(0x3C) as *const i32);
    let pe_base = base.offset(pe_offset as isize);

    let nt_sig = *(pe_base as *const u32);
    if nt_sig != IMAGE_NT_SIGNATURE {
        return false;
    }

    let subsystem = *(pe_base.add(0x5C) as *const u16);
    subsystem == IMAGE_SUBSYSTEM_WINDOWS_GUI
}

fn parse_bool(value: &str) -> bool {
    matches!(
        value.trim().to_ascii_lowercase().as_str(),
        "true" | "1" | "yes"
    )
}

// Unknown %VAR% is preserved as-is, matching Win32 semantics.
fn expand_env_vars(input: &str) -> String {
    if input.is_empty() {
        return String::new();
    }
    let wide = to_wide_null(input);
    unsafe {
        // First call gets the required size, second expands.
        let required = ExpandEnvironmentStringsW(wide.as_ptr(), std::ptr::null_mut(), 0);
        if required == 0 {
            return input.to_string();
        }

        let mut buf = vec![0u16; required as usize];
        let actual = ExpandEnvironmentStringsW(wide.as_ptr(), buf.as_mut_ptr(), required);
        if actual == 0 || actual > required {
            return input.to_string();
        }

        String::from_utf16_lossy(&buf[..actual as usize - 1])
    }
}

fn normalize_args_str(args: &mut String, cur_dir: &str) {
    if let Some(pos) = args.find(DIR_PLACEHOLDER) {
        let mut replacement = cur_dir.to_string();
        if !replacement.ends_with('\\') && !replacement.ends_with('/') {
            replacement.push('\\');
        }
        args.replace_range(pos..pos + DIR_PLACEHOLDER.len(), &replacement);
    }
}

// Quotes in .shim values are structural markers, not literal content.
fn expand_and_strip_quotes(value: &str) -> String {
    let mut result = expand_env_vars(value);
    if result.len() >= 2 && result.starts_with('"') && result.ends_with('"') {
        result = result[1..result.len() - 1].to_string();
    }
    result
}

fn parse_shim_line(line: &str) -> Option<(String, String)> {
    let line = line.trim_end();

    let trimmed = line.trim_start();
    if trimmed.is_empty()
        || trimmed.starts_with('#')
        || trimmed.starts_with(';')
        || trimmed.starts_with("//")
    {
        return None;
    }

    let sep_pos = line.find(" = ")?;
    let key = line[..sep_pos].trim();
    if key.is_empty() {
        return None;
    }
    let value = line[sep_pos + 3..].trim_start();
    Some((key.to_string(), value.to_string()))
}

fn parse_args_from_cmdline(cmdline: &str) -> Vec<String> {
    if cmdline.is_empty() {
        return Vec::new();
    }
    let wide = to_wide_null(cmdline);
    unsafe {
        let mut argc: i32 = 0;
        let argv = CommandLineToArgvW(wide.as_ptr(), &mut argc);
        if argv.is_null() {
            return Vec::new();
        }
        let mut result = Vec::with_capacity(argc as usize);
        for i in 0..argc as isize {
            let ptr = *argv.offset(i);
            if !ptr.is_null() {
                let mut len = 0usize;
                while *ptr.add(len) != 0 {
                    len += 1;
                }
                let slice = std::slice::from_raw_parts(ptr, len);
                result.push(String::from_utf16_lossy(slice));
            }
        }
        LocalFree(argv as *mut _);
        result
    }
}

// Returns the directory portion (trailing backslash) of the absolute form of `path`.
fn resolve_against_base(path: &str, base_dir: &str) -> String {
    let wide_path = to_wide_null(path);
    let wide_base = to_wide_null(base_dir);
    unsafe {
        let path_bytes = path.as_bytes();
        let is_absolute = (path_bytes.len() >= 2 && path_bytes[1] == b':')
            || (!path_bytes.is_empty() && path_bytes[0] == b'\\');

        let to_resolve = if is_absolute {
            wide_path
        } else {
            let mut combined: Vec<u16> = Vec::new();
            combined.extend_from_slice(&wide_base[..wide_base.len() - 1]);
            combined.push(b'\\' as u16);
            combined.extend_from_slice(&wide_path[..wide_path.len() - 1]);
            combined.push(0);
            combined
        };

        let mut resolved = [0u16; 261];
        let mut file_part: *mut u16 = std::ptr::null_mut();
        let len = GetFullPathNameW(
            to_resolve.as_ptr(),
            resolved.len() as u32,
            resolved.as_mut_ptr(),
            &mut file_part,
        );
        if len == 0 || len as usize >= resolved.len() {
            let mut fallback = String::from_utf16_lossy(&to_resolve[..to_resolve.len() - 1]);
            fallback.push('\\');
            return fallback;
        }

        let dir_len = if !file_part.is_null() {
            (file_part as usize - resolved.as_ptr() as usize) / 2
        } else {
            len as usize
        };

        if dir_len > 0
            && (resolved[dir_len - 1] == b'\\' as u16 || resolved[dir_len - 1] == b'/' as u16)
        {
            return String::from_utf16_lossy(&resolved[..dir_len]);
        }
        let mut result = String::from_utf16_lossy(&resolved[..dir_len]);
        result.push('\\');
        result
    }
}

// Windows CreateProcessW argument quoting rules.
fn quote_arg(arg: &str) -> String {
    if arg.is_empty() {
        return "\"\"".to_string();
    }

    let needs_quoting = arg.bytes().any(|c| c == b' ' || c == b'\t' || c == b'"');
    if !needs_quoting {
        return arg.to_string();
    }

    let mut result = String::with_capacity(arg.len() + 8);
    result.push('"');

    let mut i = 0;
    while i < arg.len() {
        let ch = arg[i..].chars().next().unwrap();
        if ch == '\\' {
            let bs_start = i;
            while i < arg.len() && arg.as_bytes()[i] == b'\\' {
                i += 1;
            }
            let count = i - bs_start;
            if i == arg.len() {
                result.extend(std::iter::repeat('\\').take(count * 2));
            } else if arg.as_bytes()[i] == b'"' {
                result.extend(std::iter::repeat('\\').take(count * 2 + 1));
                result.push('"');
                i += 1;
            } else {
                result.extend(std::iter::repeat('\\').take(count));
            }
        } else if ch == '"' {
            result.push_str("\\\"");
            i += 1;
        } else {
            result.push(ch);
            i += ch.len_utf8();
        }
    }

    result.push('"');
    result
}

// GUI/redirected launches can yield null or INVALID std handles.
unsafe fn ensure_standard_handles(si: &mut STARTUPINFOW) {
    let conin = to_wide_null("CONIN$");
    let conout = to_wide_null("CONOUT$");

    if si.hStdInput == NULL_HANDLE || si.hStdInput == INVALID_HANDLE {
        let h: HANDLE = CreateFileW(
            conin.as_ptr(),
            GENERIC_READ,
            FILE_SHARE_READ,
            std::ptr::null(),
            OPEN_EXISTING,
            0,
            NULL_HANDLE,
        );
        si.hStdInput = if h == INVALID_HANDLE { NULL_HANDLE } else { h };
    }

    if si.hStdOutput == NULL_HANDLE || si.hStdOutput == INVALID_HANDLE {
        let h: HANDLE = CreateFileW(
            conout.as_ptr(),
            GENERIC_WRITE,
            FILE_SHARE_WRITE,
            std::ptr::null(),
            OPEN_EXISTING,
            0,
            NULL_HANDLE,
        );
        si.hStdOutput = if h == INVALID_HANDLE { NULL_HANDLE } else { h };
    }

    if si.hStdError == NULL_HANDLE || si.hStdError == INVALID_HANDLE {
        let h: HANDLE = CreateFileW(
            conout.as_ptr(),
            GENERIC_WRITE,
            FILE_SHARE_WRITE,
            std::ptr::null(),
            OPEN_EXISTING,
            0,
            NULL_HANDLE,
        );
        si.hStdError = if h == INVALID_HANDLE { NULL_HANDLE } else { h };
    }
}

fn parse_shim_info(cur_dir: &str) -> ShimInfo {
    let mut info = ShimInfo {
        path: None,
        args: Vec::new(),
        cwd: None,
        env_vars: Vec::new(),
        elevate: false,
    };

    let shim_path = match get_shim_path() {
        Some(p) => p,
        None => return info,
    };

    let file = match File::open(&shim_path) {
        Ok(f) => f,
        Err(e) => {
            let err = e.raw_os_error().unwrap_or(0) as u32;
            unsafe {
                write_error_wide(&to_wide(&format!(
                    "Shim: Cannot open shim file for read: '{}'",
                    shim_path
                )));
                write_error_sys(err);
            }
            return info;
        }
    };

    let reader = BufReader::new(file);

    let all_lines: Vec<String> = reader
        .lines()
        .filter_map(|l| l.ok())
        .map(|l| l.trim_start_matches('\u{feff}').to_string())
        .collect();

    // %~dp0 means the *target* exe directory, not the shim's own. Pass 1 resolves
    // path to absolute so pass 2 can expand %~dp0 against the right base.
    let mut target_dir = cur_dir.to_string();
    for line in &all_lines {
        if let Some((key, value)) = parse_shim_line(line) {
            if key != "path" {
                continue;
            }
            let expanded = expand_and_strip_quotes(&value);
            target_dir = resolve_against_base(&expanded, cur_dir);
            break;
        }
    }

    for line in &all_lines {
        let Some((key, value)) = parse_shim_line(line) else {
            continue;
        };

        match key.as_str() {
            "path" => {
                info.path = Some(expand_and_strip_quotes(&value));
            }
            "args" => {
                let mut args_str = value.to_string();
                normalize_args_str(&mut args_str, &target_dir);
                if !args_str.is_empty() {
                    info.args = parse_args_from_cmdline(&args_str);
                }
            }
            "cwd" | "workdir" => {
                let mut cwd_str = value.to_string();
                normalize_args_str(&mut cwd_str, &target_dir);
                info.cwd = Some(expand_and_strip_quotes(&cwd_str));
            }
            "elevate" | "runas" => {
                info.elevate = parse_bool(&value);
            }
            _ => {
                info.env_vars
                    .push((key.to_string(), expand_and_strip_quotes(&value)));
            }
        }
    }

    if info.path.is_none() {
        unsafe {
            write_error_wide(&to_wide(&format!(
                "Shim: 'path' not found in shim file '{}'.\n",
                shim_path
            )));
        }
    }

    info
}

unsafe fn launch_elevated(
    path_w: &[u16],
    params: &[u16],
    cwd_ptr: *const u16,
    job_handle: HANDLE,
) -> (HANDLE, HANDLE) {
    let runas = to_wide_null("runas");
    let mut sei: SHELLEXECUTEINFOW = std::mem::zeroed();
    sei.cbSize = std::mem::size_of::<SHELLEXECUTEINFOW>() as u32;
    sei.fMask = SEE_MASK_NOCLOSEPROCESS;
    sei.lpFile = path_w.as_ptr();
    sei.lpParameters = if params.len() <= 1 {
        std::ptr::null()
    } else {
        params.as_ptr()
    };
    sei.lpDirectory = cwd_ptr;
    sei.lpVerb = runas.as_ptr();
    sei.nShow = SW_SHOW;

    if ShellExecuteExW(&mut sei) == 0 {
        // On failure hInstApp holds an SE_ERR_* value (<=32); otherwise use GetLastError.
        let mut err = match sei.hInstApp as isize {
            0..=32 => sei.hInstApp as isize as u32,
            _ => 0,
        };
        if err == 0 {
            err = GetLastError();
        }
        if err == 0 {
            err = 1;
        }
        write_error_ctx("Unable to create elevated process", err);
        return (NULL_HANDLE, NULL_HANDLE);
    }

    let proc_handle: HANDLE = sei.hProcess;
    if job_handle != NULL_HANDLE && proc_handle != NULL_HANDLE {
        AssignProcessToJobObject(job_handle, proc_handle);
    }

    (proc_handle, NULL_HANDLE)
}

unsafe fn make_process(info: &ShimInfo, job_handle: HANDLE) -> (HANDLE, HANDLE) {
    let path = match &info.path {
        Some(p) => p,
        None => return (NULL_HANDLE, NULL_HANDLE),
    };

    // Child inherits the updated environment block, hence before CreateProcessW.
    for (key, value) in &info.env_vars {
        let key_w = to_wide_null(key);
        let value_w = to_wide_null(value);
        if SetEnvironmentVariableW(key_w.as_ptr(), value_w.as_ptr()) == 0 {
            let err = GetLastError();
            unsafe {
                write_error_wide(&to_wide(&format!(
                    "Shim: Could not set environment variable '{key}'"
                )));
                write_error_sys(err);
            }
        }
    }

    let cmd_str = {
        let mut c = quote_arg(path);
        for arg in &info.args {
            c.push(' ');
            c.push_str(&quote_arg(arg));
        }
        c
    };
    let mut cmd = to_wide_null(&cmd_str);
    // No exe prefix - ShellExecuteExW takes parameters separately from the file.
    let params = {
        let mut p = String::new();
        for (i, arg) in info.args.iter().enumerate() {
            if i > 0 {
                p.push(' ');
            }
            p.push_str(&quote_arg(arg));
        }
        to_wide_null(&p)
    };
    let path_w = to_wide_null(path);

    let mut si: STARTUPINFOW = std::mem::zeroed();
    si.cb = std::mem::size_of::<STARTUPINFOW>() as u32;
    GetStartupInfoW(&mut si);
    ensure_standard_handles(&mut si);

    let cwd_w = info.cwd.as_ref().map(|c| to_wide_null(c));
    let cwd_ptr = match &cwd_w {
        Some(cwd) => cwd.as_ptr(),
        None => std::ptr::null(),
    };

    if info.elevate {
        return launch_elevated(path_w.as_slice(), params.as_slice(), cwd_ptr, job_handle);
    }

    // SUSPENDED: the child must join the job object before it can spawn its own children.
    let mut pi: PROCESS_INFORMATION = std::mem::zeroed();

    if CreateProcessW(
        std::ptr::null(),
        cmd.as_mut_ptr(),
        std::ptr::null(),
        std::ptr::null(),
        1,
        CREATE_SUSPENDED,
        std::ptr::null(),
        cwd_ptr,
        &mut si,
        &mut pi,
    ) != 0
    {
        if job_handle != NULL_HANDLE {
            AssignProcessToJobObject(job_handle, pi.hProcess);
        }
        ResumeThread(pi.hThread);
        return (pi.hProcess, pi.hThread);
    }

    // Target manifest requires elevation: retry through ShellExecuteExW.
    let err = GetLastError();
    if err == ERROR_ELEVATION_REQUIRED {
        return launch_elevated(path_w.as_slice(), params.as_slice(), cwd_ptr, job_handle);
    }

    write_error_ctx(
        &format!("Could not create process with command '{cmd_str}'"),
        err,
    );
    (NULL_HANDLE, NULL_HANDLE)
}

// Swallow the known console control events so only the child handles them.
unsafe extern "system" fn ctrl_handler(ctrl_type: u32) -> BOOL {
    match ctrl_type {
        0 | 1 | 2 | 5 | 6 => 1,
        _ => 0,
    }
}

fn main() {
    let cur_dir = get_shim_dir();
    let mut info = parse_shim_info(&cur_dir);

    if info.path.is_none() {
        std::process::exit(1);
    }

    let user_args: Vec<String> = std::env::args_os()
        .skip(1)
        .map(|a| a.to_string_lossy().into_owned())
        .collect();
    let has_user_args = !user_args.is_empty();

    for arg_str in user_args {
        info.args.push(arg_str);
    }

    // A GUI-subsystem shim would flash a console; with args it behaves as a CLI
    // tool, so it re-attaches to the parent console for output.
    let is_gui = unsafe { is_gui_subsystem() };
    if is_gui {
        if has_user_args || !info.args.is_empty() {
            unsafe {
                AttachConsole(ATTACH_PARENT_PROCESS);
            }
        } else {
            unsafe {
                FreeConsole();
            }
        }
    }

    // KILL_ON_JOB_CLOSE ties child lifetime to the shim.
    let job_handle: HANDLE = unsafe { CreateJobObjectW(std::ptr::null(), std::ptr::null()) };

    if job_handle != NULL_HANDLE {
        unsafe {
            let mut jeli: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std::mem::zeroed();
            jeli.BasicLimitInformation.LimitFlags =
                JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK;
            SetInformationJobObject(
                job_handle,
                JOB_OBJECT_EXTENDED_LIMIT_INFORMATION_CLASS,
                &jeli as *const _ as *const _,
                std::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
            );
        }
    }

    // Before spawn: a Ctrl event in the gap would kill the shim and
    // KILL_ON_JOB_CLOSE would take the child down with it.
    unsafe {
        SetConsoleCtrlHandler(Some(ctrl_handler), 1);
    }

    let (process_handle, thread_handle) = unsafe { make_process(&info, job_handle) };

    if process_handle == NULL_HANDLE {
        std::process::exit(1);
    }

    unsafe {
        WaitForSingleObject(process_handle, INFINITE);

        let mut exit_code: u32 = 1;
        GetExitCodeProcess(process_handle, &mut exit_code);

        if thread_handle != NULL_HANDLE {
            CloseHandle(thread_handle);
        }
        CloseHandle(process_handle);
        if job_handle != NULL_HANDLE {
            CloseHandle(job_handle);
        }

        std::process::exit(exit_code as i32);
    }
}
