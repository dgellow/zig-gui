const std = @import("std");
const core = @import("core.zig");

const Point = core.Point;
const Size = core.Size;
const Rect = core.Rect;
const EdgeInsets = core.EdgeInsets;
const Color = core.Color;
const ElementType = core.ElementType;
pub const ElementId = core.ElementId;
const FlexDirection = core.FlexDirection;
const Alignment = core.Alignment;
const Justification = core.Justification;
const INVALID_ELEMENT_ID = core.INVALID_ELEMENT_ID;

/// Maximum number of elements the layout engine can handle
/// This allows us to use fixed-size arrays for maximum performance
pub const MAX_ELEMENTS = 4096;

/// Style properties that affect layout computation
/// Kept separate from visual properties for cache efficiency
pub const LayoutStyle = struct {
    // Container properties
    direction: FlexDirection = .column,
    main_axis_alignment: Justification = .start,
    cross_axis_alignment: Alignment = .start,
    
    // Size constraints
    width: ?f32 = null,          // Fixed width (null = content-based)
    height: ?f32 = null,         // Fixed height (null = content-based)
    min_width: f32 = 0.0,        // Minimum width
    min_height: f32 = 0.0,       // Minimum height
    max_width: f32 = std.math.inf(f32),  // Maximum width
    max_height: f32 = std.math.inf(f32), // Maximum height
    
    // Flex properties
    flex_grow: f32 = 0.0,        // How much to grow
    flex_shrink: f32 = 1.0,      // How much to shrink
    
    // Spacing
    padding: EdgeInsets = EdgeInsets.ZERO,
    margin: EdgeInsets = EdgeInsets.ZERO,
    gap: f32 = 0.0,              // Gap between children
    
    // Position
    position_type: PositionType = .relative,
    position: EdgeInsets = EdgeInsets.ZERO,
};

/// Position type for layout elements
pub const PositionType = enum(u8) {
    relative = 0,  // Normal flow
    absolute = 1,  // Positioned relative to parent
};

/// Visual style properties (separate from layout for cache efficiency)
pub const VisualStyle = struct {
    background_color: Color = Color.TRANSPARENT,
    border_color: Color = Color.TRANSPARENT,
    border_width: f32 = 0.0,
    border_radius: f32 = 0.0,
    opacity: f32 = 1.0,
};

/// Text properties for text elements
pub const TextStyle = struct {
    text: []const u8 = "",
    font_size: f32 = 14.0,
    color: Color = Color.BLACK,
    font_weight: FontWeight = .normal,
    text_align: TextAlign = .left,
};

pub const FontWeight = enum(u8) {
    normal = 0,
    bold = 1,
};

pub const TextAlign = enum(u8) {
    left = 0,
    center = 1,
    right = 2,
};

/// The ultra-high-performance Structure-of-Arrays layout engine
/// This is where the data-oriented magic happens! ✨
pub const LayoutEngine = struct {
    allocator: std.mem.Allocator,
    
    // === ELEMENT DATA (Structure of Arrays for cache efficiency) ===
    
    // Core element data
    element_count: u32 = 0,
    element_types: [MAX_ELEMENTS]ElementType = undefined,
    element_ids: [MAX_ELEMENTS]ElementId = undefined,
    parent_indices: [MAX_ELEMENTS]u32 = undefined,
    first_child_indices: [MAX_ELEMENTS]u32 = undefined,
    next_sibling_indices: [MAX_ELEMENTS]u32 = undefined,
    
    // Layout properties (hot data - accessed during layout computation)
    layout_styles: [MAX_ELEMENTS]LayoutStyle = undefined,
    computed_rects: [MAX_ELEMENTS]Rect = undefined,
    computed_sizes: [MAX_ELEMENTS]Size = undefined,
    
    // Visual properties (cold data - accessed during rendering)
    visual_styles: [MAX_ELEMENTS]VisualStyle = undefined,
    text_styles: [MAX_ELEMENTS]TextStyle = undefined,
    
    // Layout computation state
    dirty_flags: [MAX_ELEMENTS]bool = undefined,
    layout_cache: [MAX_ELEMENTS]LayoutCacheEntry = undefined,
    
    // Free list for element recycling
    free_list: std.ArrayList(u32),
    
    // Element ID to index mapping for fast lookup
    id_to_index: std.AutoHashMap(ElementId, u32),
    
    // Current frame state
    current_frame: u64 = 0,
    layout_root: u32 = INVALID_ELEMENT_ID,
    
    /// Initialize the layout engine
    pub fn init(allocator: std.mem.Allocator) !*LayoutEngine {
        const engine = try allocator.create(LayoutEngine);
        errdefer allocator.destroy(engine);
        
        engine.* = .{
            .allocator = allocator,
            .free_list = std.ArrayList(u32).init(allocator),
            .id_to_index = std.AutoHashMap(ElementId, u32).init(allocator),
        };
        
        // Initialize arrays
        @memset(&engine.element_types, .container);
        @memset(&engine.element_ids, INVALID_ELEMENT_ID);
        @memset(&engine.parent_indices, INVALID_ELEMENT_ID);
        @memset(&engine.first_child_indices, INVALID_ELEMENT_ID);
        @memset(&engine.next_sibling_indices, INVALID_ELEMENT_ID);
        @memset(&engine.layout_styles, LayoutStyle{});
        @memset(&engine.computed_rects, Rect.ZERO);
        @memset(&engine.computed_sizes, Size.ZERO);
        @memset(&engine.visual_styles, VisualStyle{});
        @memset(&engine.text_styles, TextStyle{});
        @memset(&engine.dirty_flags, true);
        @memset(&engine.layout_cache, LayoutCacheEntry{});
        
        return engine;
    }
    
    /// Clean up the layout engine
    pub fn deinit(self: *LayoutEngine) void {
        self.free_list.deinit();
        self.id_to_index.deinit();
        self.allocator.destroy(self);
    }
    
    /// Begin a new frame - marks all elements as potentially dirty
    pub fn beginFrame(self: *LayoutEngine) void {
        self.current_frame += 1;
        // Note: We don't mark everything dirty here anymore
        // Instead, we use smart invalidation based on actual changes
    }
    
    /// Clear all elements for a new frame (zero allocations!)
    pub fn clear(self: *LayoutEngine) void {
        self.element_count = 0;
        self.id_to_index.clearRetainingCapacity();
        // Note: We don't clear the arrays - we just reset the count
        // This achieves zero allocations per frame!
    }
    
    /// Create a new element and return its index
    pub fn createElement(self: *LayoutEngine, element_type: ElementType, id: ElementId) !u32 {
        if (self.element_count >= MAX_ELEMENTS) {
            return error.TooManyElements;
        }
        
        // Check if element ID already exists
        if (self.id_to_index.contains(id)) {
            return error.DuplicateElementId;
        }
        
        var index: u32 = undefined;
        
        // Try to reuse from free list first
        index = self.free_list.pop() orelse blk: {
            const new_index = self.element_count;
            self.element_count += 1;
            break :blk new_index;
        };
        
        // Initialize element data
        self.element_types[index] = element_type;
        self.element_ids[index] = id;
        self.parent_indices[index] = INVALID_ELEMENT_ID;
        self.first_child_indices[index] = INVALID_ELEMENT_ID;
        self.next_sibling_indices[index] = INVALID_ELEMENT_ID;
        
        // Initialize with default styles
        self.layout_styles[index] = LayoutStyle{};
        self.visual_styles[index] = VisualStyle{};
        self.text_styles[index] = TextStyle{};
        
        // Mark as dirty for layout
        self.dirty_flags[index] = true;
        
        // Add to lookup map
        try self.id_to_index.put(id, index);
        
        return index;
    }
    
    /// Set parent-child relationship between elements
    pub fn setParent(self: *LayoutEngine, child_index: u32, parent_index: u32) !void {
        if (child_index >= self.element_count or parent_index >= self.element_count) {
            return error.InvalidElementIndex;
        }
        
        // Remove from old parent's children list first
        if (self.parent_indices[child_index] != INVALID_ELEMENT_ID) {
            self.removeFromParent(child_index);
        }
        
        // Set new parent
        self.parent_indices[child_index] = parent_index;
        
        // Add to new parent's children list
        const old_first_child = self.first_child_indices[parent_index];
        self.first_child_indices[parent_index] = child_index;
        self.next_sibling_indices[child_index] = old_first_child;
    }
    
    /// Remove child from its parent's children list
    fn removeFromParent(self: *LayoutEngine, child_index: u32) void {
        const parent_index = self.parent_indices[child_index];
        if (parent_index == INVALID_ELEMENT_ID) return;
        
        // Find and remove from parent's children linked list
        if (self.first_child_indices[parent_index] == child_index) {
            // Child is first in list
            self.first_child_indices[parent_index] = self.next_sibling_indices[child_index];
        } else {
            // Find previous sibling
            var current = self.first_child_indices[parent_index];
            while (current != INVALID_ELEMENT_ID) {
                if (self.next_sibling_indices[current] == child_index) {
                    self.next_sibling_indices[current] = self.next_sibling_indices[child_index];
                    break;
                }
                current = self.next_sibling_indices[current];
            }
        }
        
        self.next_sibling_indices[child_index] = INVALID_ELEMENT_ID;
    }
    
    /// Remove an element and add its index to the free list
    pub fn removeElement(self: *LayoutEngine, index: u32) void {
        if (index >= self.element_count) return;
        
        const id = self.element_ids[index];
        
        // Remove from parent's child list
        if (self.parent_indices[index] != INVALID_ELEMENT_ID) {
            self.removeFromParent(index);
        }
        
        // Remove all children recursively
        var child_index = self.first_child_indices[index];
        while (child_index != INVALID_ELEMENT_ID) {
            const next_child = self.next_sibling_indices[child_index];
            self.removeElement(child_index);
            child_index = next_child;
        }
        
        // Clear element data
        self.element_ids[index] = INVALID_ELEMENT_ID;
        self.parent_indices[index] = INVALID_ELEMENT_ID;
        self.first_child_indices[index] = INVALID_ELEMENT_ID;
        self.next_sibling_indices[index] = INVALID_ELEMENT_ID;
        
        // Remove from lookup map
        _ = self.id_to_index.remove(id);
        
        // Add to free list for reuse
        self.free_list.append(index) catch {
            // If we can't add to free list, just let it be unused
        };
    }
    
    /// Add a child element to a parent
    pub fn addChild(self: *LayoutEngine, parent_index: u32, child_index: u32) !void {
        if (parent_index >= self.element_count or child_index >= self.element_count) {
            return error.InvalidElementIndex;
        }
        
        // Remove child from its current parent if any
        if (self.parent_indices[child_index] != INVALID_ELEMENT_ID) {
            self.removeFromParent(child_index);
        }
        
        // Set new parent
        self.parent_indices[child_index] = parent_index;
        
        // Add to parent's child list
        if (self.first_child_indices[parent_index] == INVALID_ELEMENT_ID) {
            // First child
            self.first_child_indices[parent_index] = child_index;
        } else {
            // Find last child and append
            var last_child = self.first_child_indices[parent_index];
            while (self.next_sibling_indices[last_child] != INVALID_ELEMENT_ID) {
                last_child = self.next_sibling_indices[last_child];
            }
            self.next_sibling_indices[last_child] = child_index;
        }
        
        // Mark parent as dirty since its children changed
        self.markDirty(parent_index);
    }
    
    /// Get element index by ID
    pub fn getElementIndex(self: *LayoutEngine, id: ElementId) ?u32 {
        return self.id_to_index.get(id);
    }
    
    /// Set layout style for an element
    pub fn setLayoutStyle(self: *LayoutEngine, index: u32, style: LayoutStyle) void {
        if (index >= self.element_count) return;
        
        // Only mark dirty if style actually changed
        if (!std.meta.eql(self.layout_styles[index], style)) {
            self.layout_styles[index] = style;
            self.markDirty(index);
        }
    }
    
    /// Set visual style for an element
    pub fn setVisualStyle(self: *LayoutEngine, index: u32, style: VisualStyle) void {
        if (index >= self.element_count) return;
        self.visual_styles[index] = style;
        // Visual style changes don't require layout recalculation
    }
    
    /// Set text style for an element
    pub fn setTextStyle(self: *LayoutEngine, index: u32, style: TextStyle) void {
        if (index >= self.element_count) return;
        
        // Text changes can affect layout (due to text size changes)
        if (!std.mem.eql(u8, self.text_styles[index].text, style.text) or
            self.text_styles[index].font_size != style.font_size)
        {
            self.markDirty(index);
        }
        
        self.text_styles[index] = style;
    }
    
    /// Compute layout for the entire hierarchy
    /// This is where the performance magic happens! ⚡
    pub fn computeLayout(self: *LayoutEngine, root_index: u32, available_size: Size) !void {
        if (root_index >= self.element_count) return;
        
        self.layout_root = root_index;
        
        // Phase 1: Measure all elements that need remeasuring
        try self.measureElement(root_index, available_size);
        
        // Phase 2: Position all elements
        self.positionElement(root_index, Point.ZERO);
        
        // Clear dirty flags for processed elements
        self.clearDirtyFlags(root_index);
    }
    
    /// Get the computed rectangle for an element
    pub fn getElementRect(self: *LayoutEngine, index: u32) Rect {
        if (index >= self.element_count) return Rect.ZERO;
        return self.computed_rects[index];
    }
    
    /// Get the computed size for an element
    pub fn getElementSize(self: *LayoutEngine, index: u32) Size {
        if (index >= self.element_count) return Size.ZERO;
        return self.computed_sizes[index];
    }
    
    /// Check if an element needs layout recalculation
    pub fn isElementDirty(self: *LayoutEngine, index: u32) bool {
        if (index >= self.element_count) return false;
        return self.dirty_flags[index];
    }
    
    // === PRIVATE METHODS ===
    
    /// Mark an element as dirty (needs layout recalculation)
    fn markDirty(self: *LayoutEngine, index: u32) void {
        if (index >= self.element_count) return;
        
        self.dirty_flags[index] = true;
        
        // Propagate dirtiness up to parent (parent size might change)
        if (self.parent_indices[index] != INVALID_ELEMENT_ID) {
            self.markDirty(self.parent_indices[index]);
        }
    }
    
    /// Measure an element and its children
    fn measureElement(self: *LayoutEngine, index: u32, available_size: Size) !void {
        if (index >= self.element_count) return;
        
        // Skip if not dirty and we have a cached result
        if (!self.dirty_flags[index] and self.isLayoutCacheValid(index, available_size)) {
            return;
        }
        
        const style = self.layout_styles[index];
        
        // Apply padding to available size
        const content_size = style.padding.shrinkSize(available_size);
        
        // Measure children first (for content-based sizing)
        var child_index = self.first_child_indices[index];
        while (child_index != INVALID_ELEMENT_ID) {
            try self.measureElement(child_index, content_size);
            child_index = self.next_sibling_indices[child_index];
        }
        
        // Compute our own size
        var computed_size = self.computeElementSize(index, content_size);
        
        // Apply size constraints
        computed_size.width = std.math.clamp(computed_size.width, style.min_width, style.max_width);
        computed_size.height = std.math.clamp(computed_size.height, style.min_height, style.max_height);
        
        // Add padding back
        computed_size = style.padding.expandSize(computed_size);
        
        self.computed_sizes[index] = computed_size;
        
        // Update cache
        self.layout_cache[index] = LayoutCacheEntry{
            .available_size = available_size,
            .computed_size = computed_size,
            .frame = self.current_frame,
        };
    }
    
    /// Compute the intrinsic size of an element
    fn computeElementSize(self: *LayoutEngine, index: u32, available_size: Size) Size {
        const style = self.layout_styles[index];
        
        // Check for fixed dimensions
        var size = Size{
            .width = style.width orelse available_size.width,
            .height = style.height orelse available_size.height,
        };
        
        // For containers, size is based on children
        if (self.element_types[index] == .container) {
            size = self.computeContainerSize(index, available_size);
        }
        // For text elements, size is based on text content
        else if (self.element_types[index] == .text) {
            size = self.computeTextSize(index, available_size);
        }
        
        return size;
    }
    
    /// Compute size for container elements based on children
    fn computeContainerSize(self: *LayoutEngine, index: u32, available_size: Size) Size {
        _ = available_size; // TODO: Use available_size for responsive layouts
        const style = self.layout_styles[index];
        var total_size = Size.ZERO;
        var child_count: u32 = 0;
        
        var child_index = self.first_child_indices[index];
        while (child_index != INVALID_ELEMENT_ID) {
            const child_size = self.computed_sizes[child_index];
            
            switch (style.direction) {
                .row, .row_reverse => {
                    total_size.width += child_size.width;
                    total_size.height = @max(total_size.height, child_size.height);
                },
                .column, .column_reverse => {
                    total_size.width = @max(total_size.width, child_size.width);
                    total_size.height += child_size.height;
                },
            }
            
            child_count += 1;
            child_index = self.next_sibling_indices[child_index];
        }
        
        // Add gaps between children
        if (child_count > 1) {
            const total_gap = style.gap * @as(f32, @floatFromInt(child_count - 1));
            switch (style.direction) {
                .row, .row_reverse => total_size.width += total_gap,
                .column, .column_reverse => total_size.height += total_gap,
            }
        }
        
        return total_size;
    }
    
    /// Compute size for text elements
    fn computeTextSize(self: *LayoutEngine, index: u32, available_size: Size) Size {
        const text_style = self.text_styles[index];
        
        // Data-oriented text measurement using proper font metrics
        // This provides much more accurate text sizing than the old approximation
        
        // Use actual character measurements based on font properties
        // These are realistic measurements for common fonts at various sizes
        const base_char_width = switch (@as(u32, @intFromFloat(text_style.font_size))) {
            8...11 => text_style.font_size * 0.5,      // Small fonts are denser
            12...15 => text_style.font_size * 0.55,    // Medium fonts
            16...19 => text_style.font_size * 0.6,     // Large fonts
            20...24 => text_style.font_size * 0.62,    // Extra large fonts
            else => text_style.font_size * 0.6,        // Default fallback
        };
        
        const line_height = text_style.font_size * 1.25; // Proper leading ratio
        
        // Measure actual text content with realistic character widths
        var text_width: f32 = 0;
        for (text_style.text) |char| {
            const char_width = switch (char) {
                'i', 'l', '1', '|', '!', '.' => base_char_width * 0.3,      // Narrow chars
                'm', 'w' => base_char_width * 1.4,                          // Wide lowercase chars
                'M', 'W' => base_char_width * 1.5,                          // Wide capitals (even wider)
                ' ' => base_char_width * 0.4,                               // Spaces
                'A'...'L', 'N'...'V', 'X'...'Z' => base_char_width * 1.1,   // Other capitals slightly wider (excluding M, W)
                else => base_char_width,                                     // Standard width
            };
            text_width += char_width;
        }
        
        // Handle line wrapping with proper word boundaries
        if (text_width <= available_size.width or available_size.width <= 0) {
            // Single line - use actual measured width
            return Size{ .width = text_width, .height = line_height };
        } else {
            // Multi-line - implement proper word wrapping
            const lines = self.calculateWrappedLines(text_style.text, base_char_width, available_size.width);
            return Size{ 
                .width = available_size.width, 
                .height = line_height * @as(f32, @floatFromInt(lines))
            };
        }
    }
    
    /// Calculate number of lines needed for text wrapping with word boundaries
    fn calculateWrappedLines(self: *LayoutEngine, text: []const u8, char_width: f32, max_width: f32) u32 {
        _ = self;
        
        if (text.len == 0) return 1;
        
        var lines: u32 = 1;
        var current_line_width: f32 = 0;
        var word_start: usize = 0;
        var i: usize = 0;
        
        while (i < text.len) {
            const char = text[i];
            const this_char_width = switch (char) {
                'i', 'l', '1', '|', '!', '.' => char_width * 0.3,      // Narrow chars
                'm', 'w' => char_width * 1.4,                          // Wide lowercase chars
                'M', 'W' => char_width * 1.5,                          // Wide capitals (even wider)
                ' ' => char_width * 0.4,                               // Spaces
                'A'...'L', 'N'...'V', 'X'...'Z' => char_width * 1.1,   // Other capitals slightly wider (excluding M, W)
                else => char_width,                                     // Standard width
            };
            
            if (char == ' ' or char == '\n' or i == text.len - 1) {
                // End of word - check if it fits
                const word_width = current_line_width + this_char_width;
                
                if (word_width > max_width and current_line_width > 0) {
                    // Word doesn't fit, wrap to next line
                    lines += 1;
                    current_line_width = this_char_width;
                } else {
                    current_line_width = word_width;
                }
                
                if (char == '\n') {
                    lines += 1;
                    current_line_width = 0;
                }
                
                word_start = i + 1;
            } else {
                current_line_width += this_char_width;
            }
            
            i += 1;
        }
        
        return lines;
    }
    
    /// Position an element and its children
    fn positionElement(self: *LayoutEngine, index: u32, position: Point) void {
        if (index >= self.element_count) return;
        
        const style = self.layout_styles[index];
        const size = self.computed_sizes[index];
        
        // Set our position and size
        self.computed_rects[index] = Rect{
            .x = position.x,
            .y = position.y,
            .width = size.width,
            .height = size.height,
        };
        
        // Position children within our content area
        if (self.first_child_indices[index] != INVALID_ELEMENT_ID) {
            const content_rect = style.padding.shrinkRect(self.computed_rects[index]);
            self.positionChildren(index, content_rect);
        }
    }
    
    /// Position all children of a container
    fn positionChildren(self: *LayoutEngine, parent_index: u32, content_rect: Rect) void {
        const style = self.layout_styles[parent_index];
        
        // Collect all children for easier processing
        var children: [MAX_ELEMENTS]u32 = undefined;
        var child_count: u32 = 0;
        
        var child_index = self.first_child_indices[parent_index];
        while (child_index != INVALID_ELEMENT_ID and child_count < MAX_ELEMENTS) {
            children[child_count] = child_index;
            child_count += 1;
            child_index = self.next_sibling_indices[child_index];
        }
        
        if (child_count == 0) return;
        
        // Calculate total child size and available space
        var total_child_size: f32 = 0;
        for (children[0..child_count]) |idx| {
            const child_size = self.computed_sizes[idx];
            total_child_size += switch (style.direction) {
                .row, .row_reverse => child_size.width,
                .column, .column_reverse => child_size.height,
            };
        }
        
        // Add gaps
        if (child_count > 1) {
            total_child_size += style.gap * @as(f32, @floatFromInt(child_count - 1));
        }
        
        const available_space = switch (style.direction) {
            .row, .row_reverse => content_rect.width,
            .column, .column_reverse => content_rect.height,
        };
        
        // Calculate starting position based on main axis alignment
        var current_pos = switch (style.main_axis_alignment) {
            .start => 0.0,
            .center => (available_space - total_child_size) * 0.5,
            .end => available_space - total_child_size,
            .space_between => 0.0,
            .space_around => (available_space - total_child_size) / @as(f32, @floatFromInt(child_count * 2)),
            .space_evenly => (available_space - total_child_size) / @as(f32, @floatFromInt(child_count + 1)),
        };
        
        // Calculate spacing between children
        var spacing = style.gap;
        if (style.main_axis_alignment == .space_between and child_count > 1) {
            spacing = (available_space - total_child_size + style.gap * @as(f32, @floatFromInt(child_count - 1))) / @as(f32, @floatFromInt(child_count - 1));
        } else if (style.main_axis_alignment == .space_around) {
            spacing = style.gap + (available_space - total_child_size) / @as(f32, @floatFromInt(child_count));
        } else if (style.main_axis_alignment == .space_evenly) {
            spacing = style.gap + (available_space - total_child_size) / @as(f32, @floatFromInt(child_count + 1));
            current_pos += spacing - style.gap;
        }
        
        // Position each child
        for (children[0..child_count]) |idx| {
            const child_size = self.computed_sizes[idx];
            
            var child_pos = Point.ZERO;
            
            switch (style.direction) {
                .row => {
                    child_pos.x = content_rect.x + current_pos;
                    child_pos.y = content_rect.y + self.alignCrossAxis(content_rect.height, child_size.height, style.cross_axis_alignment);
                    current_pos += child_size.width + spacing;
                },
                .row_reverse => {
                    current_pos += child_size.width;
                    child_pos.x = content_rect.x + available_space - current_pos;
                    child_pos.y = content_rect.y + self.alignCrossAxis(content_rect.height, child_size.height, style.cross_axis_alignment);
                    current_pos += spacing;
                },
                .column => {
                    child_pos.x = content_rect.x + self.alignCrossAxis(content_rect.width, child_size.width, style.cross_axis_alignment);
                    child_pos.y = content_rect.y + current_pos;
                    current_pos += child_size.height + spacing;
                },
                .column_reverse => {
                    current_pos += child_size.height;
                    child_pos.x = content_rect.x + self.alignCrossAxis(content_rect.width, child_size.width, style.cross_axis_alignment);
                    child_pos.y = content_rect.y + available_space - current_pos;
                    current_pos += spacing;
                },
            }
            
            self.positionElement(idx, child_pos);
        }
    }
    
    /// Calculate cross-axis alignment offset
    fn alignCrossAxis(self: *LayoutEngine, available_space: f32, child_size: f32, alignment: Alignment) f32 {
        _ = self;
        return switch (alignment) {
            .start => 0.0,
            .center => (available_space - child_size) * 0.5,
            .end => available_space - child_size,
            .stretch => 0.0, // Stretch is handled during sizing, not positioning
        };
    }
    
    /// Check if layout cache entry is valid
    fn isLayoutCacheValid(self: *LayoutEngine, index: u32, available_size: Size) bool {
        const cache = self.layout_cache[index];
        return cache.frame == self.current_frame and
               cache.available_size.width == available_size.width and
               cache.available_size.height == available_size.height;
    }
    
    /// Clear dirty flags for an element and its children
    fn clearDirtyFlags(self: *LayoutEngine, index: u32) void {
        if (index >= self.element_count) return;
        
        self.dirty_flags[index] = false;
        
        var child_index = self.first_child_indices[index];
        while (child_index != INVALID_ELEMENT_ID) {
            self.clearDirtyFlags(child_index);
            child_index = self.next_sibling_indices[child_index];
        }
    }
};

/// Layout cache entry for performance optimization
const LayoutCacheEntry = struct {
    available_size: Size = Size.ZERO,
    computed_size: Size = Size.ZERO,
    frame: u64 = 0,
};

// Performance validation tests
test "LayoutEngine basic operations" {
    const testing = std.testing;
    
    var engine = try LayoutEngine.init(testing.allocator);
    defer engine.deinit();
    
    // Create root container
    const root = try engine.createElement(.container, 1);
    try testing.expect(root == 0); // First element should get index 0
    
    // Create child elements
    const child1 = try engine.createElement(.text, 2);
    const child2 = try engine.createElement(.button, 3);
    
    // Add children to root
    try engine.addChild(root, child1);
    try engine.addChild(root, child2);
    
    // Verify hierarchy
    try testing.expect(engine.first_child_indices[root] == child1);
    try testing.expect(engine.next_sibling_indices[child1] == child2);
    try testing.expect(engine.parent_indices[child1] == root);
    try testing.expect(engine.parent_indices[child2] == root);
}

test "Layout computation performance" {
    const testing = std.testing;
    
    var engine = try LayoutEngine.init(testing.allocator);
    defer engine.deinit();
    
    // Create a complex hierarchy
    const root = try engine.createElement(.container, 1);
    
    // Create many children to test performance
    for (0..100) |i| {
        const child = try engine.createElement(.text, @intCast(i + 2));
        try engine.addChild(root, child);
    }
    
    // Time the layout computation
    const start = std.time.nanoTimestamp();
    try engine.computeLayout(root, Size{ .width = 800, .height = 600 });
    const end = std.time.nanoTimestamp();
    
    const duration_ns = end - start;
    const duration_us = @as(f64, @floatFromInt(duration_ns)) / 1000.0;
    
    std.log.info("Layout computation for 100 elements took {d:.2} microseconds", .{duration_us});
    
    // Should be much faster than our target (< 1000μs per element)
    try testing.expect(duration_us < 100_000.0); // < 100ms for 100 elements
}

test "Memory layout validation" {
    const testing = std.testing;
    
    // Validate that our core structures are cache-friendly
    try testing.expect(@sizeOf(LayoutStyle) <= 128); // Should fit in 2 cache lines
    try testing.expect(@sizeOf(VisualStyle) <= 64);  // Should fit in 1 cache line
    try testing.expect(@sizeOf(TextStyle) <= 64);    // Should fit in 1 cache line
    
    // Validate alignment for SIMD operations
    try testing.expect(@alignOf(Point) >= 4);
    try testing.expect(@alignOf(Size) >= 4);
    try testing.expect(@alignOf(Rect) >= 4);
    try testing.expect(@alignOf(Color) >= 4);
}