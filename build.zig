const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create zlay module (our data-oriented layout engine)
    const zlay_mod = b.addModule("zlay", .{
        .root_source_file = b.path("lib/zlay/src/zlay.zig"),
    });

    // Create static library
    const lib = b.addStaticLibrary(.{
        .name = "gui",
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib.root_module.addImport("zlay", zlay_mod);
    b.installArtifact(lib);

    // ===== Revolutionary Demo =====

    // Create revolutionary demo executable
    const demo_exe = b.addExecutable(.{
        .name = "revolutionary_demo",
        .root_source_file = b.path("examples/revolutionary_demo.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add zlay as a dependency for the demo
    demo_exe.root_module.addImport("zlay", zlay_mod);

    // Install the demo
    b.installArtifact(demo_exe);

    // Create run step for the demo
    const demo_run = b.addRunArtifact(demo_exe);
    demo_run.step.dependOn(b.getInstallStep());

    // Add run step
    const demo_step = b.step("demo", "Run the revolutionary data-oriented demo");
    demo_step.dependOn(&demo_run.step);

    // ===== Tests and Benchmarks =====

    // Create test suite for zlay
    const zlay_tests = b.addTest(.{
        .root_source_file = b.path("lib/zlay/src/zlay.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_zlay_tests = b.addRunArtifact(zlay_tests);

    // Create test suite for layout_engine
    const layout_tests = b.addTest(.{
        .root_source_file = b.path("lib/zlay/src/layout_engine.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_layout_tests = b.addRunArtifact(layout_tests);

    // Create test suite for text measurement
    const text_tests = b.addTest(.{
        .root_source_file = b.path("lib/zlay/src/text.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_text_tests = b.addRunArtifact(text_tests);

    // Test step that runs all tests
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_zlay_tests.step);
    test_step.dependOn(&run_layout_tests.step);
    test_step.dependOn(&run_text_tests.step);

    // Performance benchmark
    const benchmark_exe = b.addExecutable(.{
        .name = "benchmark",
        .root_source_file = b.path("examples/benchmark.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });

    benchmark_exe.root_module.addImport("zlay", zlay_mod);
    b.installArtifact(benchmark_exe);

    const benchmark_run = b.addRunArtifact(benchmark_exe);
    benchmark_run.step.dependOn(b.getInstallStep());

    const benchmark_step = b.step("benchmark", "Run performance benchmarks");
    benchmark_step.dependOn(&benchmark_run.step);
}
