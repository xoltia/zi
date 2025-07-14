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
    \\    ls-mirrors           List available mirrors
    \\    install <version>    Install a specific remote Zig version
    \\    use [version]        Switch to a specific local Zig version, using .zirc if version is omitted
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
    \\        --mirror=<url>   Use a specific mirror (must be in the community-mirrors.txt format; see https://ziglang.org/download/community-mirrors)
    \\        --no-mirror      Download directly from ziglang.org (not recommended)
    \\    -s, --skip-zls       Skip downloading and/or linking the ZLS executable
    \\
    \\Flags for `use` subcommand:
    \\    --zls                Change only the ZLS version, useful for mismatching ZLS and Zig versions
    \\
    \\Environment variables:
    \\    ZI_INSTALL_DIR       Directory to install Zig versions (default: $HOME/.zi)
    \\    ZI_LINK_DIR          Directory to create symlinks for the active Zig version (default: $HOME/.local/bin)
    \\
;

const Subcommand = enum {
    ls,
    ls_mirror,
    install,
    use,
};

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const stderr = std.io.getStdErr().writer().any();
    const stdout = std.io.getStdOut().writer().any();

    // TODO: more versatile flag parsing
    var local_flag = false;
    var remote_flag = false;
    var skip_zls_flag = false;
    var force_flag = false;
    var zls_flag = false;
    var no_mirror_flag = false;
    var subcommand: ?Subcommand = null;
    var reading_positional = false;
    var positional: ?[]const u8 = null;
    var mirror_option: ?[]const u8 = null;

    for (args[1..]) |arg| {
        if (reading_positional) {
            positional = arg;
            reading_positional = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try stderr.writeAll(help_text);
            return;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
            try stdout.writeAll("zi version 0.1.5\n");
            return;
        } else if (std.mem.eql(u8, arg, "--local") or std.mem.eql(u8, arg, "-l")) {
            local_flag = true;
        } else if (std.mem.eql(u8, arg, "--remote") or std.mem.eql(u8, arg, "-r")) {
            remote_flag = true;
        } else if (std.mem.eql(u8, arg, "--skip-zls") or std.mem.eql(u8, arg, "-s")) {
            skip_zls_flag = true;
        } else if (std.mem.eql(u8, arg, "--force") or std.mem.eql(u8, arg, "-f")) {
            force_flag = true;
        } else if (std.mem.eql(u8, arg, "--zls")) {
            zls_flag = true;
        } else if (std.mem.eql(u8, arg, "--no-mirror")) {
            no_mirror_flag = true;
        } else if (std.mem.startsWith(u8, arg, "--mirror")) {
            if (arg.len == 8) {
                try stderr.writeAll("zi: Missing argument value: --mirror\n");
                try stderr.writeAll("See 'zi --help' for more information.\n");
                return;
            } else if (arg[8] != '=') {
                try stderr.print("zi: Unknown argument: {s}\n", .{arg});
                try stderr.writeAll("See 'zi --help' for more information.\n");
                return;
            }
            mirror_option = arg[9..];
            // Basic sanity check
            if (!std.mem.startsWith(u8, mirror_option.?, "http")) {
                try stderr.writeAll("zi: Mirror url does not start with 'http'\n");
                return;
            }
        } else if (std.mem.eql(u8, arg, "ls") and subcommand == null) {
            subcommand = .ls;
        } else if (std.mem.eql(u8, arg, "ls-mirrors") and subcommand == null) {
            subcommand = .ls_mirror;
        } else if (std.mem.eql(u8, arg, "use") and subcommand == null) {
            subcommand = .use;
            reading_positional = true;
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

    const color = std.io.getStdOut().isTty();
    switch (subcommand.?) {
        .ls => try listZigVersions(allocator, stdout, local_flag, remote_flag, color),
        .install => {
            if (positional == null) {
                try stderr.writeAll("zi: No version provided\n");
                try stderr.writeAll("See 'zi --help' for more information.\n");
                return;
            }
            try installZigVersion(
                allocator,
                stderr,
                positional.?,
                force_flag,
                skip_zls_flag,
                mirror_option,
                no_mirror_flag,
            );
        },
        .use => {
            try useZigVersion(allocator, stderr, positional, zls_flag);
        },
        .ls_mirror => {
            try listMirrors(allocator, stdout);
        },
    }
}

fn installZigVersion(
    allocator: std.mem.Allocator,
    stderr: std.io.AnyWriter,
    version_str: []const u8,
    force: bool,
    skip_zls: bool,
    mirror_option: ?[]const u8,
    no_mirror: bool,
) !void {
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

        // Must hold this for as long as mirror string is needed.
        var mirrors: ?zi.remote.MirrorList = null;
        var mirror: ?[]const u8 = null;

        if (mirror_option) |m| {
            try stderr.print("Using specified mirror: {s}\n", .{m});
            mirror = m;
        } else if (!no_mirror) {
            mirrors = try zi.remote.fetchZigMirrors(allocator, &client);
            if (mirrors.?.items.len > 0) {
                var prng = std.Random.DefaultPrng.init(@bitCast(std.time.milliTimestamp()));
                const random = prng.random();
                const random_mirror = random.intRangeLessThan(usize, 0, mirrors.?.items.len);
                mirror = mirrors.?.items[random_mirror];
                try stderr.print("Using random mirror: {s}\n", .{mirror.?});
            }
        }
        defer if (mirrors) |mirror_list| mirror_list.deinit();

        // TODO: Try additional mirrors if random one doesn't work
        zi.remote.downloadZig(
            allocator,
            &client,
            version_info,
            mirror,
            install_dir,
            zig_download_progress,
        ) catch |err| {
            if (err == error.SignatureVerificationFailed and mirror != null)
                try stderr.print("Warning: signature verification failed for mirror: {s}\n", .{mirror.?});
            return err;
        };
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
        try stderr.writeAll("Alternatively, if this version has no matching zls release, use 'zi use' with the '--zls' flag to specify a different installed version.\n");
        zls_linking_progress.end();
        zls_install_progress.end();
        return;
    };
    const zls_link_path = try std.fs.path.join(arena_allocator, &[_][]const u8{ link_dir, zls_name });
    try std.fs.cwd().atomicSymLink(zls_location, zls_link_path, .{ .is_directory = false });
    zls_linking_progress.end();
    zls_install_progress.end();
}

fn useZigVersion(
    allocator: std.mem.Allocator,
    stderr: std.io.AnyWriter,
    maybe_version_str: ?[]const u8,
    zls_only: bool,
) !void {
    var local_iterator = try zi.local.iterateInstalledVersions(allocator);
    defer local_iterator.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    const arena_allocator = arena.allocator();
    defer arena.deinit();

    const version_str: []const u8 = maybe_version_str orelse blk: {
        const file_content = std.fs.cwd().readFileAlloc(arena_allocator, ".zirc", 256) catch |err| {
            if (err != error.FileNotFound) return err;
            try stderr.writeAll("No version provided and no .zirc found.\n");
            try stderr.writeAll("See 'zi --help' for more information.\n");
            return;
        };
        const line_end = std.mem.indexOfScalar(u8, file_content, '\n') orelse 0;
        break :blk file_content[0..line_end];
    };

    const installed_version = while (try local_iterator.next()) |v| {
        if (std.mem.eql(u8, version_str, v.name)) {
            break v;
        }
    } else null;

    if (installed_version == null) {
        try stderr.writeAll("Version not found in install directory.\n");
        try stderr.print("Use 'zi install {s}' to install it.\n", .{version_str});
        return;
    }

    const full_version_str = installed_version.?.name;
    var install_dir = zi.local.openInstallDir(allocator, full_version_str, .{ .iterate = true }) catch |err| blk: {
        if (err != error.FileNotFound) return err;
        const new_dir = try zi.local.makeOpenInstallDir(allocator, full_version_str, .{ .iterate = true });
        break :blk new_dir;
    };
    defer install_dir.close();

    const zig_name = if (@import("builtin").os.tag == .windows) "zig.exe" else "zig";
    const zls_name = if (@import("builtin").os.tag == .windows) "zls.exe" else "zls";
    const link_dir = try zi.local.linkDir(arena_allocator);
    const link_path = try std.fs.path.join(arena_allocator, &[_][]const u8{ link_dir, zig_name });

    if (!zls_only) {
        const zig_location = try zi.local.locateExecutable(.zig, arena_allocator, install_dir) orelse {
            try stderr.writeAll("Failed to locate zig executable.\n");
            try stderr.writeAll("Try reinstalling with 'zi install' using the '--force' flag.\n");
            return;
        };
        std.fs.cwd().atomicSymLink(zig_location, link_path, .{ .is_directory = false }) catch |err| {
            if (err != error.FileNotFound) return err;
            try stderr.writeAll("Invalid link directory.\n");
            return;
        };
    }

    if (try zi.local.locateExecutable(.zls, arena_allocator, install_dir)) |zls_location| {
        const zls_link_path = try std.fs.path.join(arena_allocator, &[_][]const u8{ link_dir, zls_name });
        try std.fs.cwd().atomicSymLink(zls_location, zls_link_path, .{ .is_directory = false });
    } else if (!zls_only) {
        try stderr.writeAll("Warning: Unable to locate zls.\n");
        try stderr.writeAll("If this version has a tagged zls release, try reinstalling using 'zi install' with the '--force' flag.\n");
        try stderr.writeAll("Alternatively, specify a different zls version using this command with the '--zls' flag.\n");
    } else {
        try stderr.writeAll("Failed to locate zls executable.\n");
        try stderr.writeAll("Try reinstalling with 'zi install' using the '--force' flag.\n");
        return;
    }

    const name = if (zls_only) "zls" else "Zig";
    try stderr.print("Using {s} version {s}\n", .{ name, full_version_str });
}

fn listZigVersions(
    allocator: std.mem.Allocator,
    stdout: std.io.AnyWriter,
    local_flag: bool,
    remote_flag: bool,
    color: bool,
) !void {
    if (local_flag) {
        try listLocalZigVersions(allocator, stdout);
    } else if (remote_flag) {
        try listRemoteZigVersions(allocator, stdout);
    } else {
        try listAllZigVersions(allocator, stdout, color);
    }
}

fn listMirrors(
    allocator: std.mem.Allocator,
    stdout: std.io.AnyWriter,
) !void {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();
    const mirrors = try zi.remote.fetchZigMirrors(allocator, &client);
    defer mirrors.deinit();
    for (mirrors.items) |mirror| {
        try stdout.writeAll(mirror);
        try stdout.writeByte('\n');
    }
}

fn listAllZigVersions(
    allocator: std.mem.Allocator,
    stdout: std.io.AnyWriter,
    color: bool,
) !void {
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

    const SortCtx = struct {
        map: @TypeOf(versions),

        pub fn lessThan(ctx: @This(), a_index: usize, b_index: usize) bool {
            const keys = ctx.map.unmanaged.entries.items(.key);
            const a_semvar = std.SemanticVersion.parse(keys[a_index]) catch return false;
            const b_semvar = std.SemanticVersion.parse(keys[b_index]) catch return false;
            return a_semvar.order(b_semvar) != .lt; // Descending order
        }
    };

    versions.sort(SortCtx{ .map = versions });

    var it = versions.iterator();
    while (it.next()) |entry| {
        const version = entry.key_ptr.*;
        const status = entry.value_ptr.*;
        if (color) {
            const ansi: [2]u8 = .{ 0o033, '[' };
            try stdout.writeAll(ansi ++ switch (status) {
                .remote_only => "31mR",
                .local_only => "34mL",
                .local_and_remote => "32mI",
            } ++ ansi ++ "0m ");
        } else {
            try stdout.writeAll(switch (status) {
                .remote_only => "R",
                .local_only => "L",
                .local_and_remote => "I",
            } ++ " ");
        }
        try stdout.writeAll(version);
        try stdout.writeByte('\n');
    }
}

fn listLocalZigVersions(allocator: std.mem.Allocator, stdout: std.io.AnyWriter) !void {
    var version_iterator = try zi.local.iterateInstalledVersions(allocator);
    defer version_iterator.deinit();

    var versions = std.ArrayList([]const u8).init(allocator);
    defer versions.deinit();

    while (try version_iterator.next()) |v| {
        try versions.append(v.name);
    }

    const version_slice = try versions.toOwnedSlice();
    defer allocator.free(version_slice);

    const Sort = struct {
        fn sortFunc(_: void, lhs: []const u8, rhs: []const u8) bool {
            const a_semver = std.SemanticVersion.parse(lhs) catch return false;
            const b_semver = std.SemanticVersion.parse(rhs) catch return false;
            return a_semver.order(b_semver) != .lt; // Descending order
        }
    };

    std.mem.sort([]const u8, version_slice, {}, Sort.sortFunc);

    for (version_slice) |v| {
        try stdout.print("{s}\n", .{v});
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
