//! `zig build index -- <out>`: writes zcaml's index (`src/Index.zig`) from what's
//! published, for zcaml.dev: every release of the OCaml toolchains and dune
//! since `oldest_ocaml` and `oldest_dune`, with the Zig and macOS SDK each
//! toolchain was built with (its tag's `build.zig.zon`'s).
//!
//! Archives are pinned by the SHA-256 GitHub has of them (ziglang.org's index
//! has Zig's): it downloads none, but the macOS SDKs. A release that's a draft
//! or a prerelease isn't in it: making one a prerelease takes it out.
//!
//! GITHUB_TOKEN, if set, is sent to GitHub's API (whose limit without one is
//! 60 requests an hour). GITHUB_REPOSITORY is the repository: zcaml/zcaml.
const std = @import("std");
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Index = @import("Index");
const Json = Index.Json;
const Target = Index.Target;

/// The oldest releases index v1 has: the first in its archives' layout, which
/// zcaml's CLI installs.
const oldest_ocaml: Version = .{ .version = .{ .major = 5, .minor = 5, .patch = 1 }, .revision = 13 };
const oldest_dune: Version = .{ .version = .{ .major = 3, .minor = 24, .patch = 2 }, .revision = 7 };

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    var args = try init.minimal.args.iterateAllocator(arena);
    _ = args.skip();
    const out_path = args.next() orelse fatal("usage: zig build index -- <out.json>", .{});
    if (args.next() != null) fatal("usage: zig build index -- <out.json>", .{});

    var gen: Generator = .{
        .arena = arena,
        .client = .{ .allocator = init.gpa, .io = io },
        .github_token = init.environ_map.get("GITHUB_TOKEN") orelse init.environ_map.get("GH_TOKEN"),
        .repository = init.environ_map.get("GITHUB_REPOSITORY") orelse "zcaml/zcaml",
    };
    defer gen.client.deinit();
    try gen.client.initDefaultProxies(arena, init.environ_map);

    var ocaml: std.ArrayList(Sorted(Json.OcamlRelease)) = .empty;
    var dune: std.ArrayList(Sorted(Json.DuneRelease)) = .empty;
    for (try gen.releases()) |release| {
        if (release.draft or release.prerelease) continue;
        if (Version.ofTag(release.tag_name)) |o| {
            if (o.order(oldest_ocaml) == .lt) continue;
            try ocaml.append(arena, .{ .key = o, .value = try gen.ocaml(release, o) });
        } else if (Version.ofDuneTag(release.tag_name)) |d| {
            if (d.order(oldest_dune) == .lt) continue;
            try dune.append(arena, .{ .key = d, .value = try gen.dune(release, d) });
        }
    }
    if (ocaml.items.len == 0) fatal("no OCaml releases since ocaml-v{f}-{d}", .{ oldest_ocaml.version, oldest_ocaml.revision });
    if (dune.items.len == 0) fatal("no dune releases since dune-v{f}-zcaml.{d}", .{ oldest_dune.version, oldest_dune.revision });
    sortNewest(Json.OcamlRelease, ocaml.items);
    sortNewest(Json.DuneRelease, dune.items);

    var zig: std.ArrayList(Json.ZigRelease) = .empty;
    var macos_sdk: std.ArrayList(Json.SdkRelease) = .empty;
    for (ocaml.items) |o| {
        for (zig.items) |z| {
            if (std.mem.eql(u8, z.version, o.value.zig)) break;
        } else try zig.append(arena, try gen.zig(o.value.zig));
        for (macos_sdk.items) |sdk| {
            if (std.mem.eql(u8, sdk.revision, o.value.macos_sdk)) break;
        } else try macos_sdk.append(arena, try gen.macosSdk(o.value.macos_sdk));
    }

    const index: Json = .{
        .schema = Index.schema,
        .serial = @intCast(Io.Clock.real.now(io).toSeconds()),
        .ocaml = try values(Json.OcamlRelease, arena, ocaml.items),
        .dune = try values(Json.DuneRelease, arena, dune.items),
        .zig = zig.items,
        .macos_sdk = macos_sdk.items,
    };
    const json = try std.fmt.allocPrint(arena, "{f}\n", .{std.json.fmt(index, .{ .whitespace = .indent_1 })});

    // What zcaml reads of it: what it'll install.
    const parsed = Index.parse(arena, json) catch fatal("the index isn't one zcaml can read", .{});
    try check(&parsed);

    if (std.fs.path.dirname(out_path)) |dir| try Io.Dir.cwd().createDirPath(io, dir);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = json });
    for (parsed.ocaml) |o| std.log.info("OCaml {s}-{d}: Zig {s}, macOS SDK {s}", .{ o.version, o.revision, o.zig, o.macos_sdk[0..12] });
    for (parsed.dune) |d| std.log.info("dune {s}", .{d.version});
}

/// What zcaml installs with a toolchain is there for each host it has.
fn check(index: *const Index) !void {
    const dune = index.latestDune().?;
    for (index.ocaml) |*release| {
        const zig = index.zigRelease(release.zig);
        for (release.archives) |a| {
            if (release.archive(a.host, a.host) == null) fatal("OCaml {s}-{d} has a toolchain on {t}, but not its native one", .{ release.version, release.revision, a.host });
            // Hosts that only compile for themselves (riscv64, ...) have no dune.
            if (a.host != a.target and dune.archive(a.host) == null) fatal("dune {s} has no build for {t}, a host of OCaml {s}-{d}", .{ dune.version, a.host, release.version, release.revision });
            if (zig.archive(a.host) == null) fatal("Zig {s} has no build for {t}", .{ zig.version, a.host });
        }
    }
}

/// A release's version: `5.5.1-13`, `3.24.2+zcaml.7`.
const Version = struct {
    version: std.SemanticVersion,
    revision: u32,

    /// `ocaml-v5.5.1-13`: zcaml's 13th build of OCaml 5.5.1; `ocaml-v5.5.1`, its first.
    fn ofTag(tag: []const u8) ?Version {
        const rest = between(tag, "ocaml-v", "") orelse return null;
        const version_text, const revision = if (std.mem.findScalar(u8, rest, '-')) |dash|
            .{ rest[0..dash], std.fmt.parseInt(u32, rest[dash + 1 ..], 10) catch return null }
        else
            .{ rest, 1 };
        return .{ .version = std.SemanticVersion.parse(version_text) catch return null, .revision = revision };
    }

    /// `dune-v3.24.2-zcaml.7`: dune 3.24.2+zcaml.7. `dune-v3.24.2`, upstream's, isn't.
    fn ofDuneTag(tag: []const u8) ?Version {
        const rest = between(tag, "dune-v", "") orelse return null;
        const at = std.mem.find(u8, rest, "-zcaml.") orelse return null;
        return .{
            .version = std.SemanticVersion.parse(rest[0..at]) catch return null,
            .revision = std.fmt.parseInt(u32, rest[at + "-zcaml.".len ..], 10) catch return null,
        };
    }

    fn order(a: Version, b: Version) std.math.Order {
        return switch (a.version.order(b.version)) {
            .eq => std.math.order(a.revision, b.revision),
            else => |o| o,
        };
    }
};

fn Sorted(T: type) type {
    return struct { key: Version, value: T };
}

fn sortNewest(T: type, items: []Sorted(T)) void {
    std.mem.sort(Sorted(T), items, {}, struct {
        fn newer(_: void, a: Sorted(T), b: Sorted(T)) bool {
            return a.key.order(b.key) == .gt;
        }
    }.newer);
}

fn values(T: type, arena: std.mem.Allocator, items: []const Sorted(T)) ![]const T {
    const out = try arena.alloc(T, items.len);
    for (items, out) |item, *o| o.* = item.value;
    return out;
}

const Release = struct {
    tag_name: []const u8,
    draft: bool,
    prerelease: bool,
    assets: []const Asset,
};

const Asset = struct {
    name: []const u8,
    size: u64,
    browser_download_url: []const u8,
    /// `sha256:<hex>`.
    digest: ?[]const u8 = null,

    fn sha256(asset: Asset) []const u8 {
        const digest = asset.digest orelse fatal("GitHub has no digest of {s}", .{asset.name});
        const hex = between(digest, "sha256:", "") orelse fatal("{s}'s digest isn't a SHA-256: {s}", .{ asset.name, digest });
        return checkedSha256(hex, asset.name);
    }
};

const Generator = struct {
    arena: std.mem.Allocator,
    client: std.http.Client,
    github_token: ?[]const u8,
    repository: []const u8,

    fn releases(gen: *Generator) ![]const Release {
        var all: std.ArrayList(Release) = .empty;
        var page: usize = 1;
        while (true) : (page += 1) {
            const url = try std.fmt.allocPrint(gen.arena, "https://api.github.com/repos/{s}/releases?per_page=100&page={d}", .{ gen.repository, page });
            const batch = std.json.parseFromSliceLeaky([]const Release, gen.arena, try gen.get(url, gen.github_token), .{
                .ignore_unknown_fields = true,
            }) catch |err| fatal("{s}: not a list of releases ({t})", .{ url, err });
            if (batch.len == 0) break;
            try all.appendSlice(gen.arena, batch);
        }
        return all.items;
    }

    fn ocaml(gen: *Generator, release: Release, o: Version) !Json.OcamlRelease {
        const arena = gen.arena;
        const version = try std.fmt.allocPrint(arena, "{f}", .{o.version});
        const archive_prefix = try std.fmt.allocPrint(arena, "ocaml-{s}-host-", .{version});
        const separator = "-target-";
        var archives: std.ArrayList(Json.Archive(Json.OcamlRelease)) = .empty;
        for (release.assets) |asset| {
            const names = between(asset.name, archive_prefix, ".tar.zst") orelse continue;
            const at = std.mem.find(u8, names, separator) orelse continue;
            try archives.append(arena, .{
                .host = names[0..at],
                .target = names[at + separator.len ..],
                .url = asset.browser_download_url,
                .sha256 = asset.sha256(),
                .size = asset.size,
            });
        }
        if (archives.items.len == 0) fatal("the release {s} has no {s}<host>{s}<target>.tar.zst", .{ release.tag_name, archive_prefix, separator });
        sortArchives(Json.Archive(Json.OcamlRelease), archives.items);

        // What it was built with.
        const Manifest = struct {
            minimum_zig_version: []const u8,
            dependencies: struct { xcode_frameworks: struct { url: []const u8 } },
        };
        const zon_url = try std.fmt.allocPrint(arena, "https://raw.githubusercontent.com/{s}/{s}/build.zig.zon", .{ gen.repository, release.tag_name });
        const zon = try arena.dupeSentinel(u8, try gen.get(zon_url, null), 0);
        var diagnostics: std.zon.parse.Diagnostics = undefined;
        const manifest = std.zon.parse.fromSlice(Manifest, .{
            .gpa = arena,
            .arena = arena,
            .source = zon,
            .diagnostics = &diagnostics,
            .ignore_unknown_fields = true,
        }) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            error.ParseZon => fatal("{f}", .{diagnostics.fmt(zon_url)}),
        };
        const sdk_url = manifest.dependencies.xcode_frameworks.url;
        const sdk_revision = between(sdk_url, "https://code.hexops.org/hexops/xcode-frameworks/archive/", ".tar.gz") orelse
            fatal("{s}: xcode_frameworks isn't hexops' archive of a commit: {s}", .{ zon_url, sdk_url });

        return .{
            .version = version,
            .revision = o.revision,
            .zig = manifest.minimum_zig_version,
            .macos_sdk = sdk_revision,
            .archives = archives.items,
        };
    }

    fn dune(gen: *Generator, release: Release, d: Version) !Json.DuneRelease {
        const arena = gen.arena;
        const archive_prefix = try std.fmt.allocPrint(arena, "dune-{f}-zcaml.{d}-", .{ d.version, d.revision });
        var archives: std.ArrayList(Json.Archive(Json.DuneRelease)) = .empty;
        for (release.assets) |asset| {
            const host = between(asset.name, archive_prefix, ".tar.zst") orelse continue;
            try archives.append(arena, .{ .host = host, .url = asset.browser_download_url, .sha256 = asset.sha256(), .size = asset.size });
        }
        if (archives.items.len == 0) fatal("the release {s} has no {s}<host>.tar.zst", .{ release.tag_name, archive_prefix });
        sortArchives(Json.Archive(Json.DuneRelease), archives.items);
        return .{ .version = try std.fmt.allocPrint(arena, "{f}+zcaml.{d}", .{ d.version, d.revision }), .archives = archives.items };
    }

    fn zig(gen: *Generator, version: []const u8) !Json.ZigRelease {
        const arena = gen.arena;
        const index_url = "https://ziglang.org/download/index.json";
        const index = try std.json.parseFromSliceLeaky(std.json.Value, arena, try gen.get(index_url, null), .{});
        const builds = switch (index) {
            .object => |versions| switch (versions.get(version) orelse fatal("{s} has no Zig {s}", .{ index_url, version })) {
                .object => |builds| builds,
                else => fatal("{s}: not as expected", .{index_url}),
            },
            else => fatal("{s}: not as expected", .{index_url}),
        };
        const Build = struct { tarball: []const u8, shasum: []const u8, size: []const u8 };
        var archives: std.ArrayList(Json.Archive(Json.ZigRelease)) = .empty;
        for (std.enums.values(Target.Os)) |os| for (std.enums.values(Target.Arch)) |arch| {
            // Only what a toolchain runs on.
            const hosts = for (Target.all) |target| {
                if (target.os() == os and target.arch() == arch) break true;
            } else false;
            if (!hosts) continue;
            const key = try std.fmt.allocPrint(arena, "{t}-{t}", .{ arch, os });
            const value = builds.get(key) orelse continue;
            const build = std.json.parseFromValueLeaky(Build, arena, value, .{ .ignore_unknown_fields = true }) catch
                fatal("{s}: {s}'s {s} isn't as expected", .{ index_url, version, key });
            try archives.append(arena, .{
                .arch = @tagName(arch),
                .os = @tagName(os),
                .url = build.tarball,
                .sha256 = checkedSha256(build.shasum, build.tarball),
                .size = std.fmt.parseInt(u64, build.size, 10) catch fatal("{s}: {s}'s size isn't a number", .{ index_url, key }),
            });
        };
        if (archives.items.len == 0) fatal("{s}: Zig {s} has no builds", .{ index_url, version });
        return .{ .version = version, .archives = archives.items };
    }

    /// Not in a release, so with no hash but its own: downloaded.
    fn macosSdk(gen: *Generator, revision: []const u8) !Json.SdkRelease {
        const url = try std.fmt.allocPrint(gen.arena, "https://code.hexops.org/hexops/xcode-frameworks/archive/{s}.tar.gz", .{revision});
        const archive = try gen.get(url, null);
        var digest: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(archive, &digest, .{});
        return .{
            .revision = revision,
            .url = url,
            .sha256 = try gen.arena.dupe(u8, &std.fmt.bytesToHex(digest, .lower)),
            .size = archive.len,
        };
    }

    fn get(gen: *Generator, url: []const u8, token: ?[]const u8) ![]const u8 {
        var body: Io.Writer.Allocating = .init(gen.arena);
        const result = gen.client.fetch(.{
            .location = .{ .url = url },
            .response_writer = &body.writer,
            .redirect_behavior = .init(5),
            .keep_alive = false,
            .privileged_headers = if (token) |t| &.{
                .{ .name = "authorization", .value = try std.fmt.allocPrint(gen.arena, "Bearer {s}", .{t}) },
            } else &.{},
        }) catch |err| fatal("GET {s}: {t}", .{ url, err });
        if (result.status != .ok) fatal("GET {s}: HTTP {d} {s}", .{ url, @backingInt(result.status), result.status.phrase() orelse "" });
        return body.written();
    }
};

fn sortArchives(T: type, archives: []T) void {
    std.mem.sort(T, archives, {}, struct {
        fn lessThan(_: void, a: T, b: T) bool {
            return switch (std.mem.order(u8, a.host, b.host)) {
                .lt => true,
                .gt => false,
                .eq => if (@hasField(T, "target")) std.mem.order(u8, a.target, b.target) == .lt else false,
            };
        }
    }.lessThan);
}

/// `text` without `prefix` and `suffix`, if it has both.
fn between(text: []const u8, prefix: []const u8, suffix: []const u8) ?[]const u8 {
    if (text.len < prefix.len + suffix.len) return null;
    if (!std.mem.startsWith(u8, text, prefix) or !std.mem.endsWith(u8, text, suffix)) return null;
    return text[prefix.len .. text.len - suffix.len];
}

/// 64 lowercase hexadecimal digits.
fn checkedSha256(hex: []const u8, of: []const u8) []const u8 {
    if (hex.len != Sha256.digest_length * 2) fatal("{s}'s SHA-256 isn't one: {s}", .{ of, hex });
    for (hex) |c| switch (c) {
        '0'...'9', 'a'...'f' => {},
        else => fatal("{s}'s SHA-256 isn't one: {s}", .{ of, hex }),
    };
    return hex;
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt ++ "\n", args);
    std.process.exit(1);
}
