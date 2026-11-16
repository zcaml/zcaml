//! Where zcaml keeps what it installs: the OCaml toolchains, dune, Zig and the
//! macOS SDK of zcaml's index, each in a directory named for its version.
//!
//!   ocaml/<version>-<revision>/host-<triple>/target-<triple>/
//!   dune/<version, + as ->/host-<triple>/
//!   zig/<version>/
//!   macos-sdk/<revision>/
//!
//! A directory that exists is complete and never changes: an install unpacks
//! beside it (`tmp/`) and renames into place, so runs can share a store, and a
//! CI cache of it can be restored into any run. `index/` has the index zcaml
//! fetched last, by where it's from.
const Store = @This();

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Index = @import("Index.zig");
const Download = Index.Download;
const Target = @import("target.zig").Target;

const log = std.log.scoped(.zcaml);

io: Io,
gpa: std.mem.Allocator,
/// For the paths it returns: they live as long as the process.
arena: std.mem.Allocator,
environ: *const std.process.Environ.Map,
/// Absolute.
root: []const u8,
client: ?std.http.Client = null,
/// `install`'s unpacks' permits.
unpacking: Io.Semaphore = .{ .permits = max_unpacking },

pub const InitError = error{NoHomeDirectory} || std.mem.Allocator.Error || std.process.CurrentPathAllocError;

/// `$ZCAML_HOME`, or the user's data directory: `%LOCALAPPDATA%\zcaml` on
/// Windows, `~/.local/share/zcaml` (`$XDG_DATA_HOME/zcaml`) elsewhere, macOS
/// too: `~/Library/Application Support` has a space, which breaks builds.
pub fn init(process: std.process.Init) InitError!Store {
    const arena = process.arena.allocator();
    const environ = process.environ_map;
    const root = root: {
        if (nonEmpty(environ.get("ZCAML_HOME"))) |home| {
            if (std.fs.path.isAbsolute(home)) break :root home;
            const cwd = try std.process.currentPathAlloc(process.io, arena);
            break :root try std.fs.path.resolve(arena, &.{ cwd, home });
        }
        if (builtin.os.tag == .windows) {
            const local = nonEmpty(environ.get("LOCALAPPDATA")) orelse return error.NoHomeDirectory;
            break :root try std.fs.path.join(arena, &.{ local, "zcaml" });
        }
        if (nonEmpty(environ.get("XDG_DATA_HOME"))) |data| {
            if (std.fs.path.isAbsolute(data)) break :root try std.fs.path.join(arena, &.{ data, "zcaml" });
        }
        const home = nonEmpty(environ.get("HOME")) orelse return error.NoHomeDirectory;
        break :root try std.fs.path.join(arena, &.{ home, ".local", "share", "zcaml" });
    };
    return .{ .io = process.io, .gpa = process.gpa, .arena = arena, .environ = environ, .root = root };
}

pub fn deinit(store: *Store) void {
    if (store.client) |*client| client.deinit();
    store.* = undefined;
}

pub const Error = error{
    /// Reported: a download, its check or unpacking it failed.
    InstallFailed,
} || std.mem.Allocator.Error || Io.Cancelable;

/// Installs those of `items` that aren't installed, all at once: the downloads
/// run in parallel, at most `max_unpacking` of the unpacks. On a terminal, it
/// shows their progress.
///
/// Once per process: `std.Progress` is the process's, and starts only once.
pub fn install(store: *Store, items: []const Install) Error!void {
    const io = store.io;
    var missing: std.ArrayList(*const Install) = .empty;
    for (items) |*item| {
        if (exists(io, item.dir)) continue;
        for (missing.items) |m| {
            if (std.mem.eql(u8, m.dir, item.dir)) break;
        } else try missing.append(store.arena, item);
    }
    if (missing.items.len == 0) return;

    for (missing.items) |item| log.info("installing {s} ({B:.1})", .{ item.what, item.download.size });
    store.initClient() catch |err| {
        log.err("setting up the HTTP client failed: {t}", .{err});
        return error.InstallFailed;
    };

    const progress = std.Progress.start(io, .{
        .root_name = "installing",
        .estimated_total_items = missing.items.len,
    });
    defer progress.end();

    const results = try store.arena.alloc(Error!void, missing.items.len);
    var group: Io.Group = .init;
    defer group.cancel(io);
    for (missing.items, results) |item, *result| {
        const args = .{ store, item, progress, result };
        group.concurrent(io, installTask, args) catch |err| switch (err) {
            // It runs when the group's awaited, or now.
            error.ConcurrencyUnavailable => group.async(io, installTask, args),
        };
    }
    try group.await(io);

    var failed = false;
    for (results) |result| result catch |err| switch (err) {
        error.OutOfMemory, error.Canceled => |e| return e,
        error.InstallFailed => failed = true,
    };
    if (failed) return error.InstallFailed;
}

/// Something `install` puts in the store.
pub const Install = struct {
    /// For people: "OCaml 5.4.0 for x86_64-linux-gnu".
    what: []const u8,
    /// Absolute: where it is once installed.
    dir: []const u8,
    download: Download,
    layout: Layout,
    /// Windows' programs: each `.exe` gets a manifest (`windows.manifest`).
    manifests: bool = false,
};

pub const ResolveError = error{
    /// The index has no build of this for the host (and target).
    NotShipped,
} || std.mem.Allocator.Error;

/// The toolchain of `release` that runs on `host` and compiles for `target`:
/// its directory has `bin/` and `lib/ocaml/`.
pub fn ocaml(store: *Store, release: *const Index.Ocaml, host: Target, target: Target) ResolveError!Install {
    const archive = release.archive(host, target) orelse return error.NotShipped;
    return .{
        .what = try std.fmt.allocPrint(store.arena, "OCaml {s} for {t}", .{ release.version, target }),
        .dir = try store.dirPath("ocaml/{s}-{d}/host-{t}/target-{t}", .{ release.version, release.revision, host, target }),
        .download = archive.download,
        .layout = .as_is,
        .manifests = host.os() == .windows,
    };
}

/// zcaml's dune for `host`: its directory has `bin/dune`.
pub fn dune(store: *Store, release: *const Index.Dune, host: Target) ResolveError!Install {
    const archive = release.archive(host) orelse return error.NotShipped;
    // `+` is a URL's space: the releases' names have `-`.
    const version = try store.arena.dupe(u8, release.version);
    std.mem.replaceScalar(u8, version, '+', '-');
    return .{
        .what = try std.fmt.allocPrint(store.arena, "dune {s}", .{release.version}),
        .dir = try store.dirPath("dune/{s}/host-{t}", .{ version, host }),
        .download = archive.download,
        .layout = .as_is,
        .manifests = host.os() == .windows,
    };
}

/// The Zig the toolchains compile C with, for `host`: its directory has `zig`
/// and `lib/`.
pub fn zig(store: *Store, release: *const Index.Zig, host: Target) ResolveError!Install {
    const archive = release.archive(host) orelse return error.NotShipped;
    return .{
        .what = try std.fmt.allocPrint(store.arena, "Zig {s}", .{release.version}),
        .dir = try store.dirPath("zig/{s}", .{release.version}),
        .download = archive.download,
        .layout = .strip_root,
    };
}

/// The macOS SDK, in Xcode's layout: `ZCAML_MACOS_SDK`.
pub fn macosSdk(store: *Store, sdk: *const Index.MacosSdk) std.mem.Allocator.Error!Install {
    return .{
        .what = "the macOS SDK",
        .dir = try store.dirPath("macos-sdk/{s}", .{sdk.revision[0..@min(12, sdk.revision.len)]}),
        .download = sdk.download,
        .layout = .macos_sdk,
    };
}

fn dirPath(store: *Store, comptime fmt: []const u8, args: anytype) std.mem.Allocator.Error![]const u8 {
    return std.fs.path.join(store.arena, &.{ store.root, try std.fmt.allocPrint(store.arena, fmt, args) });
}

/// A file zcaml writes for a build (`findlib.conf`), named for its content:
/// `env/<hash>/<name>`. Like the rest of the store, it never changes.
pub fn generated(store: *Store, name: []const u8, content: []const u8) Error![]const u8 {
    const io = store.io;
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(content, &digest, .{});
    const dir_path = try std.fs.path.join(store.arena, &.{ store.root, "env", &std.fmt.bytesToHex(digest[0..8].*, .lower) });
    const final = try std.fs.path.join(store.arena, &.{ dir_path, name });
    if (exists(io, final)) return final;

    store.writeAtomic(dir_path, name, content) catch |err| switch (err) {
        error.Canceled => |e| return e,
        else => {
            log.err("writing {s} failed: {t}", .{ final, err });
            return error.InstallFailed;
        },
    };
    return final;
}

/// `dir_path/name`, whole or not at all.
pub fn writeAtomic(store: *Store, dir_path: []const u8, name: []const u8, content: []const u8) !void {
    const io = store.io;
    var dir = try Io.Dir.cwd().createDirPathOpen(io, dir_path, .{});
    defer dir.close(io);
    var random: [8]u8 = undefined;
    io.random(&random);
    const tmp_name = std.fmt.bytesToHex(random, .lower) ++ ".tmp";
    errdefer dir.deleteFile(io, tmp_name) catch {};
    try dir.writeFile(io, .{ .sub_path = tmp_name, .data = content });
    try dir.rename(tmp_name, dir, name, io);
}

const Layout = enum {
    /// The archive's files are the directory's.
    as_is,
    /// The archive has one directory, whose files are the directory's.
    strip_root,
    /// `strip_root`, then hexops' xcode-frameworks' directories where Xcode's SDK
    /// has them (build/ocaml/macos_sdk.zig).
    macos_sdk,
};

/// The most unpacks `install` runs at once: a toolchain's zstd window is 128
/// MiB, and its decoder takes twice that. 4 take about 1 GB.
const max_unpacking = 4;

fn installTask(store: *Store, item: *const Install, progress: std.Progress.Node, result: *Error!void) void {
    const node = progress.start(item.what, 0);
    defer node.end();
    result.* = store.installOne(item, node);
}

fn installOne(store: *Store, item: *const Install, node: std.Progress.Node) Error!void {
    store.installInto(item, node) catch |err| switch (err) {
        error.OutOfMemory, error.Canceled => |e| return e,
        // Reported where they happen.
        error.InstallFailed, error.NotTheReleasedFile => return error.InstallFailed,
        else => {
            log.err("installing {s} to {s} failed: {t}", .{ item.what, item.dir, err });
            return error.InstallFailed;
        },
    };
}

fn installInto(store: *Store, item: *const Install, node: std.Progress.Node) !void {
    const final = item.dir;
    const download = item.download;
    const io = store.io;
    const tmp_path = try std.fs.path.join(store.gpa, &.{ store.root, "tmp" });
    defer store.gpa.free(tmp_path);
    var tmp = try Io.Dir.cwd().createDirPathOpen(io, tmp_path, .{});
    defer tmp.close(io);

    // Both in `tmp/`, the store's file system: the rename into place is atomic.
    var random: [8]u8 = undefined;
    io.random(&random);
    const hex = std.fmt.bytesToHex(random, .lower);
    const archive_name = hex ++ ".archive";
    const unpacked_name: []const u8 = &hex;
    defer tmp.deleteFile(io, archive_name) catch {};
    defer tmp.deleteTree(io, unpacked_name) catch {};

    try store.fetch(tmp, archive_name, item, node);
    {
        var name_buffer: [std.Progress.Node.max_name_len]u8 = undefined;
        node.setName(std.fmt.bufPrint(&name_buffer, "{s}: waiting to unpack", .{item.what}) catch &name_buffer);
        try store.unpacking.wait(io);
        defer store.unpacking.post(io);
        node.setName(std.fmt.bufPrint(&name_buffer, "{s}: unpacking", .{item.what}) catch &name_buffer);

        var unpacked = try tmp.createDirPathOpen(io, unpacked_name, .{});
        defer unpacked.close(io);
        const archive = try tmp.openFile(io, archive_name, .{});
        defer archive.close(io);
        try store.unpack(archive, download.format, unpacked);
        if (item.layout == .macos_sdk) try sdkLayout(io, unpacked);
        if (item.manifests) try addManifests(store.gpa, io, unpacked);
    }

    const source = switch (item.layout) {
        .as_is => try store.gpa.dupe(u8, unpacked_name),
        .strip_root => try onlyEntry(store.gpa, io, tmp, unpacked_name),
        .macos_sdk => try std.fs.path.join(store.gpa, &.{ unpacked_name, "sdk" }),
    };
    defer store.gpa.free(source);

    try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(final).?);
    tmp.rename(source, .cwd(), final, io) catch |err| {
        // Another run installed it meanwhile: the same files.
        if (exists(io, final)) return;
        return err;
    };
}

/// Before `install`'s tasks: they share it.
pub fn initClient(store: *Store) !void {
    if (store.client != null) return;
    store.client = .{ .allocator = store.gpa, .io = store.io };
    try store.client.?.initDefaultProxies(store.arena, store.environ);
}

/// Downloads `item` to `dir/name`, and checks it's what the index says.
fn fetch(store: *Store, dir: Io.Dir, name: []const u8, item: *const Install, node: std.Progress.Node) !void {
    const io = store.io;
    const download = item.download;

    // A release's files don't change: what fails is the network.
    const delays_s = [_]i64{ 1, 4, 10 };
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        if (store.fetchOnce(dir, name, item, node)) |_| return else |err| switch (err) {
            error.Canceled, error.OutOfMemory, error.NotTheReleasedFile => |e| return e,
            else => {
                if (attempt == delays_s.len) {
                    log.err("downloading {s} failed: {t}", .{ download.url, err });
                    return error.InstallFailed;
                }
                log.warn("downloading {s} failed ({t}): trying again", .{ download.url, err });
                try io.sleep(.fromSeconds(delays_s[attempt]), .awake);
            },
        }
    }
}

fn fetchOnce(store: *Store, dir: Io.Dir, name: []const u8, item: *const Install, node: std.Progress.Node) !void {
    const io = store.io;
    const download = item.download;
    const file = try dir.createFile(io, name, .{});
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var file_writer = file.writer(io, &buffer);
    var hashed = file_writer.interface.hashed(Sha256.init(.{}), &.{});
    var counted: Counted = .init(&hashed.writer, node, item.what, download.size);
    counted.show();

    const result = try store.client.?.fetch(.{
        .location = .{ .url = download.url },
        .response_writer = &counted.writer,
        .redirect_behavior = .init(5),
        // Unpacking takes longer than a server keeps an idle connection.
        .keep_alive = false,
    });
    if (result.status != .ok) {
        log.warn("HTTP {d} {s}", .{ @backingInt(result.status), result.status.phrase() orelse "" });
        return error.HttpStatus;
    }
    try hashed.writer.flush();
    try file_writer.interface.flush();

    const sha256 = std.fmt.bytesToHex(hashed.hasher.finalResult(), .lower);
    if (file_writer.pos != download.size or !std.mem.eql(u8, &sha256, download.sha256)) {
        log.err(
            \\{s} isn't the file zcaml's index has:
            \\  expected {d} bytes, SHA-256 {s}
            \\  got      {d} bytes, SHA-256 {s}
        , .{ download.url, download.size, download.sha256, file_writer.pos, &sha256 });
        return error.NotTheReleasedFile;
    }
}

/// Passes what's written to `out`, showing how much on a progress node:
/// "dune 3.24.2: 1.2MB/5.8MB".
const Counted = struct {
    out: *Io.Writer,
    node: std.Progress.Node,
    what: []const u8,
    size: u64,
    written: u64 = 0,
    shown: u64 = 0,
    writer: Io.Writer,

    /// How often it shows: the node's name is a copy.
    const step = 256 * 1024;

    fn init(out: *Io.Writer, node: std.Progress.Node, what: []const u8, size: u64) Counted {
        return .{
            .out = out,
            .node = node,
            .what = what,
            .size = size,
            .writer = .{ .buffer = &.{}, .vtable = &.{ .drain = drain } },
        };
    }

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const c: *Counted = @alignCast(@fieldParentPtr("writer", w));
        // No buffer: all of it is `data`'s.
        const n = try c.out.writeSplat(data, splat);
        c.written += n;
        if (c.written - c.shown >= step or c.written == c.size) c.show();
        return n;
    }

    fn show(c: *Counted) void {
        c.shown = c.written;
        var buffer: [std.Progress.Node.max_name_len]u8 = undefined;
        c.node.setName(std.fmt.bufPrint(&buffer, "{s}: {B:.1}/{B:.1}", .{ c.what, c.written, c.size }) catch &buffer);
    }
};

fn unpack(store: *Store, archive: Io.File, format: Download.Format, dest: Io.Dir) !void {
    const io = store.io;
    const gpa = store.gpa;
    var read_buffer: [64 * 1024]u8 = undefined;
    var file_reader = archive.reader(io, &read_buffer);
    switch (format) {
        .@"tar.zst" => {
            // The window is the decoder's to keep: with room for as much again, it
            // moves it once per window, not once per block.
            const window_len = try zstdWindowLen(&file_reader.interface);
            const buffer = try gpa.alloc(u8, 2 * @as(usize, window_len) + std.compress.zstd.block_size_max);
            defer gpa.free(buffer);
            var decompress: std.compress.zstd.Decompress = .init(&file_reader.interface, buffer, .{ .window_len = window_len });
            try std.tar.extract(io, dest, &decompress.reader, .{});
        },
        .@"tar.xz" => {
            var decompress: std.compress.xz.Decompress = try .init(&file_reader.interface, gpa, &.{});
            defer decompress.deinit();
            try std.tar.extract(io, dest, &decompress.reader, .{});
        },
        .@"tar.gz" => {
            const buffer = try gpa.alloc(u8, std.compress.flate.max_window_len);
            defer gpa.free(buffer);
            var decompress: std.compress.flate.Decompress = .init(&file_reader.interface, .gzip, buffer);
            try std.tar.extract(io, dest, &decompress.reader, .{});
        },
        .zip => try std.zip.extract(dest, &file_reader, .{}),
    }
}

/// The window a zstd archive's first frame needs, from its header. The
/// toolchains' are `zstd --long=27`'s 128 MiB, far above the decoder's default.
fn zstdWindowLen(reader: *Io.Reader) !u32 {
    const max_window_len = 1 << 27;
    const header = try reader.peek(6);
    if (std.mem.readInt(u32, header[0..4], .little) != 0xFD2FB528) return error.NotZstd;
    const single_segment = header[4] & 0b0010_0000 != 0;
    // A single segment is as long as its content: small enough for no window.
    if (single_segment) return std.compress.zstd.default_window_len;
    const exponent: u5 = @intCast(header[5] >> 3);
    const mantissa: u64 = header[5] & 0b111;
    const base = @as(u64, 1) << (10 + exponent);
    const window_len = base + (base / 8) * mantissa;
    if (window_len > max_window_len) return error.ZstdWindowTooLarge;
    return @max(@as(u32, @intCast(window_len)), std.compress.zstd.default_window_len);
}

/// `dir`'s `Frameworks`, `include` and `lib` (in its one directory), as Xcode's
/// SDK has them, in `dir/sdk`.
/// Next to each `.exe`, before it first runs: Windows caches what an
/// executable's manifest is. A toolchain's programs have none of their own, and
/// a build's paths can be longer than Windows takes from a program without one.
fn addManifests(gpa: std.mem.Allocator, io: Io, unpacked: Io.Dir) !void {
    // Windows lists only a directory opened to.
    var dir = try unpacked.openDir(io, ".", .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.ascii.endsWithIgnoreCase(entry.basename, ".exe")) continue;
        // From `dir`: on Windows, the walker's directories are open to read.
        const name = try std.fmt.allocPrint(gpa, "{s}.manifest", .{entry.path});
        defer gpa.free(name);
        try dir.writeFile(io, .{ .sub_path = name, .data = windows_manifest });
    }
}

const windows_manifest = @embedFile("windows.manifest");

fn sdkLayout(io: Io, dir: Io.Dir) !void {
    var buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    var root_name: std.ArrayList(u8) = .initBuffer(&buffer);
    {
        var it_dir = try dir.openDir(io, ".", .{ .iterate = true });
        defer it_dir.close(io);
        var it = it_dir.iterate();
        const entry = try it.next(io) orelse return error.EmptyArchive;
        root_name.appendSliceAssumeCapacity(entry.name);
        if (try it.next(io) != null) return error.UnexpectedArchiveLayout;
    }
    var root = try dir.openDir(io, root_name.items, .{});
    defer root.close(io);
    try dir.createDirPath(io, "sdk/System/Library");
    try dir.createDirPath(io, "sdk/usr");
    try root.rename("Frameworks", dir, "sdk/System/Library/Frameworks", io);
    try root.rename("include", dir, "sdk/usr/include", io);
    try root.rename("lib", dir, "sdk/usr/lib", io);
}

/// `sub_path/<its one entry>`.
fn onlyEntry(gpa: std.mem.Allocator, io: Io, dir: Io.Dir, sub_path: []const u8) ![]u8 {
    var it_dir = try dir.openDir(io, sub_path, .{ .iterate = true });
    defer it_dir.close(io);
    var it = it_dir.iterate();
    const entry = try it.next(io) orelse return error.EmptyArchive;
    const path = try std.fs.path.join(gpa, &.{ sub_path, entry.name });
    errdefer gpa.free(path);
    if (try it.next(io) != null) return error.UnexpectedArchiveLayout;
    return path;
}

fn exists(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    const v = value orelse return null;
    return if (v.len == 0) null else v;
}

test {
    std.testing.refAllDecls(@This());
}
