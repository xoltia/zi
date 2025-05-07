const std = @import("std");
const builtin = @import("builtin");
const tempfile = @import("tempfile.zig");
const xz = std.compress.xz;
const gzip = std.compress.gzip;
const Sha256 = std.crypto.hash.sha2.Sha256;

const zig_index_url = "https://ziglang.org/download/index.json";
const zls_releases_url = "https://api.github.com/repos/zigtools/zls/releases";
const zls_master_archive_url = "https://github.com/zigtools/zls/archive/refs/heads/master.tar.gz";

pub const ZigSource = struct {
    tarball: []const u8,
    shasum: []const u8,
    size: []const u8,
};

pub const ZigVersion = struct {
    date: []const u8,
    version: ?[]const u8 = null,
    @"aarch64-linux": ?ZigSource = null,
    @"aarch64-macos": ?ZigSource = null,
    @"aarch64-windows": ?ZigSource = null,
    @"armv6kz-linux": ?ZigSource = null,
    @"armv7a-linux": ?ZigSource = null,
    @"i386-linux": ?ZigSource = null,
    @"i386-windows": ?ZigSource = null,
    @"loongarch64-linux": ?ZigSource = null,
    @"powerpc64le-linux": ?ZigSource = null,
    @"powerpc-linux": ?ZigSource = null,
    @"riscv64-linux": ?ZigSource = null,
    @"x86_64-freebsd": ?ZigSource = null,
    @"x86_64-linux": ?ZigSource = null,
    @"x86_64-macos": ?ZigSource = null,
    @"x86_64-windows": ?ZigSource = null,
    @"x86-linux": ?ZigSource = null,
    @"x86-windows": ?ZigSource = null,

    pub fn getNativeSource(self: ZigVersion) ?ZigSource {
        return switch (builtin.os.tag) {
            .linux => switch (builtin.cpu.arch) {
                .x86_64 => self.@"x86_64-linux",
                .x86 => self.@"x86-linux" orelse self.@"i386-linux",
                .aarch64 => self.@"aarch64-linux",
                .loongarch64 => self.@"loongarch64-linux",
                .powerpc64le => self.@"powerpc64le-linux",
                .powerpc => self.@"powerpc-linux",
                .riscv64 => self.@"riscv64-linux",
                else => null,
            },
            .macos => switch (builtin.cpu.arch) {
                .x86_64 => self.@"x86_64-macos",
                .aarch64 => self.@"aarch64-macos",
                else => null,
            },
            .windows => switch (builtin.cpu.arch) {
                .x86_64 => self.@"x86_64-windows",
                .x86 => self.@"i386-windows" orelse self.@"x86-windows",
                .aarch64 => self.@"aarch64-windows",
                else => null,
            },
            .freebsd => switch (builtin.cpu.arch) {
                .x86_64 => self.@"x86_64-freebsd",
                else => null,
            },
            else => null,
        };
    }
};

pub const ZigVersionMap = std.json.ArrayHashMap(ZigVersion);

/// Fetches the Zig versions from the official Zig download index.
pub fn fetchZigVersions(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
) !std.json.Parsed(ZigVersionMap) {
    var response_body = std.ArrayList(u8).init(allocator);
    defer response_body.deinit();

    const response = try client.fetch(.{
        .method = .GET,
        .location = .{ .url = zig_index_url },
        .response_storage = .{ .dynamic = &response_body },
    });

    if (response.status != .ok) return error.StatusNotOk;

    return std.json.parseFromSlice(ZigVersionMap, allocator, response_body.items, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

/// Downloads the specified Zig version and extracts it into the target directory.
pub fn downloadZig(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    version: ZigVersion,
    target_dir: std.fs.Dir,
) !void {
    const source = version.getNativeSource() orelse return error.NoSourceForVersion;
    const source_uri = try std.Uri.parse(source.tarball);
    var sha256 = Sha256.init(.{});
    const sha256_writer = sha256.writer().any();
    try downloadAndExtract(allocator, client, source_uri, target_dir, sha256_writer);
    const match = try compareShasumHex(source.shasum, &sha256.finalResult());
    if (!match) return error.SumMismatch;
}

fn compareShasumHex(hex: []const u8, sum: []const u8) !bool {
    if (hex.len != sum.len * 2) return false;
    var i: usize = 0;
    while (i < hex.len) : (i += 2) {
        const hi = try std.fmt.charToDigit(hex[i], 16);
        const lo = try std.fmt.charToDigit(hex[i + 1], 16);
        if (sum[i] != (hi << 4) | lo) return false;
    }
    return true;
}

/// Downloads an archive file from the provided `source_uri` and extracts its
/// contents into the `target_directory`. Supports zip and tar (xz and gz).
/// If `tee` is provided, the response data (before decompression) will be written
/// to it as well.
fn downloadAndExtract(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    source_uri: std.Uri,
    target_dir: std.fs.Dir,
    tee: ?std.io.AnyWriter,
) !void {
    var header_buffer: [1024]u8 = undefined;
    var req = try client.open(.GET, source_uri, .{ .server_header_buffer = &header_buffer });
    defer req.deinit();
    try req.send();
    try req.finish();
    try req.wait();

    const response_reader = req.reader().any();
    var tee_reader = TeeReader.init(response_reader, tee);
    const reader = tee_reader.anyReader();
    const path_str = switch (source_uri.path) {
        .raw, .percent_encoded => |string| string,
    };
    const file_type = std.fs.path.extension(path_str);
    if (std.mem.eql(u8, file_type, ".zip")) {
        return extractZip(allocator, target_dir, reader);
    }

    // Can either be `.tar.xz`, `.tar.gz`, or `.tar`.
    var parts = std.mem.splitBackwardsScalar(u8, path_str, '.');
    var compression_type: ?[]const u8 = parts.next() orelse return error.UnknownArchiveType;
    const archive_type = parts.next() orelse blk: {
        const previous = compression_type.?;
        compression_type = null;
        break :blk previous;
    };

    if (!std.mem.eql(u8, archive_type, "tar"))
        return error.UnsupportedArchiveType;

    const CompressionExt = enum { xz, gz };
    var decompressor: DecompressReader =
        if (compression_type) |ext_str|
            if (std.meta.stringToEnum(CompressionExt, ext_str)) |ext|
                switch (ext) {
                    .xz => .{ .xz = try xz.decompress(allocator, reader) },
                    .gz => .{ .gzip = gzip.decompressor(reader) },
                }
            else
                return error.UnsupportedCompressionType
        else
            .{ .raw = reader };
    defer decompressor.deinit();

    try std.tar.pipeToFileSystem(target_dir, decompressor.reader(), .{});
}

fn extractZip(allocator: std.mem.Allocator, dest: std.fs.Dir, src: std.io.AnyReader) !void {
    var temp = try tempfile.createTemp(allocator, .{ .read = true });
    defer temp.deinit();

    var fifo = std.fifo.LinearFifo(u8, .{ .Static = 4096 }).init();
    try fifo.pump(src, temp.file);
    try temp.file.sync();

    const stream = temp.file.seekableStream();
    try std.zip.extract(dest, stream, .{});
    try temp.delete();
}

const TeeReader = struct {
    inner: std.io.AnyReader,
    tee: ?std.io.AnyWriter,

    fn init(inner: std.io.AnyReader, tee: ?std.io.AnyWriter) TeeReader {
        return TeeReader{ .inner = inner, .tee = tee };
    }

    fn read(self: TeeReader, buf: []u8) !usize {
        const bytes_read = try self.inner.read(buf);
        if (self.tee) |tee| try tee.writeAll(buf[0..bytes_read]);
        return bytes_read;
    }

    fn typeErasedReadFn(context: *const anyopaque, buffer: []u8) anyerror!usize {
        const ptr: *const TeeReader = @alignCast(@ptrCast(context));
        return read(ptr.*, buffer);
    }

    fn anyReader(self: *TeeReader) std.io.AnyReader {
        return .{
            .context = @ptrCast(self),
            .readFn = typeErasedReadFn,
        };
    }
};

const DecompressReader = union(enum) {
    xz: xz.Decompress(std.io.AnyReader),
    gzip: gzip.Decompressor(std.io.AnyReader),
    raw: std.io.AnyReader,

    fn reader(self: *@This()) std.io.AnyReader {
        return switch (self.*) {
            .raw => |raw| raw,
            .gzip => |*d| d.reader().any(),
            .xz => |*d| d.reader().any(),
        };
    }

    fn deinit(self: *@This()) void {
        switch (self.*) {
            .xz => |*d| d.deinit(),
            else => {},
        }
    }
};

const ZlsVersion = union(enum) {
    tagged: []const u8,
    master: void,
};

pub fn downloadZls(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    version: ZlsVersion,
    target_dir: std.fs.Dir,
) !void {
    _ = allocator;
    _ = client;
    _ = version;
    _ = target_dir;
    // const source = version.getNativeSource() orelse return error.NoSourceForVersion;
    // const source_uri = try std.Uri.parse(source.tarball);
    // try downloadAndExtract(allocator, client, source_uri, target_dir, null);
}

pub const ZlsRelease = struct {
    tag_name: []const u8,
    assets: []Asset,

    pub fn getNativeAsset(self: @This()) ?Asset {
        const possible_exts = [_][]const u8{ ".zip", ".tar", ".tar.xz", ".tar.gz" };
        const possible_arch = switch (builtin.cpu.arch) {
            .aarch64 => [_][]const u8{"aarch64"},
            .loongarch64 => [_][]const u8{"loongarch64"},
            .powerpc64le => [_][]const u8{"powerpc64le"},
            .riscv64 => [_][]const u8{"riscv64"},
            .x86 => [_][]const u8{ "x86", "i386" },
            .x86_64 => [_][]const u8{"x86_64"},
            else => @compileError("unsupported arch"),
        };
        const os_str = switch (builtin.os.tag) {
            .windows => "windows",
            .linux => "linux",
            .macos => "maxos",
        };
    }

    const Asset = struct {
        url: []const u8,
        size: u64,
        name: []const u8,
    };
};

/// Fetches the zls versions from the Github releases API.
pub fn fetchZlsVersions(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
) !std.json.Parsed([]ZlsRelease) {
    var response_body = std.ArrayList(u8).init(allocator);
    defer response_body.deinit();

    const response = try client.fetch(.{
        .method = .GET,
        .location = .{ .url = zls_releases_url },
        .response_storage = .{ .dynamic = &response_body },
    });

    if (response.status != .ok) return error.StatusNotOk;

    return std.json.parseFromSlice([]ZlsRelease, allocator, response_body.items, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}
