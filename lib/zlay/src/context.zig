//! Data-Oriented Context API
//! Wraps the ultra-fast LayoutEngine with an immediate-mode interface
//! Designed for cache efficiency and minimal allocations

const std = @import("std");
const core = @import("core.zig");
const layout_engine = @import("layout_engine.zig");

const LayoutEngine = layout_engine.LayoutEngine;
const ElementId = layout_engine.ElementId;
const ElementType = layout_engine.ElementType;
const MAX_ELEMENTS = layout_engine.MAX_ELEMENTS;

// Re-export layout engine types as our canonical style types
pub const LayoutStyle = layout_engine.LayoutStyle;
pub const VisualStyle = layout_engine.VisualStyle;
pub const TextStyle = layout_engine.TextStyle;

/// The high-level context that provides immediate-mode UI API
/// while leveraging the data-oriented LayoutEngine underneath
pub const Context = struct {
    allocator: std.mem.Allocator,
    layout: *LayoutEngine,
    viewport: core.Size,
    scale_factor: f32,
    
    // Frame state
    frame_arena: std.heap.ArenaAllocator,
    frame_count: u64,
    delta_time: f32,
    
    // Input state (data-oriented!)
    mouse_pos: core.Point,
    mouse_buttons: packed struct {
        left: bool = false,
        middle: bool = false,
        right: bool = false,
        _padding: u5 = 0,
    },
    
    // Interaction state (indices into layout arrays)
    hovered_index: u32 = INVALID_INDEX,
    focused_index: u32 = INVALID_INDEX,
    pressed_index: u32 = INVALID_INDEX,
    
    // Immediate-mode stack for building UI
    parent_stack: [MAX_DEPTH]u32,
    parent_stack_depth: u8,
    
    // Performance tracking
    perf_stats: PerformanceStats,
    
    const INVALID_INDEX = std.math.maxInt(u32);
    const MAX_DEPTH = 64;
    
    pub const PerformanceStats = struct {
        layout_time_ns: u64 = 0,
        render_time_ns: u64 = 0,
        frame_time_ns: u64 = 0,
        elements_processed: u32 = 0,
        cache_hits: u32 = 0,
        cache_misses: u32 = 0,
        
        pub fn reset(self: *PerformanceStats) void {
            self.* = .{};
        }
        
        pub fn getFPS(self: PerformanceStats) f32 {
            if (self.frame_time_ns == 0) return 0;
            return 1_000_000_000.0 / @as(f32, @floatFromInt(self.frame_time_ns));
        }
    };
    
    /// Initialize a new Context with data-oriented layout engine
    pub fn init(allocator: std.mem.Allocator, viewport: core.Size) !*Context {
        const ctx = try allocator.create(Context);
        errdefer allocator.destroy(ctx);
        
        const layout = try LayoutEngine.init(allocator);
        errdefer layout.deinit(allocator);
        
        ctx.* = Context{
            .allocator = allocator,
            .layout = layout,
            .viewport = viewport,
            .scale_factor = 1.0,
            .frame_arena = std.heap.ArenaAllocator.init(allocator),
            .frame_count = 0,
            .delta_time = 0,
            .mouse_pos = .{},
            .mouse_buttons = .{},
            .parent_stack = undefined,
            .parent_stack_depth = 0,
            .perf_stats = .{},
        };
        
        return ctx;
    }
    
    pub fn deinit(self: *Context) void {
        self.frame_arena.deinit();
        self.layout.deinit();
        self.allocator.destroy(self);
    }
    
    /// Begin a new frame - resets temporary state
    pub fn beginFrame(self: *Context, delta_time: f32) !void {
        const frame_start = std.time.nanoTimestamp();
        
        self.delta_time = delta_time;
        self.frame_count += 1;
        
        // Reset frame arena for zero allocations per frame!
        _ = self.frame_arena.reset(.retain_capacity);
        
        // Clear layout engine for new frame
        self.layout.clear();
        
        // Reset immediate-mode state
        self.parent_stack_depth = 0;
        
        // Track frame timing
        if (self.frame_count > 1) {
            self.perf_stats.frame_time_ns = @intCast(frame_start - self.perf_stats.frame_time_ns);
        }
        self.perf_stats.frame_time_ns = @intCast(frame_start);
    }
    
    /// End frame - compute layout and prepare for rendering
    pub fn endFrame(self: *Context) !void {
        const layout_start = std.time.nanoTimestamp();
        
        // Compute layout with our data-oriented engine
        // TODO: Need to specify root element for layout computation
        if (self.layout.element_count > 0) {
            try self.layout.computeLayout(0, self.viewport); // Use first element as root
        }
        
        self.perf_stats.layout_time_ns = @intCast(std.time.nanoTimestamp() - layout_start);
        self.perf_stats.elements_processed = self.layout.element_count;
    }
    
    /// Push a parent element onto the stack
    pub fn pushParent(self: *Context, index: u32) !void {
        if (self.parent_stack_depth >= MAX_DEPTH) return error.StackOverflow;
        self.parent_stack[self.parent_stack_depth] = index;
        self.parent_stack_depth += 1;
    }
    
    /// Pop a parent element from the stack
    pub fn popParent(self: *Context) void {
        if (self.parent_stack_depth > 0) {
            self.parent_stack_depth -= 1;
        }
    }
    
    /// Get current parent index
    fn getCurrentParent(self: *Context) u32 {
        if (self.parent_stack_depth == 0) return INVALID_INDEX;
        return self.parent_stack[self.parent_stack_depth - 1];
    }
    
    // ====== Immediate-Mode UI API ======
    
    /// Begin a container element
    pub fn beginContainer(self: *Context, id: []const u8) !u32 {
        const hash = hashId(id);
        const index = try self.layout.createElement(.container, hash);
        
        // Set parent relationship if we have one
        const parent_index = self.getCurrentParent();
        if (parent_index != INVALID_INDEX) {
            try self.layout.setParent(index, parent_index);
        }
        
        try self.pushParent(index);
        return index;
    }
    
    /// End a container element
    pub fn endContainer(self: *Context) void {
        self.popParent();
    }
    
    /// Create a text element
    pub fn text(self: *Context, id: []const u8, content: []const u8) !u32 {
        const hash = hashId(id);
        const index = try self.layout.createElement(.text, hash);
        
        // Set parent relationship if we have one
        const parent_index = self.getCurrentParent();
        if (parent_index != INVALID_INDEX) {
            try self.layout.setParent(index, parent_index);
        }
        
        // Store text content and styling
        self.layout.setTextStyle(index, TextStyle{
            .text = content,
            .font_size = 16.0,
            .color = core.Color.rgba(0, 0, 0, 255),
        });
        
        // Set layout style for text
        self.layout.setLayoutStyle(index, LayoutStyle{
            .direction = .row,
            .main_axis_alignment = .start,
            .cross_axis_alignment = .start,
            .padding = core.EdgeInsets.all(4.0),
            .margin = core.EdgeInsets.all(2.0),
            .gap = 0.0,
            .min_width = 0.0,
            .max_width = std.math.inf(f32),
            .min_height = 20.0,
            .max_height = std.math.inf(f32),
        });
        
        return index;
    }
    
    /// Create a button and return if clicked
    pub fn button(self: *Context, id: []const u8, label: []const u8) !bool {
        const hash = hashId(id);
        const index = try self.layout.createElement(.button, hash);
        
        // Set parent relationship if we have one
        const parent_index = self.getCurrentParent();
        if (parent_index != INVALID_INDEX) {
            try self.layout.setParent(index, parent_index);
        }
        
        // Store button label in text style
        self.layout.setTextStyle(index, TextStyle{
            .text = label,
            .font_size = 14.0,
            .color = core.Color.rgba(0, 0, 0, 255),
        });
        
        // Set default button styles
        self.layout.setLayoutStyle(index, LayoutStyle{
            .direction = .row,
            .main_axis_alignment = .center,
            .cross_axis_alignment = .center,
            .padding = core.EdgeInsets.all(8.0),
            .margin = core.EdgeInsets.all(2.0),
            .gap = 0.0,
            .min_width = 80.0,
            .max_width = std.math.inf(f32),
            .min_height = 32.0,
            .max_height = 32.0,
        });
        
        self.layout.setVisualStyle(index, VisualStyle{
            .background_color = if (self.pressed_index == index) 
                core.Color.rgba(180, 180, 180, 255) 
            else if (self.hovered_index == index) 
                core.Color.rgba(220, 220, 220, 255)
            else 
                core.Color.rgba(240, 240, 240, 255),
            .border_color = core.Color.rgba(100, 100, 100, 255),
            .border_width = 1.0,
            .border_radius = 4.0,
        });
        
        // Button click detection for immediate-mode UI
        // We need to track if this specific button was clicked this frame
        var was_clicked = false;
        
        // Check if this button is currently being interacted with
        if (self.hovered_index == index) {
            // If mouse was just pressed on this button
            if (self.mouse_buttons.left and self.pressed_index == INVALID_INDEX) {
                self.pressed_index = index;
            }
            
            // If mouse was released and this button was pressed
            if (!self.mouse_buttons.left and self.pressed_index == index) {
                was_clicked = true;
                self.pressed_index = INVALID_INDEX;
            }
        }
        
        // Reset pressed state if mouse left the button or was released elsewhere
        if (self.pressed_index == index and (self.hovered_index != index or !self.mouse_buttons.left)) {
            self.pressed_index = INVALID_INDEX;
        }
        
        return was_clicked;
    }
    
    /// Set layout style for the last created element
    pub fn setLayoutStyle(self: *Context, layout_style: LayoutStyle) !void {
        if (self.layout.element_count == 0) return;
        const index = self.layout.element_count - 1;
        self.layout.setLayoutStyle(index, layout_style);
    }
    
    /// Set visual style for the last created element
    pub fn setVisualStyle(self: *Context, visual_style: VisualStyle) !void {
        if (self.layout.element_count == 0) return;
        const index = self.layout.element_count - 1;
        self.layout.setVisualStyle(index, visual_style);
    }
    
    /// Set text style for the last created element
    pub fn setTextStyle(self: *Context, text_style: TextStyle) !void {
        if (self.layout.element_count == 0) return;
        const index = self.layout.element_count - 1;
        self.layout.setTextStyle(index, text_style);
    }
    
    // ====== Input Handling (Data-Oriented) ======
    
    /// Update mouse position and hover state
    pub fn updateMousePos(self: *Context, pos: core.Point) void {
        self.mouse_pos = pos;
        
        // Hit test all elements (could be optimized with spatial partitioning)
        self.hovered_index = INVALID_INDEX;
        
        // Reverse iterate for top-to-bottom hit testing
        var i = self.layout.element_count;
        while (i > 0) {
            i -= 1;
            const rect = self.layout.computed_rects[i];
            if (rect.contains(pos)) {
                self.hovered_index = i;
                break;
            }
        }
    }
    
    /// Handle mouse button press
    pub fn handleMouseDown(self: *Context, mouse_button: MouseButton) void {
        switch (mouse_button) {
            .left => self.mouse_buttons.left = true,
            .middle => self.mouse_buttons.middle = true,
            .right => self.mouse_buttons.right = true,
        }
        
        if (mouse_button == .left and self.hovered_index != INVALID_INDEX) {
            self.pressed_index = self.hovered_index;
            self.focused_index = self.hovered_index;
        }
    }
    
    /// Handle mouse button release
    pub fn handleMouseUp(self: *Context, mouse_button: MouseButton) void {
        switch (mouse_button) {
            .left => self.mouse_buttons.left = false,
            .middle => self.mouse_buttons.middle = false,
            .right => self.mouse_buttons.right = false,
        }
    }
    
    // ====== Utilities ======
    
    /// Simple hash function for string IDs
    fn hashId(id: []const u8) ElementId {
        var hash: u32 = 0;
        for (id) |byte| {
            hash = hash *% 31 +% byte;
        }
        return hash;
    }
    
    /// Get performance statistics
    pub fn getPerformanceStats(self: *Context) PerformanceStats {
        return self.perf_stats;
    }
    
    /// Check if we need to redraw (for event-driven mode)
    pub fn needsRedraw(self: *Context) bool {
        // Check various dirty flags
        _ = self;
        // TODO: Implement dirty tracking
        return false;
    }
};

pub const MouseButton = enum {
    left,
    middle,
    right,
};

// Re-export core types for convenience
pub const Point = core.Point;
pub const Size = core.Size;
pub const Rect = core.Rect;
pub const Color = core.Color;