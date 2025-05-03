const std = @import("std");
const View = @import("components/view.zig").View;
const Size = @import("core/geometry.zig").Size;
const Rect = @import("core/geometry.zig").Rect;
const Point = @import("core/geometry.zig").Point;
const EdgeInsets = @import("core/geometry.zig").EdgeInsets;

/// Length constraint for layout
pub const LengthConstraint = union(enum) {
    /// Automatic sizing based on content
    auto,
    /// Fixed size in pixels
    fixed: f32,
    /// Percentage of parent size (0.0-1.0)
    percentage: f32,

    /// Convert to a fixed value based on parent size
    pub fn resolve(self: LengthConstraint, parent_size: f32) f32 {
        return switch (self) {
            .auto => parent_size,
            .fixed => |value| value,
            .percentage => |value| parent_size * value,
        };
    }
};

/// Alignment options for flex layout
pub const Alignment = enum {
    auto, // Use parent's alignment
    start, // Align to start of axis
    end, // Align to end of axis
    center, // Center along axis
    stretch, // Stretch to fill axis
};

/// Position type for layout
pub const PositionType = enum {
    relative, // Positioned relative to normal flow
    absolute, // Positioned absolutely within parent
};

/// Direction for flex layout
pub const FlexDirection = enum {
    row, // Left to right
    row_reverse, // Right to left
    column, // Top to bottom
    column_reverse, // Bottom to top
};

/// Wrapping behavior for flex layout
pub const FlexWrap = enum {
    nowrap, // Single line
    wrap, // Multiple lines
    wrap_reverse, // Multiple lines, reversed
};

/// Alignment of items along main axis
pub const JustifyContent = enum {
    start, // Items at start
    end, // Items at end
    center, // Items at center
    space_between, // Items with space between
    space_around, // Items with space around
    space_evenly, // Items with equal space
};

/// Alignment of items along cross axis
pub const AlignItems = enum {
    start, // Items at start of cross axis
    end, // Items at end of cross axis
    center, // Items centered on cross axis
    stretch, // Items stretched to fill cross axis
    baseline, // Items aligned on baseline
};

/// Alignment of lines within container
pub const AlignContent = enum {
    start, // Lines at start
    end, // Lines at end
    center, // Lines at center
    stretch, // Lines stretched to fill
    space_between, // Lines with space between
    space_around, // Lines with space around
};

/// Parameters for controlling layout
pub const LayoutParams = struct {
    width: LengthConstraint = .auto,
    height: LengthConstraint = .auto,
    min_width: ?f32 = null,
    min_height: ?f32 = null,
    max_width: ?f32 = null,
    max_height: ?f32 = null,

    flex_grow: f32 = 0.0,
    flex_shrink: f32 = 1.0,
    flex_basis: LengthConstraint = .auto,

    align_self: Alignment = .auto,

    margin: EdgeInsets = EdgeInsets.zero(),
    padding: EdgeInsets = EdgeInsets.zero(),

    position_type: PositionType = .relative,
    position: EdgeInsets = EdgeInsets.zero(),

    // Container layout properties (only relevant for container components)
    flex_direction: FlexDirection = .column,
    flex_wrap: FlexWrap = .nowrap,
    justify_content: JustifyContent = .start,
    align_items: AlignItems = .stretch,
    align_content: AlignContent = .stretch,

    /// Create a copy of these layout parameters
    pub fn clone(self: LayoutParams) LayoutParams {
        return self;
    }
};

/// Individual item in a flex layout
const FlexItem = struct {
    view: *View,
    natural_size: Size,
    flex_basis: f32,
    margin_box: EdgeInsets,

    is_absolute: bool,
    cross_size: ?f32 = null,
    main_size: ?f32 = null,
    main_pos: ?f32 = null,
    cross_pos: ?f32 = null,
};

/// Line of flex items in a layout
const FlexLine = struct {
    items: std.ArrayList(FlexItem),
    main_size: f32 = 0,
    cross_size: f32 = 0,
    remaining_free_space: f32 = 0,

    pub fn init(allocator: std.mem.Allocator) FlexLine {
        return .{
            .items = std.ArrayList(FlexItem).init(allocator),
        };
    }

    pub fn deinit(self: *FlexLine) void {
        self.items.deinit();
    }
};

/// Engine for calculating layout
pub const LayoutEngine = struct {
    allocator: std.mem.Allocator,
    dirty_views: std.AutoHashMap(u64, void),
    extensions: std.ArrayList(*LayoutEngineExtension),

    /// Initialize a new layout engine
    pub fn init(allocator: std.mem.Allocator, capacity: u32) !*LayoutEngine {
        const engine = try allocator.create(LayoutEngine);
        engine.* = .{
            .allocator = allocator,
            .dirty_views = std.AutoHashMap(u64, void).init(allocator),
            .extensions = std.ArrayList(*LayoutEngineExtension).init(allocator),
        };

        try engine.dirty_views.ensureTotalCapacity(capacity);

        return engine;
    }

    /// Free resources used by the layout engine
    pub fn deinit(self: *LayoutEngine) void {
        self.dirty_views.deinit();
        self.extensions.deinit();
        self.allocator.destroy(self);
    }

    /// Register a layout engine extension
    pub fn registerExtension(self: *LayoutEngine, extension: *LayoutEngineExtension) !void {
        try self.extensions.append(extension);
    }

    /// Check if any views need layout recalculation
    pub fn needsLayout(self: *LayoutEngine) bool {
        return self.dirty_views.count() > 0;
    }

    /// Mark a view as needing layout recalculation
    pub fn markDirty(self: *LayoutEngine, view: *View) void {
        self.dirty_views.put(view.id, {}) catch {};
    }

    /// Calculate layout for the entire view hierarchy
    pub fn calculateLayout(self: *LayoutEngine, root_view: *View) void {
        // Calculate layout starting from root
        _ = self.calculateViewLayout(root_view, root_view.rect.size);

        // Update positions based on calculated sizes
        self.updateViewPositions(root_view, Point{ .x = 0, .y = 0 });

        // Clear dirty flag
        self.dirty_views.clearRetainingCapacity();
    }

    /// Calculate layout for a view and its children
    fn calculateViewLayout(self: *LayoutEngine, view: *View, constraint: Size) Size {
        // Skip if not visible
        if (!view.isVisible()) {
            return Size{ .width = 0, .height = 0 };
        }

        // Check for custom layout handled by extensions
        for (self.extensions.items) |extension| {
            if (extension.vtable.supportedLayoutType(extension) == .custom) {
                const size = extension.vtable.measureComponent(extension, view, constraint);
                extension.vtable.arrangeChildren(extension, view, Rect{
                    .x = 0,
                    .y = 0,
                    .width = size.width,
                    .height = size.height,
                });
                return size;
            }
        }

        // First measure the view itself
        const size = view.vtable.layout(view, constraint);

        // If it's a container with children, arrange them
        if (view.children.items.len > 0) {
            self.arrangeChildren(view, size);
        }

        return size;
    }

    /// Update positions of a view and its children
    fn updateViewPositions(self: *LayoutEngine, view: *View, position: Point) void {
        // Skip if not visible
        if (!view.isVisible()) {
            return;
        }

        // Update view position
        view.rect.x = position.x;
        view.rect.y = position.y;

        // Update children
        for (view.children.items) |child| {
            // For relative positioning, positions are relative to parent
            if (child.layout_params.position_type == .relative) {
                const child_x = position.x + child.rect.x;
                const child_y = position.y + child.rect.y;
                self.updateViewPositions(child, .{ .x = child_x, .y = child_y });
            } else {
                // For absolute positioning, positions are absolute within parent
                const abs_x = position.x + child.layout_params.position.left;
                const abs_y = position.y + child.layout_params.position.top;
                self.updateViewPositions(child, .{ .x = abs_x, .y = abs_y });
            }
        }
    }

    /// Arrange children according to flex layout rules
    fn arrangeChildren(self: *LayoutEngine, view: *View, container_size: Size) void {
        // Get layout parameters for the container
        const params = view.layout_params;

        // Determine if we're working with a horizontal or vertical layout
        const is_horizontal = params.flex_direction == .row or params.flex_direction == .row_reverse;
        const is_reverse = params.flex_direction == .row_reverse or params.flex_direction == .column_reverse;

        // Get the available space for children
        var available_main_axis = if (is_horizontal) container_size.width else container_size.height;
        var available_cross_axis = if (is_horizontal) container_size.height else container_size.width;

        // Subtract padding
        available_main_axis -= if (is_horizontal)
            params.padding.left + params.padding.right
        else
            params.padding.top + params.padding.bottom;

        available_cross_axis -= if (is_horizontal)
            params.padding.top + params.padding.bottom
        else
            params.padding.left + params.padding.right;

        // Sort children into flex lines
        var lines = std.ArrayList(FlexLine).init(self.allocator);
        defer {
            for (lines.items) |*line| {
                line.deinit();
            }
            lines.deinit();
        }

        var current_line = FlexLine.init(self.allocator);
        var current_line_size: f32 = 0;

        // First pass: measure items and collect them into lines
        var absolute_items = std.ArrayList(FlexItem).init(self.allocator);
        defer absolute_items.deinit();

        for (view.children.items) |child| {
            // Skip if not visible
            if (!child.isVisible()) continue;

            // Handle absolute positioned items separately
            if (child.layout_params.position_type == .absolute) {
                // Measure absolute items with unbounded constraints
                const absolute_size = self.calculateViewLayout(child, Size{
                    .width = if (child.layout_params.width == .auto) std.math.inf(f32) else child.layout_params.width.resolve(available_main_axis),
                    .height = if (child.layout_params.height == .auto) std.math.inf(f32) else child.layout_params.height.resolve(available_cross_axis),
                });

                try absolute_items.append(.{
                    .view = child,
                    .natural_size = absolute_size,
                    .flex_basis = 0,
                    .margin_box = child.layout_params.margin,
                    .is_absolute = true,
                });
                continue;
            }

            // Get child's margin
            const margin = child.layout_params.margin;

            // Calculate the margin box (space taken by margins)
            const margin_main = if (is_horizontal)
                margin.left + margin.right
            else
                margin.top + margin.bottom;

            const margin_cross = if (is_horizontal)
                margin.top + margin.bottom
            else
                margin.left + margin.right;

            // Determine the flex basis
            var flex_basis: f32 = 0;

            // If flex basis is set, use it
            if (child.layout_params.flex_basis != .auto) {
                flex_basis = child.layout_params.flex_basis.resolve(available_main_axis);
            } else {
                // Otherwise use the main axis dimension if specified
                if (is_horizontal and child.layout_params.width != .auto) {
                    flex_basis = child.layout_params.width.resolve(available_main_axis);
                } else if (!is_horizontal and child.layout_params.height != .auto) {
                    flex_basis = child.layout_params.height.resolve(available_cross_axis);
                } else {
                    // Measure the item to determine size
                    var child_constraint = Size{
                        .width = if (is_horizontal) std.math.inf(f32) else available_cross_axis - margin_cross,
                        .height = if (is_horizontal) available_cross_axis - margin_cross else std.math.inf(f32),
                    };

                    // Apply min/max constraints
                    if (child.layout_params.max_width) |max_w| {
                        child_constraint.width = @min(child_constraint.width, max_w);
                    }

                    if (child.layout_params.max_height) |max_h| {
                        child_constraint.height = @min(child_constraint.height, max_h);
                    }

                    const natural_size = self.calculateViewLayout(child, child_constraint);

                    // Use the measured size for flex basis
                    flex_basis = if (is_horizontal) natural_size.width else natural_size.height;
                }
            }

            // Apply min/max constraints to flex basis
            if (is_horizontal) {
                if (child.layout_params.min_width) |min_w| {
                    flex_basis = @max(flex_basis, min_w);
                }
                if (child.layout_params.max_width) |max_w| {
                    flex_basis = @min(flex_basis, max_w);
                }
            } else {
                if (child.layout_params.min_height) |min_h| {
                    flex_basis = @max(flex_basis, min_h);
                }
                if (child.layout_params.max_height) |max_h| {
                    flex_basis = @min(flex_basis, max_h);
                }
            }

            // Check if we need to wrap to a new line
            if (params.flex_wrap != .nowrap and
                current_line.items.items.len > 0 and
                current_line_size + flex_basis + margin_main > available_main_axis)
            {
                // Add current line to lines and start a new one
                try lines.append(current_line);
                current_line = FlexLine.init(self.allocator);
                current_line_size = 0;
            }

            // Get cross axis size based on constraints
            var cross_axis_size: f32 = undefined;
            if (is_horizontal) {
                if (child.layout_params.height != .auto) {
                    cross_axis_size = child.layout_params.height.resolve(available_cross_axis);
                } else {
                    cross_axis_size = child.rect.height;
                }
            } else {
                if (child.layout_params.width != .auto) {
                    cross_axis_size = child.layout_params.width.resolve(available_cross_axis);
                } else {
                    cross_axis_size = child.rect.width;
                }
            }

            // Apply min/max constraints to cross axis
            if (is_horizontal) {
                if (child.layout_params.min_height) |min_h| {
                    cross_axis_size = @max(cross_axis_size, min_h);
                }
                if (child.layout_params.max_height) |max_h| {
                    cross_axis_size = @min(cross_axis_size, max_h);
                }
            } else {
                if (child.layout_params.min_width) |min_w| {
                    cross_axis_size = @max(cross_axis_size, min_w);
                }
                if (child.layout_params.max_width) |max_w| {
                    cross_axis_size = @min(cross_axis_size, max_w);
                }
            }

            // Create flex item
            try current_line.items.append(.{
                .view = child,
                .natural_size = Size{
                    .width = if (is_horizontal) flex_basis else cross_axis_size,
                    .height = if (is_horizontal) cross_axis_size else flex_basis,
                },
                .flex_basis = flex_basis,
                .margin_box = margin,
                .is_absolute = false,
                .cross_size = cross_axis_size,
            });

            // Update line size
            current_line_size += flex_basis + margin_main;
            current_line.cross_size = @max(current_line.cross_size, cross_axis_size + margin_cross);
        }

        // Add last line if it has items
        if (current_line.items.items.len > 0) {
            try lines.append(current_line);
        }

        // Empty container or only absolute items
        if (lines.items.len == 0) {
            // Position absolute items
            for (absolute_items.items) |abs_item| {
                const child = abs_item.view;
                const margin = abs_item.margin_box;

                // Calculate position based on alignment and edges
                var left: f32 = params.padding.left + margin.left;
                var top: f32 = params.padding.top + margin.top;

                if (child.layout_params.position.right != 0) {
                    left = container_size.width - params.padding.right -
                        margin.right - child.rect.width -
                        child.layout_params.position.right;
                } else {
                    left += child.layout_params.position.left;
                }

                if (child.layout_params.position.bottom != 0) {
                    top = container_size.height - params.padding.bottom -
                        margin.bottom - child.rect.height -
                        child.layout_params.position.bottom;
                } else {
                    top += child.layout_params.position.top;
                }

                child.rect.x = left;
                child.rect.y = top;
            }

            return;
        }

        // Calculate the total cross size needed for all lines
        var total_cross_size: f32 = 0;
        for (lines.items) |line| {
            total_cross_size += line.cross_size;
        }

        // Second pass: resolve flexible lengths (flex grow/shrink)
        for (lines.items) |*line| {
            var line_main_size: f32 = 0;
            var total_flex_grow: f32 = 0;
            var total_flex_shrink: f32 = 0;

            // Calculate line main size and collect flex factors
            for (line.items.items) |item| {
                line_main_size += item.flex_basis +
                    (if (is_horizontal)
                        item.margin_box.left + item.margin_box.right
                    else
                        item.margin_box.top + item.margin_box.bottom);

                total_flex_grow += item.view.layout_params.flex_grow;
                total_flex_shrink += item.view.layout_params.flex_shrink;
            }

            line.main_size = line_main_size;
            line.remaining_free_space = available_main_axis - line_main_size;

            // Distribute remaining space based on flex grow/shrink
            if (line.remaining_free_space > 0 and total_flex_grow > 0) {
                // Distribute extra space based on flex grow
                for (line.items.items) |*item| {
                    if (item.view.layout_params.flex_grow > 0) {
                        const flex_grow = item.view.layout_params.flex_grow;
                        const extra = line.remaining_free_space * (flex_grow / total_flex_grow);
                        item.main_size = item.flex_basis + extra;
                    } else {
                        item.main_size = item.flex_basis;
                    }
                }
            } else if (line.remaining_free_space < 0 and total_flex_shrink > 0) {
                // Shrink items based on flex shrink
                for (line.items.items) |*item| {
                    if (item.view.layout_params.flex_shrink > 0) {
                        const flex_shrink = item.view.layout_params.flex_shrink;
                        const shrink = -line.remaining_free_space *
                            (flex_shrink / total_flex_shrink) *
                            (item.flex_basis / line_main_size);
                        item.main_size = item.flex_basis - shrink;
                    } else {
                        item.main_size = item.flex_basis;
                    }
                }
            } else {
                // Just use flex basis as main size
                for (line.items.items) |*item| {
                    item.main_size = item.flex_basis;
                }
            }
        }

        // Third pass: align items in main axis
        var cross_axis_offset: f32 = params.padding.top;
        if (!is_horizontal) {
            cross_axis_offset = params.padding.left;
        }

        // Handle align content for multi-line layouts
        if (lines.items.len > 1) {
            const remaining_cross: f32 = available_cross_axis - total_cross_size;

            switch (params.align_content) {
                .start => {
                    // Already correct (starts at beginning)
                },
                .end => {
                    cross_axis_offset += remaining_cross;
                },
                .center => {
                    cross_axis_offset += remaining_cross / 2;
                },
                .stretch => {
                    // Distribute extra space to each line proportionally
                    if (remaining_cross > 0) {
                        for (lines.items) |*line| {
                            line.cross_size += remaining_cross / @as(f32, lines.items.len);
                        }
                    }
                },
                .space_between => {
                    if (lines.items.len > 1 and remaining_cross > 0) {
                        const space_between = remaining_cross / @as(f32, lines.items.len - 1);
                        for (lines.items[1..], 0..) |*line, i| {
                            line.cross_pos = cross_axis_offset +
                                @as(f32, i + 1) * space_between;
                        }
                    }
                },
                .space_around => {
                    if (remaining_cross > 0) {
                        const space_around = remaining_cross / @as(f32, lines.items.len * 2);
                        cross_axis_offset += space_around;
                        for (lines.items, 0..) |*line, i| {
                            line.cross_pos = cross_axis_offset +
                                @as(f32, i * 2 + 1) * space_around;
                        }
                    }
                },
            }
        }

        // Position items in each line
        for (lines.items) |*line| {
            var main_axis_offset = if (is_horizontal) params.padding.left else params.padding.top;

            // Handle justify content
            if (line.remaining_free_space > 0) {
                switch (params.justify_content) {
                    .start => {
                        // Already correct (starts at beginning)
                    },
                    .end => {
                        main_axis_offset += line.remaining_free_space;
                    },
                    .center => {
                        main_axis_offset += line.remaining_free_space / 2;
                    },
                    .space_between => {
                        if (line.items.items.len > 1) {
                            const space_between = line.remaining_free_space /
                                @as(f32, line.items.items.len - 1);
                            for (line.items.items[1..], 0..) |*item, i| {
                                item.main_pos = main_axis_offset +
                                    item.flex_basis +
                                    @as(f32, i + 1) * space_between;
                            }
                        }
                    },
                    .space_around => {
                        const space_around = line.remaining_free_space /
                            @as(f32, line.items.items.len * 2);
                        main_axis_offset += space_around;
                        for (line.items.items, 0..) |*item, i| {
                            item.main_pos = main_axis_offset +
                                @as(f32, i * 2 + 1) * space_around;
                        }
                    },
                    .space_evenly => {
                        const space_evenly = line.remaining_free_space /
                            @as(f32, line.items.items.len + 1);
                        main_axis_offset += space_evenly;
                        for (line.items.items, 0..) |*item, i| {
                            item.main_pos = main_axis_offset +
                                @as(f32, i) * space_evenly;
                        }
                    },
                }
            }

            // Position items in the line
            for (line.items.items) |*item| {
                const child = item.view;

                // Get item margins
                const margin = item.margin_box;

                // Skip if already positioned (e.g. by space_between or space_around)
                if (item.main_pos == null) {
                    if (is_reverse) {
                        item.main_pos = available_main_axis - main_axis_offset - item.main_size.?;
                    } else {
                        item.main_pos = main_axis_offset;
                    }
                }

                main_axis_offset += item.main_size.? +
                    (if (is_horizontal)
                        margin.left + margin.right
                    else
                        margin.top + margin.bottom);

                // Get child's align value (align_self overrides container's align_items)
                const alignment = if (child.layout_params.align_self == .auto)
                    params.align_items
                else switch (child.layout_params.align_self) {
                    .auto => params.align_items,
                    .start => AlignItems.start,
                    .end => AlignItems.end,
                    .center => AlignItems.center,
                    .stretch => AlignItems.stretch,
                };

                // Calculate cross axis position based on alignment
                var cross_pos = line.cross_pos orelse cross_axis_offset;

                if (is_horizontal) {
                    cross_pos += margin.top;

                    switch (alignment) {
                        .start => {}, // Already at start
                        .end => {
                            cross_pos += line.cross_size - item.cross_size.? - margin.top - margin.bottom;
                        },
                        .center => {
                            cross_pos += (line.cross_size - item.cross_size.? - margin.top - margin.bottom) / 2;
                        },
                        .stretch => {
                            if (child.layout_params.height == .auto) {
                                item.cross_size = line.cross_size - margin.top - margin.bottom;
                            }
                        },
                        .baseline => {
                            // Baseline alignment not implemented yet, fall back to start
                        },
                    }
                } else {
                    cross_pos += margin.left;

                    switch (alignment) {
                        .start => {}, // Already at start
                        .end => {
                            cross_pos += line.cross_size - item.cross_size.? - margin.left - margin.right;
                        },
                        .center => {
                            cross_pos += (line.cross_size - item.cross_size.? - margin.left - margin.right) / 2;
                        },
                        .stretch => {
                            if (child.layout_params.width == .auto) {
                                item.cross_size = line.cross_size - margin.left - margin.right;
                            }
                        },
                        .baseline => {
                            // Baseline alignment not implemented yet, fall back to start
                        },
                    }
                }

                item.cross_pos = cross_pos;

                // Set the child's size and position
                if (is_horizontal) {
                    child.rect.width = item.main_size.?;
                    child.rect.height = item.cross_size.?;
                    child.rect.x = item.main_pos.? + margin.left;
                    child.rect.y = item.cross_pos.?;
                } else {
                    child.rect.width = item.cross_size.?;
                    child.rect.height = item.main_size.?;
                    child.rect.x = item.cross_pos.?;
                    child.rect.y = item.main_pos.? + margin.top;
                }
            }

            // Move to next line
            cross_axis_offset += line.cross_size;
        }

        // Position absolute items
        for (absolute_items.items) |abs_item| {
            const child = abs_item.view;
            const margin = abs_item.margin_box;

            // Calculate position based on alignment and edges
            var left: f32 = params.padding.left + margin.left;
            var top: f32 = params.padding.top + margin.top;

            if (child.layout_params.position.right != 0) {
                left = container_size.width - params.padding.right -
                    margin.right - child.rect.width -
                    child.layout_params.position.right;
            } else {
                left += child.layout_params.position.left;
            }

            if (child.layout_params.position.bottom != 0) {
                top = container_size.height - params.padding.bottom -
                    margin.bottom - child.rect.height -
                    child.layout_params.position.bottom;
            } else {
                top += child.layout_params.position.top;
            }

            child.rect.x = left;
            child.rect.y = top;
        }
    }
};

/// Interface for layout engine extensions
pub const LayoutEngineExtension = struct {
    vtable: *const VTable,

    pub const LayoutType = enum {
        flex,
        grid,
        stack,
        custom,
    };

    pub const VTable = struct {
        measureComponent: *const fn (*LayoutEngineExtension, *View, Size) Size,
        arrangeChildren: *const fn (*LayoutEngineExtension, *View, Rect) void,
        supportedLayoutType: *const fn (*LayoutEngineExtension) LayoutType,
    };
};
