const std = @import("std");
const builtin = @import("builtin");

pub const ExecutablePaths = struct {
    zig: []const u8,
    zls: ?[]const u8,

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.zig);
        if (self.zls) |zls| allocator.free(zls);
    }
};

pub const Version = struct {
    parent_dir: std.fs.Dir,
    name: []const u8,

    pub fn executables(self: @This(), allocator: std.mem.Allocator) !ExecutablePaths {
        const dir = try self.parent_dir.openDir(self.name, .{ .iterate = true });
        defer dir.close();
        return locateExecutables(allocator, dir);
    }
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

/// Open an existing install directory or create a new one for a given version string.
pub fn makeOpenInstallDir(
    allocator: std.mem.Allocator,
    version_str: []const u8,
    flags: std.fs.Dir.OpenOptions,
) !std.fs.Dir {
    const parent_dir = try baseInstallDir(allocator);
    defer allocator.free(parent_dir);
    const full_path = try std.fs.path.join(allocator, &[_][]const u8{ parent_dir, version_str });
    defer allocator.free(full_path);
    return std.fs.cwd().makeOpenPath(full_path, flags);
}

/// Get the executable paths from a version directory.
/// `dir` must have been opened with `OpenOptions{ .iterate = true }`.
pub fn locateExecutables(allocator: std.mem.Allocator, dir: std.fs.Dir) !ExecutablePaths {
    var base_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const base_path = try std.os.getFdPath(dir.fd, &base_path_buffer);
    const expected_name_zig = if (builtin.os.tag != .windows) "zig" else "zig.exe";
    const expected_name_zls = if (builtin.os.tag != .windows) "zls" else "zls.exe";
    var zig_exe_path: ?[]const u8 = null;
    var zls_exe_path: ?[]const u8 = null;

    errdefer {
        if (zig_exe_path) |p| allocator.free(p);
        if (zls_exe_path) |p| allocator.free(p);
    }

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        // The entry must be a file matching the expected name and it must be executable.
        if (entry.kind != .file) continue;
        const is_zls = zls_exe_path == null and std.mem.eql(u8, entry.basename, expected_name_zls);
        const is_zig = zig_exe_path == null and std.mem.eql(u8, entry.basename, expected_name_zig);
        if (!is_zig and !is_zls) continue;
        const executable = try isExecutableZ(dir, entry.path);
        if (!executable) continue;

        const full_path = try std.fs.path.join(allocator, &[_][]const u8{ base_path, entry.path });
        if (is_zig)
            zig_exe_path = full_path
        else
            zls_exe_path = full_path;

        if (zig_exe_path != null and zls_exe_path != null)
            break;
    }

    if (zig_exe_path == null)
        return error.MissingZigExecutable;

    return .{ .zig = zig_exe_path.?, .zls = zls_exe_path };
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
