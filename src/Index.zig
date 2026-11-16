//! zcaml's index: the releases it installs (its OCaml toolchains, dune, the Zig
//! they compile C with and the macOS SDK), each archive by its SHA-256. zcaml's
//! CI publishes it at `url` when it releases one, signed with the key in
//! `index.pub` (the repository's).
//!
//! `v1` in its URL is the archives' layout: one this zcaml can install. A layout
//! that changes is another index, so a zcaml never sees releases it can't use.
const Index = @This();

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Store = @import("Store.zig");
const minisign = @import("minisign.zig");
pub const Target = @import("target.zig").Target;

const log = std.log.scoped(.zcaml);

/// Higher in each index the CI publishes: zcaml refuses one older than one it
/// has seen, which is what serving a stale index would be.
serial: u64,
/// The newest first: by version, then revision.
ocaml: []const Ocaml,
/// The newest first.
dune: []const Dune,
zig: []const Zig,
macos_sdk: []const MacosSdk,

pub const url = "https://zcaml.dev/index/v1.json";
pub const schema = 1;
/// minisign's, the repository's `index.pub`: `minisign -V -p index.pub -m v1.json`.
const public_key = @embedFile("index.pub");

pub const LoadError = error{
    /// Reported: zcaml has no index it can use.
    IndexUnavailable,
} || std.mem.Allocator.Error || Io.Cancelable;

/// The index: the one zcaml fetched in the last hour, or the one at `url`
/// (`$ZCAML_INDEX_URL`, with `$ZCAML_INDEX_KEY` for its key). If it can't be
/// fetched, the last one is used.
pub fn load(store: *Store) LoadError!Index {
    const arena = store.arena;
    const io = store.io;
    const source: Source = try .init(store);

    // By source: another's serials are its own.
    var digest: [32]u8 = undefined;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(source.url);
    hasher.update("\x00");
    hasher.update(&source.key.key_id);
    hasher.final(&digest);
    const cache_dir = try std.fs.path.join(arena, &.{ store.root, "index", &std.fmt.bytesToHex(digest[0..8].*, .lower) });

    const cached = readCached(arena, io, cache_dir, source.key);
    if (cached) |c| if (c.fresh) return c.index;

    const fetched = fetchVerified(store, source) catch |err| switch (err) {
        error.OutOfMemory, error.Canceled => |e| return e,
        else => {
            if (cached) |c| {
                switch (err) {
                    error.BadSignature, error.WrongKey => log.warn(
                        "{s} isn't signed with zcaml's key ({t}): using the one zcaml fetched before",
                        .{ source.url, err },
                    ),
                    else => log.warn("fetching {s} failed ({t}): using the one zcaml fetched before", .{ source.url, err }),
                }
                return c.index;
            }
            switch (err) {
                error.BadSignature, error.WrongKey => log.err(
                    "{s} isn't signed with zcaml's key ({t}): refusing it",
                    .{ source.url, err },
                ),
                else => log.err("fetching zcaml's index ({s}) failed: {t}", .{ source.url, err }),
            }
            return error.IndexUnavailable;
        },
    };
    if (cached) |c| if (fetched.index.serial < c.index.serial) {
        log.warn("{s} is older than the one zcaml fetched before (serial {d}, not {d}): using that one", .{
            source.url, fetched.index.serial, c.index.serial,
        });
        return c.index;
    };
    store.writeAtomic(cache_dir, "v1.json", fetched.json) catch |err| return cacheFailed(err);
    store.writeAtomic(cache_dir, "v1.json.minisig", fetched.signature) catch |err| return cacheFailed(err);
    return fetched.index;
}

/// The OCaml release `spec` is: `5.5.1`, its newest revision, or `5.5.1-13`.
pub fn ocamlRelease(index: *const Index, spec: []const u8) ?*const Ocaml {
    const version, const revision: ?u32 = if (std.mem.findScalar(u8, spec, '-')) |dash|
        .{ spec[0..dash], std.fmt.parseInt(u32, spec[dash + 1 ..], 10) catch return null }
    else
        .{ spec, null };
    for (index.ocaml) |*release| {
        if (!std.mem.eql(u8, release.version, version)) continue;
        if (revision == null or revision.? == release.revision) return release;
    }
    return null;
}

/// The dune zcaml installs: the newest.
pub fn latestDune(index: *const Index) ?*const Dune {
    return if (index.dune.len == 0) null else &index.dune[0];
}

pub fn zigRelease(index: *const Index, version: []const u8) *const Zig {
    for (index.zig) |*release| {
        if (std.mem.eql(u8, release.version, version)) return release;
    }
    unreachable; // `parse` checked every OCaml's is there.
}

pub fn macosSdk(index: *const Index, revision: []const u8) *const MacosSdk {
    for (index.macos_sdk) |*sdk| {
        if (std.mem.eql(u8, sdk.revision, revision)) return sdk;
    }
    unreachable; // `parse` checked every OCaml's is there.
}

/// Something to download: `Store` checks its size and hash before unpacking it.
pub const Download = struct {
    url: []const u8,
    sha256: []const u8,
    size: u64,
    format: Format,

    pub const Format = enum {
        @"tar.zst",
        @"tar.xz",
        @"tar.gz",
        zip,

        fn of(archive_url: []const u8) ?Format {
            for (std.enums.values(Format)) |format| {
                const extension = @tagName(format);
                if (archive_url.len > extension.len and std.mem.endsWith(u8, archive_url, extension) and
                    archive_url[archive_url.len - extension.len - 1] == '.') return format;
            }
            return null;
        }
    };
};

pub const Ocaml = struct {
    version: []const u8,
    /// zcaml's build of it: the releases' `ocaml-v<version>-<revision>`.
    revision: u32,
    /// The Zig its C compiler is.
    zig: []const u8,
    /// The macOS SDK its macOS toolchains compile C with.
    macos_sdk: []const u8,
    archives: []const Archive,

    pub const Archive = struct {
        /// Where the compiler runs.
        host: Target,
        /// Where what it compiles runs.
        target: Target,
        download: Download,
    };

    pub fn archive(release: *const Ocaml, host: Target, target: Target) ?*const Archive {
        for (release.archives) |*a| {
            if (a.host == host and a.target == target) return a;
        }
        return null;
    }
};

/// zcaml's dune: one binary per host, for any OCaml version.
pub const Dune = struct {
    /// As `dune --version` prints it: `3.24.2+zcaml.7`.
    version: []const u8,
    archives: []const Archive,

    pub const Archive = struct {
        host: Target,
        download: Download,
    };

    pub fn archive(dune: *const Dune, host: Target) ?*const Archive {
        for (dune.archives) |*a| {
            if (a.host == host) return a;
        }
        return null;
    }
};

/// ziglang.org's builds, which are static: one per architecture and OS.
pub const Zig = struct {
    version: []const u8,
    archives: []const Archive,

    pub const Archive = struct {
        arch: Target.Arch,
        os: Target.Os,
        download: Download,
    };

    pub fn archive(zig: *const Zig, host: Target) ?*const Archive {
        for (zig.archives) |*a| {
            if (a.arch == host.arch() and a.os == host.os()) return a;
        }
        return null;
    }
};

/// What compiling C for macOS needs, anywhere but on a Mac with Xcode
/// (`ZCAML_MACOS_SDK`): hexops' xcode-frameworks, at a commit.
pub const MacosSdk = struct {
    revision: []const u8,
    download: Download,
};

/// The index as it's published: what `build/index.zig` writes. Fields that are
/// added later are ignored, and so are archives for targets this zcaml doesn't
/// have.
pub const Json = struct {
    schema: u32,
    serial: u64,
    ocaml: []const OcamlRelease,
    dune: []const DuneRelease,
    zig: []const ZigRelease,
    macos_sdk: []const SdkRelease,

    pub const OcamlRelease = struct {
        version: []const u8,
        revision: u32,
        zig: []const u8,
        macos_sdk: []const u8,
        archives: []const struct { host: []const u8, target: []const u8, url: []const u8, sha256: []const u8, size: u64 },
    };
    pub const DuneRelease = struct {
        version: []const u8,
        archives: []const struct { host: []const u8, url: []const u8, sha256: []const u8, size: u64 },
    };
    pub const ZigRelease = struct {
        version: []const u8,
        archives: []const struct { arch: []const u8, os: []const u8, url: []const u8, sha256: []const u8, size: u64 },
    };
    pub const SdkRelease = struct { revision: []const u8, url: []const u8, sha256: []const u8, size: u64 };

    /// An element of `T`'s `archives`.
    pub fn Archive(T: type) type {
        return @typeInfo(@FieldType(T, "archives")).pointer.child;
    }
};

pub const ParseError = error{
    /// Not an index this zcaml can read: its schema, or what it says.
    InvalidIndex,
} || std.mem.Allocator.Error;

pub fn parse(arena: std.mem.Allocator, json: []const u8) ParseError!Index {
    const raw = std.json.parseFromSliceLeaky(Json, arena, json, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => return invalid("{t}", .{err}),
    };
    if (raw.schema != schema) return invalid("its schema is {d}, not {d}", .{ raw.schema, schema });

    const zig = try arena.alloc(Zig, raw.zig.len);
    for (raw.zig, zig) |r, *z| {
        var archives: std.ArrayList(Zig.Archive) = .empty;
        for (r.archives) |a| {
            const arch = std.meta.stringToEnum(Target.Arch, a.arch) orelse continue;
            const os = std.meta.stringToEnum(Target.Os, a.os) orelse continue;
            try archives.append(arena, .{ .arch = arch, .os = os, .download = try download(a.url, a.sha256, a.size) });
        }
        z.* = .{ .version = r.version, .archives = archives.items };
    }

    const macos_sdk = try arena.alloc(MacosSdk, raw.macos_sdk.len);
    for (raw.macos_sdk, macos_sdk) |r, *sdk| sdk.* = .{ .revision = r.revision, .download = try download(r.url, r.sha256, r.size) };

    const dune = try arena.alloc(Dune, raw.dune.len);
    for (raw.dune, dune) |r, *d| {
        var archives: std.ArrayList(Dune.Archive) = .empty;
        for (r.archives) |a| {
            const host = Target.parse(a.host) orelse continue;
            try archives.append(arena, .{ .host = host, .download = try download(a.url, a.sha256, a.size) });
        }
        d.* = .{ .version = r.version, .archives = archives.items };
    }

    const ocaml = try arena.alloc(Ocaml, raw.ocaml.len);
    for (raw.ocaml, ocaml) |r, *o| {
        var archives: std.ArrayList(Ocaml.Archive) = .empty;
        for (r.archives) |a| {
            const host = Target.parse(a.host) orelse continue;
            const target = Target.parse(a.target) orelse continue;
            try archives.append(arena, .{ .host = host, .target = target, .download = try download(a.url, a.sha256, a.size) });
        }
        o.* = .{ .version = r.version, .revision = r.revision, .zig = r.zig, .macos_sdk = r.macos_sdk, .archives = archives.items };
        for (zig) |z| {
            if (std.mem.eql(u8, z.version, r.zig)) break;
        } else return invalid("OCaml {s}-{d}'s Zig {s} isn't in it", .{ r.version, r.revision, r.zig });
        for (macos_sdk) |sdk| {
            if (std.mem.eql(u8, sdk.revision, r.macos_sdk)) break;
        } else return invalid("OCaml {s}-{d}'s macOS SDK {s} isn't in it", .{ r.version, r.revision, r.macos_sdk });
    }

    return .{ .serial = raw.serial, .ocaml = ocaml, .dune = dune, .zig = zig, .macos_sdk = macos_sdk };
}

fn download(archive_url: []const u8, sha256: []const u8, size: u64) ParseError!Download {
    if (!std.mem.startsWith(u8, archive_url, "https://")) return invalid("{s} isn't an https:// URL", .{archive_url});
    const format = Download.Format.of(archive_url) orelse return invalid("{s}: not an archive zcaml unpacks", .{archive_url});
    if (sha256.len != 64) return invalid("{s}'s SHA-256 isn't one", .{archive_url});
    for (sha256) |c| switch (c) {
        '0'...'9', 'a'...'f' => {},
        else => return invalid("{s}'s SHA-256 isn't one", .{archive_url}),
    };
    return .{ .url = archive_url, .sha256 = sha256, .size = size, .format = format };
}

fn invalid(comptime fmt: []const u8, args: anytype) error{InvalidIndex} {
    // Not an error yet: one zcaml fetched before may do. Tests fail on warnings.
    if (!builtin.is_test) log.warn("zcaml's index: " ++ fmt, args);
    return error.InvalidIndex;
}

/// Where the index comes from, and the key it's signed with.
const Source = struct {
    url: []const u8,
    key: minisign.PublicKey,

    fn init(store: *Store) error{IndexUnavailable}!Source {
        const env_url = nonEmpty(store.environ.get("ZCAML_INDEX_URL"));
        const env_key = nonEmpty(store.environ.get("ZCAML_INDEX_KEY"));
        const key = minisign.PublicKey.parse(env_key orelse public_key) catch {
            if (env_key == null) unreachable; // A test checks it.
            log.err("ZCAML_INDEX_KEY isn't a minisign public key", .{});
            return error.IndexUnavailable;
        };
        return .{ .url = env_url orelse url, .key = key };
    }
};

const Cached = struct {
    index: Index,
    /// Fetched less than `max_age` ago.
    fresh: bool,
};

/// How long zcaml uses an index it fetched without fetching it again.
const max_age: Io.Duration = .fromSeconds(60 * 60);

/// The index zcaml fetched last, if it's still one it trusts.
fn readCached(arena: std.mem.Allocator, io: Io, dir_path: []const u8, key: minisign.PublicKey) ?Cached {
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{}) catch return null;
    defer dir.close(io);
    const json = dir.readFileAlloc(io, "v1.json", arena, .limited(max_size)) catch return null;
    const signature = dir.readFileAlloc(io, "v1.json.minisig", arena, .limited(max_signature_size)) catch return null;
    // Written apart: a run between the two writes sees another's signature.
    _ = key.verify(json, signature) catch return null;
    const index = parse(arena, json) catch return null;
    const stat = dir.statFile(io, "v1.json", .{}) catch return null;
    const age = stat.mtime.durationTo(Io.Clock.real.now(io));
    return .{ .index = index, .fresh = age.toSeconds() >= 0 and age.toSeconds() < max_age.toSeconds() };
}

const max_size = 64 * 1024 * 1024;
const max_signature_size = 4096;

const Fetched = struct {
    index: Index,
    json: []const u8,
    signature: []const u8,
};

fn fetchVerified(store: *Store, source: Source) !Fetched {
    const arena = store.arena;
    const json = try get(store, source.url, max_size);
    const signature = try get(store, try std.fmt.allocPrint(arena, "{s}.minisig", .{source.url}), max_signature_size);
    _ = try source.key.verify(json, signature);
    return .{ .index = try parse(arena, json), .json = json, .signature = signature };
}

/// `file://` too, for tests.
fn get(store: *Store, location: []const u8, limit: usize) ![]const u8 {
    const arena = store.arena;
    const io = store.io;
    if (std.mem.startsWith(u8, location, "file://")) {
        return Io.Dir.cwd().readFileAlloc(io, location["file://".len..], arena, .limited(limit));
    }
    try store.initClient();

    // What fails is the network: as `Store.fetch`.
    const delays_s = [_]i64{ 1, 4, 10 };
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        if (getOnce(store, location, limit)) |body| return body else |err| switch (err) {
            error.Canceled, error.OutOfMemory, error.StreamTooLong => |e| return e,
            else => {
                if (attempt == delays_s.len) return err;
                log.warn("fetching {s} failed ({t}): trying again", .{ location, err });
                try io.sleep(.fromSeconds(delays_s[attempt]), .awake);
            },
        }
    }
}

fn getOnce(store: *Store, location: []const u8, limit: usize) ![]const u8 {
    var body: Io.Writer.Allocating = .init(store.arena);
    const result = try store.client.?.fetch(.{
        .location = .{ .url = location },
        .response_writer = &body.writer,
        .redirect_behavior = .init(5),
        .keep_alive = false,
    });
    if (result.status != .ok) return error.HttpStatus;
    if (body.written().len > limit) return error.StreamTooLong;
    return body.written();
}

fn cacheFailed(err: anyerror) LoadError {
    if (err == error.Canceled) return error.Canceled;
    log.err("saving zcaml's index in the store failed: {t}", .{err});
    return error.IndexUnavailable;
}

fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    const v = value orelse return null;
    return if (v.len == 0) null else v;
}

/// An index for tests: OCaml 5.5.1-13 and -12, for x86_64 Linux and what it
/// compiles for.
pub const testing: Index = testing: {
    const sha: []const u8 = &@as([64]u8, @splat('0'));
    const dl = struct {
        fn of(comptime name: []const u8, comptime format: Download.Format) Download {
            return .{ .url = "https://example.com/" ++ name ++ "." ++ @tagName(format), .sha256 = sha, .size = 1, .format = format };
        }
    }.of;
    const host: Target = .@"x86_64-linux-gnu";
    const ocaml_archives: []const Ocaml.Archive = &.{
        .{ .host = host, .target = host, .download = dl("ocaml-native", .@"tar.zst") },
        .{ .host = host, .target = .@"x86_64-windows-gnu", .download = dl("ocaml-windows", .@"tar.zst") },
        .{ .host = host, .target = .@"aarch64-macos-none", .download = dl("ocaml-macos", .@"tar.zst") },
    };
    break :testing .{
        .serial = 1,
        .ocaml = &.{
            .{ .version = "5.5.1", .revision = 13, .zig = "0.17.0", .macos_sdk = "62f660e82e4e", .archives = ocaml_archives },
            .{ .version = "5.5.1", .revision = 12, .zig = "0.17.0", .macos_sdk = "62f660e82e4e", .archives = ocaml_archives },
        },
        .dune = &.{.{ .version = "3.24.2+zcaml.7", .archives = &.{.{ .host = host, .download = dl("dune", .@"tar.zst") }} }},
        .zig = &.{.{ .version = "0.17.0", .archives = &.{.{ .arch = .x86_64, .os = .linux, .download = dl("zig", .@"tar.xz") }} }},
        .macos_sdk = &.{.{ .revision = "62f660e82e4e", .download = dl("sdk", .@"tar.gz") }},
    };
};

test "index.pub is a minisign key" {
    _ = try minisign.PublicKey.parse(public_key);
}

test ocamlRelease {
    try std.testing.expectEqual(13, testing.ocamlRelease("5.5.1").?.revision);
    try std.testing.expectEqual(12, testing.ocamlRelease("5.5.1-12").?.revision);
    try std.testing.expectEqual(null, testing.ocamlRelease("5.5.1-11"));
    try std.testing.expectEqual(null, testing.ocamlRelease("5.5"));
    try std.testing.expectEqual(null, testing.ocamlRelease("5.5.1-x"));
}

test parse {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const sha: []const u8 = &@as([64]u8, @splat('a'));
    const json = std.fmt.comptimePrint(
        \\{{"schema": 1, "serial": 7, "later": true,
        \\ "ocaml": [{{"version": "5.5.1", "revision": 13, "zig": "0.17.0", "macos_sdk": "62f660e82e4e", "archives": [
        \\   {{"host": "x86_64-linux-gnu", "target": "x86_64-linux-gnu", "url": "https://e.com/o.tar.zst", "sha256": "{0s}", "size": 3}},
        \\   {{"host": "x86_64-linux-gnu", "target": "mips-plan9", "url": "https://e.com/p.tar.zst", "sha256": "{0s}", "size": 3}}]}}],
        \\ "dune": [{{"version": "3.24.2+zcaml.7", "archives": [{{"host": "x86_64-linux-gnu", "url": "https://e.com/d.tar.zst", "sha256": "{0s}", "size": 2}}]}}],
        \\ "zig": [{{"version": "0.17.0", "archives": [{{"arch": "x86_64", "os": "windows", "url": "https://e.com/z.zip", "sha256": "{0s}", "size": 1}}]}}],
        \\ "macos_sdk": [{{"revision": "62f660e82e4e", "url": "https://e.com/s.tar.gz", "sha256": "{0s}", "size": 1}}]}}
    , .{sha});
    const index = try parse(arena, json);
    try std.testing.expectEqual(7, index.serial);
    // The unknown target's archive is left out.
    try std.testing.expectEqual(1, index.ocaml[0].archives.len);
    try std.testing.expectEqual(.zip, index.zig[0].archives[0].download.format);
    try std.testing.expectEqualStrings("3.24.2+zcaml.7", index.latestDune().?.version);

    try std.testing.expectError(error.InvalidIndex, parse(arena,
        \\{"schema": 2, "serial": 1, "ocaml": [], "dune": [], "zig": [], "macos_sdk": []}
    ));
    try std.testing.expectError(error.InvalidIndex, parse(arena,
        \\{"schema": 1, "serial": 1, "dune": [], "zig": [], "macos_sdk": [],
        \\ "ocaml": [{"version": "5.5.1", "revision": 1, "zig": "0.16.0", "macos_sdk": "x", "archives": []}]}
    ));
}
