//! A distribution's archives: `.tar.gz` and `.zip`. The same files make the
//! same bytes, whenever and wherever they're archived: no times, no owners, the
//! entries in the order they're given.
const std = @import("std");
const Io = std.Io;
const flate = std.compress.flate;

pub const Format = enum {
    @"tar.gz",
    zip,

    pub fn extension(format: Format) []const u8 {
        return switch (format) {
            .@"tar.gz" => ".tar.gz",
            .zip => ".zip",
        };
    }
};

pub const Entry = struct {
    /// In the archive: relative, with `/`.
    path: []const u8,
    /// The file, in the directory the entries are from.
    source: []const u8,
    executable: bool,

    fn mode(entry: Entry) u32 {
        return if (entry.executable) 0o755 else 0o644;
    }

    pub fn lessThan(_: void, a: Entry, b: Entry) bool {
        return std.mem.order(u8, a.path, b.path) == .lt;
    }
};

/// Writes `entries`, files of `dir`, to `out` as an archive. It isn't flushed.
/// `error.TooBig`: more than a `.zip` without its 64-bit extension holds (4 GiB,
/// 65535 files).
pub fn write(gpa: std.mem.Allocator, io: Io, format: Format, out: *Io.Writer, dir: Io.Dir, entries: []const Entry) !void {
    switch (format) {
        .@"tar.gz" => try writeTarGz(gpa, io, out, dir, entries),
        .zip => try writeZip(gpa, io, out, dir, entries),
    }
}

fn writeTarGz(gpa: std.mem.Allocator, io: Io, out: *Io.Writer, dir: Io.Dir, entries: []const Entry) !void {
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    var gzip: flate.Compress = try .init(out, window, .gzip, .default);
    var tar: std.tar.Writer = .{ .underlying_writer = &gzip.writer };

    var buffer: [64 * 1024]u8 = undefined;
    for (entries) |entry| {
        const file = try dir.openFile(io, entry.source, .{});
        defer file.close(io);
        const size = (try file.stat(io)).size;
        var reader = file.reader(io, &buffer);
        try tar.writeFileStream(entry.path, size, &reader.interface, .{ .mode = entry.mode(), .mtime = 0 });
    }
    try tar.finishPedantically();
    try gzip.finish();
}

/// MS-DOS's first day, 1980-01-01: a `.zip` has no earlier.
const zip_date: u16 = (1 << 5) | 1;
const zip_time: u16 = 0;
/// Names are UTF-8.
const zip_flags: u16 = 1 << 11;
/// Made on Unix (its modes are in the external attributes), for version 2.0.
const zip_made_by: u16 = (3 << 8) | 20;
const zip_version_needed: u16 = 20;

const ZipMethod = enum(u16) { store = 0, deflate = 8 };

fn writeZip(gpa: std.mem.Allocator, io: Io, out: *Io.Writer, dir: Io.Dir, entries: []const Entry) !void {
    if (entries.len > std.math.maxInt(u16)) return error.TooBig;
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    var directory: Io.Writer.Allocating = .init(gpa);
    defer directory.deinit();
    var compressed: Io.Writer.Allocating = .init(gpa);
    defer compressed.deinit();

    var offset: u64 = 0;
    for (entries) |entry| {
        const content = try dir.readFileAlloc(io, entry.source, gpa, .unlimited);
        defer gpa.free(content);
        if (content.len > std.math.maxInt(u32) or entry.path.len > std.math.maxInt(u16)) return error.TooBig;

        compressed.clearRetainingCapacity();
        try compressed.ensureUnusedCapacity(64);
        var deflate: flate.Compress = try .init(&compressed.writer, window, .raw, .default);
        try deflate.writer.writeAll(content);
        try deflate.finish();
        const method: ZipMethod, const data: []const u8 = if (compressed.written().len < content.len)
            .{ .deflate, compressed.written() }
        else
            .{ .store, content };
        const crc = std.hash.Crc32.hash(content);
        if (offset > std.math.maxInt(u32)) return error.TooBig;

        // The local file header.
        try out.writeAll("PK\x03\x04");
        try out.writeInt(u16, zip_version_needed, .little);
        try out.writeInt(u16, zip_flags, .little);
        try out.writeInt(u16, @backingInt(method), .little);
        try out.writeInt(u16, zip_time, .little);
        try out.writeInt(u16, zip_date, .little);
        try out.writeInt(u32, crc, .little);
        try out.writeInt(u32, @intCast(data.len), .little);
        try out.writeInt(u32, @intCast(content.len), .little);
        try out.writeInt(u16, @intCast(entry.path.len), .little);
        try out.writeInt(u16, 0, .little); // extra field
        try out.writeAll(entry.path);
        try out.writeAll(data);

        // Its central directory header.
        const d = &directory.writer;
        try d.writeAll("PK\x01\x02");
        try d.writeInt(u16, zip_made_by, .little);
        try d.writeInt(u16, zip_version_needed, .little);
        try d.writeInt(u16, zip_flags, .little);
        try d.writeInt(u16, @backingInt(method), .little);
        try d.writeInt(u16, zip_time, .little);
        try d.writeInt(u16, zip_date, .little);
        try d.writeInt(u32, crc, .little);
        try d.writeInt(u32, @intCast(data.len), .little);
        try d.writeInt(u32, @intCast(content.len), .little);
        try d.writeInt(u16, @intCast(entry.path.len), .little);
        try d.writeInt(u16, 0, .little); // extra field
        try d.writeInt(u16, 0, .little); // comment
        try d.writeInt(u16, 0, .little); // disk
        try d.writeInt(u16, 0, .little); // internal attributes
        try d.writeInt(u32, (0o100000 | entry.mode()) << 16, .little);
        try d.writeInt(u32, @intCast(offset), .little);
        try d.writeAll(entry.path);

        offset += 30 + entry.path.len + data.len;
    }

    const directory_size = directory.written().len;
    if (offset > std.math.maxInt(u32) or directory_size > std.math.maxInt(u32)) return error.TooBig;
    try out.writeAll(directory.written());
    try out.writeAll("PK\x05\x06");
    try out.writeInt(u16, 0, .little); // this disk
    try out.writeInt(u16, 0, .little); // the directory's disk
    try out.writeInt(u16, @intCast(entries.len), .little);
    try out.writeInt(u16, @intCast(entries.len), .little);
    try out.writeInt(u32, @intCast(directory_size), .little);
    try out.writeInt(u32, @intCast(offset), .little);
    try out.writeInt(u16, 0, .little); // comment
}

const test_entries: []const Entry = &.{
    .{ .path = "bin/hello", .source = "staged/hello", .executable = true },
    .{ .path = "share/hello/greeting.txt", .source = "staged/greeting.txt", .executable = false },
    .{ .path = "share/hello/random", .source = "staged/random", .executable = false },
};

fn testFiles(dir: Io.Dir) !void {
    const io = std.testing.io;
    try dir.createDirPath(io, "staged");
    const repetitive: [4000]u8 = @splat('a');
    try dir.writeFile(io, .{ .sub_path = "staged/hello", .data = &repetitive });
    try dir.writeFile(io, .{ .sub_path = "staged/greeting.txt", .data = "hi\n" });
    // Doesn't compress: stored.
    var random: [4096]u8 = undefined;
    var prng: std.Random.DefaultPrng = .init(1);
    prng.random().bytes(&random);
    try dir.writeFile(io, .{ .sub_path = "staged/random", .data = &random });
}

fn testArchive(dir: Io.Dir, format: Format, name: []const u8) !void {
    const io = std.testing.io;
    const file = try dir.createFile(io, name, .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try write(std.testing.allocator, io, format, &writer.interface, dir, test_entries);
    try writer.interface.flush();
}

fn expectSameFiles(dir: Io.Dir, extracted: []const u8) !void {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    for (test_entries) |entry| {
        const expected = try dir.readFileAlloc(io, entry.source, gpa, .unlimited);
        defer gpa.free(expected);
        const path = try std.fs.path.join(gpa, &.{ extracted, entry.path });
        defer gpa.free(path);
        const actual = try dir.readFileAlloc(io, path, gpa, .unlimited);
        defer gpa.free(actual);
        try std.testing.expectEqualSlices(u8, expected, actual);
    }
}

fn expectSameBytes(dir: Io.Dir, a: []const u8, b: []const u8) !void {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const a_bytes = try dir.readFileAlloc(io, a, gpa, .unlimited);
    defer gpa.free(a_bytes);
    const b_bytes = try dir.readFileAlloc(io, b, gpa, .unlimited);
    defer gpa.free(b_bytes);
    try std.testing.expectEqualSlices(u8, a_bytes, b_bytes);
}

test "tar.gz" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try testFiles(tmp.dir);
    try testArchive(tmp.dir, .@"tar.gz", "a.tar.gz");
    try testArchive(tmp.dir, .@"tar.gz", "b.tar.gz");
    try expectSameBytes(tmp.dir, "a.tar.gz", "b.tar.gz");

    const file = try tmp.dir.openFile(io, "a.tar.gz", .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    var window: [flate.max_window_len]u8 = undefined;
    var gunzip: flate.Decompress = .init(&reader.interface, .gzip, &window);
    var out = try tmp.dir.createDirPathOpen(io, "out", .{});
    defer out.close(io);
    try std.tar.extract(io, out, &gunzip.reader, .{});
    try expectSameFiles(tmp.dir, "out");
    const stat = try out.statFile(io, "bin/hello", .{});
    try std.testing.expect(stat.permissions.toMode() & 0o100 != 0);
}

test "zip" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try testFiles(tmp.dir);
    try testArchive(tmp.dir, .zip, "a.zip");
    try testArchive(tmp.dir, .zip, "b.zip");
    try expectSameBytes(tmp.dir, "a.zip", "b.zip");

    const file = try tmp.dir.openFile(io, "a.zip", .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    var out = try tmp.dir.createDirPathOpen(io, "out", .{});
    defer out.close(io);
    try std.zip.extract(out, &reader, .{});
    try expectSameFiles(tmp.dir, "out");
}
