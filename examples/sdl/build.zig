const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const gui_dep = b.dependency("gui", .{
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("gui", gui_dep.module("gui"));
    // exe_mod.linkLibrary(gui_dep.artifact("gui"));

    const sdl_dep = b.dependency("sdl", .{
        .target = target,
        .optimize = optimize,
    });
    exe_mod.linkLibrary(sdl_dep.artifact("SDL3"));

    const exe = b.addExecutable(.{
        .name = "sdl_example",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
