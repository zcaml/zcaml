//! What zcaml reads of a dune project: enough to name what it builds, and to
//! say before a build what dune would say halfway through one (`check`). It
//! changes nothing: the lock directory, its platforms and its repositories are
//! the project's to set.
const Project = @This();

const std = @import("std");
const Io = std.Io;
const sexp = @import("sexp.zig");
const Index = @import("Index.zig");
const Target = @import("target.zig").Target;
const overlay = @import("overlay");

const log = std.log.scoped(.zcaml);

/// `dune-project`'s `(name)`.
name: ?[]const u8,
/// `dune-project`'s `(version)`.
version: ?[]const u8,
/// `dune-project`'s `(lang dune <this>)`.
lang: []const u8,
/// The project's packages: `dune-project`'s `(package)`s and the `.opam` files
/// beside it.
packages: []const []const u8,
/// Whether a package depends on anything but the compiler and dune.
has_dependencies: bool,
workspace: ?Workspace,
/// The default context's lock directory, relative to the project.
lock_path: []const u8,
/// Null: there's none.
lock: ?Lock,

pub const Workspace = struct {
    /// `(pkg enabled)` or `(pkg disabled)`.
    pkg: ?bool,
    /// The `(lock_dir)` stanza for `lock_path`.
    lock_dir: ?sexp.Value,
};

pub const Lock = struct {
    /// `lock.dune`'s `solved_for_platforms`: null if it has none (a lock of the
    /// machine it was made on).
    platforms: ?[]const sexp.Value,
    packages: []const Package,

    pub const Package = struct { name: []const u8, version: []const u8 };

    pub fn package(lock: *const Lock, name: []const u8) ?Package {
        for (lock.packages) |p| {
            if (std.mem.eql(u8, p.name, name)) return p;
        }
        return null;
    }
};

pub const LoadError = error{
    /// Reported: no project in the directory, or a file of it dune wouldn't
    /// read either.
    InvalidProject,
} || std.mem.Allocator.Error || Io.Cancelable;

/// The project whose root is `dir`.
pub fn load(arena: std.mem.Allocator, io: Io, dir: Io.Dir) LoadError!Project {
    const project_file = try readSexp(arena, io, dir, "dune-project") orelse {
        log.err("no dune-project here: zcaml builds a dune project, from its root", .{});
        return error.InvalidProject;
    };
    const lang = if (sexp.fieldOf(project_file, "lang")) |args|
        (if (args.len == 2) args[1].text() else null) orelse "3.24"
    else
        "3.24";

    var packages: std.ArrayList([]const u8) = .empty;
    var has_dependencies = false;
    for (project_file) |stanza| {
        if (!stanza.is("package")) continue;
        if (stanza.fieldText("name")) |name| try addName(arena, &packages, name);
        for (stanza.field("depends") orelse &.{}) |dependency| {
            const name = dependency.text() orelse (if (dependency.items().len != 0) dependency.items()[0].text() else null) orelse continue;
            if (!std.mem.eql(u8, name, "ocaml") and !std.mem.eql(u8, name, "dune")) has_dependencies = true;
        }
    }
    if (dir.openDir(io, ".", .{ .iterate = true })) |opened| {
        var root = opened;
        defer root.close(io);
        var it = root.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".opam")) continue;
            try addName(arena, &packages, try arena.dupe(u8, entry.name[0 .. entry.name.len - ".opam".len]));
        }
    } else |_| {}
    std.mem.sort([]const u8, packages.items, {}, lessThan);

    var lock_path: []const u8 = "dune.lock";
    var workspace: ?Workspace = null;
    if (try readSexp(arena, io, dir, "dune-workspace")) |workspace_file| {
        // `(context (default (lock_dir <path>)))`: the default context's, which
        // the targets' contexts share.
        for (workspace_file) |stanza| {
            if (!stanza.is("context") or stanza.items().len != 2) continue;
            const context = stanza.items()[1];
            if (!context.is("default")) continue;
            if (context.fieldText("name")) |context_name| if (!std.mem.eql(u8, context_name, "default")) continue;
            if (context.fieldText("lock_dir")) |path| lock_path = path;
        }
        var lock_dir: ?sexp.Value = null;
        for (workspace_file) |stanza| {
            if (!stanza.is("lock_dir")) continue;
            if (std.mem.eql(u8, stanza.fieldText("path") orelse "dune.lock", lock_path)) lock_dir = stanza;
        }
        const pkg: ?bool = if (sexp.fieldOf(workspace_file, "pkg")) |args|
            (if (args.len == 1 and args[0].text() != null) std.mem.eql(u8, args[0].atom, "enabled") else null)
        else
            null;
        workspace = .{ .pkg = pkg, .lock_dir = lock_dir };
    }

    return .{
        .name = oneAtom(project_file, "name"),
        .version = oneAtom(project_file, "version"),
        .lang = lang,
        .packages = packages.items,
        .has_dependencies = has_dependencies,
        .workspace = workspace,
        .lock_path = lock_path,
        .lock = try loadLock(arena, io, dir, lock_path),
    };
}

pub const CheckOptions = struct {
    /// The compiler the build is with.
    release: *const Index.Ocaml,
    /// For the releases there are.
    index: *const Index,
    host: Target,
    targets: []const Target,
};

pub const Problem = struct {
    /// An error: dune can't build the project for the targets.
    fatal: bool,
    message: []const u8,
};

/// Whether dune can build the project for the targets: everything that says it
/// can't, with what to change. zcaml doesn't change it: which packages a build
/// takes, from where, is the project's decision.
pub fn check(project: *const Project, arena: std.mem.Allocator, options: CheckOptions) std.mem.Allocator.Error![]const Problem {
    var problems: std.ArrayList(Problem) = .empty;
    const lock = project.lock orelse {
        const autolocks = if (project.workspace) |w| w.pkg orelse false else false;
        if (autolocks) {
            // dune locks when it builds, for the workspace's platforms.
            const asked = project.askedPlatforms();
            var missing: std.ArrayList(Target) = .empty;
            for (options.targets) |target| {
                if (!covered(asked orelse default_platforms, target)) try missing.append(arena, target);
            }
            if (missing.items.len != 0) try add(arena, &problems, true, "dune-workspace doesn't lock for {f}.\n{s}", .{
                targetList(missing.items), try project.platformsAdvice(arena, null, missing.items),
            });
        } else if (project.has_dependencies) {
            try add(arena, &problems, false,
                \\no {s}: dune builds without its package management, so with no libraries
                \\but OCaml's own. For the project's dependencies, run `dune pkg lock` and commit
                \\{s}.
            , .{ project.lock_path, project.lock_path });
        }
        return problems.items;
    };

    if (lock.platforms) |solved| {
        var missing: std.ArrayList(Target) = .empty;
        for (options.targets) |target| {
            if (!covered(solved, target)) try missing.append(arena, target);
        }
        if (missing.items.len != 0) try add(arena, &problems, true, "{s} has no solution for {f}: it's solved for{f}\n{s}", .{
            project.lock_path,
            targetList(missing.items),
            platformList(solved),
            try project.platformsAdvice(arena, solved, missing.items),
        });
    }

    if (lock.package("ocaml")) |locked| {
        // zcaml's toolchains are the compiler, the build machine's and the
        // targets': one the lock directory builds from source isn't any target's,
        // and its libraries can't be mixed with theirs.
        if (lock.package("ocaml-system") == null) {
            const built: []const u8 = for (source_compilers) |name| {
                if (lock.package(name) != null) break name;
            } else "a compiler";
            const v = options.release.version;
            const has_stanza = if (project.workspace) |workspace| workspace.lock_dir != null else false;
            const stanza = if (has_stanza)
                try std.fmt.allocPrint(arena,
                    \\Add to dune-workspace's `lock_dir`:
                    \\
                    \\  (solver_env (sys-ocaml-version {s}))
                    \\  (constraints (ocaml-system (= {s})))
                , .{ v, v })
            else
                try std.fmt.allocPrint(arena,
                    \\{s}
                    \\  (lock_dir
                    \\   (solver_env (sys-ocaml-version {s}))
                    \\   (constraints (ocaml-system (= {s}))))
                , .{
                    if (project.workspace != null)
                        "Add to dune-workspace:\n"
                    else
                        try std.fmt.allocPrint(arena, "Create dune-workspace, beside dune-project:\n\n  (lang dune {s})", .{project.lang}),
                    v,
                    v,
                });
            try add(arena, &problems, true,
                \\{s} builds OCaml from source ({s}), not for the targets: zcaml's
                \\toolchains are the compiler, and the lock directory must take the installed one
                \\(ocaml-system). {s}
                \\
                \\then `dune pkg lock`, and commit the lock directory.
            , .{ project.lock_path, built, stanza });
        }

        // OCaml reads only its own release's compiled interfaces: the targets'
        // toolchains and the lock's compiler must be the same one.
        const locked_release = releaseOf(locked.version);
        if (!std.mem.eql(u8, locked_release, options.release.version)) {
            if (options.index.ocamlRelease(locked_release) != null) {
                try add(arena, &problems, true, "{s} has OCaml {s}, not {s}: build with `--ocaml {s}`.", .{
                    project.lock_path, locked.version, options.release.version, locked_release,
                });
            } else {
                try add(arena, &problems, true,
                    \\{s} has OCaml {s}, not {s}, and zcaml has no OCaml {s}.
                    \\Lock the compiler zcaml builds with: in dune-project, a package's
                    \\
                    \\  (depends (ocaml (= {s})) ...)
                    \\
                    \\then `dune pkg lock`.
                , .{ project.lock_path, locked.version, options.release.version, locked_release, options.release.version });
            }
        }
    }

    // The overlay's packages are the ones that don't cross-compile as
    // opam-repository has them: a hint, since a build may not reach what fails.
    const cross = for (options.targets) |target| {
        if (target != options.host) break true;
    } else false;
    if (cross) {
        var upstream: std.ArrayList(u8) = .empty;
        for (lock.packages) |p| {
            if (std.mem.find(u8, p.version, "+zcaml") != null) continue;
            for (overlay.replaced) |name| {
                if (!std.mem.eql(u8, name, p.name)) continue;
                try upstream.print(arena, "{s}{s}.{s}", .{ if (upstream.items.len == 0) "" else ", ", p.name, p.version });
            }
        }
        if (upstream.items.len != 0) try add(arena, &problems, false,
            \\{s} has opam-repository's {s}: zcaml's overlay has
            \\versions that cross-compile. If their builds fail, put it ahead of the other
            \\repositories in dune-workspace:
            \\
            \\  (repository
            \\   (name zcaml)
            \\   (url git+https://github.com/zcaml/zcaml-overlay.git))
            \\  (lock_dir
            \\   (repositories zcaml overlay upstream))
            \\
            \\then `dune pkg lock`.
        , .{ project.lock_path, upstream.items });
    }
    return problems.items;
}

fn add(arena: std.mem.Allocator, problems: *std.ArrayList(Problem), fatal: bool, comptime fmt: []const u8, args: anytype) !void {
    try problems.append(arena, .{ .fatal = fatal, .message = try std.fmt.allocPrint(arena, fmt, args) });
}

/// opam's packages that build OCaml: a lock directory with one doesn't take the
/// installed compiler.
const source_compilers: []const []const u8 = &.{ "ocaml-base-compiler", "ocaml-variants", "relocatable-compiler", "ocaml-compiler" };

/// dune's `solve_for_platforms`, when a workspace doesn't set it.
const default_platforms: []const sexp.Value = &.{
    platform("x86_64", "linux"),
    platform("arm64", "linux"),
    platform("x86_64", "macos"),
    platform("arm64", "macos"),
};

fn platform(comptime arch: []const u8, comptime os: []const u8) sexp.Value {
    return .{ .list = &.{
        .{ .list = &.{ .{ .atom = "arch" }, .{ .atom = arch } } },
        .{ .list = &.{ .{ .atom = "os" }, .{ .atom = os } } },
    } };
}

/// Whether one of `platforms` is `target`'s: its `arch` and `os`, as zcaml's
/// dune picks a target's solution (build/dune/cross_pkg.ml).
fn covered(platforms: []const sexp.Value, target: Target) bool {
    for (platforms) |p| {
        const arch_ok = if (p.fieldText("arch")) |arch| std.mem.eql(u8, arch, target.opamArch()) else true;
        const os_ok = if (p.fieldText("os")) |os| std.mem.eql(u8, os, target.opamOs()) else true;
        if (arch_ok and os_ok) return true;
    }
    return false;
}

/// The workspace's `solve_for_platforms`, if it sets it.
fn askedPlatforms(project: *const Project) ?[]const sexp.Value {
    const workspace = project.workspace orelse return null;
    const lock_dir = workspace.lock_dir orelse return null;
    return lock_dir.field("solve_for_platforms");
}

/// What to change for the lock directory to have `missing`'s solutions.
/// `solved`: what it has, if there's one.
fn platformsAdvice(project: *const Project, arena: std.mem.Allocator, solved: ?[]const sexp.Value, missing: []const Target) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    project.writePlatformsAdvice(w, solved, missing) catch return error.OutOfMemory;
    return out.written();
}

fn writePlatformsAdvice(project: *const Project, w: *Io.Writer, solved: ?[]const sexp.Value, missing: []const Target) !void {
    const asked = project.askedPlatforms();
    const relock: []const u8 = if (solved != null) "\n\nthen `dune pkg lock`, and commit the lock directory." else "";

    if (asked) |platforms| {
        var unasked_buffer: [Target.all.len]Target = undefined;
        var unasked: std.ArrayList(Target) = .initBuffer(&unasked_buffer);
        for (missing) |target| {
            if (!covered(platforms, target)) unasked.appendAssumeCapacity(target);
        }
        if (unasked.items.len == 0) {
            try w.writeAll(
                \\dune-workspace asks for them: run `dune pkg lock`, which says so if it finds no
                \\solution for a platform (and still succeeds), and commit the lock directory.
            );
            return;
        }
        try w.writeAll("Add to the `solve_for_platforms` of dune-workspace's `lock_dir`:\n\n");
        for (unasked.items, 0..) |target, i| try w.print("{s}  {s}", .{ if (i == 0) "" else "\n", target.opamPlatform() });
        try w.writeAll(relock);
        return;
    }

    // Setting it replaces dune's defaults: the ones the lock has stay.
    const has_stanza = if (project.workspace) |workspace| workspace.lock_dir != null else false;
    if (has_stanza) {
        try w.writeAll("Add to dune-workspace's `lock_dir`:\n\n");
    } else if (project.workspace != null) {
        try w.writeAll("Add to dune-workspace:\n\n  (lock_dir\n");
    } else {
        try w.print("Create dune-workspace, beside dune-project:\n\n  (lang dune {s})\n  (lock_dir\n", .{project.lang});
    }
    const indent: []const u8 = if (has_stanza) "  " else "   ";
    try w.print("{s}(solve_for_platforms\n", .{indent});
    for (solved orelse default_platforms) |p| {
        // Without what dune adds to a solved platform.
        try w.print("{s} (", .{indent});
        var first = true;
        for (p.items()) |variable| {
            if (variable.is("sys-ocaml-version")) continue;
            try w.print("{s}{f}", .{ if (first) "" else " ", variable });
            first = false;
        }
        try w.writeAll(")\n");
    }
    for (missing, 0..) |target, i| {
        try w.print("{s} {s}{s}", .{ indent, target.opamPlatform(), if (i + 1 == missing.len) ")" else "\n" });
    }
    try w.print("{s}{s}", .{ if (has_stanza) "" else ")", relock });
}

fn loadLock(arena: std.mem.Allocator, io: Io, dir: Io.Dir, lock_path: []const u8) LoadError!?Lock {
    var lock_dir = dir.openDir(io, lock_path, .{ .iterate = true }) catch return null;
    defer lock_dir.close(io);
    const lock_file = try readSexp(arena, io, lock_dir, "lock.dune") orelse return null;

    // `<name>.<version>.pkg`: a package's name has no `.`.
    var packages: std.ArrayList(Lock.Package) = .empty;
    var it = lock_dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".pkg")) continue;
        const stem = try arena.dupe(u8, entry.name[0 .. entry.name.len - ".pkg".len]);
        const dot = std.mem.findScalar(u8, stem, '.') orelse continue;
        try packages.append(arena, .{ .name = stem[0..dot], .version = stem[dot + 1 ..] });
    }
    std.mem.sort(Lock.Package, packages.items, {}, struct {
        fn lessThan(_: void, a: Lock.Package, b: Lock.Package) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lessThan);
    return .{ .platforms = sexp.fieldOf(lock_file, "solved_for_platforms"), .packages = packages.items };
}

/// `dir/name`'s values, or null if there's no such file.
fn readSexp(arena: std.mem.Allocator, io: Io, dir: Io.Dir, name: []const u8) LoadError!?[]const sexp.Value {
    const source = dir.readFileAlloc(io, name, arena, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.OutOfMemory, error.Canceled => |e| return e,
        else => {
            log.err("reading {s} failed: {t}", .{ name, err });
            return error.InvalidProject;
        },
    };
    var diagnostic: sexp.Diagnostic = .{};
    return sexp.parse(arena, source, &diagnostic) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.InvalidSexp => {
            log.err("{s}:{d}: {s}", .{ name, diagnostic.line, diagnostic.message });
            return error.InvalidProject;
        },
    };
}

/// The atom of `values`' `(<name> <atom>)`.
fn oneAtom(values: []const sexp.Value, name: []const u8) ?[]const u8 {
    const args = sexp.fieldOf(values, name) orelse return null;
    return if (args.len == 1) args[0].text() else null;
}

/// A compiler's release: its version without what's after a `+` or `~`
/// (`5.5.1+options`, `5.6.0~alpha1`).
fn releaseOf(version: []const u8) []const u8 {
    const end = std.mem.findAny(u8, version, "+~") orelse version.len;
    return version[0..end];
}

fn addName(arena: std.mem.Allocator, names: *std.ArrayList([]const u8), name: []const u8) !void {
    for (names.items) |existing| {
        if (std.mem.eql(u8, existing, name)) return;
    }
    try names.append(arena, name);
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn targetList(targets: []const Target) std.fmt.Alt([]const Target, formatTargetList) {
    return .{ .data = targets };
}

fn formatTargetList(targets: []const Target, w: *Io.Writer) Io.Writer.Error!void {
    for (targets, 0..) |target, i| try w.print("{s}{t}", .{ if (i == 0) "" else ", ", target });
}

fn platformList(platforms: []const sexp.Value) std.fmt.Alt([]const sexp.Value, formatPlatformList) {
    return .{ .data = platforms };
}

fn formatPlatformList(platforms: []const sexp.Value, w: *Io.Writer) Io.Writer.Error!void {
    for (platforms) |p| try w.print("\n  {f}", .{p});
}

const Fixture = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,

    const File = struct { []const u8, []const u8 };

    fn init(files: []const File) !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        for (files) |file| {
            if (std.fs.path.dirname(file[0])) |dir| try tmp.dir.createDirPath(std.testing.io, dir);
            try tmp.dir.writeFile(std.testing.io, .{ .sub_path = file[0], .data = file[1] });
        }
        return .{ .tmp = tmp, .arena = .init(std.testing.allocator) };
    }

    fn deinit(fixture: *Fixture) void {
        fixture.arena.deinit();
        fixture.tmp.cleanup();
    }

    fn check(fixture: *Fixture, targets: []const Target) ![]const Problem {
        const arena = fixture.arena.allocator();
        const project = try load(arena, std.testing.io, fixture.tmp.dir);
        return project.check(arena, .{
            .release = &Index.testing.ocaml[0],
            .index = &Index.testing,
            .host = .@"x86_64-linux-gnu",
            .targets = targets,
        });
    }
};

const test_project: Fixture.File = .{
    "dune-project",
    \\(lang dune 3.20)
    \\(name hello)
    \\(version 1.2.3)
    \\(package (name hello) (depends ocaml dune fmt))
    \\(package (name hello-lib))
};

fn testLock(comptime platforms: []const u8) Fixture.File {
    return .{ "dune.lock/lock.dune", "(lang package 0.1)\n(solved_for_platforms\n" ++ platforms ++ ")\n" };
}

fn testCompiler(comptime name: []const u8) [2]Fixture.File {
    const version = Index.testing.ocaml[0].version;
    return .{
        .{ "dune.lock/ocaml." ++ version ++ ".pkg", "" },
        .{ "dune.lock/" ++ name ++ "." ++ version ++ ".pkg", "" },
    };
}

test load {
    var fixture: Fixture = try .init(&.{
        test_project,
        .{ "extra.opam", "" },
        .{
            "dune-workspace",
            \\(lang dune 3.20)
            \\(context (default (lock_dir locks/main)))
            \\(lock_dir (path other) (solve_for_platforms ((os linux))))
            \\(lock_dir (path locks/main) (solve_for_platforms ((arch x86_64) (os win32))))
            \\(pkg enabled)
        },
        .{ "locks/main/lock.dune", "(lang package 0.1)\n(solved_for_platforms ((arch x86_64) (os win32)))\n" },
        .{ "locks/main/fmt.0.11.0+zcaml.pkg", "" },
        .{ "locks/main/ocaml.5.5.1.pkg", "" },
        .{ "locks/main/fmt.0.11.0+zcaml.files/a.patch", "" },
    });
    defer fixture.deinit();
    const project = try load(fixture.arena.allocator(), std.testing.io, fixture.tmp.dir);

    try std.testing.expectEqualStrings("hello", project.name.?);
    try std.testing.expectEqualStrings("1.2.3", project.version.?);
    try std.testing.expectEqualStrings("3.20", project.lang);
    try std.testing.expect(project.has_dependencies);
    try std.testing.expectEqual(3, project.packages.len);
    try std.testing.expectEqualStrings("extra", project.packages[0]);
    try std.testing.expectEqualStrings("hello", project.packages[1]);
    try std.testing.expectEqualStrings("hello-lib", project.packages[2]);
    try std.testing.expectEqualStrings("locks/main", project.lock_path);
    try std.testing.expectEqual(true, project.workspace.?.pkg);
    try std.testing.expectEqualStrings("win32", project.askedPlatforms().?[0].fieldText("os").?);

    const lock = project.lock.?;
    try std.testing.expectEqual(1, lock.platforms.?.len);
    try std.testing.expectEqual(2, lock.packages.len);
    try std.testing.expectEqualStrings("0.11.0+zcaml", lock.package("fmt").?.version);
    try std.testing.expectEqualStrings("5.5.1", lock.package("ocaml").?.version);
}

test "check: a lock directory for the targets, with the installed compiler" {
    var fixture: Fixture = try .init(&(.{
        test_project,
        testLock("((arch x86_64) (os linux) (sys-ocaml-version 5.5.1)) ((arch x86_64) (os win32))"),
    } ++ testCompiler("ocaml-system")));
    defer fixture.deinit();
    const problems = try fixture.check(&.{ .@"x86_64-linux-gnu", .@"x86_64-linux-musl", .@"x86_64-windows-gnu" });
    try std.testing.expectEqual(0, problems.len);
}

test "check: targets the lock directory has no solution for" {
    var fixture: Fixture = try .init(&(.{
        test_project,
        testLock("((arch x86_64) (os linux) (sys-ocaml-version 5.5.1)) ((arch arm64) (os macos))"),
    } ++ testCompiler("ocaml-system")));
    defer fixture.deinit();
    const problems = try fixture.check(&.{ .@"x86_64-linux-gnu", .@"aarch64-linux-gnu", .@"x86_64-windows-gnu" });
    try std.testing.expectEqual(1, problems.len);
    try std.testing.expect(problems[0].fatal);
    try std.testing.expectEqualStrings(
        \\dune.lock has no solution for aarch64-linux-gnu, x86_64-windows-gnu: it's solved for
        \\  ((arch x86_64) (os linux) (sys-ocaml-version 5.5.1))
        \\  ((arch arm64) (os macos))
        \\Create dune-workspace, beside dune-project:
        \\
        \\  (lang dune 3.20)
        \\  (lock_dir
        \\   (solve_for_platforms
        \\    ((arch x86_64) (os linux))
        \\    ((arch arm64) (os macos))
        \\    ((arch arm64) (os linux))
        \\    ((arch x86_64) (os win32) (sys-ocaml-arch x86_64) (sys-ocaml-cc cc) (sys-ocaml-libc msvc))))
        \\
        \\then `dune pkg lock`, and commit the lock directory.
    , problems[0].message);
}

test "check: a workspace that asks for fewer platforms than the targets" {
    var fixture: Fixture = try .init(&(.{
        test_project,
        .{ "dune-workspace", "(lang dune 3.20)\n(lock_dir (solve_for_platforms ((arch x86_64) (os linux))))\n" },
        testLock("((arch x86_64) (os linux))"),
    } ++ testCompiler("ocaml-system")));
    defer fixture.deinit();
    const problems = try fixture.check(&.{.@"aarch64-macos-none"});
    try std.testing.expectEqual(1, problems.len);
    try std.testing.expectEqualStrings(
        \\dune.lock has no solution for aarch64-macos-none: it's solved for
        \\  ((arch x86_64) (os linux))
        \\Add to the `solve_for_platforms` of dune-workspace's `lock_dir`:
        \\
        \\  ((arch arm64) (os macos))
        \\
        \\then `dune pkg lock`, and commit the lock directory.
    , problems[0].message);
}

test "check: a lock directory that builds the compiler" {
    var fixture: Fixture = try .init(&(.{
        test_project,
        testLock("((arch x86_64) (os linux))"),
    } ++ testCompiler("ocaml-base-compiler")));
    defer fixture.deinit();
    const problems = try fixture.check(&.{.@"x86_64-linux-gnu"});
    try std.testing.expectEqual(1, problems.len);
    try std.testing.expect(problems[0].fatal);
    try std.testing.expectEqualStrings(std.fmt.comptimePrint(
        \\dune.lock builds OCaml from source (ocaml-base-compiler), not for the targets: zcaml's
        \\toolchains are the compiler, and the lock directory must take the installed one
        \\(ocaml-system). Create dune-workspace, beside dune-project:
        \\
        \\  (lang dune 3.20)
        \\  (lock_dir
        \\   (solver_env (sys-ocaml-version {0s}))
        \\   (constraints (ocaml-system (= {0s}))))
        \\
        \\then `dune pkg lock`, and commit the lock directory.
    , .{Index.testing.ocaml[0].version}), problems[0].message);
}

test "check: another compiler's lock directory" {
    var fixture: Fixture = try .init(&.{
        test_project,
        testLock("((arch x86_64) (os linux))"),
        .{ "dune.lock/ocaml.4.14.2.pkg", "" },
        .{ "dune.lock/ocaml-system.4.14.2.pkg", "" },
    });
    defer fixture.deinit();
    const problems = try fixture.check(&.{.@"x86_64-linux-gnu"});
    try std.testing.expectEqual(1, problems.len);
    try std.testing.expect(std.mem.startsWith(u8, problems[0].message, "dune.lock has OCaml 4.14.2, not "));
}

test "check: no lock directory" {
    var fixture: Fixture = try .init(&.{test_project});
    defer fixture.deinit();
    var problems = try fixture.check(&.{.@"x86_64-windows-gnu"});
    try std.testing.expectEqual(1, problems.len);
    try std.testing.expect(!problems[0].fatal);

    // dune locks as it builds: for its default platforms.
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "dune-workspace", .data = "(lang dune 3.20)\n(pkg enabled)\n" });
    problems = try fixture.check(&.{ .@"aarch64-linux-musl", .@"x86_64-windows-gnu" });
    try std.testing.expectEqual(1, problems.len);
    try std.testing.expect(problems[0].fatal);
    try std.testing.expectEqualStrings(
        \\dune-workspace doesn't lock for x86_64-windows-gnu.
        \\Add to dune-workspace:
        \\
        \\  (lock_dir
        \\   (solve_for_platforms
        \\    ((arch x86_64) (os linux))
        \\    ((arch arm64) (os linux))
        \\    ((arch x86_64) (os macos))
        \\    ((arch arm64) (os macos))
        \\    ((arch x86_64) (os win32) (sys-ocaml-arch x86_64) (sys-ocaml-cc cc) (sys-ocaml-libc msvc))))
    , problems[0].message);
}
