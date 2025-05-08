const std = @import("std");
const Element = @import("element.zig").Element;
const Style = @import("style.zig").Style;
const Renderer = @import("renderer.zig").Renderer;
const Layout = @import("layout.zig").Layout;
const Text = @import("text.zig");
const TextMeasurement = Text.TextMeasurement;
const DefaultTextMeasurement = Text.DefaultTextMeasurement;
const TextMeasurementCache = Text.TextMeasurementCache;
const Memory = @import("memory.zig");
const ElementPool = Memory.ElementPool;
const ArenaPool = Memory.ArenaPool;
const StringPool = Memory.StringPool;

/// Max number of elements in a layout
pub const MAX_ELEMENTS = 4096;

/// Layout cache entry
pub const LayoutCacheEntry = struct {
    width: f32,
    height: f32,
    hash: u64,
};

/// The main context for the zlay library.
/// Handles element management, layout calculation, and rendering.
pub const Context = struct {
    /// Memory allocator
    allocator: std.mem.Allocator,
    
    /// Arena pool for temporary allocations during layout
    arena_pool: ArenaPool,
    
    /// Element pool for efficient element allocation
    element_pool: ?ElementPool = null,
    
    /// String pool for interning element IDs
    string_pool: ?StringPool = null,
    
    /// Elements managed by this context
    elements: std.ArrayList(Element),
    
    /// Element stack for hierarchical layout
    element_stack: std.ArrayList(usize),
    
    /// Element ID to index mapping
    id_map: std.StringHashMap(usize),

    /// Children lookup for fast traversal
    /// Maps parent index to array of child indices
    children_map: std.AutoHashMap(usize, std.ArrayList(usize)),
    
    /// Renderer interface
    renderer: ?*Renderer = null,
    
    /// Text measurement interface
    text_measurement: ?*TextMeasurement = null,
    
    /// Text measurement cache for efficient text size calculations
    text_measurement_cache: ?*TextMeasurementCache = null,
    
    /// Default text measurement implementation
    default_text_measurement: ?DefaultTextMeasurement = null,
    
    /// Global style defaults
    default_style: Style = Style{},
    
    /// Layout cache for unchanged subtrees
    layout_cache: std.AutoHashMap(usize, LayoutCacheEntry),
    
    /// Element change detection
    element_hashes: std.ArrayList(u64),
    
    /// Mark if layout is dirty and needs recomputation
    layout_dirty: bool = true,
    
    /// Options for context creation
    pub const Options = struct {
        /// Enable element pooling
        use_element_pool: bool = false,
        
        /// Enable string interning
        use_string_pool: bool = false,
        
        /// Pre-allocate element pool size
        element_pool_size: usize = 128,
        
        /// Enable text measurement
        use_text_measurement: bool = true,
        
        /// Enable text measurement caching
        use_text_measurement_cache: bool = false,
    };

    /// Initialize a new context with default options
    pub fn init(allocator: std.mem.Allocator) !Context {
        return initWithOptions(allocator, .{});
    }
    
    /// Initialize a new context with custom options
    pub fn initWithOptions(allocator: std.mem.Allocator, options: Options) !Context {
        var ctx = Context{
            .allocator = allocator,
            .arena_pool = ArenaPool.init(allocator),
            .element_pool = null,
            .string_pool = null,
            .elements = try std.ArrayList(Element).initCapacity(allocator, 64),
            .element_stack = try std.ArrayList(usize).initCapacity(allocator, 32),
            .id_map = std.StringHashMap(usize).init(allocator),
            .children_map = std.AutoHashMap(usize, std.ArrayList(usize)).init(allocator),
            .layout_cache = std.AutoHashMap(usize, LayoutCacheEntry).init(allocator),
            .element_hashes = std.ArrayList(u64).init(allocator),
            .text_measurement = null,
            .text_measurement_cache = null,
            .default_text_measurement = null,
        };
        
        // Pre-allocate some elements to avoid reallocations in common cases
        try ctx.element_hashes.resize(64);
        
        // Set up memory pools if requested
        if (options.use_element_pool) {
            ctx.element_pool = ElementPool.init(allocator);
            try ctx.element_pool.?.reserve(options.element_pool_size);
        }
        
        if (options.use_string_pool) {
            ctx.string_pool = StringPool.init(allocator);
        }
        
        // Set up text measurement if requested
        if (options.use_text_measurement) {
            ctx.default_text_measurement = DefaultTextMeasurement.init();
            ctx.text_measurement = &ctx.default_text_measurement.?.measurement;
            
            if (options.use_text_measurement_cache) {
                try ctx.enableTextMeasurementCache();
            }
        }
        
        return ctx;
    }
    
    /// Initialize a new context with a custom text measurement
    pub fn initWithTextMeasurement(allocator: std.mem.Allocator, text_measurement: *TextMeasurement) !Context {
        var ctx = try init(allocator);
        ctx.text_measurement = text_measurement;
        return ctx;
    }

    /// Free all resources
    pub fn deinit(self: *Context) void {
        // Free children arrays in children map
        var it = self.children_map.valueIterator();
        while (it.next()) |children| {
            children.deinit();
        }
        
        // Free text measurement cache if we own it
        if (self.text_measurement_cache != null) {
            self.text_measurement_cache.?.deinit();
            self.text_measurement_cache = null;
        }
        
        // Free memory pools
        if (self.element_pool != null) {
            self.element_pool.?.deinit();
            self.element_pool = null;
        }
        
        if (self.string_pool != null) {
            self.string_pool.?.deinit();
            self.string_pool = null;
        }
        
        self.element_hashes.deinit();
        self.layout_cache.deinit();
        self.children_map.deinit();
        self.elements.deinit();
        self.element_stack.deinit();
        self.id_map.deinit();
        self.arena_pool.deinit();
    }

    /// Begin a new frame, clearing previous state
    pub fn beginFrame(self: *Context) !void {
        _ = self.arena_pool.reset();
        
        // Clear but retain capacity for better performance
        try self.elements.resize(0);
        try self.element_stack.resize(0);
        self.id_map.clearRetainingCapacity();
        
        // Clear children map but retain entries
        var it = self.children_map.valueIterator();
        while (it.next()) |children| {
            children.clearRetainingCapacity();
        }
        
        // Make sure element hashes has enough capacity
        if (self.element_hashes.capacity < self.elements.capacity) {
            try self.element_hashes.resize(self.elements.capacity);
        } else {
            try self.element_hashes.resize(0);
        }
        
        // Clear layout cache
        self.layout_cache.clearRetainingCapacity();
        
        // Reset element pool stats
        if (self.element_pool != null) {
            self.element_pool.?.resetStats();
        }
        
        // Mark layout as dirty
        self.layout_dirty = true;
    }

    /// Begin a new element
    pub fn beginElement(self: *Context, element_type: Element.Type, id: ?[]const u8) !usize {
        const element_index = self.elements.items.len;
        
        // Ensure element_hashes has enough space
        if (element_index >= self.element_hashes.items.len) {
            try self.element_hashes.resize(element_index + 1);
        }
        
        // Get parent if exists
        const parent = if (self.element_stack.items.len > 0) 
            self.element_stack.items[self.element_stack.items.len - 1] else null;
        
        // Create the element
        const arena_allocator = self.arena_pool.allocator();
        var element: Element = undefined;
        
        if (self.element_pool) |*pool| {
            // Use element pool for memory management
            const element_ptr = try pool.acquire();
            element_ptr.type = element_type;
            element_ptr.style = self.default_style;
            element_ptr.children = std.ArrayList(usize).init(arena_allocator);
            element_ptr.parent = parent;
            
            // Handle ID with string pool if available
            if (id) |i| {
                element_ptr.id = if (self.string_pool) |*str_pool|
                    try str_pool.intern(i)
                else
                    try arena_allocator.dupe(u8, i);
            }
            
            // Store the element
            element = element_ptr.*;
        } else {
            // Create element directly - used mostly for tests
            element = Element{
                .type = element_type,
                .id = if (id) |i| try arena_allocator.dupe(u8, i) else null,
                .parent = parent,
                .style = self.default_style,
                .children = std.ArrayList(usize).init(arena_allocator),
            };
        }
        
        // Add to elements array
        try self.elements.append(element);
        
        // Add to element stack
        try self.element_stack.append(element_index);
        
        // Add to ID map if ID provided
        if (id) |i| {
            try self.id_map.put(i, element_index);
        }
        
        // Update parent's children if parent exists
        if (parent) |p| {
            // Get or create the children array for this parent
            var children = if (self.children_map.get(p)) |ch| ch else blk: {
                const new_children = std.ArrayList(usize).init(self.allocator);
                try self.children_map.put(p, new_children);
                break :blk new_children;
            };
            
            // Add this element as a child
            try children.append(element_index);
            try self.children_map.put(p, children);
            
            // Add child to parent's children list
            if (self.elements.items[p].children.capacity == 0) {
                self.elements.items[p].children = std.ArrayList(usize).init(arena_allocator);
            }
            try self.elements.items[p].children.append(element_index);
        }
        
        // Compute element hash for change detection
        const hash = computeElementHash(&element);
        self.element_hashes.items[element_index] = hash;
        
        // Mark layout as dirty
        self.layout_dirty = true;
        
        return element_index;
    }

    /// End the current element
    pub fn endElement(self: *Context) !void {
        if (self.element_stack.items.len == 0) {
            return error.ElementStackEmpty;
        }
        
        _ = self.element_stack.pop();
    }

    /// Get an element by its ID
    pub fn getElementById(self: *Context, id: []const u8) ?*Element {
        if (self.id_map.get(id)) |index| {
            return &self.elements.items[index];
        }
        return null;
    }
    
    /// Get all children of an element
    pub fn getChildren(self: *Context, element_idx: usize) ?[]const usize {
        if (element_idx >= self.elements.items.len) {
            return null;
        }
        
        if (self.elements.items[element_idx].children.items.len > 0) {
            return self.elements.items[element_idx].children.items;
        }
        
        return null;
    }

    /// Compute layout for all elements
    pub fn computeLayout(self: *Context, width: f32, height: f32) !void {
        // Skip if layout is not dirty and dimensions are the same
        if (!self.layout_dirty) {
            return;
        }
        
        // Find root elements (elements with no parent)
        var root_indices = std.ArrayList(usize).init(self.arena_pool.allocator());
        defer root_indices.deinit();
        
        for (self.elements.items, 0..) |element, i| {
            if (element.parent == null) {
                try root_indices.append(i);
            }
        }
        
        // Compute layout for each root element
        for (root_indices.items) |root_idx| {
            var element = &self.elements.items[root_idx];
            element.width = width;
            element.height = height;
            
            // Use our advanced layout algorithm
            const LayoutAlgorithm = @import("layout_algorithm.zig").LayoutAlgorithm;
            try LayoutAlgorithm.layoutContainer(self, root_idx, width, height);
        }
        
        // Mark layout as clean
        self.layout_dirty = false;
    }

    /// Render all elements using the attached renderer
    pub fn render(self: *Context) !void {
        if (self.renderer == null) {
            return error.NoRendererAttached;
        }
        
        const renderer = self.renderer.?;
        
        // Begin frame
        renderer.beginFrame();
        
        // Render all elements
        try self.renderElement(self.getTopLevelElements(), renderer);
        
        // End frame
        renderer.endFrame();
    }
    
    /// Render an element and its children
    fn renderElement(self: *Context, elements: []const usize, renderer: *Renderer) !void {
        // Render elements in order (depth-first)
        for (elements) |element_idx| {
            const element = &self.elements.items[element_idx];
            
            // Skip if not visible or culled (outside the visible area of a scrollable container)
            if (!element.visible or element.isCulled()) {
                continue;
            }
            
            // Apply clip if needed (for style.clip or scrollable elements)
            var clipped = false;
            if (element.style.clip or element.overflow_x != .visible or element.overflow_y != .visible) {
                renderer.clipBegin(element.x, element.y, element.width, element.height);
                clipped = true;
            }
            
            // Render background if present
            if (element.style.background_color) |color| {
                if (element.style.corner_radius > 0) {
                    renderer.drawRoundedRect(
                        element.x, element.y, element.width, element.height, 
                        element.style.corner_radius, color
                    );
                } else {
                    renderer.drawRect(element.x, element.y, element.width, element.height, color);
                }
            }
            
            // Render border if present
            if (element.style.border_color != null and element.style.border_width > 0) {
                // Border rendering would go here
            }
            
            // Render text if present
            if (element.text) |text| {
                const text_color = element.style.text_color orelse Style.defaultTextColor;
                
                // Simple centered text rendering
                renderer.drawText(
                    text, 
                    element.x + element.width / 2, 
                    element.y + element.height / 2, 
                    element.style.font_size, 
                    text_color
                );
            }
            
            // Render children
            if (self.getChildren(element_idx)) |children| {
                try self.renderElement(children, renderer);
            }
            
            // End clip if applied
            if (clipped) {
                renderer.clipEnd();
            }
        }
    }
    
    /// Get top-level elements (elements with no parent)
    fn getTopLevelElements(self: *Context) []const usize {
        var result = std.ArrayList(usize).init(self.arena_pool.allocator());
        
        for (self.elements.items, 0..) |element, i| {
            if (element.parent == null) {
                result.append(i) catch continue;
            }
        }
        
        return result.items;
    }
    
    /// Set the renderer to use
    pub fn setRenderer(self: *Context, renderer: *Renderer) void {
        self.renderer = renderer;
    }
    
    /// Set the text measurement to use
    pub fn setTextMeasurement(self: *Context, text_measurement: *TextMeasurement) void {
        self.text_measurement = text_measurement;
        
        // Clear existing cache if we have one
        if (self.text_measurement_cache != null) {
            self.text_measurement_cache.?.deinit();
            self.text_measurement_cache = null;
        }
    }
    
    /// Enable text measurement caching
    pub fn enableTextMeasurementCache(self: *Context) !void {
        if (self.text_measurement_cache != null) {
            return; // Already enabled
        }
        
        if (self.text_measurement == null) {
            return error.NoTextMeasurement;
        }
        
        const cache = try self.allocator.create(TextMeasurementCache);
        cache.* = TextMeasurementCache.init(self.allocator, self.text_measurement.?);
        self.text_measurement_cache = cache;
    }
    
    /// Measure text using the current text measurement
    pub fn measureText(
        self: *Context, 
        text: []const u8, 
        font_name: ?[]const u8, 
        font_size: f32
    ) !Text.TextSize {
        if (self.text_measurement == null) {
            // Fallback approximation when no text measurement is available
            const approx_width = @as(f32, @floatFromInt(text.len)) * 8.0; // rough approximation
            const approx_height = font_size * 1.2; // rough approximation
            return Text.TextSize.init(approx_width, approx_height);
        }
        
        // Use cached measurement if available
        if (self.text_measurement_cache != null) {
            return self.text_measurement_cache.?.measureText(text, font_name, font_size);
        }
        
        // Direct measurement
        return self.text_measurement.?.measureText(text, font_name, font_size);
    }
    
    /// Measure multiline text using the current text measurement
    pub fn measureMultilineText(
        self: *Context, 
        text: []const u8, 
        font_name: ?[]const u8, 
        font_size: f32,
        line_height: f32
    ) !Text.TextSize {
        if (self.text_measurement == null) {
            // Fallback approximation when no text measurement is available
            // Count the number of lines
            var line_count: usize = 1;
            for (text) |c| {
                if (c == '\n') line_count += 1;
            }
            
            // Determine average line length to estimate width
            const avg_line_len = @as(f32, @floatFromInt(text.len)) / @as(f32, @floatFromInt(line_count));
            const approx_width = avg_line_len * 8.0; // rough approximation
            const approx_height = font_size * 1.2 * @as(f32, @floatFromInt(line_count)); // rough approximation
            
            return Text.TextSize.init(approx_width, approx_height);
        }
        
        // Use cached measurement if available
        if (self.text_measurement_cache != null) {
            return self.text_measurement_cache.?.measureMultilineText(
                text, font_name, font_size, line_height
            );
        }
        
        // Direct measurement
        return self.text_measurement.?.measureMultilineText(
            text, font_name, font_size, line_height
        );
    }
    
    /// Compute a hash for an element to detect changes
    fn computeElementHash(element: *const Element) u64 {
        var hasher = std.hash.Wyhash.init(0);
        
        // Hash basic properties
        hasher.update(&std.mem.toBytes(@intFromEnum(element.type)));
        
        if (element.id) |id| {
            hasher.update(id);
        }
        
        hasher.update(&std.mem.toBytes(element.visible));
        hasher.update(&std.mem.toBytes(element.enabled));
        
        if (element.text) |text| {
            hasher.update(text);
        }
        
        // Hash style properties that affect layout
        hasher.update(&std.mem.toBytes(@as(u32, @intFromFloat(element.style.padding_left * 100))));
        hasher.update(&std.mem.toBytes(@as(u32, @intFromFloat(element.style.padding_right * 100))));
        hasher.update(&std.mem.toBytes(@as(u32, @intFromFloat(element.style.padding_top * 100))));
        hasher.update(&std.mem.toBytes(@as(u32, @intFromFloat(element.style.padding_bottom * 100))));
        
        hasher.update(&std.mem.toBytes(@as(u32, @intFromFloat(element.style.margin_left * 100))));
        hasher.update(&std.mem.toBytes(@as(u32, @intFromFloat(element.style.margin_right * 100))));
        hasher.update(&std.mem.toBytes(@as(u32, @intFromFloat(element.style.margin_top * 100))));
        hasher.update(&std.mem.toBytes(@as(u32, @intFromFloat(element.style.margin_bottom * 100))));
        
        hasher.update(&std.mem.toBytes(@as(u32, @intFromFloat(element.style.flex_grow * 100))));
        hasher.update(&std.mem.toBytes(@as(u32, @intFromFloat(element.style.flex_shrink * 100))));
        
        if (element.style.flex_basis) |basis| {
            hasher.update(&std.mem.toBytes(@as(u32, @intFromFloat(basis * 100))));
        }
        
        hasher.update(&std.mem.toBytes(@intFromEnum(element.style.align_h)));
        hasher.update(&std.mem.toBytes(@intFromEnum(element.style.align_v)));
        
        // Hash size constraints
        if (element.min_width) |w| hasher.update(&std.mem.toBytes(@as(u32, @intFromFloat(w * 100))));
        if (element.min_height) |h| hasher.update(&std.mem.toBytes(@as(u32, @intFromFloat(h * 100))));
        if (element.max_width) |w| hasher.update(&std.mem.toBytes(@as(u32, @intFromFloat(w * 100))));
        if (element.max_height) |h| hasher.update(&std.mem.toBytes(@as(u32, @intFromFloat(h * 100))));
        
        return hasher.final();
    }
};

test "context basics" {
    var ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();
    
    try ctx.beginFrame();
    const root_index = try ctx.beginElement(.container, "root");
    const child_index = try ctx.beginElement(.box, "child");
    try ctx.endElement(); // end child
    try ctx.endElement(); // end root
    
    try std.testing.expectEqual(@as(usize, 0), root_index);
    try std.testing.expectEqual(@as(usize, 1), child_index);
    try std.testing.expectEqual(@as(?usize, 0), ctx.elements.items[child_index].parent);
    
    // Verify children relationship
    if (ctx.getChildren(root_index)) |children| {
        try std.testing.expectEqual(@as(usize, 1), children.len);
        try std.testing.expectEqual(child_index, children[0]);
    } else {
        try std.testing.expect(false);
    }
}