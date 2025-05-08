const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Determine SDL path - allow for override via SDL_PATH
    var sdl_path = b.option([]const u8, "sdl-path", "Path to SDL installation (if not in standard path)") orelse "";

    // Get zlay dependency
    const zlay_dep = b.dependency("zlay", .{
        .target = target,
        .optimize = optimize,
    });

    // Create executable
    const exe = b.addExecutable(.{
        .name = "zlay-sdl-example",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    // Add SDL dependency
    if (sdl_path.len > 0) {
        exe.addIncludePath(.{ .path = b.fmt("{s}/include", .{sdl_path}) });
        exe.addLibraryPath(.{ .path = b.fmt("{s}/lib", .{sdl_path}) });
    }
    exe.linkSystemLibrary("SDL2");
    exe.linkLibC();

    // Add zlay module
    exe.addModule("zlay", zlay_dep.module("zlay"));

    // Install
    b.installArtifact(exe);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    // Run step
    const run_step = b.step("run", "Run the SDL example");
    run_step.dependOn(&run_cmd.step);
}