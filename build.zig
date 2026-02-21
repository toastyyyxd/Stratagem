const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_model = .baseline }});
    const optimize = b.standardOptimizeOption(.{});

    const main_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .optimize = optimize,
        .target = target,
        .link_libc = false,
    });
    const exe = b.addExecutable(.{
        .name = "Stratagem",
        .root_module = main_mod,
        .use_llvm = true,
    });

    const options = b.addOptions();
    const is_dev = optimize != .ReleaseSafe and optimize != .ReleaseFast;
    options.addOption(bool, "is_dev", is_dev);
    const options_module = options.createModule();
    exe.root_module.addImport("build_options", options_module);

//    // Raylib dependency
//    const raylib_dep = b.dependency("raylib_zig", .{
//        .target = target,
//        .optimize = optimize,
//    });
//    const raylib = raylib_dep.module("raylib"); // main raylib module
//    const raygui = raylib_dep.module("raygui"); // raygui module
//    const raylib_artifact = raylib_dep.artifact("raylib");
//    exe.linkLibrary(raylib_artifact);
//    exe.root_module.addImport("raylib", raylib);
//    exe.root_module.addImport("raygui", raygui);

    // Install
    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Test step
    const test_artifact = b.addTest(.{
        .name = "Tests",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .root_source_file = b.path("src/tests.zig"), .imports = &.{std.Build.Module.Import{ .name = "build_options", .module = options_module }} }),
        .use_llvm = true,
    });
    const test_cmd = b.addRunArtifact(test_artifact);
    b.installArtifact(test_artifact);

    if (b.args) |args| {
        test_cmd.addArgs(args);
    }

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&test_cmd.step);
}
