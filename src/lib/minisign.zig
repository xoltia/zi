const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;
const Blake2b512 = std.crypto.hash.blake2.Blake2b512;
const base64_decoder = std.base64.Base64Decoder.init(std.base64.standard_alphabet_chars, '=');

/// PublicKey implements only parsing of the base64
/// encoded line of the minisign public key format.
pub const PublicKey = struct {
    id: [8]u8,
    key: Ed25519.PublicKey,

    pub fn fromBase64(str: []const u8) !PublicKey {
        if (str.len != 56) return error.InvalidLength;
        var data: [42]u8 = undefined;
        try base64_decoder.decode(&data, str);
        if (!std.mem.eql(u8, data[0..2], "Ed")) return error.UnexpectedAlgorithm;
        var key_data: [32]u8 = undefined;
        @memcpy(&key_data, data[10..42]);
        var public_key = PublicKey{
            .id = undefined,
            .key = try .fromBytes(key_data),
        };
        @memcpy(&public_key.id, data[2..10]);
        return public_key;
    }
};

/// Signature implements only parsing of the base64
/// encoded line of the minisign signature format for
/// the file data (not the global_signature).
pub const Signature = struct {
    pub const Algorithm = enum {
        legacy, // ed25519(<file data>)
        prehash, // ed25519(Blake2b-512(<file data>))
    };
    key_id: [8]u8,
    algorithm: Algorithm,
    signature: Ed25519.Signature,

    pub fn fromBase64(str: []const u8) !Signature {
        if (str.len != 100) return error.InvalidLength;
        var data: [74]u8 = undefined;
        try base64_decoder.decode(&data, str);
        const algorithm: Algorithm =
            if (std.mem.eql(u8, data[0..2], "Ed"))
                .legacy
            else if (std.mem.eql(u8, data[0..2], "ED"))
                .prehash
            else
                return error.InvalidAlgorithm;

        var key_data: [64]u8 = undefined;
        @memcpy(&key_data, data[10..74]);
        var signature = Signature{
            .algorithm = algorithm,
            .key_id = undefined,
            .signature = .fromBytes(key_data),
        };
        @memcpy(&signature.key_id, data[2..10]);
        return signature;
    }

    pub fn verifier(self: Signature, allocator: std.mem.Allocator, public_key: PublicKey) !Verifier {
        if (!std.mem.eql(u8, &self.key_id, &public_key.id))
            return error.PublicKeyMismatch;

        const ed_verifier = try allocator.create(Ed25519.Verifier);
        errdefer allocator.destroy(ed_verifier);
        ed_verifier.* = try self.signature.verifier(public_key.key);

        var minisign_verifier = Verifier{
            .allocator = allocator,
            .ed_verifier = ed_verifier,
            .hash = null,
        };

        switch (self.algorithm) {
            .legacy => {},
            .prehash => {
                minisign_verifier.hash = try allocator.create(Blake2b512);
                minisign_verifier.hash.?.* = .init(.{});
            },
        }

        return minisign_verifier;
    }
};

pub const Verifier = struct {
    allocator: std.mem.Allocator,
    ed_verifier: *Ed25519.Verifier,
    hash: ?*Blake2b512,

    pub fn deinit(self: Verifier) void {
        self.allocator.destroy(self.ed_verifier);
        if (self.hash) |h| self.allocator.destroy(h);
    }

    pub fn update(self: Verifier, message: []const u8) void {
        if (self.hash) |hash| {
            hash.update(message);
        } else {
            self.ed_verifier.update(message);
        }
    }

    pub fn verify(self: Verifier) Ed25519.Verifier.VerifyError!void {
        if (self.hash) |hash| {
            var digest: [Blake2b512.digest_length]u8 = undefined;
            hash.final(&digest);
            self.ed_verifier.update(&digest);
        }
        try self.ed_verifier.verify();
    }

    fn typeErasedWriteFn(context: *const anyopaque, buffer: []const u8) anyerror!usize {
        const ptr: *const Verifier = @alignCast(@ptrCast(context));
        update(ptr.*, buffer);
        return buffer.len;
    }

    pub fn anyWriter(self: *Verifier) std.io.AnyWriter {
        return .{
            .context = @ptrCast(self),
            .writeFn = typeErasedWriteFn,
        };
    }
};
