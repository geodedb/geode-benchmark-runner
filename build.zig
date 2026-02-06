const std = @import("std");

fn getGitVersion(b: *std.Build) []const u8 {
    var exit_code: u8 = 0;
    const result = b.runAllowFail(&.{ "git", "describe", "--tags", "--always" }, &exit_code, .Inherit) catch {
        return "0.2.0";
    };
    if (exit_code != 0) return "0.2.0";
    const trimmed = std.mem.trim(u8, result, " \t\n\r");
    if (trimmed.len == 0) return "0.2.0";
    return b.dupe(trimmed);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get version from git tags, falling back to build.zig.zon version
    const version = getGitVersion(b);

    const build_opts = b.addOptions();
    build_opts.addOption([]const u8, "version", version);

    // ========================================================================
    // External Dependencies
    // ========================================================================

    // Geode client library
    const geode_client_dep = b.dependency("geode_client", .{
        .target = target,
        .optimize = optimize,
    });
    const geode_client_mod = geode_client_dep.module("geode_client");

    // CLI framework
    const zig_cli_dep = b.dependency("zig_cli", .{
        .target = target,
        .optimize = optimize,
    });
    const zig_cli_mod = zig_cli_dep.module("zig_cli");

    // YAML parser
    const yaml_dep = b.dependency("yaml", .{
        .target = target,
        .optimize = optimize,
    });
    const yaml_mod = yaml_dep.module("yaml");

    // QUIC transport
    const quic_dep = b.dependency("quic", .{
        .target = target,
        .optimize = optimize,
    });
    const quic_mod = quic_dep.module("quic");

    // JSON library
    const json_dep = b.dependency("json", .{
        .target = target,
        .optimize = optimize,
    });
    const json_mod = json_dep.module("json");

    // Structured logging
    const slog_dep = b.dependency("slog", .{
        .target = target,
        .optimize = optimize,
    });
    const slog_mod = slog_dep.module("slogz");

    // Strings library
    const strings_dep = b.dependency("strings", .{
        .target = target,
        .optimize = optimize,
    });
    const strings_mod = strings_dep.module("strings");

    // ========================================================================
    // Main Executable
    // ========================================================================

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add all dependencies
    exe_mod.addImport("geode_client", geode_client_mod);
    exe_mod.addImport("zig_cli", zig_cli_mod);
    exe_mod.addImport("yaml", yaml_mod);
    exe_mod.addImport("quic", quic_mod);
    exe_mod.addImport("json", json_mod);
    exe_mod.addImport("slog", slog_mod);
    exe_mod.addImport("strings", strings_mod);
    exe_mod.addOptions("build_options", build_opts);

    const exe = b.addExecutable(.{
        .name = "graphbench",
        .root_module = exe_mod,
    });

    // Link system libraries for QUIC
    exe.linkLibC();
    if (target.result.os.tag != .windows) {
        exe.linkSystemLibrary("ssl");
        exe.linkSystemLibrary("crypto");
    }
    if (target.result.os.tag == .linux) {
        exe.linkSystemLibrary("dl");
    }
    if (target.result.os.tag == .windows) {
        exe.linkSystemLibrary("ws2_32");
    }

    b.installArtifact(exe);

    // ========================================================================
    // Run Command
    // ========================================================================

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run graphbench");
    run_step.dependOn(&run_cmd.step);

    // ========================================================================
    // Unit Tests
    // ========================================================================

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    test_mod.addImport("geode_client", geode_client_mod);
    test_mod.addImport("zig_cli", zig_cli_mod);
    test_mod.addImport("yaml", yaml_mod);
    test_mod.addImport("quic", quic_mod);
    test_mod.addImport("json", json_mod);
    test_mod.addImport("slog", slog_mod);
    test_mod.addImport("strings", strings_mod);
    test_mod.addOptions("build_options", build_opts);

    const tests = b.addTest(.{
        .root_module = test_mod,
    });

    tests.linkLibC();
    if (target.result.os.tag != .windows) {
        tests.linkSystemLibrary("ssl");
        tests.linkSystemLibrary("crypto");
    }
    if (target.result.os.tag == .linux) {
        tests.linkSystemLibrary("dl");
    }

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
