//! Checks minisign signatures (https://jedisct1.github.io/minisign/): how zcaml
//! knows its index is the one zcaml's CI signed.
const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;
const Blake2b512 = std.crypto.hash.blake2.Blake2b512;

pub const Error = error{
    /// Not a minisign public key or signature.
    Malformed,
    /// Signed with another key.
    WrongKey,
    /// The signature isn't of this file, or its trusted comment changed.
    BadSignature,
};

pub const PublicKey = struct {
    key_id: [8]u8,
    key: Ed25519.PublicKey,

    /// A key as `minisign -G` writes it: its file, or the file's second line.
    pub fn parse(text: []const u8) Error!PublicKey {
        var lines = std.mem.tokenizeAny(u8, text, "\r\n");
        var line = lines.next() orelse return error.Malformed;
        if (std.mem.startsWith(u8, line, "untrusted comment:")) line = lines.next() orelse return error.Malformed;
        var bytes: [2 + 8 + Ed25519.PublicKey.encoded_length]u8 = undefined;
        try decode(&bytes, line);
        if (!std.mem.eql(u8, bytes[0..2], "Ed")) return error.Malformed;
        return .{
            .key_id = bytes[2..10].*,
            .key = Ed25519.PublicKey.fromBytes(bytes[10..].*) catch return error.Malformed,
        };
    }

    /// Checks that `signature` (a `.minisig` file) is of `message`, and returns
    /// its trusted comment.
    pub fn verify(pk: PublicKey, message: []const u8, signature: []const u8) Error![]const u8 {
        var lines = std.mem.tokenizeAny(u8, signature, "\r\n");
        const untrusted = lines.next() orelse return error.Malformed;
        if (!std.mem.startsWith(u8, untrusted, "untrusted comment:")) return error.Malformed;
        var sig: [2 + 8 + Ed25519.Signature.encoded_length]u8 = undefined;
        try decode(&sig, lines.next() orelse return error.Malformed);
        const trusted_prefix = "trusted comment: ";
        const trusted = lines.next() orelse return error.Malformed;
        if (!std.mem.startsWith(u8, trusted, trusted_prefix)) return error.Malformed;
        var global: [Ed25519.Signature.encoded_length]u8 = undefined;
        try decode(&global, lines.next() orelse return error.Malformed);

        if (!std.mem.eql(u8, sig[2..10], &pk.key_id)) return error.WrongKey;
        const file_sig: Ed25519.Signature = .fromBytes(sig[10..].*);
        // `ED`: the signature is of the file's BLAKE2b-512, minisign's default;
        // `Ed`: of the file itself (`minisign -l`).
        if (std.mem.eql(u8, sig[0..2], "ED")) {
            var digest: [Blake2b512.digest_length]u8 = undefined;
            Blake2b512.hash(message, &digest, .{});
            file_sig.verify(&digest, pk.key) catch return error.BadSignature;
        } else if (std.mem.eql(u8, sig[0..2], "Ed")) {
            file_sig.verify(message, pk.key) catch return error.BadSignature;
        } else return error.Malformed;

        // The trusted comment is signed with the file's signature.
        const comment = trusted[trusted_prefix.len..];
        var verifier = Ed25519.Signature.fromBytes(global).verifier(pk.key) catch return error.BadSignature;
        verifier.update(sig[10..]);
        verifier.update(comment);
        verifier.verify() catch return error.BadSignature;
        return comment;
    }
};

fn decode(out: []u8, text: []const u8) Error!void {
    const decoder = std.base64.standard.Decoder;
    const line = std.mem.trim(u8, text, " \t");
    const len = decoder.calcSizeForSlice(line) catch return error.Malformed;
    if (len != out.len) return error.Malformed;
    decoder.decode(out, line) catch return error.Malformed;
}

// Made with minisign 0.12: `minisign -G -W`, then `minisign -S` (and `-l`).
const test_key =
    \\untrusted comment: minisign public key 674979100681FD5E
    \\RWRe/YEGEHlJZw3hMbmN6fF65LfyFdi8nn+yd8irOjRXxYmikUeqjnyG
    \\
;
const test_message = "zcaml minisign test\n";
const test_signature =
    \\untrusted comment: signature from minisign secret key
    \\RURe/YEGEHlJZwNqflyDyn7f54myd9AXb3ialr4qd1MSalvxvy/Lxzq+y4AN49BxiCB2CK4GCGXI3t38A2u4uqYbAGMRPYss7AM=
    \\trusted comment: trusted test
    \\B53AJy1Gs7BdVm7gmJDPlIIgkhIo65hSsYvPfbHwlk7f3C15Ms6/2lByocxZiAAcLlD6BT5HKb2iLGCcPK0QAA==
    \\
;
const test_legacy_signature =
    \\untrusted comment: signature from minisign secret key
    \\RWRe/YEGEHlJZ2bgr5bd5dxGiPsZ8/+eLmLv1QT0G4o1GVIEeQleu0xQ/REnDLGSsYGlWCr8pfdAPPANs6CsOQf27DaT8+rF9ws=
    \\trusted comment: legacy test
    \\1LF5ZPAqvPUT97R4P98hB/fiSxH+L+Gpl8FPkaQ8Y0ijhGxsRrK6e8hC23WwoZC2SmeLgVgRZyLJt+CQajMUAw==
    \\
;

test "a signature of the file" {
    const pk: PublicKey = try .parse(test_key);
    try std.testing.expectEqualStrings("trusted test", try pk.verify(test_message, test_signature));
    try std.testing.expectEqualStrings("legacy test", try pk.verify(test_message, test_legacy_signature));
    // The key's line alone.
    _ = try PublicKey.parse("RWRe/YEGEHlJZw3hMbmN6fF65LfyFdi8nn+yd8irOjRXxYmikUeqjnyG");
}

test "what isn't" {
    const pk: PublicKey = try .parse(test_key);
    try std.testing.expectError(error.BadSignature, pk.verify("zcaml minisign test!\n", test_signature));

    // Its trusted comment, changed.
    var changed: [test_signature.len]u8 = test_signature.*;
    const at = std.mem.find(u8, &changed, "trusted test").?;
    changed[at] = 'T';
    try std.testing.expectError(error.BadSignature, pk.verify(test_message, &changed));

    var other = pk;
    other.key_id[0] ^= 1;
    try std.testing.expectError(error.WrongKey, other.verify(test_message, test_signature));
    try std.testing.expectError(error.Malformed, pk.verify(test_message, "untrusted comment: x\nnot base64\n"));
    try std.testing.expectError(error.Malformed, PublicKey.parse("untrusted comment: x\n"));
}
