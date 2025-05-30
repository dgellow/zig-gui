//! zlay - Data-Oriented UI Layout Library
//! 
//! High-performance, cache-friendly layout engine designed for:
//! - Game UIs (60+ FPS with thousands of elements)
//! - Desktop applications (0% idle CPU)
//! - Embedded systems (<32KB RAM)
//! 
//! Features:
//! - Structure-of-Arrays design for cache efficiency
//! - Zero allocations per frame
//! - Immediate-mode API with retained-mode performance
//! - Clean C API for language bindings

const std = @import("std");

// Core types
pub const core = @import("core.zig");
pub const Point = core.Point;
pub const Size = core.Size;
pub const Rect = core.Rect;
pub const Color = core.Color;

// Layout engine
pub const Context = @import("context.zig").Context;
pub const MouseButton = @import("context.zig").MouseButton;
pub const PerformanceStats = Context.PerformanceStats;

// Style system
pub const Style = @import("style.zig").Style;

// Element types (for backwards compatibility)
pub const ElementType = @import("layout_engine.zig").ElementType;

/// Initialize a new zlay context with default viewport
pub fn init(allocator: std.mem.Allocator) !*Context {
    return Context.init(allocator, Size{ .width = 800, .height = 600 });
}

/// Initialize a new zlay context with custom viewport
pub fn initWithViewport(allocator: std.mem.Allocator, viewport: Size) !*Context {
    return Context.init(allocator, viewport);
}

test {
    // Import and run tests from all modules
    std.testing.refAllDeclsRecursive(@This());
}