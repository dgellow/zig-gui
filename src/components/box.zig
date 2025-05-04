const std = @import("std");
const View = @import("view.zig").View;
const RenderContext = @import("../renderer.zig").RenderContext;
const Rect = @import("../core/geometry.zig").Rect;
const Size = @import("../core/geometry.zig").Size;
const UIEvent = @import("../events.zig").UIEvent;
const Color = @import("../core/color.zig").Color;
const LayoutParams = @import("../layout.zig").LayoutParams;
const LengthConstraint = @import("../layout.zig").LengthConstraint;

/// Box component for drawing rectangles with optional rounded corners
pub const Box = struct {
    const Self = @This();

    view: View,

    /// Create a new box
    pub fn create(allocator: std.mem.Allocator) !*Self {
        var rect = try allocator.create(Self);
        rect.* = .{
            .view = View.init(allocator, rect, &vtable),
        };

        // Initialize with default box style
        rect.view.style.background_color = Color.fromRGB(200, 200, 200);

        return rect;
    }

    /// Free resources used by this box
    pub fn deinit(self: *Self) void {
        // Free children
        for (self.view.children.items) |child| {
            child.deinit();
        }
        self.view.children.deinit();

        // Free self
        const allocator = self.view.allocator;
        allocator.destroy(self);
    }

    /// Set background color
    pub fn setColor(self: *Self, color: Color) void {
        var style = self.view.style;
        style.background_color = color;
        self.view.setStyle(style);
    }

    /// Set border color
    pub fn setBorderColor(self: *Self, color: Color) void {
        var style = self.view.style;
        style.border_color = color;
        self.view.setStyle(style);
    }

    /// Set border width
    pub fn setBorderWidth(self: *Self, width: f32) void {
        var style = self.view.style;
        style.border_width = width;
        self.view.setStyle(style);
    }

    /// Set corner radius
    pub fn setCornerRadius(self: *Self, radius: f32) void {
        var style = self.view.style;
        style.border_radius = radius;
        self.view.setStyle(style);
    }

    /// Set fixed size
    pub fn setSize(self: *Self, width: f32, height: f32) void {
        var params = self.view.layout_params;
        params.width = LengthConstraint{ .fixed = width };
        params.height = LengthConstraint{ .fixed = height };
        self.view.setLayoutParams(params);
    }

    /// Set width
    pub fn setWidth(self: *Self, width: f32) void {
        var params = self.view.layout_params;
        params.width = LengthConstraint{ .fixed = width };
        self.view.setLayoutParams(params);
    }

    /// Set height
    pub fn setHeight(self: *Self, height: f32) void {
        var params = self.view.layout_params;
        params.height = LengthConstraint{ .fixed = height };
        self.view.setLayoutParams(params);
    }

    /// Set percentage width
    pub fn setPercentWidth(self: *Self, percent: f32) void {
        var params = self.view.layout_params;
        params.width = LengthConstraint{ .percentage = percent / 100.0 };
        self.view.setLayoutParams(params);
    }

    /// Set percentage height
    pub fn setPercentHeight(self: *Self, percent: f32) void {
        var params = self.view.layout_params;
        params.height = LengthConstraint{ .percentage = percent / 100.0 };
        self.view.setLayoutParams(params);
    }

    /// Set style properties
    pub fn setStyle(self: *Self, style: anytype) void {
        // Handle box-specific style properties
        const T = @TypeOf(style);

        // This uses Zig's comptime reflection to check for fields
        // and apply them to the component's style
        var view_style = self.view.style;

        inline for (std.meta.fields(T)) |field| {
            if (std.meta.fieldIndex(@TypeOf(view_style), field.name)) |_| {
                @field(view_style, field.name) = @field(style, field.name);
            }
        }

        self.view.setStyle(view_style);
    }

    // Implement vtable methods
    fn build(view: *View) void {
        _ = view;
        // Boxes don't need to build anything
    }

    fn layout(view: *View, constraint: Size) Size {
        // Handle sizing constraints
        var width = constraint.width;
        var height = constraint.height;

        // Apply fixed size if specified
        if (view.style.width) |w| {
            width = w;
        }

        if (view.style.height) |h| {
            height = h;
        }

        // Apply min/max constraints
        if (view.style.min_width) |min_w| {
            width = @max(width, min_w);
        }

        if (view.style.min_height) |min_h| {
            height = @max(height, min_h);
        }

        if (view.style.max_width) |max_w| {
            width = @min(width, max_w);
        }

        if (view.style.max_height) |max_h| {
            height = @min(height, max_h);
        }

        // Set size
        view.rect.width = width;
        view.rect.height = height;

        return Size{ .width = width, .height = height };
    }

    fn paint(view: *View, context: *const RenderContext) void {
        // Get background color with fallback to transparent
        const background_color = view.style.background_color orelse Color{ .r = 0, .g = 0, .b = 0, .a = 0 };

        // Check if we have rounded corners
        if (view.style.border_radius) |radius| {
            // Draw rounded box
            context.renderer.vtable.drawRoundRect(context.renderer, view.rect, radius, .{ .color = background_color });
        } else {
            // Draw regular box
            context.renderer.vtable.drawRect(context.renderer, view.rect, .{ .color = background_color });
        }

        // Draw border if specified
        if (view.style.border_color != null and view.style.border_width != null) {
            const border_color = view.style.border_color.?;
            const border_width = view.style.border_width.?;

            // Check if we have rounded corners
            if (view.style.border_radius) |radius| {
                context.renderer.vtable.drawRoundRect(context.renderer, view.rect, radius, .{
                    .color = .{ .r = 0, .g = 0, .b = 0, .a = 0 }, // Transparent fill
                    .stroke_color = border_color,
                    .stroke_width = border_width,
                });
            } else {
                // Draw box border
                context.renderer.vtable.drawRect(context.renderer, view.rect, .{
                    .color = .{ .r = 0, .g = 0, .b = 0, .a = 0 }, // Transparent fill
                    .stroke_color = border_color,
                    .stroke_width = border_width,
                });
            }
        }
    }

    fn handleEvent(view: *View, event: *UIEvent) bool {
        _ = view;
        _ = event;
        // Basic box doesn't handle any events
        return false;
    }

    // Static vtable implementation
    const vtable = View.VTable{
        .build = build,
        .layout = layout,
        .paint = paint,
        .handleEvent = handleEvent,
        .deinit = deinitView,
    };

    // Wrapper for deinitializing through the view
    fn deinitView(view: *View) void {
        const self: *Self = @fieldParentPtr("view", view);
        self.deinit();
    }
};
