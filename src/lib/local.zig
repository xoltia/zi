const std = @import("std");
const builtin = @import("builtin");

pub const Version = struct {
    parent_dir: std.fs.Dir,
    name: []const u8,
};

pub const VersionIterator = struct {
    dir: std.fs.Dir,
    dir_iterator: std.fs.Dir.Iterator,

    pub fn deinit(self: *@This()) void {
        self.dir.close();
    }

    pub fn next(self: *@This()) !?Version {
        var dir_name: ?[]const u8 = null;
        while (try self.dir_iterator.next()) |entry| {
            if (entry.kind != .directory) continue;
            dir_name = entry.name;
            break;
        }
        if (dir_name == null) return null;
        return .{
            .parent_dir = self.dir,
            .name = dir_name.?,
        };
    }
};

/// Creates a new iterator to list installed Zig versions.
pub fn iterateInstalledVersions(allocator: std.mem.Allocator) !VersionIterator {
    const base_dir_path = try baseInstallDir(allocator);
    defer allocator.free(base_dir_path);
    var dir = try std.fs.cwd().makeOpenPath(base_dir_path, .{ .iterate = true });
    return .{
        .dir = dir,
        .dir_iterator = dir.iterate(),
    };
}

pub fn openInstallDir(
    allocator: std.mem.Allocator,
    version_str: []const u8,
    flags: std.fs.Dir.OpenOptions,
) !std.fs.Dir {
    const install_path = try baseInstallDir(allocator);
    var install_dir = try std.fs.cwd().openDir(install_path, .{});
    defer install_dir.close();
    return install_dir.openDir(version_str, flags);
}

/// Open an existing install directory or create a new one for a given version string.
pub fn makeOpenInstallDir(
    allocator: std.mem.Allocator,
    version_str: []const u8,
    flags: std.fs.Dir.OpenOptions,
) !std.fs.Dir {
    const install_path = try baseInstallDir(allocator);
    var install_dir = try std.fs.cwd().openDir(install_path, .{});
    defer install_dir.close();
    return install_dir.makeOpenPath(version_str, flags);
}

pub const Executable = enum { zls, zig };

/// Locates an executable in the given directory.
/// `dir` must have been opened with `OpenOptions{ .iterate = true }`.
pub fn locateExecutable(
    comptime kind: Executable,
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
) !?[]const u8 {
    var base_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const base_path = try std.os.getFdPath(dir.fd, &base_path_buffer);
    const expected_name = @tagName(kind) ++ if (builtin.os.tag == .windows) ".exe" else "";
    var exe_path: ?[]const u8 = null;

    errdefer if (exe_path) |p| allocator.free(p);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        // The entry must be a file matching the expected name and it must be executable.
        if (entry.kind != .file) continue;
        if (!std.mem.eql(u8, expected_name, entry.basename)) continue;
        const executable = try isExecutableZ(dir, entry.path);
        if (!executable) continue;
        const full_path = try std.fs.path.join(allocator, &[_][]const u8{ base_path, entry.path });
        exe_path = full_path;
        break;
    }

    return exe_path;
}

pub fn baseInstallDir(allocator: std.mem.Allocator) ![]const u8 {
    if (std.process.getEnvVarOwned(allocator, "ZI_INSTALL_DIR")) |base_path|
        return base_path
    else |err| if (err != error.EnvironmentVariableNotFound)
        return err;

    const home = try homeDir(allocator);
    defer allocator.free(home);
    return std.fs.path.join(allocator, &[_][]const u8{ home, ".zi" });
}

pub fn linkDir(allocator: std.mem.Allocator) ![]const u8 {
    if (std.process.getEnvVarOwned(allocator, "ZI_LINK_DIR")) |base_path|
        return base_path
    else |err| if (err != error.EnvironmentVariableNotFound)
        return err;

    const home = try homeDir(allocator);
    defer allocator.free(home);
    return std.fs.path.join(allocator, &[_][]const u8{ home, ".local", "bin" });
}

fn homeDir(allocator: std.mem.Allocator) ![]const u8 {
    return std.process.getEnvVarOwned(allocator, switch (builtin.os.tag) {
        .windows => @compileError("unimplemented"),
        else => "HOME",
    });
}

fn isExecutableZ(dir: std.fs.Dir, path: [:0]const u8) !bool {
    if (builtin.os.tag == .windows)
        return true; // Idk man looks executable to me

    const file = try dir.openFileZ(path, .{});
    defer file.close();
    const stat = try file.stat();
    return stat.mode & std.posix.S.IXUSR != 0;
}
