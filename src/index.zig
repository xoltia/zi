const std = @import("std");
const builtin = @import("builtin");

const index_url = "https://ziglang.org/download/index.json";

pub const Version = struct {
    date: []const u8,
    version: ?[]const u8,
    @"aarch64-linux": ?Source,
    @"aarch64-macos": ?Source,
    @"aarch64-windows": ?Source,
    @"armv6kz-linux": ?Source,
    @"armv7a-linux": ?Source,
    @"i386-linux": ?Source,
    @"i386-windows": ?Source,
    @"loongarch64-linux": ?Source,
    @"powerpc64le-linux": ?Source,
    @"powerpc-linux": ?Source,
    @"riscv64-linux": ?Source,
    @"x86_64-freebsd": ?Source,
    @"x86_64-linux": ?Source,
    @"x86_64-macos": ?Source,
    @"x86_64-windows": ?Source,
    @"x86-linux": ?Source,
    @"x86-windows": ?Source,

    const Source = struct {
        tarball: []const u8,
        shasum: []const u8,
        size: []const u8,
    };

    pub fn getNativeSource(self: Version) ?Source {
        switch (builtin.os.tag) {
            .linux => switch (builtin.cpu.arch) {
                .x86_64 => return self.@"x86_64-linux",
                .x86 => return self.@"i386-linux" orelse self.@"x86-linux",
                .aarch64 => return self.@"aarch64-linux",
                .loongarch64 => return self.@"loongarch64-linux",
                .powerpc64le => return self.@"powerpc64le-linux",
                .powerpc => return self.@"powerpc-linux",
                .riscv64 => return self.@"riscv64-linux",
                else => return null,
            },
            .macos => switch (builtin.cpu.arch) {
                .x86_64 => return self.@"x86_64-macos",
                .aarch64 => return self.@"aarch64-macos",
                else => return null,
            },
            .windows => switch (builtin.cpu.arch) {
                .x86_64 => return self.@"x86_64-windows",
                .x86 => return self.@"i386-windows" orelse self.@"x86-windows",
                .aarch64 => return self.@"aarch64-windows",
                else => return null,
            },
            .freebsd => switch (builtin.cpu.arch) {
                .x86_64 => return self.@"x86_64-freebsd",
                else => return null,
            },
            else => return null,
        }
    }
};

pub const VersionMap = std.json.ArrayHashMap(Version);

pub fn fetchVersions(allocator: std.mem.Allocator) !std.json.Parsed(VersionMap) {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var response_body = std.ArrayList(u8).init(allocator);
    defer response_body.deinit();

    const response = try client.fetch(.{
        .method = .GET,
        .location = .{ .url = index_url },
        .response_storage = .{ .dynamic = &response_body },
    });

    if (response.status != .ok) return error.StatusNotOk;

    return std.json.parseFromSlice(VersionMap, allocator, response_body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

pub fn fetchVersionFromKey(allocator: std.mem.Allocator, key: []const u8) !Version {
    const versions = try fetchVersions(allocator);
    defer versions.deinit();
    return versions.value.map.get(key);
}
