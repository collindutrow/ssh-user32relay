const std = @import("std");
const win32 = @import("win32");
const log = @import("log.zig");
const process = @import("process.zig");

const foundation = win32.foundation;
const threading = win32.system.threading;
const security = win32.security;
const console = win32.system.console;
const user32 = win32.ui.windows_and_messaging;

const app_dir_name = "ssh-user32relay";
const win32_false: i32 = 0;

const Token = struct {
    value: []const u8,
    span: usize, // size of full token, including quotes
    start_idx: usize, // start index (including quotes)
    end_idx: usize, // end index (excluding quotes)
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Check if process is elevated
    process.is_elevated = try process.isProcessElevated();

    // Enforce single instance
    enforceSingleton(allocator) catch {
        std.process.exit(0);
    };

    // Free console if attached
    _ = console.FreeConsole();

    // Get environment variables
    const appdata = try getEnvOwned(allocator, "APPDATA");
    defer allocator.free(appdata);

    const program_data = try getEnvOwned(allocator, "PROGRAMDATA");
    defer allocator.free(program_data);

    // Declare and ensure local user monitor directories
    const user_dir = try std.fs.path.join(allocator, &.{ appdata, app_dir_name });
    defer allocator.free(user_dir);
    try ensureDir(user_dir);

    // Ensure local log file
    try log.ensureLocalLog(allocator, user_dir);

    // Prepare local run.txt paths
    const user_run_path = try std.fs.path.join(allocator, &.{ user_dir, "run.txt" });
    defer allocator.free(user_run_path);

    // Declare and ensure system-wide monitor directories
    var sys_run_path: []const u8 = &.{};
    if (process.is_elevated) {
        const sys_dir = try std.fs.path.join(allocator, &.{ program_data, app_dir_name });
        defer allocator.free(sys_dir);
        try ensureDir(sys_dir);

        // Ensure log files
        try log.ensureSystemLog(allocator, sys_dir);

        // Prepare system run.txt path
        sys_run_path = try std.fs.path.join(allocator, &.{ sys_dir, "run.txt" });
        defer allocator.free(sys_run_path);
    }

    // Loop delay: X seconds
    const loop_delay = std.time.ns_per_s * 5;

    // Main loop
    while (true) {
        processRunFile(allocator, user_run_path, false) catch {};

        if (process.is_elevated) {
            processRunFile(allocator, sys_run_path, true) catch {};
        }
        std.Thread.sleep(loop_delay);
    }
}

/// Enforce single instance using a named mutex. Exits process if another instance is running.
fn enforceSingleton(allocator: std.mem.Allocator) !void {
    const mutex_name = "Global\\ssh-user32-relay-mutex";
    const name_w = try utf8ToWideNul(allocator, mutex_name);
    defer allocator.free(name_w);

    const handle = threading.CreateMutexW(
        null,
        win32_false,
        name_w.ptr,
    );
    if (handle == null) {
        return error.MutexCreateFailed;
    }

    const err = foundation.GetLastError();
    switch (err) {
        .NO_ERROR => {},
        .ERROR_ALREADY_EXISTS => {
            std.process.exit(0);
        },
        else => {
            std.process.exit(0);
        },
    }
}

/// Returns owned buffer containing value of environment variable `name` or error.MissingEnv
fn getEnvOwned(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const env_var = try std.process.getEnvVarOwned(allocator, name);

    return if (env_var.len == 0)
        error.MissingEnv
    else
        env_var;
}

/// Create directory if doesn't exist, no-op already exists.
fn ensureDir(path: []const u8) !void {
    // Create directory if it doesn't exist
    var cwd = std.fs.cwd();
    cwd.makePath(path) catch |err| switch (err) {
        error.PathAlreadyExists => return,
        else => return err,
    };
}

/// Process commands listed in run file, spawning them as elevated or unelevated.
fn processRunFile(
    allocator: std.mem.Allocator,
    run_path: []const u8,
    run_elevated: bool,
) !void {
    const cwd = std.fs.cwd();

    // Check if file exists
    const stat = cwd.statFile(run_path) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };

    // Refuse to read files larger than 1 MiB
    if (stat.size > 1024 * 1024) {
        std.fs.deleteFileAbsolute(run_path) catch {};
        return;
    }

    // Open file for reading and writing
    var file = try std.fs.openFileAbsolute(run_path, .{ .mode = .read_write });
    defer file.close();

    // Read entire file content
    const data = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(data);

    // Process each non-empty line
    var it = std.mem.tokenizeAny(u8, data, "\r\n");
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t");

        // Skip empty lines
        if (line.len == 0) {
            continue;
        }

        // Spawn command line depending on elevation flag
        if (run_elevated) {
            _ = spawnCmdLine(allocator, line) catch {};
        } else {
            if (process.is_elevated) {
                // If current process is elevated, spawn unelevated
                _ = spawnUnelevatedCmdLine(allocator, line) catch {};
            } else {
                // If current process is unelevated, spawn normally
                // spawnUnelevatedCmdLine would fail here because we can't get shell process
                _ = spawnCmdLine(allocator, line) catch {};
            }
        }
    }

    // Truncate file to zero length and if this fails, log and hard-exit
    // Otherwise, on next loop iteration, we might try to read same commands again
    file.setEndPos(0) catch |err| {
        // Log and hard-exit; nothing returns
        if (run_elevated) {
            log.system(.err, "Failed to truncate run file '{s}': {s}", .{ run_path, @errorName(err) });
        } else {
            log.local(.err, "Failed to truncate run file '{s}': {s}", .{ run_path, @errorName(err) });
        }
        std.process.exit(1);
    };
}

/// Parse first token from line, handling quoted and unquoted tokens.
pub fn parseFirstToken(line: []const u8) Token {
    if (line.len == 0) {
        return .{
            .value = line[0..0],
            .span = 0,
            .start_idx = 0,
            .end_idx = 0,
        };
    }

    const first_char: u8 = line[0];

    // Handle quoted token
    if (first_char == '"' or first_char == '\'') {
        const quote_char: u8 = first_char;
        var i: usize = 1;

        // Scan until closing quote or end
        while (i < line.len and line[i] != quote_char) : (i += 1) {}

        const start_idx: usize = 0;
        const end_idx: usize = i;

        // Compute span including closing quote if present
        const span: usize = if (i < line.len and line[i] == quote_char)
            (i + 1) - start_idx
        else
            i - start_idx;

        return .{
            .value = line[1..end_idx],
            .span = span,
            .start_idx = start_idx,
            .end_idx = end_idx,
        };
    }

    // Handle unquoted token
    var i: usize = 0;
    while (i < line.len and line[i] != ' ' and line[i] != '\t') : (i += 1) {}

    return .{
        .value = line[0..i],
        .span = i,
        .start_idx = 0,
        .end_idx = i,
    };
}

/// Spawn command line with same elevation as current process.
fn spawnCmdLine(allocator: std.mem.Allocator, line: []const u8) !void {
    // Build command line command
    var builder: std.ArrayList(u8) = .empty;
    defer builder.deinit(allocator);

    // First token of line is desired working directory
    const workdir_token = parseFirstToken(line);
    var workdir: []const u8 = undefined;
    if (workdir_token.value.len == 0) {
        const cwd = try std.process.getCwdAlloc(allocator);
        workdir = cwd;
    } else {
        workdir = workdir_token.value;
    }
    const workdir_w = try utf8ToWideNul(allocator, workdir);
    const line_remainder = std.mem.trim(u8, line[workdir_token.start_idx + workdir_token.span ..], " \t");

    try builder.appendSlice(allocator, "cmd.exe /C start \"\" /B ");
    try builder.appendSlice(allocator, line_remainder);

    const cmdline_w = try utf8ToWideNul(allocator, builder.items);
    defer allocator.free(cmdline_w);

    var si: threading.STARTUPINFOW = std.mem.zeroes(threading.STARTUPINFOW);
    si.cb = @sizeOf(threading.STARTUPINFOW);

    var pi: threading.PROCESS_INFORMATION = undefined;

    // Create elevated process
    const ok = threading.CreateProcessW(
        null, // lpApplicationName
        cmdline_w.ptr, // lpCommandLine
        null, // lpProcessAttributes
        null, // lpThreadAttributes
        win32_false, // bInheritHandles
        .{}, // dwCreationFlags
        null, // lpEnvironment
        workdir_w.ptr, // lpCurrentDirectory
        &si, // lpStartupInfo
        &pi, // lpProcessInformation
    );

    if (ok == win32_false) {
        log.system(.err, "{s} ... working_dir: {s}", .{ line_remainder, workdir });
        const err = foundation.GetLastError();
        log.system(.err, "CreateProcessW Error: {d}", .{@intFromEnum(err)});
        return error.CreateProcessFailed;
    } else {
        log.system(.info, "{s} ... working_dir: {s}", .{ line_remainder, workdir });
    }

    // Close handles immediately as we don't need them
    _ = foundation.CloseHandle(pi.hProcess);
    _ = foundation.CloseHandle(pi.hThread);
}

/// Spawn command line as unelevated process.
fn spawnUnelevatedCmdLine(allocator: std.mem.Allocator, line: []const u8) !void {
    // Get shell window handle
    const shell_hwnd = user32.GetShellWindow();
    if (shell_hwnd == null) {
        return error.ShellNotFound;
    }

    // Get shell process ID
    var shell_pid: u32 = 0;
    _ = user32.GetWindowThreadProcessId(shell_hwnd.?, &shell_pid);
    if (shell_pid == 0) {
        return error.ShellNotFound;
    }

    // Access rights for OpenProcess
    const access = threading.PROCESS_ACCESS_RIGHTS{
        .QUERY_LIMITED_INFORMATION = 1,
    };

    // Open shell process
    const shell_proc = threading.OpenProcess(
        access,
        win32_false,
        shell_pid,
    );

    if (shell_proc == null) {
        return error.OpenProcessFailed;
    }
    defer _ = foundation.CloseHandle(shell_proc.?);

    // Access mask for OpenProcessToken
    const desired_access = security.TOKEN_ACCESS_MASK{
        .DUPLICATE = 1,
        .ASSIGN_PRIMARY = 1,
        .QUERY = 1,
    };

    // Open shell process token
    var shell_token: ?foundation.HANDLE = null;
    if (threading.OpenProcessToken(
        shell_proc.?,
        desired_access,
        &shell_token,
    ) == win32_false) {
        return error.OpenProcessTokenFailed;
    }

    if (threading.OpenProcessToken(
        shell_proc.?,
        desired_access,
        &shell_token,
    ) == win32_false) {
        return error.OpenProcessTokenFailed;
    }
    defer _ = foundation.CloseHandle(shell_token);

    // Duplicate token for use in CreateProcessWithTokenW
    var new_token: ?foundation.HANDLE = null;
    const desired_dup = @as(security.TOKEN_ACCESS_MASK, @bitCast(@as(u32, 0x02000000)));

    if (security.DuplicateTokenEx(
        shell_token,
        desired_dup,
        null,
        security.SECURITY_IMPERSONATION_LEVEL.Impersonation,
        security.TOKEN_TYPE.Primary,
        &new_token,
    ) == win32_false) {
        return error.DuplicateTokenFailed;
    }
    defer _ = foundation.CloseHandle(new_token);

    // First token of line is desired working directory
    const workdir_token = parseFirstToken(line);
    var workdir: []const u8 = undefined;
    if (workdir_token.value.len == 0) {
        const cwd = try std.process.getCwdAlloc(allocator);
        workdir = cwd;
    } else {
        workdir = workdir_token.value;
    }
    const workdir_w = try utf8ToWideNul(allocator, workdir);
    const line_remainder = std.mem.trim(u8, line[workdir_token.start_idx + workdir_token.span ..], " \t");

    // Build command line command
    var builder: std.ArrayList(u8) = .empty;
    defer builder.deinit(allocator);

    try builder.appendSlice(allocator, "cmd.exe /C start \"\" /B ");
    try builder.appendSlice(allocator, line_remainder);

    const cmdline_w = try utf8ToWideNul(allocator, builder.items);
    defer allocator.free(cmdline_w);

    var si: threading.STARTUPINFOW = std.mem.zeroes(threading.STARTUPINFOW);
    si.cb = @sizeOf(threading.STARTUPINFOW);

    var pi: threading.PROCESS_INFORMATION = undefined;

    // Create process with duplicated unelevated token
    const ok = threading.CreateProcessWithTokenW(
        new_token, // hToken
        threading.CREATE_PROCESS_LOGON_FLAGS.WITH_PROFILE, // dwLogonFlags
        null, // lpApplicationName
        cmdline_w.ptr, // lpCommandLine
        0, // dwCreationFlags
        null, // lpEnvironment
        workdir_w.ptr, // lpCurrentDirectory   ← supply working directory here
        &si, // lpStartupInfo
        &pi, // lpProcessInformation
    );

    if (ok == win32_false) {
        log.local(.err, "{s} ... working_dir: {s}", .{ line_remainder, workdir });
        const err = foundation.GetLastError();
        log.local(.err, "CreateProcessWithTokenW Error: {d}", .{@intFromEnum(err)});
        return error.CreateProcessFailed;
    } else {
        log.local(.info, "{s} ... working_dir: {s}", .{ line_remainder, workdir });
    }

    // Close handles immediately as we don't need them
    _ = foundation.CloseHandle(pi.hProcess);
    _ = foundation.CloseHandle(pi.hThread);
}

/// Build command line to run cmd.exe /C <line>
fn buildCmdExeCmdlineWide(allocator: std.mem.Allocator, line: []const u8) ![]u16 {
    var builder = std.ArrayList(u8).init(allocator);
    defer builder.deinit();

    try builder.appendSlice("cmd.exe /C ");
    try builder.appendSlice(line);

    return try utf8ToWideNul(allocator, builder.items);
}

/// Convert UTF-8 string to UTF-16 with trailing NUL sentinel.
pub fn utf8ToWideNul(allocator: std.mem.Allocator, utf8: []const u8) ![:0]u16 {
    // Convert UTF-8 -> UTF-16 (no sentinel)
    const utf16 = try std.unicode.utf8ToUtf16LeAlloc(allocator, utf8);
    defer allocator.free(utf16);

    // Allocate UTF-16 with trailing NUL sentinel
    const out = try allocator.allocSentinel(u16, utf16.len, 0);

    // Copy and return
    std.mem.copyForwards(u16, out[0..utf16.len], utf16);
    return out;
}
