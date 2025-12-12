const std = @import("std");
const clap = @import("clap");
const process = @import("process.zig");

const USER_ENV_VAR: []const u8 = "APPDATA";
const SYSTEM_ENV_VAR: []const u8 = "PROGRAMDATA";

// Example relative paths; replace with desired layout.
const USER_FILE_REL_PATH: []const u8 = "ssh-user32relay\\run.txt";
const SYSTEM_FILE_REL_PATH: []const u8 = "ssh-user32relay\\run.txt";

fn buildPathFromEnv(
    allocator: std.mem.Allocator,
    env_name: []const u8,
    rel_path: []const u8,
) ![]u8 {
    const base = try std.process.getEnvVarOwned(allocator, env_name);
    defer allocator.free(base);

    return try std.fs.path.join(allocator, &.{ base, rel_path });
}

pub fn main() !void {
    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;

    const allocator = std.heap.page_allocator;

    const params = comptime clap.parseParamsComptime(
        \\-h, --help           Display help and exit.
        \\-d, --dir <STR>      Working directory.
        \\-s, --system         Write to system file.
        \\-u, --user           Write to user file (default).
        \\<TARGET>             Target program to start.
        \\<ARG>...             Additional arguments passed to target.
        \\
    );

    const parsers = comptime .{
        .STR = clap.parsers.string,
        .TARGET = clap.parsers.string,
        .ARG = clap.parsers.string,
    };

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, parsers, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        try diag.reportToFile(.stderr(), err);
        return err;
    };
    defer res.deinit();

    // Handle help request.
    if (res.args.help != 0) {
        try stdout.print(
            "usage: gstart [-s|-u] [-d <dir>] <target_program> [<target_args>...]\n",
            .{},
        );
        return;
    }

    const system_requested = res.args.system != 0;
    const user_requested = res.args.user != 0;

    // Check mutual exclusivity of -s and -u.
    if (system_requested and user_requested) {
        try stdout.print(
            "error: -s/--system and -u/--user are mutually exclusive\n",
            .{},
        );
        return;
    }

    // Default to user mode unless -s explicitly requested.
    const system_mode = system_requested;

    const elevated = try process.isProcessElevated();
    if (system_mode and !elevated) {
        try stdout.print(
            "error: system mode requested but process is not elevated\n",
            .{},
        );
        return;
    }

    // positionals[0] : ?[]const u8  (TARGET)
    // positionals[1] : []const []const u8 (ARG... as slice)
    const target_opt = res.positionals[0];
    if (target_opt == null) {
        try stdout.print(
            "error: missing <target_program>\n",
            .{},
        );
        return;
    }
    const target_program = target_opt.?;
    const target_args = res.positionals[1];
    var work_dir: []u8 = undefined;

    // If work_dir supplied, use it; otherwise use current directory.
    if (res.args.dir) |d| {
        // clone user-supplied directory
        work_dir = try allocator.dupe(u8, d);
    } else {
        work_dir = try std.process.getCwdAlloc(allocator);
    }
    defer allocator.free(work_dir);

    // Build the file path based on mode.
    const file_path = blk: {
        if (system_mode) {
            break :blk try buildPathFromEnv(
                allocator,
                SYSTEM_ENV_VAR,
                SYSTEM_FILE_REL_PATH,
            );
        } else {
            break :blk try buildPathFromEnv(
                allocator,
                USER_ENV_VAR,
                USER_FILE_REL_PATH,
            );
        }
    };
    defer allocator.free(file_path);

    // Print the file path we are writing to.
    // try stdout.print("Writing to file: {s}\n", .{file_path});

    // Create or open file without truncation; append by seeking to end.
    const file = try std.fs.createFileAbsolute(file_path, .{
        .read = true,
        .truncate = false,
    });
    defer file.close();

    try file.seekFromEnd(0);

    var file_buffer: [1024]u8 = undefined;
    var file_writer = file.writer(&file_buffer);
    const out = &file_writer.interface;

    try out.print("\"{s}\" {s}", .{ work_dir, target_program });
    for (target_args) |arg| {
        try out.print(" {s}", .{arg});
    }

    try out.print("\n", .{});
    try out.flush();
}
