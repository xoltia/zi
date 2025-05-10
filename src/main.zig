const std = @import("std");
const zi = @import("zi");

const help_text =
    \\zi is a simple Zig version manager.
    \\
    \\Usage:
    \\    zi [OPTIONS] [SUBCOMMAND]
    \\
    \\Subcommands:
    \\    ls                   List Zig versions
    \\    install <version>    Install a specific Zig version
    \\
    \\Flags:
    \\    -h, --help           Print help information
    \\    -V, --version        Print version information
    \\
    \\Flags for `ls` subcommand:
    \\    -r, --remote         List only remote versions
    \\    -l, --local          List only local versions
    \\
    \\Flags for `install` subcommand:
    \\    -f, --force          Remove the existing download if it exists
    \\    -s, --skip-zls       Skip downloading and/or linking the ZLS executable
    \\
    \\Environment variables:
    \\    ZI_INSTALL_DIR       Directory to install Zig versions (default: $HOME/.zi)
    \\    ZI_LINK_DIR          Directory to create symlinks for the active Zig version (default: $HOME/.local/bin)
    \\
;

const Subcommand = enum {
    ls,
    install,
};

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const stderr = std.io.getStdErr().writer().any();
    const stdout = std.io.getStdOut().writer().any();

    // TODO: In the future more than one flag can be passed.
    // This should be made more flexible.
    var local_flag = false;
    var remote_flag = false;
    var skip_zls_flag = false;
    var force_flag = false;
    var subcommand: ?Subcommand = null;
    var reading_positional = false;
    var positional: ?[]const u8 = null;

    defer if (positional) |str| allocator.free(str);

    for (args[1..]) |arg| {
        if (reading_positional) {
            positional = try allocator.dupe(u8, arg);
            reading_positional = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try stderr.writeAll(help_text);
            return;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
            try stdout.writeAll("zi version 0.1.0\n");
            return;
        } else if (std.mem.eql(u8, arg, "--local") or std.mem.eql(u8, arg, "-l")) {
            local_flag = true;
        } else if (std.mem.eql(u8, arg, "--remote") or std.mem.eql(u8, arg, "-r")) {
            remote_flag = true;
        } else if (std.mem.eql(u8, arg, "--skip-zls") or std.mem.eql(u8, arg, "-s")) {
            skip_zls_flag = true;
        } else if (std.mem.eql(u8, arg, "--force") or std.mem.eql(u8, arg, "-f")) {
            force_flag = true;
        } else if (std.mem.eql(u8, arg, "ls") and subcommand == null) {
            subcommand = .ls;
        } else if (std.mem.eql(u8, arg, "install") and subcommand == null) {
            subcommand = .install;
            reading_positional = true;
        } else {
            try stderr.print("zi: Unknown argument: {s}\n", .{arg});
            try stderr.writeAll("See 'zi --help' for more information.\n");
            return;
        }
    }

    if (subcommand == null) {
        try stderr.writeAll("zi: No subcommand provided\n");
        try stderr.writeAll("See 'zi --help' for more information.\n");
        return;
    }

    switch (subcommand.?) {
        .ls => try listZigVersions(allocator, stdout, local_flag, remote_flag),
        .install => {
            if (positional == null) {
                try stderr.writeAll("zi: No version provided\n");
                try stderr.writeAll("See 'zi --help' for more information.\n");
                return;
            }
            try installZigVersion(allocator, stderr, positional.?, force_flag, skip_zls_flag);
        },
    }
}

fn installZigVersion(
    allocator: std.mem.Allocator,
    stderr: std.io.AnyWriter,
    version_str: []const u8,
    force: bool,
    skip_zls: bool,
) !void {
    // TODO: Pass progress to long running fuctions (download/compile)
    const progress = std.Progress.start(.{});
    defer progress.end();

    const fetch_progress = progress.start("Fetching versions", 0);
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();
    var versions = try zi.remote.fetchZigVersions(allocator, &client);
    defer versions.deinit();
    fetch_progress.end();

    const version_info = versions.value.map.get(version_str) orelse {
        try stderr.writeAll("Version not found in index.\n");
        try stderr.writeAll("See 'zi ls --remote' for a list of available versions.\n");
        return;
    };

    const zig_install_progress = progress.start("Installing zig", 0);
    const full_version_str = version_info.version orelse version_str;
    var new_install = force;
    var install_dir = zi.local.openInstallDir(allocator, full_version_str, .{ .iterate = true }) catch |err| blk: {
        if (err != error.FileNotFound) return err;
        new_install = true;
        const new_dir = try zi.local.makeOpenInstallDir(allocator, full_version_str, .{ .iterate = true });
        break :blk new_dir;
    };
    defer install_dir.close();

    if (new_install) {
        var iterator = install_dir.iterate();
        while (try iterator.next()) |entry|
            try install_dir.deleteTree(entry.name);
        const zig_download_progress = zig_install_progress.start("Downloading", 0);
        defer zig_download_progress.end();
        try zi.remote.downloadZig(allocator, &client, version_info, install_dir, zig_download_progress);
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    const arena_allocator = arena.allocator();
    defer arena.deinit();

    const zig_linking_progress = zig_install_progress.start("Linking", 0);
    const zig_name = if (@import("builtin").os.tag == .windows) "zig.exe" else "zig";
    const zls_name = if (@import("builtin").os.tag == .windows) "zls.exe" else "zls";
    const zig_location = try zi.local.locateExecutable(.zig, arena_allocator, install_dir) orelse {
        try stderr.writeAll("Failed to locate zig executable.\n");
        try stderr.writeAll("Try reinstalling using the '--force' flag.\n");
        return;
    };

    const link_dir = try zi.local.linkDir(arena_allocator);
    const link_path = try std.fs.path.join(arena_allocator, &[_][]const u8{ link_dir, zig_name });
    std.fs.cwd().atomicSymLink(zig_location, link_path, .{ .is_directory = false }) catch |err| {
        if (err != error.FileNotFound) return err;
        try stderr.writeAll("Invalid link directory.\n");
        return;
    };

    zig_linking_progress.end();
    zig_install_progress.end();
    if (skip_zls) return;

    const zls_install_progress = progress.start("Installing zls", 0);

    if (new_install) {
        if (std.mem.eql(u8, version_str, "master")) {
            try zi.remote.downloadCompileMasterZls(allocator, &client, zig_location, version_info.version.?, install_dir, zls_install_progress);
        } else {
            zi.remote.fetchDownloadTaggedZls(allocator, &client, version_str, install_dir, zls_install_progress) catch |err| {
                if (err != error.NoTaggedRelease)
                    return err;
                try stderr.writeAll("Warning: zls not installed!\n");
                try stderr.writeAll("Unable to find a matching zls tagged release. Use '--skip-zls' to switch to this version in the future.\n");
                return;
            };
        }
    }

    const zls_linking_progress = zls_install_progress.start("Linking", 0);
    const zls_location = try zi.local.locateExecutable(.zls, arena_allocator, install_dir) orelse {
        try stderr.writeAll("Failed to locate zls executable.\n");
        try stderr.writeAll("Try reinstalling using the '--force' flag or ignoring this error using '--skip-zls'.\n");
        return;
    };
    const zls_link_path = try std.fs.path.join(arena_allocator, &[_][]const u8{ link_dir, zls_name });
    try std.fs.cwd().atomicSymLink(zls_location, zls_link_path, .{ .is_directory = false });
    zls_linking_progress.end();
    zls_install_progress.end();
}

fn listZigVersions(
    allocator: std.mem.Allocator,
    stdout: std.io.AnyWriter,
    local_flag: bool,
    remote_flag: bool,
) !void {
    if (local_flag) {
        try listLocalZigVersions(allocator, stdout);
    } else if (remote_flag) {
        try listRemoteZigVersions(allocator, stdout);
    } else {
        try listAllZigVersions(allocator, stdout);
    }
}

fn listAllZigVersions(allocator: std.mem.Allocator, stdout: std.io.AnyWriter) !void {
    var local_iterator = try zi.local.iterateInstalledVersions(allocator);
    defer local_iterator.deinit();

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();
    var remote_versions = try zi.remote.fetchZigVersions(allocator, &client);
    defer remote_versions.deinit();

    const remote_version_map = remote_versions.value.map;
    const remote_version_keys = remote_version_map.keys();
    const VersionStatus = enum { remote_only, local_only, local_and_remote };
    var versions = std.StringArrayHashMap(VersionStatus).init(allocator);
    defer versions.deinit();

    while (try local_iterator.next()) |version| {
        try versions.put(version.name, .local_only);
    }

    var has_status_indicator = false;
    for (remote_version_keys) |key| {
        const info = remote_version_map.get(key).?;
        const version_string = info.version orelse key;
        if (versions.getPtr(version_string)) |value_ptr| {
            value_ptr.* = .local_and_remote;
            has_status_indicator = true;
        } else {
            try versions.put(version_string, .remote_only);
        }
    }

    // TODO: Sort versions
    var it = versions.iterator();
    while (it.next()) |entry| {
        const version = entry.key_ptr.*;
        const status = entry.value_ptr.*;

        switch (status) {
            .remote_only => try stdout.print("{s}{s}\n", .{
                if (has_status_indicator) "  " else "",
                version,
            }),
            else => try stdout.print("+ {s}\n", .{version}),
        }
    }
}

fn listLocalZigVersions(allocator: std.mem.Allocator, stdout: std.io.AnyWriter) !void {
    var versions = try zi.local.iterateInstalledVersions(allocator);
    defer versions.deinit();

    while (try versions.next()) |v| {
        try stdout.print("{s}\n", .{v.name});
    }
}

fn listRemoteZigVersions(allocator: std.mem.Allocator, stdout: std.io.AnyWriter) !void {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();
    const versions = try zi.remote.fetchZigVersions(allocator, &client);
    defer versions.deinit();
    var iterator = versions.value.map.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.version) |semvar| {
            try stdout.print("{s} -> {s}\n", .{ entry.key_ptr.*, semvar });
        } else {
            try stdout.print("{s}\n", .{entry.key_ptr.*});
        }
    }
}
