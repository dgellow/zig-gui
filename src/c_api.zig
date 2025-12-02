//! C API Implementation for zig-gui
//!
//! Exports functions matching zgl.h for C/C++ interoperability.
//! All functions use C calling convention and ABI-stable types.

const std = @import("std");
const layout_engine = @import("layout/engine.zig");
const flexbox = @import("layout/flexbox.zig");
const gui_mod = @import("gui.zig");
const widget_id = @import("widget_id.zig");

// =============================================================================
// Type Aliases (matching zgl.h)
// =============================================================================

pub const ZglNode = u32;
pub const ZglId = u32;

pub const ZGL_NULL: ZglNode = 0xFFFFFFFF;

pub const ZglRect = extern struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
};

pub const ZglDirection = enum(c_int) {
    row = 0,
    column = 1,
};

pub const ZglJustify = enum(c_int) {
    start = 0,
    center = 1,
    end = 2,
    space_between = 3,
    space_around = 4,
    space_evenly = 5,
};

pub const ZglAlign = enum(c_int) {
    start = 0,
    center = 1,
    end = 2,
    stretch = 3,
};

pub const ZglError = enum(c_int) {
    ok = 0,
    out_of_memory = 1,
    capacity_exceeded = 2,
    invalid_node = 3,
    cycle_detected = 4,
};

/// C-compatible style structure (56 bytes, matches zgl.h)
pub const ZglStyle = extern struct {
    // Flexbox properties (4 bytes total - use u8 to match C enum sizes)
    direction: u8 = 1, // ZGL_COLUMN = 1
    justify: u8 = 0, // ZGL_JUSTIFY_START = 0
    align_: u8 = 3, // ZGL_ALIGN_STRETCH = 3
    _reserved: u8 = 0,

    // Flex item properties (8 bytes)
    flex_grow: f32 = 0.0,
    flex_shrink: f32 = 1.0,

    // Dimensions (24 bytes)
    width: f32 = -1.0, // ZGL_AUTO
    height: f32 = -1.0,
    min_width: f32 = 0.0,
    min_height: f32 = 0.0,
    max_width: f32 = 1e30, // ZGL_NONE
    max_height: f32 = 1e30,

    // Spacing (20 bytes)
    gap: f32 = 0.0,
    padding_top: f32 = 0.0,
    padding_right: f32 = 0.0,
    padding_bottom: f32 = 0.0,
    padding_left: f32 = 0.0,

    comptime {
        if (@sizeOf(ZglStyle) != 56) {
            @compileError("ZglStyle size mismatch with C header");
        }
    }
};

pub const ZglGuiConfig = extern struct {
    max_widgets: u32 = 4096,
    viewport_width: f32 = 800.0,
    viewport_height: f32 = 600.0,
};

// =============================================================================
// Global State (thread-local for thread safety)
// =============================================================================

threadlocal var last_error: ZglError = .ok;

// =============================================================================
// Version and ABI Checks
// =============================================================================

pub export fn zgl_get_version() u32 {
    return (1 << 16) | 0; // Version 1.0
}

pub export fn zgl_max_elements() u32 {
    return layout_engine.MAX_ELEMENTS;
}

pub export fn zgl_style_size() usize {
    return @sizeOf(ZglStyle);
}

pub export fn zgl_rect_size() usize {
    return @sizeOf(ZglRect);
}

// =============================================================================
// Error Handling
// =============================================================================

pub export fn zgl_get_last_error() ZglError {
    return last_error;
}

pub export fn zgl_error_string(err: ZglError) [*:0]const u8 {
    return switch (err) {
        .ok => "Success",
        .out_of_memory => "Out of memory",
        .capacity_exceeded => "Maximum node capacity exceeded",
        .invalid_node => "Invalid node handle",
        .cycle_detected => "Operation would create cycle in tree",
    };
}

// =============================================================================
// Layout Engine Wrapper
// =============================================================================

/// Opaque layout engine handle
pub const ZglLayout = opaque {
    fn fromPtr(ptr: *layout_engine.LayoutEngine) *ZglLayout {
        return @ptrCast(ptr);
    }

    fn toPtr(self: *ZglLayout) *layout_engine.LayoutEngine {
        return @ptrCast(@alignCast(self));
    }

    fn toPtrConst(self: *const ZglLayout) *const layout_engine.LayoutEngine {
        return @ptrCast(@alignCast(self));
    }
};

// =============================================================================
// Layer 1: Layout Engine API
// =============================================================================

pub export fn zgl_layout_create(max_nodes: u32) ?*ZglLayout {
    _ = max_nodes; // TODO: Use for configurable capacity

    // Use C allocator for C API (no Zig allocator management needed)
    const engine = std.heap.c_allocator.create(layout_engine.LayoutEngine) catch {
        last_error = .out_of_memory;
        return null;
    };

    engine.* = layout_engine.LayoutEngine.init(std.heap.c_allocator) catch {
        std.heap.c_allocator.destroy(engine);
        last_error = .out_of_memory;
        return null;
    };

    last_error = .ok;
    return ZglLayout.fromPtr(engine);
}

pub export fn zgl_layout_destroy(layout_opt: ?*ZglLayout) void {
    const layout = layout_opt orelse return;
    const engine = layout.toPtr();
    engine.deinit();
    std.heap.c_allocator.destroy(engine);
}

pub export fn zgl_layout_add(
    layout_opt: ?*ZglLayout,
    parent: ZglNode,
    style: ?*const ZglStyle,
) ZglNode {
    const layout = layout_opt orelse {
        last_error = .invalid_node;
        return ZGL_NULL;
    };
    const engine = layout.toPtr();

    const flex_style = if (style) |s| convertStyle(s) else flexbox.FlexStyle{};

    const parent_opt: ?u32 = if (parent == ZGL_NULL) null else parent;

    const index = engine.addElement(parent_opt, flex_style) catch {
        last_error = .capacity_exceeded;
        return ZGL_NULL;
    };

    last_error = .ok;
    return index;
}

pub export fn zgl_layout_remove(layout_opt: ?*ZglLayout, node: ZglNode) void {
    const layout = layout_opt orelse return;
    const engine = layout.toPtr();

    if (node >= engine.element_count) return;

    engine.removeElement(node);
}

pub export fn zgl_layout_set_style(
    layout_opt: ?*ZglLayout,
    node: ZglNode,
    style: ?*const ZglStyle,
) void {
    const layout = layout_opt orelse return;
    const engine = layout.toPtr();

    if (node >= engine.element_count) return;

    const flex_style = if (style) |s| convertStyle(s) else flexbox.FlexStyle{};
    engine.setStyle(node, flex_style);
}

pub export fn zgl_layout_reparent(
    layout_opt: ?*ZglLayout,
    node: ZglNode,
    new_parent: ZglNode,
) void {
    _ = layout_opt;
    _ = node;
    _ = new_parent;
    // TODO: Implement reparenting
}

pub export fn zgl_layout_compute(
    layout_opt: ?*ZglLayout,
    available_width: f32,
    available_height: f32,
) void {
    const layout = layout_opt orelse return;
    const engine = layout.toPtr();

    engine.computeLayout(available_width, available_height) catch {};
}

pub export fn zgl_layout_get_rect(layout_opt: ?*const ZglLayout, node: ZglNode) ZglRect {
    const layout = layout_opt orelse return ZglRect{ .x = 0, .y = 0, .width = 0, .height = 0 };
    const engine = layout.toPtrConst();

    if (node >= engine.element_count) {
        return ZglRect{ .x = 0, .y = 0, .width = 0, .height = 0 };
    }

    const rect = engine.computed_rects[node];
    return ZglRect{
        .x = rect.x,
        .y = rect.y,
        .width = rect.width,
        .height = rect.height,
    };
}

pub export fn zgl_layout_get_parent(layout_opt: ?*const ZglLayout, node: ZglNode) ZglNode {
    const layout = layout_opt orelse return ZGL_NULL;
    const engine = layout.toPtrConst();

    if (node >= engine.element_count) return ZGL_NULL;

    const parent = engine.parent[node];
    return if (parent == 0xFFFFFFFF) ZGL_NULL else parent;
}

pub export fn zgl_layout_get_first_child(layout_opt: ?*const ZglLayout, node: ZglNode) ZglNode {
    const layout = layout_opt orelse return ZGL_NULL;
    const engine = layout.toPtrConst();

    if (node >= engine.element_count) return ZGL_NULL;

    const child = engine.first_child[node];
    return if (child == 0xFFFFFFFF) ZGL_NULL else child;
}

pub export fn zgl_layout_get_next_sibling(layout_opt: ?*const ZglLayout, node: ZglNode) ZglNode {
    const layout = layout_opt orelse return ZGL_NULL;
    const engine = layout.toPtrConst();

    if (node >= engine.element_count) return ZGL_NULL;

    const sibling = engine.next_sibling[node];
    return if (sibling == 0xFFFFFFFF) ZGL_NULL else sibling;
}

pub export fn zgl_layout_node_count(layout_opt: ?*const ZglLayout) u32 {
    const layout = layout_opt orelse return 0;
    const engine = layout.toPtrConst();
    return engine.element_count;
}

pub export fn zgl_layout_dirty_count(layout_opt: ?*const ZglLayout) u32 {
    const layout = layout_opt orelse return 0;
    const engine = layout.toPtrConst();
    return @intCast(engine.dirty_bits.dirtyCount());
}

pub export fn zgl_layout_cache_hit_rate(layout_opt: ?*const ZglLayout) f32 {
    const layout = layout_opt orelse return 0.0;
    const engine = layout.toPtrConst();
    return engine.cache_stats.getHitRate();
}

pub export fn zgl_layout_reset_stats(layout_opt: ?*ZglLayout) void {
    const layout = layout_opt orelse return;
    const engine = layout.toPtr();
    engine.cache_stats = .{};
}

// =============================================================================
// Layer 2: GUI Context API
// =============================================================================

pub const ZglGui = opaque {
    fn fromPtr(ptr: *gui_mod.GUI) *ZglGui {
        return @ptrCast(ptr);
    }

    fn toPtr(self: *ZglGui) *gui_mod.GUI {
        return @ptrCast(@alignCast(self));
    }

    fn toPtrConst(self: *const ZglGui) *const gui_mod.GUI {
        return @ptrCast(@alignCast(self));
    }
};

pub export fn zgl_gui_create(config: ?*const ZglGuiConfig) ?*ZglGui {
    const gui_config = if (config) |c| gui_mod.GUIConfig{
        .window_width = @intFromFloat(c.viewport_width),
        .window_height = @intFromFloat(c.viewport_height),
    } else gui_mod.GUIConfig{};

    const gui_ptr = gui_mod.GUI.init(std.heap.c_allocator, gui_config) catch {
        last_error = .out_of_memory;
        return null;
    };

    last_error = .ok;
    return ZglGui.fromPtr(gui_ptr);
}

pub export fn zgl_gui_destroy(gui_opt: ?*ZglGui) void {
    const gui = gui_opt orelse return;
    const gui_ptr = gui.toPtr();
    gui_ptr.deinit(); // deinit() already frees the GUI pointer
}

pub export fn zgl_gui_begin_frame(gui_opt: ?*ZglGui) void {
    const gui = gui_opt orelse return;
    const gui_ptr = gui.toPtr();
    gui_ptr.beginFrame() catch {};
}

pub export fn zgl_gui_end_frame(gui_opt: ?*ZglGui) void {
    const gui = gui_opt orelse return;
    const gui_ptr = gui.toPtr();
    gui_ptr.endFrame() catch {};
}

pub export fn zgl_gui_set_viewport(gui_opt: ?*ZglGui, width: f32, height: f32) void {
    const gui = gui_opt orelse return;
    const gui_ptr = gui.toPtr();
    gui_ptr.config.window_width = @intFromFloat(width);
    gui_ptr.config.window_height = @intFromFloat(height);
}

// --- Widget ID System ---

pub export fn zgl_id(label: [*:0]const u8) ZglId {
    const len = std.mem.len(label);
    return widget_id.WidgetId.runtime(label[0..len]).hash;
}

pub export fn zgl_id_index(label: [*:0]const u8, index: u32) ZglId {
    const base = zgl_id(label);
    return base ^ (index +% 1) *% 0x9e3779b9;
}

pub export fn zgl_id_combine(parent: ZglId, child: ZglId) ZglId {
    return parent ^ child;
}

pub export fn zgl_gui_push_id(gui_opt: ?*ZglGui, id: ZglId) void {
    const gui = gui_opt orelse return;
    const gui_ptr = gui.toPtr();
    gui_ptr.id_stack.pushHash(id);
}

pub export fn zgl_gui_pop_id(gui_opt: ?*ZglGui) void {
    const gui = gui_opt orelse return;
    const gui_ptr = gui.toPtr();
    gui_ptr.id_stack.pop();
}

// --- Widget Declaration ---

pub export fn zgl_gui_widget(gui_opt: ?*ZglGui, id: ZglId, style: ?*const ZglStyle) void {
    _ = gui_opt;
    _ = id;
    _ = style;
    // TODO: Generic widget implementation
}

pub export fn zgl_gui_begin(gui_opt: ?*ZglGui, id: ZglId, style: ?*const ZglStyle) void {
    _ = gui_opt;
    _ = id;
    _ = style;
    // TODO: Container begin implementation
}

pub export fn zgl_gui_end(gui_opt: ?*ZglGui) void {
    _ = gui_opt;
    // TODO: Container end implementation
}

// --- Queries ---

pub export fn zgl_gui_get_rect(gui_opt: ?*const ZglGui, id: ZglId) ZglRect {
    _ = gui_opt;
    _ = id;
    return ZglRect{ .x = 0, .y = 0, .width = 0, .height = 0 };
}

pub export fn zgl_gui_hit_test(gui_opt: ?*const ZglGui, id: ZglId, x: f32, y: f32) bool {
    _ = gui_opt;
    _ = id;
    _ = x;
    _ = y;
    return false;
}

// --- Input State ---

pub export fn zgl_gui_set_mouse(gui_opt: ?*ZglGui, x: f32, y: f32, down: bool) void {
    const gui = gui_opt orelse return;
    const gui_ptr = gui.toPtr();
    gui_ptr.setMousePosition(x, y);
    gui_ptr.setMouseButton(down);
}

pub export fn zgl_gui_clicked(gui_opt: ?*const ZglGui, id: ZglId) bool {
    const gui = gui_opt orelse return false;
    const gui_ptr = gui.toPtrConst();
    return gui_ptr.wasClickedId(id);
}

pub export fn zgl_gui_hovered(gui_opt: ?*const ZglGui, id: ZglId) bool {
    const gui = gui_opt orelse return false;
    const gui_ptr = gui.toPtrConst();
    return gui_ptr.isHoveredId(id);
}

pub export fn zgl_gui_pressed(gui_opt: ?*const ZglGui, id: ZglId) bool {
    const gui = gui_opt orelse return false;
    const gui_ptr = gui.toPtrConst();
    return gui_ptr.isPressedId(id);
}

// --- Direct Layout Access ---

pub export fn zgl_gui_get_layout(gui_opt: ?*ZglGui) ?*ZglLayout {
    _ = gui_opt;
    // TODO: Return underlying layout engine
    return null;
}

// =============================================================================
// Helper Functions
// =============================================================================

fn convertStyle(style: *const ZglStyle) flexbox.FlexStyle {
    return flexbox.FlexStyle{
        .direction = @enumFromInt(style.direction),
        .justify_content = @enumFromInt(style.justify),
        .align_items = @enumFromInt(style.align_),
        .flex_grow = style.flex_grow,
        .flex_shrink = style.flex_shrink,
        .width = style.width,
        .height = style.height,
        .min_width = style.min_width,
        .min_height = style.min_height,
        .max_width = style.max_width,
        .max_height = style.max_height,
        .gap = style.gap,
        .padding_top = style.padding_top,
        .padding_right = style.padding_right,
        .padding_bottom = style.padding_bottom,
        .padding_left = style.padding_left,
    };
}

// =============================================================================
// Comptime ABI Checks
// =============================================================================

comptime {
    // Verify struct sizes match C header expectations
    if (@sizeOf(ZglStyle) != 56) @compileError("ZglStyle ABI break: expected 56 bytes");
    if (@sizeOf(ZglRect) != 16) @compileError("ZglRect ABI break: expected 16 bytes");
}

// =============================================================================
// Tests
// =============================================================================

test "C API struct sizes" {
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(ZglStyle));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(ZglRect));
}

test "C API layout lifecycle" {
    const layout = zgl_layout_create(100);
    try std.testing.expect(layout != null);
    defer zgl_layout_destroy(layout);

    try std.testing.expectEqual(ZglError.ok, zgl_get_last_error());
}

test "C API add nodes" {
    const layout = zgl_layout_create(100).?;
    defer zgl_layout_destroy(layout);

    var style = ZglStyle{};
    style.width = 100;
    style.height = 50;

    const root = zgl_layout_add(layout, ZGL_NULL, &style);
    try std.testing.expect(root != ZGL_NULL);
    try std.testing.expectEqual(@as(u32, 1), zgl_layout_node_count(layout));

    const child = zgl_layout_add(layout, root, &style);
    try std.testing.expect(child != ZGL_NULL);
    try std.testing.expectEqual(@as(u32, 2), zgl_layout_node_count(layout));
}

test "C API compute layout" {
    const layout = zgl_layout_create(100).?;
    defer zgl_layout_destroy(layout);

    var style = ZglStyle{};
    style.width = 100;
    style.height = 50;

    const root = zgl_layout_add(layout, ZGL_NULL, &style);

    zgl_layout_compute(layout, 800, 600);

    const rect = zgl_layout_get_rect(layout, root);
    try std.testing.expectEqual(@as(f32, 100), rect.width);
    try std.testing.expectEqual(@as(f32, 50), rect.height);
}

test "C API widget ID" {
    const id1 = zgl_id("button");
    const id2 = zgl_id("button");
    const id3 = zgl_id("other");

    try std.testing.expectEqual(id1, id2);
    try std.testing.expect(id1 != id3);

    const indexed1 = zgl_id_index("item", 0);
    const indexed2 = zgl_id_index("item", 1);
    try std.testing.expect(indexed1 != indexed2);
}

test "C API GUI lifecycle" {
    const gui = zgl_gui_create(null);
    try std.testing.expect(gui != null);
    defer zgl_gui_destroy(gui);

    zgl_gui_begin_frame(gui);
    zgl_gui_end_frame(gui);
}
