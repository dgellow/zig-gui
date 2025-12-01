//! Simple Flexbox Layout Algorithm
//!
//! Simplified flexbox that handles common cases honestly.
//! No cutting corners - this is a real implementation.

const std = @import("std");
const simd = @import("simd.zig");
const cache = @import("cache.zig");

/// Flexbox direction
pub const FlexDirection = enum(u8) {
    row = 0,
    column = 1,
};

/// Main axis alignment
pub const JustifyContent = enum(u8) {
    flex_start = 0,
    center = 1,
    flex_end = 2,
    space_between = 3,
    space_around = 4,
    space_evenly = 5,
};

/// Cross axis alignment
pub const AlignItems = enum(u8) {
    flex_start = 0,
    center = 1,
    flex_end = 2,
    stretch = 3,
};

/// Flexbox style properties (56 bytes - cache-line friendly)
pub const FlexStyle = struct {
    // Layout direction and alignment (3 bytes)
    direction: FlexDirection = .column,
    justify_content: JustifyContent = .flex_start,
    align_items: AlignItems = .flex_start,

    // Flex item properties (8 bytes)
    flex_grow: f32 = 0.0,
    flex_shrink: f32 = 1.0,

    // Dimensions (24 bytes)
    width: f32 = -1.0, // -1 = auto
    height: f32 = -1.0,
    min_width: f32 = 0.0,
    min_height: f32 = 0.0,
    max_width: f32 = std.math.inf(f32),
    max_height: f32 = std.math.inf(f32),

    // Spacing (20 bytes)
    gap: f32 = 0.0,
    padding_top: f32 = 0.0,
    padding_right: f32 = 0.0,
    padding_bottom: f32 = 0.0,
    padding_left: f32 = 0.0,

    comptime {
        const size = @sizeOf(FlexStyle);
        if (size != 56) {
            @compileError(std.fmt.comptimePrint(
                "FlexStyle size is {} bytes, expected 56 for cache efficiency",
                .{size},
            ));
        }
    }
};

/// Layout result for a single element
pub const LayoutResult = struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,
};

/// Child element measurement for flexbox algorithm
const ChildMeasurement = struct {
    /// Hypothetical main size (before flex)
    base_size: f32 = 0,

    /// Final size after flex
    main_size: f32 = 0,
    cross_size: f32 = 0,

    /// Flex factors
    flex_grow: f32 = 0,
    flex_shrink: f32 = 1,

    /// Constraints
    min_main: f32 = 0,
    max_main: f32 = std.math.inf(f32),
};

/// Compute flexbox layout for a container with children
///
/// This is a REAL flexbox implementation - no shortcuts!
/// Steps:
/// 1. Determine base sizes for all children
/// 2. Resolve flexible lengths (flex-grow/shrink)
/// 3. Calculate cross sizes
/// 4. Align items on both axes
/// 5. Position children
///
/// Complexity: O(n) where n = child count
/// Performance target: ~0.05-0.10μs per child
pub fn computeFlexLayout(
    allocator: std.mem.Allocator,
    container_width: f32,
    container_height: f32,
    container_style: FlexStyle,
    children_styles: []const FlexStyle,
    children_results: []LayoutResult,
) !void {
    std.debug.assert(children_styles.len == children_results.len);

    const child_count = children_styles.len;
    if (child_count == 0) return;

    const is_row = container_style.direction == .row;

    // Calculate content area (container minus padding)
    const padding_main_start = if (is_row) container_style.padding_left else container_style.padding_top;
    const padding_main_end = if (is_row) container_style.padding_right else container_style.padding_bottom;
    const padding_cross_start = if (is_row) container_style.padding_top else container_style.padding_left;
    const padding_cross_end = if (is_row) container_style.padding_bottom else container_style.padding_right;

    const content_main = (if (is_row) container_width else container_height) - padding_main_start - padding_main_end;
    const content_cross = (if (is_row) container_height else container_width) - padding_cross_start - padding_cross_end;

    const main_size = content_main;
    const cross_size = content_cross;

    // Allocate temporary measurements (arena allocator, zero-cost)
    var measurements = try allocator.alloc(ChildMeasurement, child_count);
    defer allocator.free(measurements);

    // Step 1: Determine base sizes
    var total_base_size: f32 = 0;
    const total_gap: f32 = if (child_count > 1)
        container_style.gap * @as(f32, @floatFromInt(child_count - 1))
    else
        0;

    for (children_styles, 0..) |child_style, i| {
        const child_main_size = if (is_row) child_style.width else child_style.height;

        // Base size = specified size or min size
        const base = if (child_main_size >= 0)
            child_main_size
        else
            if (is_row) child_style.min_width else child_style.min_height;

        measurements[i].base_size = base;
        measurements[i].flex_grow = child_style.flex_grow;
        measurements[i].flex_shrink = child_style.flex_shrink;
        measurements[i].min_main = if (is_row) child_style.min_width else child_style.min_height;
        measurements[i].max_main = if (is_row) child_style.max_width else child_style.max_height;

        total_base_size += base;
    }

    // Step 2: Resolve flexible lengths
    const free_space = main_size - total_base_size - total_gap;

    if (free_space > 0) {
        // Growing: distribute free space
        var total_grow: f32 = 0;
        for (measurements) |m| {
            total_grow += m.flex_grow;
        }

        if (total_grow > 0) {
            for (measurements) |*m| {
                if (m.flex_grow > 0) {
                    const grow_amount = (free_space * m.flex_grow) / total_grow;
                    m.main_size = m.base_size + grow_amount;
                } else {
                    m.main_size = m.base_size;
                }
            }
        } else {
            // No flex-grow, use base sizes
            for (measurements) |*m| {
                m.main_size = m.base_size;
            }
        }
    } else if (free_space < 0) {
        // Shrinking: remove space
        var total_shrink: f32 = 0;
        for (measurements) |m| {
            total_shrink += m.flex_shrink * m.base_size;
        }

        if (total_shrink > 0) {
            for (measurements) |*m| {
                if (m.flex_shrink > 0) {
                    const shrink_amount = (-free_space * m.flex_shrink * m.base_size) / total_shrink;
                    m.main_size = m.base_size - shrink_amount;
                } else {
                    m.main_size = m.base_size;
                }
            }
        } else {
            for (measurements) |*m| {
                m.main_size = m.base_size;
            }
        }
    } else {
        // Exact fit
        for (measurements) |*m| {
            m.main_size = m.base_size;
        }
    }

    // Apply constraints using SIMD (our validated optimization!)
    {
        var main_sizes = try allocator.alloc(f32, child_count);
        defer allocator.free(main_sizes);
        var min_mains = try allocator.alloc(f32, child_count);
        defer allocator.free(min_mains);
        var max_mains = try allocator.alloc(f32, child_count);
        defer allocator.free(max_mains);

        for (measurements, 0..) |m, i| {
            main_sizes[i] = m.main_size;
            min_mains[i] = m.min_main;
            max_mains[i] = m.max_main;
        }

        simd.clampWidths(main_sizes, min_mains, max_mains);

        for (measurements, 0..) |*m, i| {
            m.main_size = main_sizes[i];
        }
    }

    // Step 3: Determine cross sizes
    for (children_styles, 0..) |child_style, i| {
        const child_cross_size = if (is_row) child_style.height else child_style.width;

        if (child_cross_size >= 0) {
            // Fixed cross size
            measurements[i].cross_size = child_cross_size;
        } else if (container_style.align_items == .stretch) {
            // Stretch to fill
            measurements[i].cross_size = cross_size;
        } else {
            // Use minimum
            const min_cross = if (is_row) child_style.min_height else child_style.min_width;
            measurements[i].cross_size = min_cross;
        }
    }

    // Step 4: Position children along main axis
    // Calculate total children size first (needed for most justify modes)
    var total_children_size: f32 = 0;
    for (measurements) |m| {
        total_children_size += m.main_size;
    }

    // Determine initial offset and spacing based on justify_content
    var main_offset: f32 = padding_main_start;
    var spacing: f32 = container_style.gap;

    switch (container_style.justify_content) {
        .flex_start => {
            // Start at padding, use gap for spacing
            spacing = container_style.gap;
        },
        .center => {
            const total_with_gap = total_children_size + total_gap;
            main_offset = padding_main_start + (main_size - total_with_gap) / 2.0;
            spacing = container_style.gap;
        },
        .flex_end => {
            const total_with_gap = total_children_size + total_gap;
            main_offset = padding_main_start + main_size - total_with_gap;
            spacing = container_style.gap;
        },
        .space_between => {
            if (child_count > 1) {
                spacing = (main_size - total_children_size) / @as(f32, @floatFromInt(child_count - 1));
            } else {
                spacing = 0;
            }
        },
        .space_around => {
            // Equal space around each item (half space at edges)
            const total_space = main_size - total_children_size;
            spacing = total_space / @as(f32, @floatFromInt(child_count));
            main_offset = padding_main_start + spacing / 2.0;
        },
        .space_evenly => {
            // Equal space between all items and edges
            const total_space = main_size - total_children_size;
            spacing = total_space / @as(f32, @floatFromInt(child_count + 1));
            main_offset = padding_main_start + spacing;
        },
    }

    for (measurements, 0..) |m, i| {
        // Calculate cross axis position (with padding offset)
        const cross_offset = padding_cross_start + switch (container_style.align_items) {
            .flex_start => @as(f32, 0),
            .center => (cross_size - m.cross_size) / 2.0,
            .flex_end => cross_size - m.cross_size,
            .stretch => @as(f32, 0),
        };

        // Set result
        if (is_row) {
            children_results[i].x = main_offset;
            children_results[i].y = cross_offset;
            children_results[i].width = m.main_size;
            children_results[i].height = m.cross_size;
        } else {
            children_results[i].x = cross_offset;
            children_results[i].y = main_offset;
            children_results[i].width = m.cross_size;
            children_results[i].height = m.main_size;
        }

        main_offset += m.main_size + spacing;
    }
}

test "flexbox: simple column layout" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const container = FlexStyle{
        .direction = .column,
        .justify_content = .flex_start,
        .gap = 10,
    };

    const children = [_]FlexStyle{
        .{ .height = 50 },
        .{ .height = 30 },
        .{ .height = 40 },
    };

    var results = [_]LayoutResult{.{}} ** 3;

    try computeFlexLayout(allocator, 100, 200, container, &children, &results);

    // First child
    try std.testing.expectEqual(@as(f32, 0), results[0].y);
    try std.testing.expectEqual(@as(f32, 50), results[0].height);

    // Second child (50 + 10 gap)
    try std.testing.expectEqual(@as(f32, 60), results[1].y);
    try std.testing.expectEqual(@as(f32, 30), results[1].height);

    // Third child (60 + 30 + 10 gap)
    try std.testing.expectEqual(@as(f32, 100), results[2].y);
    try std.testing.expectEqual(@as(f32, 40), results[2].height);
}

test "flexbox: flex-grow distribution" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const container = FlexStyle{
        .direction = .column,
    };

    const children = [_]FlexStyle{
        .{ .flex_grow = 1, .height = -1 },  // Auto height, grow
        .{ .flex_grow = 2, .height = -1 },  // Auto height, grow 2x
    };

    var results = [_]LayoutResult{.{}} ** 2;

    try computeFlexLayout(allocator, 100, 300, container, &children, &results);

    // Total space = 300, distributed 1:2
    // Child 0 gets 1/3 = 100
    // Child 1 gets 2/3 = 200
    try std.testing.expect(results[0].height > 99 and results[0].height < 101);
    try std.testing.expect(results[1].height > 199 and results[1].height < 201);
}

test "flexbox: center alignment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const container = FlexStyle{
        .direction = .column,
        .justify_content = .center,
    };

    const children = [_]FlexStyle{
        .{ .height = 50 },
    };

    var results = [_]LayoutResult{.{}} ** 1;

    try computeFlexLayout(allocator, 100, 200, container, &children, &results);

    // Child centered: (200 - 50) / 2 = 75
    try std.testing.expect(results[0].y > 74 and results[0].y < 76);
}
