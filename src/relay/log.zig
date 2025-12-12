const std = @import("std");

const ActiveLog = enum {
    local,
    system,
};

var logging_enabled: bool = true;
var local_log_file: ?std.fs.File = null;
var system_log_file: ?std.fs.File = null;

fn writeToFileBackend(
    active_log: ActiveLog,
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime fmt: []const u8,
    args: anytype,
) void {
    // Select active file pointer (optional)
    const file = switch (active_log) {
        .system => system_log_file,
        .local => local_log_file,
    };

    // If there is no active file, bail
    if (file) |*f| {
        var buf: [256]u8 = undefined;

        // Check log file size, truncate if too large
        const max_size: u64 = 10 * 1024 * 1024; // 10 MiB
        const size = f.getEndPos() catch return;
        if (size > max_size) {
            f.setEndPos(0) catch {};
        }

        // Prefix: timestamp
        const ts = std.time.milliTimestamp();
        const prefix = std.fmt.bufPrint(&buf, "[{d}]", .{ts}) catch return;
        var used: usize = prefix.len;

        // Prefix: scope
        var scope_buf: [32]u8 = undefined;
        const scope_name = @tagName(scope); // e.g. "App"
        const scope_upper = std.ascii.upperString(&scope_buf, scope_name);
        const scope_prefix = std.fmt.bufPrint(buf[used..], "[{s}]", .{scope_upper}) catch return;
        used += scope_prefix.len;

        // Prefix: level
        const level_str = switch (level) {
            .debug => "DBG",
            .info => "INF",
            .warn => "WRN",
            .err => "ERR",
        };

        const level_prefix = std.fmt.bufPrint(buf[used..], "[{s}]: ", .{level_str}) catch return;
        used += level_prefix.len;

        // Message body
        const msg_slice = std.fmt.bufPrint(buf[used..], fmt, args) catch return;
        used += msg_slice.len;

        // Write full line
        f.writeAll(buf[0..used]) catch return;
        f.writeAll("\n") catch {};
    }
}

/// Helper function to log messages to user and system log files.
pub fn local(comptime level: std.log.Level, comptime fmt: []const u8, args: anytype) void {
    if (!logging_enabled) {
        return;
    }

    writeToFileBackend(.local, level, .App, fmt, args);
}

/// Helper function to log messages to user and system log files.
pub fn system(comptime level: std.log.Level, comptime fmt: []const u8, args: anytype) void {
    if (!logging_enabled) {
        return;
    }

    writeToFileBackend(.system, level, .App, fmt, args);
}

/// Setup local log file
pub fn ensureLocalLog(allocator: std.mem.Allocator, user_dir: []const u8) !void {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    logging_enabled = !(args.len > 1 and std.mem.eql(u8, args[1], "--no-log"));

    // Setup logging
    if (logging_enabled) {
        const local_log_path = try std.fs.path.join(allocator, &.{ user_dir, "run.log" });
        defer allocator.free(local_log_path);
        local_log_file = try std.fs.createFileAbsolute(local_log_path, .{
            .truncate = false,
        });
    }
}

/// Setup system log file
pub fn ensureSystemLog(allocator: std.mem.Allocator, sys_dir: []const u8) !void {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    logging_enabled = !(args.len > 1 and std.mem.eql(u8, args[1], "--no-log"));

    // Setup logging
    if (logging_enabled) {
        const system_log_path = try std.fs.path.join(allocator, &.{ sys_dir, "run.log" });
        defer allocator.free(system_log_path);
        system_log_file = try std.fs.createFileAbsolute(system_log_path, .{
            .truncate = false,
        });
    }
}
