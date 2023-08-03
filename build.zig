const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addStaticLibrary(.{
        .name = "stub",
        .target = target,
        .optimize = optimize,
    });
    lib.linkLibC();
    lib.addCSourceFiles(&.{"stub.c"}, &.{});
    try addPaths(b, lib);

    b.installArtifact(lib);
}

/// Add the necessary paths to the given compilation step for the Xcode SDK.
///
/// This is required to workaround a Zig issue where we can't depend directly
/// on the hexops/xcode-frameworks repository: https://github.com/ziglang/zig/pull/15382
///
/// This is copied and adapted from hexops/mach. I modified it slightly
/// for my own personal taste (nothing wrong with theirs!), but the logic
/// is effectively identical.
pub fn addPaths(b: *std.Build, step: *std.build.CompileStep) !void {
    // branch: mach
    try ensureGitRepoCloned(
        b.allocator,
        "https://github.com/hexops/xcode-frameworks",
        "723aa55e9752c8c6c25d3413722b5fe13d72ac4f",
        xSdkPath("/zig-cache/xcode_frameworks"),
    );

    step.addFrameworkPath(.{ .path = xSdkPath("/zig-cache/xcode_frameworks/Frameworks") });
    step.addSystemIncludePath(.{ .path = xSdkPath("/zig-cache/xcode_frameworks/include") });
    step.addLibraryPath(.{ .path = xSdkPath("/zig-cache/xcode_frameworks/lib") });
}

fn ensureGitRepoCloned(
    allocator: std.mem.Allocator,
    clone_url: []const u8,
    revision: []const u8,
    dir: []const u8,
) !void {
    if (envVarIsTruthy(allocator, "NO_ENSURE_SUBMODULES") or
        envVarIsTruthy(allocator, "NO_ENSURE_GIT")) return;

    ensureGit(allocator);

    if (std.fs.openDirAbsolute(dir, .{})) |_| {
        const current_revision = try currentGitRevision(allocator, dir);
        if (!std.mem.eql(u8, current_revision, revision)) {
            // Reset to the desired revision
            exec(
                allocator,
                &[_][]const u8{ "git", "fetch" },
                dir,
            ) catch |err| std.debug.print(
                "warning: failed to 'git fetch' in {s}: {s}\n",
                .{ dir, @errorName(err) },
            );
            try exec(allocator, &[_][]const u8{ "git", "checkout", "--quiet", "--force", revision }, dir);
            try exec(allocator, &[_][]const u8{ "git", "submodule", "update", "--init", "--recursive" }, dir);
        }
        return;
    } else |err| return switch (err) {
        error.FileNotFound => {
            std.log.info("cloning required dependency..\ngit clone {s} {s}..\n", .{ clone_url, dir });
            try exec(allocator, &[_][]const u8{ "git", "clone", "-c", "core.longpaths=true", clone_url, dir }, ".");
            try exec(allocator, &[_][]const u8{ "git", "checkout", "--quiet", "--force", revision }, dir);
            try exec(allocator, &[_][]const u8{ "git", "submodule", "update", "--init", "--recursive" }, dir);
            return;
        },
        else => err,
    };
}

fn exec(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    cwd: []const u8,
) !void {
    var child = std.ChildProcess.init(argv, allocator);
    child.cwd = cwd;
    _ = try child.spawnAndWait();
}

fn currentGitRevision(allocator: std.mem.Allocator, cwd: []const u8) ![]const u8 {
    const result = try std.ChildProcess.exec(.{
        .allocator = allocator,
        .argv = &.{ "git", "rev-parse", "HEAD" },
        .cwd = cwd,
    });
    allocator.free(result.stderr);
    if (result.stdout.len > 0) return result.stdout[0 .. result.stdout.len - 1]; // trim newline
    return result.stdout;
}

fn ensureGit(allocator: std.mem.Allocator) void {
    const argv = &[_][]const u8{ "git", "--version" };
    const result = std.ChildProcess.exec(.{
        .allocator = allocator,
        .argv = argv,
        .cwd = ".",
    }) catch { // e.g. FileNotFound
        std.log.err("mach: error: 'git --version' failed. Is git not installed?", .{});
        std.process.exit(1);
    };
    defer {
        allocator.free(result.stderr);
        allocator.free(result.stdout);
    }
    if (result.term.Exited != 0) {
        std.log.err("mach: error: 'git --version' failed. Is git not installed?", .{});
        std.process.exit(1);
    }
}

fn envVarIsTruthy(allocator: std.mem.Allocator, name: []const u8) bool {
    if (std.process.getEnvVarOwned(allocator, name)) |truthy| {
        defer allocator.free(truthy);
        if (std.mem.eql(u8, truthy, "true")) return true;
        return false;
    } else |_| {
        return false;
    }
}

fn xSdkPath(comptime suffix: []const u8) []const u8 {
    if (suffix[0] != '/') @compileError("suffix must be an absolute path");
    return comptime blk: {
        const root_dir = std.fs.path.dirname(@src().file) orelse ".";
        break :blk root_dir ++ suffix;
    };
}
