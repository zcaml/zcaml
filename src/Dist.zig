//! A project's distribution: for each target, what its packages install but
//! their libraries (executables, their data and manuals), built by dune,
//! tested where this machine can run it, and archived.
//!
//!   <out>/<name>-<version>-<target>.tar.gz   (.zip for Windows)
//!   <out>/SHA256SUMS
//!
//! An archive is an installation prefix: `bin/`, `share/`, `man/`...
const Dist = @This();

const std = @import("std");
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Environment = @import("Environment.zig");
const Project = @import("Project.zig");
const Runner = @import("Runner.zig");
const Store = @import("Store.zig");
const Index = @import("Index.zig");
const Target = @import("target.zig").Target;
const archive = @import("archive.zig");
const exec = @import("exec.zig");

const log = std.log.scoped(.zcaml);

pub const Options = struct {
    /// The OCaml version: exactly `x.y.z`.
    ocaml: []const u8,
    /// Targets' names, or `native`.
    targets: []const []const u8,
    /// The packages whose files are archived. None: the project's.
    packages: []const []const u8 = &.{},
    /// The directory the archives go to, relative to the project.
    out: []const u8 = "dist",
    /// Null: `dune-project`'s `(name)`, or its only package.
    name: ?[]const u8 = null,
    /// Null: `dune-project`'s `(version)`, or `git describe`'s.
    version: ?[]const u8 = null,
    profile: []const u8 = "release",
    format: Format = .auto,
    /// Command lines: each one's program is an executable of the archive's
    /// `bin/`, and must succeed.
    tests: []const []const u8 = &.{},
    /// Whether an archive has its packages' `<package>.install`: what opam and
    /// dune install it with.
    install_file: bool = false,

    pub const Format = enum {
        /// `.zip` for Windows, `.tar.gz` for the others.
        auto,
        @"tar.gz",
        zip,
    };
};

/// Builds the project in the current directory for `options`' targets and
/// writes their archives, whose paths it prints.
pub fn run(init: std.process.Init, options: Options) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const cwd = Io.Dir.cwd();

    var store: Store = try .init(init);
    defer store.deinit();
    const index = try Index.load(&store);

    // Everything that's wrong, before a download or a build.
    var ok = true;
    const resolved: ?Environment.Selection = Environment.resolve(arena, io, &index, .{
        .ocaml = options.ocaml,
        .targets = options.targets,
    }) catch |err| switch (err) {
        error.Unsupported => resolved: {
            ok = false;
            break :resolved null;
        },
        else => |e| return e,
    };
    const project = Project.load(arena, io, cwd) catch |err| switch (err) {
        error.InvalidProject => return error.Reported,
        else => |e| return e,
    };

    const name = options.name orelse project.name orelse name: {
        if (project.packages.len == 1) break :name project.packages[0];
        ok = false;
        log.err("the archives have no name: dune-project has no (name), and {s}. Pass --name.", .{
            if (project.packages.len == 0) "no package" else "more than one package",
        });
        break :name "";
    };
    const version = options.version orelse project.version orelse try gitVersion(arena, io) orelse version: {
        ok = false;
        log.err("the archives have no version: dune-project has no (version), and git has no description of this commit. Pass --version.", .{});
        break :version "";
    };
    for ([_][]const u8{ name, version }) |part| {
        if (std.mem.findAny(u8, part, "/\\") == null) continue;
        ok = false;
        log.err("'{s}' can't be in a file's name", .{part});
    }

    const packages = if (options.packages.len != 0) options.packages else project.packages;
    if (project.packages.len == 0) {
        ok = false;
        log.err("the project has no packages: dune-project has no (package), and there's no .opam file", .{});
    }
    for (options.packages) |package| {
        if (contains(project.packages, package)) continue;
        ok = false;
        log.err("{s} isn't a package of this project: it has {f}", .{ package, list(project.packages) });
    }

    var tests: std.ArrayList([]const []const u8) = .empty;
    for (options.tests) |line| {
        const argv = exec.splitCommand(arena, line) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            error.UnclosedQuote => {
                ok = false;
                log.err("--test '{s}': a quote that isn't closed", .{line});
                continue;
            },
        };
        if (argv.len == 0) {
            ok = false;
            log.err("--test '{s}': no command", .{line});
        } else if (std.fs.path.dirname(argv[0]) != null) {
            ok = false;
            log.err("--test '{s}': {s} isn't a name: a test's program is one of the archive's bin/", .{ line, argv[0] });
        } else try tests.append(arena, argv);
    }

    if (resolved) |selection| {
        for (try project.check(arena, .{
            .release = selection.release,
            .index = &index,
            .host = selection.host,
            .targets = selection.targets,
        })) |problem| {
            if (problem.fatal) {
                ok = false;
                log.err("{s}", .{problem.message});
            } else log.warn("{s}", .{problem.message});
        }
        // What a test needs whatever the build makes: not after the builds.
        if (tests.items.len != 0) for (selection.targets) |target| {
            switch (try Runner.planTarget(arena, io, init.environ_map, target)) {
                .run, .impossible => {},
                .missing => |what| {
                    ok = false;
                    log.err("{t}: can't be tested. {f}", .{ target, upperFirst(what) });
                },
            }
        };
    }
    if (!ok) return error.Reported;
    const selection = resolved.?;

    const env = try Environment.prepare(&store, selection);
    var build_environ = try env.environMap(init.gpa, init.environ_map);
    defer build_environ.deinit();

    var dist: Dist = .{
        .arena = arena,
        .gpa = init.gpa,
        .io = io,
        .options = &options,
        .environ = init.environ_map,
        .host = selection.host,
        .packages = packages,
        .tests = tests.items,
        .out = try cwd.createDirPathOpen(io, options.out, .{}),
    };
    defer dist.out.close(io);
    // dune doesn't look into a directory whose name starts with `.`.
    try dist.out.deleteTree(io, stage_dir);
    defer dist.out.deleteTree(io, stage_dir) catch {};
    // The last run's: not what a failed one leaves.
    dist.out.deleteFile(io, sums_name) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };

    var artifacts: std.ArrayList(Artifact) = .empty;
    for (selection.targets) |target| {
        log.info("{t}: building", .{target});
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(arena, &.{ env.dune_exe, "build" });
        if (target != selection.host) try argv.appendSlice(arena, &.{ "-x", target.duneName() });
        // The target's context alone: another's packages aren't built.
        try argv.appendSlice(arena, &.{
            "--profile", options.profile, try std.fmt.allocPrint(arena, "@_build/{s}/install", .{try dist.context(target)}),
        });
        const term = try exec.run(arena, io, .{ .argv = argv.items, .environ = &build_environ, .stdout_to_stderr = true });
        if (!term.success()) {
            var buffer: [64]u8 = undefined;
            log.err("{t}: dune build {s}", .{ target, exec.describe(term, &buffer) });
            return error.Reported;
        }

        // Now: dune removes a context's `_build/install/` when it builds without it.
        const entries = try dist.stage(target);
        try dist.runTests(target);
        try artifacts.append(arena, try dist.pack(target, name, version, entries));
    }

    var sums: Io.Writer.Allocating = .init(arena);
    std.mem.sort(Artifact, artifacts.items, {}, Artifact.lessThan);
    for (artifacts.items) |artifact| try sums.writer.print("{s}  {s}\n", .{ &artifact.sha256, artifact.name });
    try dist.out.writeFile(io, .{ .sub_path = sums_name, .data = sums.written() });

    var buffer: [1024]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &buffer);
    for (artifacts.items) |artifact| try stdout.interface.print("{f}\n", .{std.fs.path.fmtJoin(&.{ options.out, artifact.name })});
    try stdout.interface.print("{f}\n", .{std.fs.path.fmtJoin(&.{ options.out, sums_name })});
    try stdout.interface.flush();
}

arena: std.mem.Allocator,
gpa: std.mem.Allocator,
io: Io,
options: *const Options,
/// This process's: a test's, without the build's toolchains.
environ: *const std.process.Environ.Map,
host: Target,
packages: []const []const u8,
tests: []const []const []const u8,
out: Io.Dir,

/// In `out`: each target's files as its archive has them, until it's made.
const stage_dir = ".stage";
const sums_name = "SHA256SUMS";

const Artifact = struct {
    name: []const u8,
    sha256: [Sha256.digest_length * 2]u8,

    fn lessThan(_: void, a: Artifact, b: Artifact) bool {
        return std.mem.order(u8, a.name, b.name) == .lt;
    }
};

/// The sections of an install file that aren't a package's libraries.
const sections: []const []const u8 = &.{ "bin", "sbin", "share", "share_root", "etc", "doc", "man" };

/// dune's build context for `target`.
fn context(dist: *const Dist, target: Target) ![]const u8 {
    if (target == dist.host) return "default";
    return std.fmt.allocPrint(dist.arena, "default.{s}", .{target.duneName()});
}

/// Copies what the packages install for `target` to its staging directory, as
/// `_build/install/<context>/` has it: an installation prefix. Returns the
/// archive's entries, whose sources are relative to `out`.
fn stage(dist: *const Dist, target: Target) ![]const archive.Entry {
    const arena = dist.arena;
    const io = dist.io;
    const cwd = Io.Dir.cwd();
    const build_context = try dist.context(target);
    const stage_path = try std.fs.path.join(arena, &.{ stage_dir, target.name() });
    var staged = try dist.out.createDirPathOpen(io, stage_path, .{});
    defer staged.close(io);
    // The paths of an install file are in it, and a cross build's destinations
    // aren't a prefix's (they're the toolchain's sysroot's).
    const installed = try std.fmt.allocPrint(arena, "_build/install/{s}/", .{build_context});

    var entries: std.ArrayList(archive.Entry) = .empty;
    for (dist.packages) |package| {
        const install_path = if (target == dist.host)
            try std.fmt.allocPrint(arena, "_build/{s}/{s}.install", .{ build_context, package })
        else
            try std.fmt.allocPrint(arena, "_build/{s}/{s}-{s}.install", .{ build_context, package, target.duneName() });
        const source = cwd.readFileAlloc(io, install_path, arena, .unlimited) catch |err| switch (err) {
            error.FileNotFound => {
                log.err("{t}: dune built no {s}: does the project have a package {s}?", .{ target, install_path, package });
                return error.Reported;
            },
            else => |e| return e,
        };
        const files = parseInstall(arena, source) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            error.InvalidInstallFile => {
                log.err("{s} isn't an install file as dune writes them", .{install_path});
                return error.Reported;
            },
        };

        var install_file: Io.Writer.Allocating = .init(arena);
        var section_open: ?[]const u8 = null;
        for (files) |file| {
            if (!contains(sections, file.section)) continue;
            if (!std.mem.startsWith(u8, file.path, installed)) {
                log.err("{s}: {s} isn't in {s}", .{ install_path, file.path, installed });
                return error.Reported;
            }
            var rel = file.path[installed.len..];
            const stat = cwd.statFile(io, file.path, .{}) catch |err| switch (err) {
                error.FileNotFound => if (file.optional) continue else {
                    log.err("{t}: {s} has {s}, which dune didn't build", .{ target, install_path, file.path });
                    return error.Reported;
                },
                else => |e| return e,
            };
            const program = std.mem.endsWith(u8, file.section, "bin");
            // An install file leaves a Windows executable's `.exe` to who installs it.
            if (program and target.os() == .windows and !std.ascii.endsWithIgnoreCase(rel, ".exe")) {
                if (try Runner.inspect(arena, io, file.path) == .pe) rel = try std.fmt.allocPrint(arena, "{s}.exe", .{rel});
            }
            const executable = program or
                (Io.File.Permissions.has_executable_bit and stat.permissions.toMode() & 0o111 != 0);

            const exists = for (entries.items) |entry| {
                if (std.mem.eql(u8, entry.path, rel)) break true;
            } else false;
            if (!exists) {
                // dune's are symbolic links to read-only files: copies, that an
                // archive's user can replace.
                try cwd.copyFile(file.path, staged, rel, io, .{
                    .make_path = true,
                    .permissions = if (executable) .executable_file else .default_file,
                });
                try entries.append(arena, .{
                    .path = rel,
                    .source = try std.fs.path.join(arena, &.{ stage_path, rel }),
                    .executable = executable,
                });
            }

            // Where an installer puts it, under the section's directory.
            const w = &install_file.writer;
            if (section_open == null or !std.mem.eql(u8, section_open.?, file.section)) {
                if (section_open != null) try w.writeAll("]\n");
                try w.print("{s}: [\n", .{file.section});
                section_open = file.section;
            }
            const root = if (std.mem.eql(u8, file.section, "bin") or std.mem.eql(u8, file.section, "sbin") or std.mem.eql(u8, file.section, "man"))
                try std.fmt.allocPrint(arena, "{s}/", .{file.section})
            else if (std.mem.eql(u8, file.section, "share_root"))
                "share/"
            else
                try std.fmt.allocPrint(arena, "{s}/{s}/", .{ file.section, package });
            if (std.mem.startsWith(u8, rel, root)) {
                try w.print("  \"{s}\" {{\"{s}\"}}\n", .{ rel, rel[root.len..] });
            } else {
                try w.print("  \"{s}\"\n", .{rel});
            }
        }
        if (section_open != null) try install_file.writer.writeAll("]\n");

        if (dist.options.install_file) {
            const install_name = try std.fmt.allocPrint(arena, "{s}.install", .{package});
            try staged.writeFile(io, .{ .sub_path = install_name, .data = install_file.written() });
            try entries.append(arena, .{
                .path = install_name,
                .source = try std.fs.path.join(arena, &.{ stage_path, install_name }),
                .executable = false,
            });
        }
    }

    const has_files = for (entries.items) |entry| {
        if (std.fs.path.dirname(entry.path) != null) break true;
    } else false;
    if (!has_files) {
        log.err("{t}: {f} install{s} nothing but libraries: there's nothing to archive", .{
            target, list(dist.packages), if (dist.packages.len == 1) "s" else "",
        });
        return error.Reported;
    }
    std.mem.sort(archive.Entry, entries.items, {}, archive.Entry.lessThan);
    return entries.items;
}

/// Runs the tests on `target`'s staged files, if this machine can.
fn runTests(dist: *const Dist, target: Target) !void {
    const arena = dist.arena;
    const io = dist.io;
    for (dist.tests) |argv| {
        const program = try std.fmt.allocPrint(arena, "{s}{s}", .{ argv[0], target.exeExt() });
        const exe = try std.fs.path.join(arena, &.{ dist.options.out, stage_dir, target.name(), "bin", program });
        Io.Dir.cwd().access(io, exe, .{}) catch {
            log.err("{t}: --test's {s} isn't in the archive's bin/", .{ target, argv[0] });
            return error.Reported;
        };
        const runner = switch (try Runner.plan(arena, io, dist.environ, exe)) {
            .run => |runner| runner,
            .impossible => |why| {
                log.warn("{t}: not tested. {f}", .{ target, upperFirst(why) });
                return;
            },
            .missing => |what| {
                log.err("{t}: can't be tested. {f}", .{ target, upperFirst(what) });
                return error.Reported;
            },
        };
        log.info("{t}: testing: {f}", .{ target, list(argv) });
        var environ = try runner.environMap(dist.gpa, dist.environ);
        defer environ.deinit();
        const term = try exec.run(arena, io, .{
            .argv = try runner.argv(arena, exe, argv[1..]),
            .environ = &environ,
            .stdout_to_stderr = true,
        });
        if (!term.success()) {
            var buffer: [64]u8 = undefined;
            log.err("{t}: the test `{f}` {s}", .{ target, list(argv), exec.describe(term, &buffer) });
            return error.Reported;
        }
    }
}

/// Archives `target`'s staged files.
fn pack(dist: *const Dist, target: Target, name: []const u8, version: []const u8, entries: []const archive.Entry) !Artifact {
    const arena = dist.arena;
    const io = dist.io;
    const format: archive.Format = switch (dist.options.format) {
        .auto => if (target.os() == .windows) .zip else .@"tar.gz",
        .@"tar.gz" => .@"tar.gz",
        .zip => .zip,
    };
    const file_name = try std.fmt.allocPrint(arena, "{s}-{s}-{t}{s}", .{ name, version, target, format.extension() });
    {
        const file = try dist.out.createFile(io, file_name, .{});
        defer file.close(io);
        var buffer: [64 * 1024]u8 = undefined;
        var writer = file.writer(io, &buffer);
        archive.write(dist.gpa, io, format, &writer.interface, dist.out, entries) catch |err| switch (err) {
            error.TooBig => {
                log.err("{t}: more than a .zip holds (4 GiB): use --format tar.gz", .{target});
                return error.Reported;
            },
            else => |e| return e,
        };
        try writer.interface.flush();
    }

    const file = try dist.out.openFile(io, file_name, .{});
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &buffer);
    var hash: Sha256 = .init(.{});
    while (true) {
        const chunk = reader.interface.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        hash.update(chunk);
        reader.interface.toss(chunk.len);
    }
    var digest: [Sha256.digest_length]u8 = undefined;
    hash.final(&digest);
    log.info("{t}: {f}", .{ target, std.fs.path.fmtJoin(&.{ dist.options.out, file_name }) });
    return .{ .name = file_name, .sha256 = std.fmt.bytesToHex(digest, .lower) };
}

/// The commit's version, as git describes it: its tag (without a `v`), or
/// what's since one, or its hash.
fn gitVersion(arena: std.mem.Allocator, io: Io) !?[]const u8 {
    const result = std.process.run(arena, io, .{ .argv = &.{ "git", "describe", "--tags", "--always" } }) catch |err| switch (err) {
        error.OutOfMemory, error.Canceled => |e| return e,
        else => return null,
    };
    if (!result.term.success()) return null;
    const described = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (described.len == 0) return null;
    if (described.len > 1 and described[0] == 'v' and std.ascii.isDigit(described[1])) return described[1..];
    return described;
}

const InstallEntry = struct {
    section: []const u8,
    /// The file, from the project's root.
    path: []const u8,
    /// `"?<path>"`: installed if it was built.
    optional: bool,
};

/// The files of an install file (opam's `<package>.install`), in its order:
///
///   bin: [
///     "_build/install/default/bin/hello" {"hello"}
///   ]
fn parseInstall(arena: std.mem.Allocator, source: []const u8) error{ OutOfMemory, InvalidInstallFile }![]const InstallEntry {
    var entries: std.ArrayList(InstallEntry) = .empty;
    var section: ?[]const u8 = null;
    var in_list = false;
    var in_destination = false;
    var i: usize = 0;
    while (i < source.len) {
        const c = source[i];
        switch (c) {
            ' ', '\t', '\r', '\n' => i += 1,
            '#' => i = std.mem.findScalarPos(u8, source, i, '\n') orelse source.len,
            '[' => {
                if (section == null or in_list) return error.InvalidInstallFile;
                in_list = true;
                i += 1;
            },
            ']' => {
                if (!in_list or in_destination) return error.InvalidInstallFile;
                in_list = false;
                section = null;
                i += 1;
            },
            '{' => {
                if (!in_list or in_destination) return error.InvalidInstallFile;
                in_destination = true;
                i += 1;
            },
            '}' => {
                if (!in_destination) return error.InvalidInstallFile;
                in_destination = false;
                i += 1;
            },
            '"' => {
                var text: std.ArrayList(u8) = .empty;
                i += 1;
                while (i < source.len and source[i] != '"') : (i += 1) {
                    if (source[i] == '\\' and i + 1 < source.len) i += 1;
                    try text.append(arena, source[i]);
                }
                if (i == source.len) return error.InvalidInstallFile;
                i += 1;
                if (in_destination) continue;
                // A section with one file needs no list.
                const name = section orelse return error.InvalidInstallFile;
                const optional = text.items.len != 0 and text.items[0] == '?';
                try entries.append(arena, .{
                    .section = name,
                    .path = if (optional) text.items[1..] else text.items,
                    .optional = optional,
                });
                if (!in_list) section = null;
            },
            else => {
                const end = std.mem.findScalarPos(u8, source, i, ':') orelse return error.InvalidInstallFile;
                if (in_list or section != null) return error.InvalidInstallFile;
                section = source[i..end];
                for (section.?) |s| {
                    if (!std.ascii.isAlphanumeric(s) and s != '_' and s != '-') return error.InvalidInstallFile;
                }
                i = end + 1;
            },
        }
    }
    if (in_list or in_destination) return error.InvalidInstallFile;
    return entries.items;
}

/// A message, as a sentence.
fn upperFirst(message: []const u8) std.fmt.Alt([]const u8, formatUpperFirst) {
    return .{ .data = message };
}

fn formatUpperFirst(message: []const u8, w: *Io.Writer) Io.Writer.Error!void {
    if (message.len == 0) return;
    try w.print("{c}{s}", .{ std.ascii.toUpper(message[0]), message[1..] });
}

fn contains(names: []const []const u8, name: []const u8) bool {
    for (names) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

fn list(words: []const []const u8) std.fmt.Alt([]const []const u8, formatList) {
    return .{ .data = words };
}

fn formatList(words: []const []const u8, w: *Io.Writer) Io.Writer.Error!void {
    for (words, 0..) |word, i| try w.print("{s}{s}", .{ if (i == 0) "" else " ", word });
}

test parseInstall {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const entries = try parseInstall(arena,
        \\lib: [
        \\  "_build/install/default/lib/hello/META"
        \\  "_build/install/default/lib/hello/sub/a.cmi" {"sub/a.cmi"}
        \\]
        \\bin: [
        \\  "_build/install/default.x86_64_windows_gnu/bin/hello" {"../x86_64_windows_gnu-sysroot/bin/hello"}
        \\  "?_build/install/default/bin/maybe"
        \\]
        \\man: "_build/install/default/man/man1/hello.1"
        \\doc: []
        \\
    );
    try std.testing.expectEqual(5, entries.len);
    try std.testing.expectEqualStrings("lib", entries[1].section);
    try std.testing.expectEqualStrings("_build/install/default/lib/hello/sub/a.cmi", entries[1].path);
    try std.testing.expectEqualStrings("bin", entries[2].section);
    try std.testing.expectEqualStrings("_build/install/default.x86_64_windows_gnu/bin/hello", entries[2].path);
    try std.testing.expect(!entries[2].optional);
    try std.testing.expectEqualStrings("_build/install/default/bin/maybe", entries[3].path);
    try std.testing.expect(entries[3].optional);
    try std.testing.expectEqualStrings("man", entries[4].section);

    try std.testing.expectError(error.InvalidInstallFile, parseInstall(arena, "bin: [\n \"a\"\n"));
    try std.testing.expectError(error.InvalidInstallFile, parseInstall(arena, "\"a\""));
    try std.testing.expectError(error.InvalidInstallFile, parseInstall(arena, "bin [ \"a\" ]"));
}
