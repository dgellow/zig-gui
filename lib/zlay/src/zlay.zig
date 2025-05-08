const std = @import("std");

pub const Context = @import("context.zig").Context;
pub const Element = @import("element.zig").Element;
pub const Layout = @import("layout.zig").Layout;
pub const LayoutAlgorithm = @import("layout_algorithm.zig").LayoutAlgorithm;
pub const Renderer = @import("renderer.zig").Renderer;
pub const Style = @import("style.zig").Style;
pub const Color = @import("color.zig").Color;
pub const Text = @import("text.zig");
pub const TextMeasurement = Text.TextMeasurement;
pub const DefaultTextMeasurement = Text.DefaultTextMeasurement;
pub const TextMeasurementCache = Text.TextMeasurementCache;
pub const Memory = @import("memory.zig");
pub const ElementPool = Memory.ElementPool;
pub const ArenaPool = Memory.ArenaPool;
pub const StringPool = Memory.StringPool;
pub const HitTest = @import("hit_test.zig");
pub const HitTesting = HitTest.HitTesting;
pub const HitTestResult = HitTest.HitTestResult;
pub const HitTestOptions = HitTest.HitTestOptions;

// C API is implemented but exposed separately
// import it only when C API is needed

/// Initialize a new zlay context with the given allocator
pub fn init(allocator: std.mem.Allocator) !Context {
    return Context.init(allocator);
}

/// Initialize a new zlay context with the given allocator and text measurement
pub fn initWithTextMeasurement(allocator: std.mem.Allocator, text_measurement: *TextMeasurement) !Context {
    return Context.initWithTextMeasurement(allocator, text_measurement);
}

/// Initialize a new zlay context with memory optimizations enabled
pub fn initOptimized(allocator: std.mem.Allocator) !Context {
    return Context.initWithOptions(allocator, .{
        .use_element_pool = true,
        .use_string_pool = true,
        .element_pool_size = 256,
        .use_text_measurement = true,  // We now have fallbacks if this fails
        .use_text_measurement_cache = false,  // Disable cache until we fix it
    });
}

/// Initialize a new zlay context with minimal configuration (no text measurement)
/// Useful for simple layouts or when debugging issues with text measurement
pub fn initMinimal(allocator: std.mem.Allocator) !Context {
    return Context.initWithOptions(allocator, .{
        .use_element_pool = false,
        .use_string_pool = false,
        .use_text_measurement = false,  // No text measurement
        .use_text_measurement_cache = false,  // No caching
    });
}

test {
    // Import and run tests from all modules
    std.testing.refAllDeclsRecursive(@This());
}