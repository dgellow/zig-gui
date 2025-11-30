const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Profiling build option: -Denable_profiling=true
    const enable_profiling = b.option(bool, "enable_profiling", "Enable profiling and tracing") orelse false;

    // Create build options module for compile-time configuration
    const build_options = b.addOptions();
    build_options.addOption(bool, "enable_profiling", enable_profiling);

    // Create zig-gui module for examples to import
    // Note: zlay is now integrated into src/layout/ instead of separate module
    const zig_gui_mod = b.addModule("zig-gui", .{
        .root_source_file = b.path("src/root.zig"),
    });
    zig_gui_mod.addOptions("build_options", build_options);

    // Create static library
    const lib = b.addStaticLibrary(.{
        .name = "gui",
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib.root_module.addOptions("build_options", build_options);
    b.installArtifact(lib);

    // ===== Examples =====

    // Counter example (event-driven mode)
    const counter_exe = b.addExecutable(.{
        .name = "counter",
        .root_source_file = b.path("examples/counter.zig"),
        .target = target,
        .optimize = optimize,
    });
    counter_exe.root_module.addImport("zig-gui", zig_gui_mod);
    b.installArtifact(counter_exe);

    const counter_run = b.addRunArtifact(counter_exe);
    counter_run.step.dependOn(b.getInstallStep());

    const counter_step = b.step("counter", "Run counter example (event-driven mode)");
    counter_step.dependOn(&counter_run.step);

    // Game HUD example (game loop mode)
    const game_hud_exe = b.addExecutable(.{
        .name = "game_hud",
        .root_source_file = b.path("examples/game_hud.zig"),
        .target = target,
        .optimize = optimize,
    });
    game_hud_exe.root_module.addImport("zig-gui", zig_gui_mod);
    b.installArtifact(game_hud_exe);

    const game_hud_run = b.addRunArtifact(game_hud_exe);
    game_hud_run.step.dependOn(b.getInstallStep());

    const game_hud_step = b.step("game-hud", "Run game HUD example (game loop mode)");
    game_hud_step.dependOn(&game_hud_run.step);

    // Profiling demo (demonstrates zero-cost profiling system)
    const profiling_demo_exe = b.addExecutable(.{
        .name = "profiling_demo",
        .root_source_file = b.path("examples/profiling_demo.zig"),
        .target = target,
        .optimize = optimize,
    });
    profiling_demo_exe.root_module.addImport("zig-gui", zig_gui_mod);
    b.installArtifact(profiling_demo_exe);

    const profiling_demo_run = b.addRunArtifact(profiling_demo_exe);
    profiling_demo_run.step.dependOn(b.getInstallStep());

    const profiling_demo_step = b.step("profiling-demo", "Run profiling demo (zero-cost profiling system)");
    profiling_demo_step.dependOn(&profiling_demo_run.step);

    // Rendering benchmark (software renderer with actual pixel drawing)
    const rendering_benchmark_exe = b.addExecutable(.{
        .name = "rendering_benchmark",
        .root_source_file = b.path("examples/rendering_benchmark.zig"),
        .target = target,
        .optimize = .ReleaseFast, // Always optimize for accurate benchmarks
    });
    b.installArtifact(rendering_benchmark_exe);

    const rendering_benchmark_run = b.addRunArtifact(rendering_benchmark_exe);
    rendering_benchmark_run.step.dependOn(b.getInstallStep());

    const rendering_benchmark_step = b.step("rendering-benchmark", "Run rendering benchmark (actual pixel drawing)");
    rendering_benchmark_step.dependOn(&rendering_benchmark_run.step);

    // Multi-resolution benchmark (realistic layouts across different screen sizes)
    const multi_res_benchmark_exe = b.addExecutable(.{
        .name = "multi_res_benchmark",
        .root_source_file = b.path("examples/multi_res_benchmark.zig"),
        .target = target,
        .optimize = .ReleaseFast, // Always optimize for accurate benchmarks
    });
    b.installArtifact(multi_res_benchmark_exe);

    const multi_res_benchmark_run = b.addRunArtifact(multi_res_benchmark_exe);
    multi_res_benchmark_run.step.dependOn(b.getInstallStep());

    const multi_res_benchmark_step = b.step("multi-res-benchmark", "Run multi-resolution benchmark (mobile/desktop/4K)");
    multi_res_benchmark_step.dependOn(&multi_res_benchmark_run.step);

    // Run all examples
    const examples_step = b.step("examples", "Run all examples");
    examples_step.dependOn(&counter_run.step);
    examples_step.dependOn(&game_hud_run.step);
    examples_step.dependOn(&profiling_demo_run.step);

    // ===== Tests and Benchmarks =====

    // Create test suite for zig-gui (includes layout tests)
    const gui_tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    gui_tests.root_module.addOptions("build_options", build_options);

    const run_gui_tests = b.addRunArtifact(gui_tests);

    // Create CPU usage verification test
    const cpu_tests = b.addTest(.{
        .root_source_file = b.path("src/cpu_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    cpu_tests.root_module.addOptions("build_options", build_options);

    const run_cpu_tests = b.addRunArtifact(cpu_tests);

    // Test step that runs all tests
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_gui_tests.step);
    test_step.dependOn(&run_cpu_tests.step);

    // ===== Profiling Tools =====

    // Profile viewer - ASCII art flamechart analyzer
    const profile_viewer_exe = b.addExecutable(.{
        .name = "profile_viewer",
        .root_source_file = b.path("tools/profile_viewer.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(profile_viewer_exe);

    const profile_viewer_run = b.addRunArtifact(profile_viewer_exe);
    if (b.args) |args| {
        profile_viewer_run.addArgs(args);
    }

    const profile_viewer_step = b.step("profile-viewer", "Build and run profile viewer tool");
    profile_viewer_step.dependOn(&profile_viewer_run.step);
}
