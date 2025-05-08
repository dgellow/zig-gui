const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zlay = b.addStaticLibrary(.{
        .name = "zlay",
        .root_source_file = b.path("src/zlay.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Install the library
    b.installArtifact(zlay);

    // Simple example
    const simple_example = b.addExecutable(.{
        .name = "zlay-simple-example",
        .root_source_file = b.path("examples/simple.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    // Link to zlay so example can import it
    simple_example.root_module.addImport("zlay", zlay.root_module);
    
    // Install the example
    b.installArtifact(simple_example);

    // Run example
    const run_simple_cmd = b.addRunArtifact(simple_example);
    const run_simple_step = b.step("run-simple", "Run the simple example application");
    run_simple_step.dependOn(&run_simple_cmd.step);
    
    // Advanced layout example
    const layout_example = b.addExecutable(.{
        .name = "zlay-layout-example",
        .root_source_file = b.path("examples/advanced_layout.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    // Link to zlay so example can import it
    layout_example.root_module.addImport("zlay", zlay.root_module);
    
    // Install the example
    b.installArtifact(layout_example);

    // Run advanced layout example
    const run_layout_cmd = b.addRunArtifact(layout_example);
    const run_layout_step = b.step("run-layout", "Run the advanced layout example");
    run_layout_step.dependOn(&run_layout_cmd.step);
    
    // Scrollable container example
    const scrollable_example = b.addExecutable(.{
        .name = "zlay-scrollable-example",
        .root_source_file = b.path("examples/scrollable.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    // Link to zlay so example can import it
    scrollable_example.root_module.addImport("zlay", zlay.root_module);
    
    // Install the example
    b.installArtifact(scrollable_example);
    
    // Run scrollable example
    const run_scrollable_cmd = b.addRunArtifact(scrollable_example);
    const run_scrollable_step = b.step("run-scrollable", "Run the scrollable container example");
    run_scrollable_step.dependOn(&run_scrollable_cmd.step);
    
    // Minimal scrollable description example
    const minimal_scrollable_example = b.addExecutable(.{
        .name = "zlay-minimal-scrollable",
        .root_source_file = b.path("examples/minimal_scrollable.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    // Link to zlay so example can import it
    minimal_scrollable_example.root_module.addImport("zlay", zlay.root_module);
    
    // Install the example
    b.installArtifact(minimal_scrollable_example);
    
    // Run minimal scrollable example
    const run_minimal_cmd = b.addRunArtifact(minimal_scrollable_example);
    const run_minimal_step = b.step("run-minimal", "Run the minimal scrollable description");
    run_minimal_step.dependOn(&run_minimal_cmd.step);
    
    // Default run step - prints available examples
    const run_step = b.step("run", "Lists available examples");
    const list_examples_cmd = b.addSystemCommand(&.{
        "echo", 
        "\nAvailable examples:",
        "\n  zig build run-simple       - Simple UI layout demo",
        "\n  zig build run-layout       - Advanced layout demo",
        "\n  zig build run-scrollable   - Scrollable container demo",
        "\n  zig build run-minimal      - Minimal scrollable description",
        "\n"
    });
    run_step.dependOn(&list_examples_cmd.step);
    
    // Default example (backward compatibility)
    const run_example_step = b.step("run-example", "Run an example application");
    run_example_step.dependOn(&run_minimal_cmd.step);

    // Benchmarks
    const benchmark = b.addExecutable(.{
        .name = "zlay-benchmark",
        .root_source_file = b.path("src/benchmark.zig"),
        .target = target,
        .optimize = .ReleaseFast, // Use ReleaseFast for benchmarks
    });
    
    // Link to zlay so benchmark can import it
    benchmark.root_module.addImport("zlay", zlay.root_module);
    
    b.installArtifact(benchmark);

    // Run benchmarks
    const benchmark_cmd = b.addRunArtifact(benchmark);
    const benchmark_step = b.step("benchmark", "Run performance benchmarks");
    benchmark_step.dependOn(&benchmark_cmd.step);

    // Main tests
    const main_tests = b.addTest(.{
        .root_source_file = b.path("src/zlay.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    // Link to zlay so tests can import it
    main_tests.root_module.addImport("zlay", zlay.root_module);

    // Performance tests
    const perf_tests = b.addTest(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = .ReleaseFast, // Use ReleaseFast for performance tests
    });
    
    // Link to zlay so tests can import it
    perf_tests.root_module.addImport("zlay", zlay.root_module);

    const run_main_tests = b.addRunArtifact(main_tests);
    const run_perf_tests = b.addRunArtifact(perf_tests);
    
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_main_tests.step);
    
    const perf_test_step = b.step("test-perf", "Run performance tests");
    perf_test_step.dependOn(&run_perf_tests.step);
    
    // Run all tests
    const test_all_step = b.step("test-all", "Run all tests including performance tests");
    test_all_step.dependOn(&run_main_tests.step);
    test_all_step.dependOn(&run_perf_tests.step);
}