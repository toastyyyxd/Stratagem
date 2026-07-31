const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_model = .baseline } });
    const optimize = b.standardOptimizeOption(.{});

    const main_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .optimize = optimize,
        .target = target,
        .link_libc = true,
    });

    const z_wgpu_native_pkg = b.dependency("z_wgpu_native", .{
        .target = target,
        .optimize = optimize,
        .mode = "minimal",
    });
    const wgpu = z_wgpu_native_pkg.module("z_wgpu_native");
    const wgpu_artifact = z_wgpu_native_pkg.artifact("z_wgpu_native");
    main_mod.linkLibrary(wgpu_artifact);
    main_mod.addImport("wgpu", wgpu);

    const zigwin32_pkgs = b.dependency("zigwin32", .{});
    const win32 = zigwin32_pkgs.module("win32");
    main_mod.addImport("win32", win32);

    const diffz_pkg = b.dependency("diffz", .{});
    const diffz = diffz_pkg.module("diffz");
    main_mod.addImport("diffz", diffz);

    const hwloc_translate_c = b.addTranslateC(.{
        .optimize = optimize,
        .target = target,
        .root_source_file = b.path("src/utils/hwloc_c.h"),
        .link_libc = true,
    });
    hwloc_translate_c.linkSystemLibrary("hwloc", .{});
    const hwloc = hwloc_translate_c.createModule();
    main_mod.addImport("hwloc", hwloc);

    const exe = b.addExecutable(.{
        .name = "Stratagem",
        .root_module = main_mod,
        .use_llvm = true,
    });

    // Install
    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run Stratagem");
    run_step.dependOn(&run_cmd.step);

    // --- Test step ---
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .optimize = optimize,
        .target = target,
        .link_libc = false,
    });
    test_mod.linkLibrary(wgpu_artifact);
    test_mod.addImport("wgpu", wgpu);
    test_mod.addImport("win32", win32);
    test_mod.addImport("diffz", diffz);
    test_mod.addImport("hwloc", hwloc);

    const tests = b.addTest(.{
        .root_module = test_mod,
        .use_llvm = true,
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
}
