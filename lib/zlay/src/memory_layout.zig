//! Memory Layout Documentation Pattern for Performance-Critical Structs
//! 
//! Use this pattern to document structs where cache efficiency matters.

const std = @import("std");

/// Example of structured memory layout documentation
/// 
/// @memory-layout {
///   size: 32 bytes (fits 2 per cache line)
///   align: 4 bytes
///   hot-path: yes
///   cache-lines: 0.5 (half a cache line per element)
/// }
pub const ExampleStruct = struct {
    // Fields grouped by access pattern, not by logical grouping
    field1: u32,
    field2: f32,
    // ...
};

/// Memory layout verification helper
/// Add this to any performance-critical struct to verify assumptions
pub fn comptime_verify_layout(comptime T: type, comptime expected_size: usize, comptime expected_align: usize) void {
    comptime {
        const actual_size = @sizeOf(T);
        const actual_align = @alignOf(T);
        
        if (actual_size != expected_size) {
            @compileError(std.fmt.comptimePrint(
                "{s}: Expected size {} bytes, got {} bytes", 
                .{ @typeName(T), expected_size, actual_size }
            ));
        }
        
        if (actual_align != expected_align) {
            @compileError(std.fmt.comptimePrint(
                "{s}: Expected alignment {} bytes, got {} bytes", 
                .{ @typeName(T), expected_align, actual_align }
            ));
        }
    }
}

/// Cache efficiency documentation macro
pub fn cache_line_info(comptime T: type) []const u8 {
    comptime {
        const size = @sizeOf(T);
        const cache_line = 64;
        const per_line = cache_line / size;
        const efficiency = @as(f32, @floatFromInt(size % cache_line)) / @as(f32, @floatFromInt(cache_line)) * 100;
        
        return std.fmt.comptimePrint(
            "Size: {} bytes | {} per cache line | {}% cache utilization",
            .{ size, per_line, 100 - efficiency }
        );
    }
}