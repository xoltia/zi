const std = @import("std");
const builtin = @import("builtin");

const TempDirImpl = if (builtin.os.tag == .windows)
    TempDirWindowsImpl
else
    TempDirPosixImpl;

var prng: ?std.Random.DefaultPrng = null;
var prng_lock: std.Thread.Mutex = .{};

/// Returns the system's temporary directory.
pub fn tempDirPath(allocator: std.mem.Allocator) ![]const u8 {
    return TempDirImpl.get(allocator);
}

/// Returns the system's temporary directory as a `std.fs.Dir`.
pub fn tempDir(allocator: std.mem.Allocator, flags: std.fs.Dir.OpenDirOptions) !std.fs.Dir {
    const path = try tempDirPath(allocator);
    return std.fs.openDirAbsolute(path, flags);
}

pub const TempFile = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    dir: std.fs.Dir,
    file: std.fs.File,

    pub fn delete(self: *TempFile) !void {
        try self.dir.deleteFile(self.name);
    }

    pub fn deinit(self: *TempFile) void {
        self.allocator.free(self.name);
        self.file.close();
    }
};

/// Creates a temporary file in the system's temporary directory.
pub fn createTemp(allocator: std.mem.Allocator, flags: std.fs.File.CreateFlags) !TempFile {
    const dir = try tempDir(allocator, .{});
    const name = try randomName(allocator, "tempfile-", 16);
    const file = try dir.createFile(name, flags);
    return .{
        .allocator = allocator,
        .name = name,
        .dir = dir,
        .file = file,
    };
}

/// Gets a random file name with a given prefix and random part of a specified length.
fn randomName(allocator: std.mem.Allocator, prefix: []const u8, random_length: comptime_int) ![]u8 {
    prng_lock.lock();
    defer prng_lock.unlock();
    if (prng == null) prng = .init(@bitCast(std.time.milliTimestamp()));
    const random = prng.?.random();
    var str = try allocator.alloc(u8, prefix.len + random_length);
    var buf: [random_length / 2]u8 = undefined;
    random.bytes(&buf);
    @memcpy(str[0..prefix.len], prefix);
    @memcpy(str[prefix.len..], &std.fmt.bytesToHex(&buf, .lower));
    return str;
}

const TempDirPosixImpl = struct {
    const env_vars = &[_][]const u8{ "TEMPDIR", "TMPDIR", "TEMP", "TMP" };

    pub fn get(allocator: std.mem.Allocator) ![]const u8 {
        for (env_vars) |env_var| {
            if (std.process.getEnvVarOwned(allocator, env_var) catch |err| blk: {
                if (err != error.EnvironmentVariableNotFound)
                    return err;
                break :blk null;
            }) |dir| return dir;
        }
        return try allocator.dupe(u8, "/tmp");
    }
};

const TempDirWindowsImpl = struct {
    const windows = std.os.windows;

    extern "C" fn GetTempPath2W(BufferLength: windows.DWORD, Buffer: windows.LPWSTR) windows.DWORD;

    pub fn get(allocator: std.mem.Allocator) ![]const u8 {
        var wchar_buf: [windows.MAX_PATH + 2]windows.WCHAR = undefined;
        wchar_buf[windows.MAX_PATH + 1] = 0;
        const ret = GetTempPath2W(windows.MAX_PATH + 1, &wchar_buf);
        if (ret != 0) {
            const path = wchar_buf[0..ret];
            return std.unicode.utf16leToUtf8Alloc(allocator, path);
        } else {
            return error.GetTempPath2WFailed;
        }
    }
};
