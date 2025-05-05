const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const clay_dep = b.dependency("clay", .{
        .target = target,
        .optimize = optimize,
    });

    const clay_lib = b.addStaticLibrary(.{
        .name = "clay",
        .target = target,
        .optimize = optimize,
    });
    clay_lib.addIncludePath(clay_dep.path(""));
    clay_lib.addCSourceFile(.{
        .file = b.path("src/clay.c"),
    });
    clay_lib.linkLibC();
    b.installArtifact(clay_lib);

    const clay_mod = b.addModule("clay", .{
        .root_source_file = b.path("src/root.zig"),
    });
    clay_mod.linkLibrary(clay_lib);

    // Testing
    const test_step = b.step("test", "Run unit tests");
    const main_tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    main_tests.addIncludePath(clay_dep.path(""));
    main_tests.linkLibrary(clay_lib);

    const test_run = b.addRunArtifact(main_tests);
    test_step.dependOn(&test_run.step);
}
