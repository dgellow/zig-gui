const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Profiling build option: -Denable_profiling=true
    const enable_profiling = b.option(bool, "enable_profiling", "Enable profiling and tracing") orelse false;

    // Embedded config: -Dmax_layout_elements=64 (default 4096)
    // For embedded systems: use 64-256 elements to fit in <32KB RAM
    const max_layout_elements = b.option(u32, "max_layout_elements", "Maximum layout elements (default 4096, embedded: 64-256)") orelse 4096;

    // Create build options module for compile-time configuration
    const build_options = b.addOptions();
    build_options.addOption(bool, "enable_profiling", enable_profiling);
    build_options.addOption(u32, "max_layout_elements", max_layout_elements);

    // Create zig-gui module for examples to import
    // Note: zlay is now integrated into src/layout/ instead of separate module
    const zig_gui_mod = b.addModule("zig-gui", .{
        .root_source_file = b.path("src/root.zig"),
    });
    zig_gui_mod.addOptions("build_options", build_options);

    // Create static library (Zig API)
    const lib = b.addStaticLibrary(.{
        .name = "gui",
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib.root_module.addOptions("build_options", build_options);
    b.installArtifact(lib);

    // Create C API static library
    const c_lib = b.addStaticLibrary(.{
        .name = "zgl",
        .root_source_file = b.path("src/c_api.zig"),
        .target = target,
        .optimize = optimize,
    });
    c_lib.root_module.addOptions("build_options", build_options);
    c_lib.linkLibC();
    b.installArtifact(c_lib);

    // Install C header
    b.installFile("include/zgl.h", "include/zgl.h");

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

    // Render demo (BYOR draw system demo - outputs PPM image)
    const render_demo_exe = b.addExecutable(.{
        .name = "render_demo",
        .root_source_file = b.path("examples/render_demo.zig"),
        .target = target,
        .optimize = optimize,
    });
    render_demo_exe.root_module.addImport("zig-gui", zig_gui_mod);
    b.installArtifact(render_demo_exe);

    const render_demo_run = b.addRunArtifact(render_demo_exe);
    render_demo_run.step.dependOn(b.getInstallStep());

    const render_demo_step = b.step("render-demo", "Run render demo (outputs PPM image)");
    render_demo_step.dependOn(&render_demo_run.step);

    // GUI demo (GUI widgets → DrawList → SoftwareBackend → PPM)
    const gui_demo_exe = b.addExecutable(.{
        .name = "gui_demo",
        .root_source_file = b.path("examples/gui_demo.zig"),
        .target = target,
        .optimize = optimize,
    });
    gui_demo_exe.root_module.addImport("zig-gui", zig_gui_mod);
    b.installArtifact(gui_demo_exe);

    const gui_demo_run = b.addRunArtifact(gui_demo_exe);
    gui_demo_run.step.dependOn(b.getInstallStep());

    const gui_demo_step = b.step("gui-demo", "Run GUI integration demo (outputs PPM image)");
    gui_demo_step.dependOn(&gui_demo_run.step);

    // Generate docs image (runs gui-demo and converts to PNG for README)
    const convert_to_png = b.addSystemCommand(&.{
        "convert",
        "gui_demo.ppm",
        "docs/gui_demo.png",
    });
    convert_to_png.step.dependOn(&gui_demo_run.step);

    const update_docs_step = b.step("update-docs", "Regenerate docs/gui_demo.png for README");
    update_docs_step.dependOn(&convert_to_png.step);

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

    // C API tests
    const c_api_tests = b.addTest(.{
        .root_source_file = b.path("src/c_api.zig"),
        .target = target,
        .optimize = optimize,
    });
    c_api_tests.root_module.addOptions("build_options", build_options);
    c_api_tests.linkLibC();

    const run_c_api_tests = b.addRunArtifact(c_api_tests);

    // C test executable (tests from actual C code)
    const c_test_exe = b.addExecutable(.{
        .name = "c_api_test",
        .target = target,
        .optimize = optimize,
    });
    c_test_exe.addCSourceFile(.{
        .file = b.path("tests/c_api_test.c"),
        .flags = &.{ "-std=c99", "-Wall", "-Wextra" },
    });
    c_test_exe.addIncludePath(b.path("include"));
    c_test_exe.linkLibrary(c_lib);
    c_test_exe.linkLibC();
    b.installArtifact(c_test_exe);

    const run_c_test = b.addRunArtifact(c_test_exe);
    run_c_test.step.dependOn(b.getInstallStep());

    const c_test_step = b.step("c-test", "Run C API tests");
    c_test_step.dependOn(&run_c_test.step);

    // Test step that runs all tests
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_gui_tests.step);
    test_step.dependOn(&run_cpu_tests.step);
    test_step.dependOn(&run_c_api_tests.step);

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
