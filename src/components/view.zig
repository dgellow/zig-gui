const std = @import("std");
const Rect = @import("../core/geometry.zig").Rect;
const Size = @import("../core/geometry.zig").Size;
const Point = @import("../core/geometry.zig").Point;
const EdgeInsets = @import("../core/geometry.zig").EdgeInsets;
const Style = @import("../style.zig").Style;
const RenderContext = @import("../renderer.zig").RenderContext;
const LayoutParams = @import("../layout.zig").LayoutParams;
const UIEvent = @import("../events.zig").UIEvent;

/// Unique identifier generator for views
fn nextId() u64 {
    const Static = struct {
        var id: u64 = 0;
    };
    Static.id += 1;
    return Static.id;
}

/// Base component that serves as the foundation for all UI elements
pub const View = struct {
    id: u64,
    rect: Rect,
    parent: ?*View = null,
    children: std.ArrayList(*View),

    style: Style,
    layout_params: LayoutParams,

    data: *anyopaque,
    vtable: *const VTable,

    dirty_layout: bool = true,
    dirty_render: bool = true,

    allocator: std.mem.Allocator,
    visible: bool = true,
    tag: []const u8 = "", // Optional identifier for finding views
    user_data: ?*anyopaque = null, // For application-specific data

    /// Virtual method table for polymorphic behavior
    pub const VTable = struct {
        /// Build or rebuild component (called when data changes)
        build: *const fn (*View) void,

        /// Measure and layout component
        layout: *const fn (*View, Size) Size,

        /// Paint component to renderer
        paint: *const fn (*View, *const RenderContext) void,

        /// Handle UI events
        handleEvent: *const fn (*View, *UIEvent) bool,

        /// Free resources used by component
        deinit: *const fn (*View) void,
    };

    /// Initialize base fields for a new View
    pub fn init(allocator: std.mem.Allocator, data: *anyopaque, vtable: *const VTable) View {
        return View{
            .id = nextId(),
            .rect = Rect.zero(),
            .children = std.ArrayList(*View).init(allocator),
            .style = Style.default(),
            .layout_params = LayoutParams{},
            .data = data,
            .vtable = vtable,
            .allocator = allocator,
        };
    }

    /// Request layout recalculation for this view and ancestors
    pub fn requestRebuild(self: *View) void {
        self.dirty_layout = true;
        self.dirty_render = true;

        // Propagate up to invalidate parent layouts
        var parent = self.parent;
        while (parent) |p| {
            p.dirty_layout = true;
            parent = p.parent;
        }
    }

    /// Call the build method for this view
    pub fn build(self: *View) void {
        self.vtable.build(self);
    }

    /// Measure and layout this view given a size constraint
    pub fn layout(self: *View, constraint: Size) Size {
        return self.vtable.layout(self, constraint);
    }

    /// Paint this view to the renderer
    pub fn paint(self: *View, context: *const RenderContext) void {
        self.vtable.paint(self, context);
    }

    /// Handle an event in this view
    pub fn handleEvent(self: *View, event: *UIEvent) bool {
        return self.vtable.handleEvent(self, event);
    }

    /// Free resources used by this view
    pub fn deinit(self: *View) void {
        self.vtable.deinit(self);
    }

    // Child management

    /// Add a child view to this view
    pub fn addChild(self: *View, child: *View) !void {
        // Remove from old parent if exists
        if (child.parent) |old_parent| {
            try old_parent.removeChild(child);
        }

        // Add to our children
        try self.children.append(child);
        child.parent = self;

        // Mark layout as dirty
        self.dirty_layout = true;
        child.dirty_layout = true;
    }

    /// Remove a child view from this view
    pub fn removeChild(self: *View, child: *View) !void {
        const index = for (self.children.items, 0..) |item, i| {
            if (item.id == child.id) break i;
        } else return error.ChildNotFound;

        _ = self.children.orderedRemove(index);
        child.parent = null;

        // Mark layout as dirty
        self.dirty_layout = true;
    }

    /// Remove all children from this view
    pub fn removeAllChildren(self: *View) void {
        // Clear parent references
        for (self.children.items) |child| {
            child.parent = null;
        }

        // Clear the list
        self.children.clearRetainingCapacity();

        // Mark layout as dirty
        self.dirty_layout = true;
    }

    /// Find a view by tag, searching from this view's hierarchy
    pub fn findViewByTag(self: *View, tag: []const u8) ?*View {
        // Check self first
        if (std.mem.eql(u8, self.tag, tag)) {
            return self;
        }

        // Check children recursively
        for (self.children.items) |child| {
            if (child.findViewByTag(tag)) |found| {
                return found;
            }
        }

        return null;
    }

    /// Find a view by ID
    pub fn findViewById(self: *View, id: u64) ?*View {
        // Check self first
        if (self.id == id) {
            return self;
        }

        // Check children recursively
        for (self.children.items) |child| {
            if (child.findViewById(id)) |found| {
                return found;
            }
        }

        return null;
    }

    /// Check if this view is visible
    pub fn isVisible(self: *const View) bool {
        return self.visible;
    }

    /// Set visibility of this view
    pub fn setVisible(self: *View, visible: bool) void {
        if (self.visible != visible) {
            self.visible = visible;
            self.dirty_render = true;

            // Invalidate parent layout if needed
            if (self.parent) |parent| {
                parent.dirty_layout = true;
            }
        }
    }

    /// Set position and size
    pub fn setBounds(self: *View, rect: Rect) void {
        if (!self.rect.equals(rect)) {
            self.rect = rect;
            self.dirty_render = true;
        }
    }

    /// Set position
    pub fn setPosition(self: *View, position: Point) void {
        if (self.rect.x != position.x or self.rect.y != position.y) {
            self.rect.x = position.x;
            self.rect.y = position.y;
            self.dirty_render = true;
        }
    }

    /// Set size
    pub fn setSize(self: *View, size: Size) void {
        if (self.rect.width != size.width or self.rect.height != size.height) {
            self.rect.width = size.width;
            self.rect.height = size.height;
            self.dirty_layout = true;
            self.dirty_render = true;
        }
    }

    /// Set layout parameters
    pub fn setLayoutParams(self: *View, params: LayoutParams) void {
        self.layout_params = params;
        self.dirty_layout = true;

        // Invalidate parent layout
        if (self.parent) |parent| {
            parent.dirty_layout = true;
        }
    }

    /// Set style
    pub fn setStyle(self: *View, style: Style) void {
        self.style = style;
        self.dirty_render = true;
    }

    /// Check if point is inside this view (hit testing)
    pub fn hitTest(self: *const View, point: Point) bool {
        return self.rect.contains(point);
    }

    /// Find deepest view that contains point
    pub fn findViewAtPoint(self: *View, point: Point) ?*View {
        // Skip if not visible or point is outside bounds
        if (!self.isVisible() or !self.hitTest(point)) {
            return null;
        }

        // Check children back to front (last drawn is on top)
        var i: usize = self.children.items.len;
        while (i > 0) {
            i -= 1;
            const child = self.children.items[i];

            if (child.findViewAtPoint(point)) |found| {
                return found;
            }
        }

        // If no child contains point, return self
        return self;
    }

    /// Set a property by name (used for data binding)
    pub fn setProperty(self: *View, name: []const u8, value: anytype) void {
        // Default implementation - can be overridden by specific components
        _ = self;
        _ = name;
        _ = value;
    }
};

/// Basic View component implementation
/// This is a simple wrapper around the base View type that provides
/// a concrete implementation
pub const ViewComponent = struct {
    const Self = @This();

    view: View,

    /// Create a new ViewComponent
    pub fn create(allocator: std.mem.Allocator) !*ViewComponent {
        const component = try allocator.create(ViewComponent);
        component.* = .{
            .view = View.init(allocator, component, &vtable),
        };
        return component;
    }

    /// Free resources used by this component
    pub fn deinit(self: *ViewComponent) void {
        // Free children first
        for (self.view.children.items) |child| {
            child.deinit();
        }
        self.view.children.deinit();

        // Free self
        const allocator = self.view.allocator;
        allocator.destroy(self);
    }

    // Implement vtable methods
    fn build(view: *View) void {
        _ = view;
        // Nothing to build for a basic view
    }

    fn layout(view: *View, constraint: Size) Size {
        // Default layout just uses available space or fixed size if specified
        var width = constraint.width;
        var height = constraint.height;

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

        view.rect.width = width;
        view.rect.height = height;

        return Size{ .width = width, .height = height };
    }

    fn paint(view: *View, context: *const RenderContext) void {
        // Only draw background if color is specified
        if (view.style.background_color) |color| {
            context.renderer.vtable.drawRect(context.renderer, view.rect, .{ .color = color });
        }

        // Draw border if specified
        if (view.style.border_color != null and view.style.border_width != null) {
            const border_color = view.style.border_color.?;
            const border_width = view.style.border_width.?;

            const border_rect = view.rect;

            // Check if we have rounded corners
            if (view.style.border_radius) |radius| {
                context.renderer.vtable.drawRoundRect(context.renderer, border_rect, radius, .{
                    .color = .{ .r = 0, .g = 0, .b = 0, .a = 0 }, // Transparent fill
                    .stroke_color = border_color,
                    .stroke_width = border_width,
                });
            } else {
                // Draw regular rectangle border
                context.renderer.vtable.drawRect(context.renderer, border_rect, .{
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
        // Basic view doesn't handle any events
        return false;
    }

    /// Set a property value
    pub fn setProperty(self: *ViewComponent, name: []const u8, value: anytype) void {
        if (std.mem.eql(u8, name, "backgroundColor")) {
            // Update background color
            var style = self.view.style;
            style.background_color = value;
            self.view.setStyle(style);
        } else if (std.mem.eql(u8, name, "borderColor")) {
            // Update border color
            var style = self.view.style;
            style.border_color = value;
            self.view.setStyle(style);
        } else if (std.mem.eql(u8, name, "borderWidth")) {
            // Update border width
            var style = self.view.style;
            style.border_width = value;
            self.view.setStyle(style);
        } else if (std.mem.eql(u8, name, "borderRadius")) {
            // Update border radius
            var style = self.view.style;
            style.border_radius = value;
            self.view.setStyle(style);
        }
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
