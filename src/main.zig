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
    // This shouuld be made more flexible.
    var local_flag = false;
    var remote_flag = false;
    var subcommand: ?Subcommand = null;
    var reading_positional = false;
    var positional: ?[]const u8 = null;

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
            try stdout.writeAll("zi version 0.0.0\n");
            return;
        } else if (std.mem.eql(u8, arg, "--local") or std.mem.eql(u8, arg, "-l")) {
            local_flag = true;
        } else if (std.mem.eql(u8, arg, "--remote") or std.mem.eql(u8, arg, "-r")) {
            remote_flag = true;
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
            // if (positional == null) {
            //     try stderr.writeAll("zi: No version provided\n");
            //     try stderr.writeAll("See 'zi --help' for more information.\n");
            //     return;
            // }
            // try installZigVersion(allocator, stdout, positional.?);
            return error.NotImplemented;
        },
    }
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
