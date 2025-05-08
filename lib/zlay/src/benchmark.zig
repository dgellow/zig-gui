const std = @import("std");
const zlay = @import("zlay.zig");
const testing = std.testing;

/// Benchmark result struct
pub const BenchmarkResult = struct {
    elapsed_time: u64,
    memory_used: usize,
};

/// Benchmark: Element creation
pub fn benchmarkElementCreation(allocator: std.mem.Allocator, element_count: usize) !BenchmarkResult {
    // Create a memory tracking allocator
    var tracked_allocator = std.heap.ArenaAllocator.init(allocator);
    defer tracked_allocator.deinit();
    const tracking_allocator = tracked_allocator.allocator();
    
    // Create context with the tracking allocator
    var ctx = try zlay.init(tracking_allocator);
    defer ctx.deinit();
    
    try ctx.beginFrame();
    
    var timer = try std.time.Timer.start();
    const start = timer.lap();
    
    // Create root container
    _ = try ctx.beginElement(.container, "root");
    
    // Create elements
    for (0..element_count) |i| {
        var id_buf: [64]u8 = undefined;
        const id = std.fmt.bufPrintZ(&id_buf, "element_{d}", .{i}) catch "element_x";
        
        _ = try ctx.beginElement(.box, id);
        try ctx.endElement();
    }
    
    try ctx.endElement(); // root
    
    const end = timer.read();
    
    // Get memory usage
    const memory_used = tracked_allocator.queryCapacity();
    
    return BenchmarkResult{
        .elapsed_time = end - start,
        .memory_used = memory_used,
    };
}

/// Benchmark: Layout computation
pub fn benchmarkLayoutComputation(allocator: std.mem.Allocator, element_count: usize, depth: usize) !BenchmarkResult {
    // Create a memory tracking allocator
    var tracked_allocator = std.heap.ArenaAllocator.init(allocator);
    defer tracked_allocator.deinit();
    const tracking_allocator = tracked_allocator.allocator();
    
    var ctx = try zlay.init(tracking_allocator);
    defer ctx.deinit();
    
    try ctx.beginFrame();
    
    // Create hierarchical structure with specified depth
    const createNestedStructure = struct {
        fn create(context: *zlay.Context, current_depth: usize, max_depth: usize, elements_per_level: usize) !void {
            if (current_depth >= max_depth) return;
            
            for (0..elements_per_level) |i| {
                var id_buf: [64]u8 = undefined;
                const id = std.fmt.bufPrintZ(&id_buf, "container_{d}_{d}", .{current_depth, i}) catch "container_x_x";
                _ = try context.beginElement(.container, id);
                
                try create(context, current_depth + 1, max_depth, elements_per_level);
                
                try context.endElement();
            }
        }
    }.create;
    
    // Create a balanced tree of elements
    const elements_per_level = if (depth > 1) @max(2, element_count / depth) else element_count;
    
    _ = try ctx.beginElement(.container, "root");
    try createNestedStructure(&ctx, 0, depth, elements_per_level);
    try ctx.endElement(); // root
    
    // Get initial memory usage
    const initial_memory = tracked_allocator.queryCapacity();
    
    // Measure layout computation
    var timer = try std.time.Timer.start();
    const start = timer.lap();
    
    try ctx.computeLayout(1000, 1000);
    
    const end = timer.read();
    
    // Get final memory usage
    const final_memory = tracked_allocator.queryCapacity();
    const memory_used = final_memory - initial_memory;
    
    return BenchmarkResult{
        .elapsed_time = end - start,
        .memory_used = memory_used,
    };
}

/// Run all benchmarks
pub fn runBenchmarks(allocator: std.mem.Allocator, writer: anytype) !void {
    const configs = [_]struct { name: []const u8, element_count: usize, depth: usize }{
        .{ .name = "Small UI (50 elements, depth 2)", .element_count = 50, .depth = 2 },
        .{ .name = "Medium UI (100 elements, depth 3)", .element_count = 100, .depth = 3 },
        .{ .name = "Large UI (500 elements, depth 4)", .element_count = 500, .depth = 4 },
    };
    
    try writer.writeAll("# Zlay Benchmarks\n\n");
    try writer.writeAll("| Test | Element Creation (ns/element) | Layout Computation (ns/element) | Memory Usage (bytes/element) |\n");
    try writer.writeAll("|------|-------------------------------|--------------------------------|------------------------------|\n");
    
    // Performance targets from technical debt document
    const TARGET_CREATION_TIME = 500; // ns/element
    const TARGET_LAYOUT_TIME = 1000; // ns/element
    const TARGET_MEMORY_USAGE = 128; // bytes/element
    
    for (configs) |config| {
        // Element creation benchmark
        try writer.print("Running benchmark: {s} - Element Creation...\n", .{config.name});
        const creation_result = try benchmarkElementCreation(allocator, config.element_count);
        const creation_time_per_element = creation_result.elapsed_time / config.element_count;
        const creation_memory_per_element = creation_result.memory_used / (config.element_count + 1); // +1 for root
        
        // Layout computation benchmark
        try writer.print("Running benchmark: {s} - Layout Computation...\n", .{config.name});
        const layout_result = try benchmarkLayoutComputation(allocator, config.element_count, config.depth);
        
        // Calculate total elements in the hierarchy
        var count: usize = 0;
        var level_size: usize = 1;
        var max_depth = config.depth;
        if (max_depth == 0) max_depth = 1; // Ensure we don't have zero depth
        
        // Safely compute the total number of elements
        var elements_per_level: usize = 0;
        if (config.depth > 1) {
            elements_per_level = @max(2, config.element_count / max_depth);
        } else {
            elements_per_level = config.element_count;
        }
        
        // Count elements at each level
        var current_depth: usize = 0;
        while (current_depth < max_depth) : (current_depth += 1) {
            // Add the elements at this level
            count += level_size;
            
            // Prevent potential overflow in the next level calculation
            if (level_size > std.math.maxInt(usize) / elements_per_level) {
                break; // Would overflow, stop counting
            }
            
            // Calculate elements for the next level
            level_size *= elements_per_level;
        }
        
        // Ensure we don't divide by zero
        const total_elements = if (count > 0) count else 1;
        const layout_time_per_element = layout_result.elapsed_time / total_elements;
        const layout_memory_per_element = layout_result.memory_used / total_elements;
        
        // Average memory usage
        const avg_memory_per_element = (creation_memory_per_element + layout_memory_per_element) / 2;
        
        try writer.print("| {s} | {d:.2} | {d:.2} | {d} |\n", .{
            config.name, 
            @as(f64, @floatFromInt(creation_time_per_element)),
            @as(f64, @floatFromInt(layout_time_per_element)),
            avg_memory_per_element,
        });
        
        // Additional detailed output for clarity
        try writer.print("\nDetailed Results for {s}:\n", .{config.name});
        try writer.print("- Elements: {d}\n", .{config.element_count});
        try writer.print("- Total Elements in Layout: {d}\n", .{total_elements});
        
        // Element creation metrics
        try writer.print("- Element Creation: {d:.2} ns/element ({d:.4} µs/element)", 
            .{
                @as(f64, @floatFromInt(creation_time_per_element)),
                @as(f64, @floatFromInt(creation_time_per_element)) / 1000.0,
            });
        // Add target comparison
        if (creation_time_per_element <= TARGET_CREATION_TIME) {
            try writer.print(" ✅ (target: < {d} ns)\n", .{TARGET_CREATION_TIME});
        } else {
            try writer.print(" ❌ (target: < {d} ns)\n", .{TARGET_CREATION_TIME});
        }
        
        // Layout computation metrics
        try writer.print("- Layout Computation: {d:.2} ns/element ({d:.4} µs/element)", 
            .{
                @as(f64, @floatFromInt(layout_time_per_element)),
                @as(f64, @floatFromInt(layout_time_per_element)) / 1000.0,
            });
        // Add target comparison
        if (layout_time_per_element <= TARGET_LAYOUT_TIME) {
            try writer.print(" ✅ (target: < {d} ns)\n", .{TARGET_LAYOUT_TIME});
        } else {
            try writer.print(" ❌ (target: < {d} ns)\n", .{TARGET_LAYOUT_TIME});
        }
        
        // Memory usage metrics
        try writer.print("- Memory Usage: {d} bytes/element", .{avg_memory_per_element});
        // Add target comparison
        if (avg_memory_per_element <= TARGET_MEMORY_USAGE) {
            try writer.print(" ✅ (target: < {d} bytes)\n", .{TARGET_MEMORY_USAGE});
        } else {
            try writer.print(" ❌ (target: < {d} bytes)\n", .{TARGET_MEMORY_USAGE});
        }
        
        try writer.print("- Total Creation Time: {d:.2} µs\n", .{@as(f64, @floatFromInt(creation_result.elapsed_time)) / 1000.0});
        try writer.print("- Total Layout Time: {d:.2} µs\n", .{@as(f64, @floatFromInt(layout_result.elapsed_time)) / 1000.0});
        try writer.print("- Total Memory Used: {d:.2} KB\n\n", .{@as(f64, @floatFromInt(creation_result.memory_used + layout_result.memory_used)) / 1024.0});
    }
    
    // Performance target summary
    try writer.writeAll("\n## Performance Targets\n\n");
    try writer.writeAll("These are our performance targets (from TECHNICAL_DEBT.md):\n\n");
    try writer.writeAll("- Element creation: < 500 ns/element\n");
    try writer.writeAll("- Layout computation: < 1000 ns/element\n");
    try writer.writeAll("- Memory usage per element: < 128 bytes/element\n");
    try writer.writeAll("- Render command generation: < 200 ns/element\n");
}

/// Benchmark entry point
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll("\n=== Zlay Performance Benchmarks ===\n\n");
    
    try runBenchmarks(allocator, stdout);
}