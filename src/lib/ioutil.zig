const std = @import("std");

pub const TeeReader = struct {
    inner: std.io.AnyReader,
    tee: ?std.io.AnyWriter,

    pub fn init(inner: std.io.AnyReader, tee: ?std.io.AnyWriter) TeeReader {
        return TeeReader{ .inner = inner, .tee = tee };
    }

    pub fn read(self: TeeReader, buf: []u8) !usize {
        const bytes_read = try self.inner.read(buf);
        if (self.tee) |tee| try tee.writeAll(buf[0..bytes_read]);
        return bytes_read;
    }

    fn typeErasedReadFn(context: *const anyopaque, buffer: []u8) anyerror!usize {
        const ptr: *const TeeReader = @alignCast(@ptrCast(context));
        return read(ptr.*, buffer);
    }

    pub fn anyReader(self: *TeeReader) std.io.AnyReader {
        return .{
            .context = @ptrCast(self),
            .readFn = typeErasedReadFn,
        };
    }
};

pub const ProgressWriter = struct {
    node: std.Progress.Node,
    n: *usize,

    pub fn init(allocator: std.mem.Allocator, node: std.Progress.Node) !ProgressWriter {
        const n = try allocator.create(usize);
        n.* = 0;
        return .{ .node = node, .n = n };
    }

    pub fn deinit(self: ProgressWriter, allocator: std.mem.Allocator) void {
        allocator.destroy(self.n);
    }

    pub fn write(self: ProgressWriter, buf: []const u8) !usize {
        self.n.* += buf.len;
        self.node.setCompletedItems(self.n.*);
        return buf.len;
    }

    fn typeErasedWriteFn(context: *const anyopaque, buffer: []const u8) anyerror!usize {
        const ptr: *const ProgressWriter = @alignCast(@ptrCast(context));
        return write(ptr.*, buffer);
    }

    pub fn anyWriter(self: *ProgressWriter) std.io.AnyWriter {
        return .{
            .context = @ptrCast(self),
            .writeFn = typeErasedWriteFn,
        };
    }
};

/// Reads all data from the provided reader without preserving the data.
pub fn discard(reader: anytype) anyerror!void {
    var buf: [512]u8 = undefined;
    while (try reader.read(&buf) > 0) continue;
}
