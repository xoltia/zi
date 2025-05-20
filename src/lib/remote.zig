const std = @import("std");
const builtin = @import("builtin");
const tempfile = @import("tempfile.zig");
const xz = std.compress.xz;
const gzip = std.compress.gzip;
const ioutil = @import("ioutil.zig");
const MultiWriter = ioutil.MultiWriter;
const TeeReader = ioutil.TeeReader;
const ProgressWriter = ioutil.ProgressWriter;
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
    progress: std.Progress.Node,
) !void {
    const source = version.getNativeSource() orelse return error.NoSourceForVersion;
    const source_uri = try std.Uri.parse(source.tarball);
    const size = try std.fmt.parseInt(usize, source.size, 10);

    progress.setEstimatedTotalItems(size);
    var progress_writer = try ProgressWriter.init(allocator, progress);
    defer progress_writer.deinit(allocator);
    var sha256 = Sha256.init(.{});
    var multi = MultiWriter.init(&.{
        sha256.writer().any(),
        progress_writer.anyWriter(),
    });

    try downloadAndExtract(allocator, client, source_uri, target_dir, multi.anyWriter());
    const sum = sha256.finalResult();
    const sum_str = &std.fmt.bytesToHex(sum, .lower);
    const match = std.mem.eql(u8, source.shasum, sum_str);
    if (!match) return error.SumMismatch;
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
    var header_buffer: [8192]u8 = undefined;
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
        try extractZip(allocator, target_dir, reader);
        try ioutil.discard(reader);
        return;
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

    if (compression_type == null) {
        try std.tar.pipeToFileSystem(target_dir, reader, .{});
        try ioutil.discard(reader);
        return;
    }

    const ext = std.meta.stringToEnum(enum { xz, gz }, compression_type.?) orelse
        return error.UnsupportedCompressionType;

    switch (ext) {
        .xz => {
            var xz_decompressor = try xz.decompress(allocator, reader);
            defer xz_decompressor.deinit();
            try std.tar.pipeToFileSystem(target_dir, xz_decompressor.reader(), .{});
        },
        .gz => {
            var gzip_decompressor = gzip.decompressor(reader);
            try std.tar.pipeToFileSystem(target_dir, gzip_decompressor.reader(), .{});
        },
    }

    // Make sure to read everything so the checksum doesn't get messed up.
    try ioutil.discard(reader);
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

pub fn fetchDownloadTaggedZls(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    tag_name: []const u8,
    target_dir: std.fs.Dir,
    progress: std.Progress.Node,
) !void {
    const fetch_progress = progress.start("Fetching zls versions", 0);
    const versions = try fetchZlsVersions(allocator, client);
    defer versions.deinit();
    fetch_progress.end();

    const release = for (versions.value) |release| {
        if (std.mem.eql(u8, release.tag_name, tag_name))
            break release;
    } else return error.NoTaggedRelease;

    const asset = release.getNativeAsset() orelse return error.NoNativeAsset;
    const source_uri = try std.Uri.parse(asset.browser_download_url);
    const download_progress = progress.start("Downloading", asset.size);
    defer download_progress.end();
    var progress_writer = try ProgressWriter.init(allocator, download_progress);
    defer progress_writer.deinit(allocator);
    try downloadAndExtract(allocator, client, source_uri, target_dir, progress_writer.anyWriter());
}

pub fn downloadCompileMasterZls(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    compiler: []const u8,
    version_string: []const u8,
    target_dir: std.fs.Dir,
    progress: std.Progress.Node,
) !void {
    const download_progress = progress.start("Downloading", 0);
    const source_uri = try std.Uri.parse(zls_master_archive_url);
    var progress_writer = try ProgressWriter.init(allocator, download_progress);
    defer progress_writer.deinit(allocator);
    try downloadAndExtract(allocator, client, source_uri, target_dir, progress_writer.anyWriter());
    download_progress.end();

    const compile_progress = progress.start("Compiling", 0);
    const source_dir_path = try target_dir.realpathAlloc(allocator, "zls-master");
    defer allocator.free(source_dir_path);
    const version_arg = try std.fmt.allocPrint(allocator, "-Dversion-string={s}", .{version_string});
    defer allocator.free(version_arg);

    const compiler_args = &[_][]const u8{ compiler, "build", "-Doptimize=ReleaseSafe", version_arg };

    var compiler_process = std.process.Child.init(compiler_args, allocator);
    compiler_process.stderr_behavior = .Ignore;
    compiler_process.stdout_behavior = .Ignore;
    compiler_process.cwd = source_dir_path;
    compiler_process.progress_node = compile_progress;
    const term = try compiler_process.spawnAndWait();
    compile_progress.end();

    var source_dir = try std.fs.cwd().openDir(source_dir_path, .{ .iterate = true });
    defer source_dir.close();
    try source_dir.deleteTree(".zig-cache");

    switch (term) {
        .Exited => |code| {
            if (code != 0)
                return error.UnexpectedExitCode;
        },
        else => return error.CommandFailed,
    }
}

pub const ZlsRelease = struct {
    tag_name: []const u8,
    assets: []Asset,

    const Asset = struct {
        browser_download_url: []const u8,
        size: u64,
        name: []const u8,
    };

    pub fn getNativeAsset(self: @This()) ?Asset {
        const possible_exts = [_][]const u8{ "zip", "tar", "tar.xz", "tar.gz" };
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
            .macos => "macos",
            else => @compileError("unsupported platform"),
        };

        var possible_names: [possible_exts.len * possible_arch.len][]const u8 = undefined;
        comptime var index: comptime_int = 0;
        inline for (possible_exts) |ext| {
            inline for (possible_arch) |arch| {
                const name = std.fmt.comptimePrint("{s}-{s}.{s}", .{ arch, os_str, ext });
                possible_names[index] = name;
                index += 1;
            }
        }

        for (self.assets) |asset| {
            for (possible_names) |name| {
                // Sometimes has `zls-` prefix.
                if (std.mem.endsWith(u8, asset.name, name)) {
                    return asset;
                }
            }
        }

        return null;
    }
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
