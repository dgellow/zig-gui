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

/// Layout style properties - hot data path
/// 
/// @memory-layout {
///   size: 32 bytes
///   align: 4 bytes  
///   cache-lines: 0.5 (2 per cache line)
///   access-pattern: sequential during layout computation
///   hot-path: yes - accessed for every element during layout
/// }
pub const LayoutStyle = struct {
    // === Grouped by access frequency, not logical grouping ===
    
    // Most frequently accessed (layout algorithm core)
    direction: FlexDirection = .column,
    main_axis_alignment: Justification = .start,
    cross_axis_alignment: Alignment = .start,
    position_type: PositionType = .relative,
    
    // Size determination (accessed during measure phase)
    width: f32 = -1.0,           // -1 = content-based, >= 0 = fixed
    height: f32 = -1.0,          // -1 = content-based, >= 0 = fixed
    min_width: f32 = 0.0,
    min_height: f32 = 0.0,
    max_width: f32 = std.math.inf(f32),
    
    // Flex layout (accessed during flex computation)
    flex_grow: f32 = 0.0,
    flex_shrink: f32 = 1.0,
    
    comptime {
        // Verify our memory layout assumptions
        const size = @sizeOf(LayoutStyle);
        
        if (size != 32) {
            @compileError(std.fmt.comptimePrint(
                "LayoutStyle size changed! Expected 32 bytes, got {} bytes", 
                .{size}
            ));
        }
        
        if (size > 64) {
            @compileError("LayoutStyle exceeds cache line size!");
        }
    }
};

/// Layout style cold properties - positioning phase only
/// 
/// @memory-layout {
///   size: 56 bytes  
///   align: 4 bytes
///   cache-lines: 0.875 (wastes 8 bytes per element)
///   access-pattern: sequential during positioning phase only
///   hot-path: no - only during final positioning
/// }
pub const LayoutStyleCold = struct {
    max_height: f32 = std.math.inf(f32),
    gap: f32 = 0.0,
    
    // EdgeInsets are 16 bytes each (4 x f32)
    padding: EdgeInsets = EdgeInsets.ZERO,    // For content area calculation
    margin: EdgeInsets = EdgeInsets.ZERO,     // For element spacing
    position: EdgeInsets = EdgeInsets.ZERO,   // For absolute positioning
    
    // Note: This struct is intentionally NOT optimized to 32/64 bytes
    // because it's cold data. Better to keep hot data compact than
    // to pad cold data for alignment.
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

/// Structure-of-Arrays layout engine for maximum cache efficiency
/// 
/// @memory-layout {
///   total-size: ~975KB for 4096 elements
///   architecture: Structure-of-Arrays (SoA)
///   cache-pattern: Sequential array access
///   hot-arrays: element_types, layout_styles, computed_sizes, indices
///   cold-arrays: visual_styles, text_styles, layout_styles_cold
/// }
/// 
/// @performance {
///   layout-time: <10μs per element (target)
///   allocations: 0 per frame (arena-based)
///   cache-misses: minimized via hot/cold separation
/// }
pub const LayoutEngine = struct {
    allocator: std.mem.Allocator,
    
    // === HOT DATA: Accessed during every layout computation ===
    
    element_count: u32 = 0,
    element_types: [MAX_ELEMENTS]ElementType = undefined,         // 4KB
    element_ids: [MAX_ELEMENTS]ElementId = undefined,             // 16KB
    parent_indices: [MAX_ELEMENTS]u32 = undefined,                // 16KB
    first_child_indices: [MAX_ELEMENTS]u32 = undefined,           // 16KB
    next_sibling_indices: [MAX_ELEMENTS]u32 = undefined,          // 16KB
    
    // Layout properties (ultra-hot data - accessed during layout computation)
    layout_styles: [MAX_ELEMENTS]LayoutStyle = undefined,          // 32 bytes each - cache friendly!
    layout_styles_cold: [MAX_ELEMENTS]LayoutStyleCold = undefined, // Cold data accessed less frequently
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
        @memset(&engine.layout_styles_cold, LayoutStyleCold{});
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
        self.layout_styles_cold[index] = LayoutStyleCold{};
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
    
    /// Set cold layout style for an element (spacing, positioning)
    pub fn setLayoutStyleCold(self: *LayoutEngine, index: u32, style: LayoutStyleCold) void {
        if (index >= self.element_count) return;
        
        // Cold style changes also require layout recalculation
        if (!std.meta.eql(self.layout_styles_cold[index], style)) {
            self.layout_styles_cold[index] = style;
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
        const style_cold = self.layout_styles_cold[index];
        
        // Apply padding to available size
        const content_size = style_cold.padding.shrinkSize(available_size);
        
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
        computed_size.height = std.math.clamp(computed_size.height, style.min_height, style_cold.max_height);
        
        // Add padding back
        computed_size = style_cold.padding.expandSize(computed_size);
        
        self.computed_sizes[index] = computed_size;
        
        // Update cache
        self.layout_cache[index] = LayoutCacheEntry{
            .available_size = available_size,
            .computed_size = computed_size,
            .frame = self.current_frame,
        };
    }
    
    /// Compute the intrinsic size of an element with proper flex handling
    fn computeElementSize(self: *LayoutEngine, index: u32, available_size: Size) Size {
        const style = self.layout_styles[index];
        
        // Start with intrinsic content size
        var size = Size.ZERO;
        
        // For containers, size is based on children
        if (self.element_types[index] == .container) {
            size = self.computeContainerSize(index, available_size);
        }
        // For text elements, size is based on text content
        else if (self.element_types[index] == .text) {
            size = self.computeTextSize(index, available_size);
        }
        // For buttons, size is based on text content plus padding
        else if (self.element_types[index] == .button) {
            size = self.computeTextSize(index, available_size);
        }
        
        // Apply explicit width/height if specified (-1 means content-based)
        if (style.width >= 0) {
            size.width = style.width;
        }
        if (style.height >= 0) {
            size.height = style.height;
        }
        
        // If no explicit size and no content size, use available size
        if (size.width == 0 and style.width < 0) {
            size.width = available_size.width;
        }
        if (size.height == 0 and style.height < 0) {
            size.height = available_size.height;
        }
        
        return size;
    }
    
    /// Compute size for container elements - O(n) single pass, cache-friendly
    fn computeContainerSize(self: *LayoutEngine, index: u32, available_size: Size) Size {
        const style = self.layout_styles[index];
        const style_cold = self.layout_styles_cold[index];
        var total_size = Size.ZERO;
        var child_count: u32 = 0;
        
        // Calculate the content area available to children (subtract padding)
        const content_available = style_cold.padding.shrinkSize(available_size);
        
        // Single pass through children - count and accumulate sizes simultaneously
        // This is O(n) instead of O(2n) and much more cache-friendly
        var child_index = self.first_child_indices[index];
        while (child_index != INVALID_ELEMENT_ID) {
            const child_size = self.computed_sizes[child_index];
            child_count += 1;
            
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
            
            child_index = self.next_sibling_indices[child_index];
        }
        
        // Add gaps between children
        if (child_count > 1) {
            const total_gap = style_cold.gap * @as(f32, @floatFromInt(child_count - 1));
            switch (style.direction) {
                .row, .row_reverse => total_size.width += total_gap,
                .column, .column_reverse => total_size.height += total_gap,
            }
        }
        
        // Respect available space constraints - containers should not exceed available space
        // unless they have an explicit size set
        if (style.width < 0) {
            total_size.width = @min(total_size.width, content_available.width);
        }
        if (style.height < 0) {
            total_size.height = @min(total_size.height, content_available.height);
        }
        
        return total_size;
    }
    
    /// Compute size for text elements using improved character width approximations
    /// 
    /// ✅ IMPLEMENTED:
    /// - Per-character width ratios (matches text.zig implementation)
    /// - Realistic line height calculations
    /// - Basic word wrapping with proper word boundaries
    /// 
    /// ❌ TODO - Integration with Real Text Measurement:
    /// - [ ] Use TextMeasurement interface instead of duplicated character width logic
    /// - [ ] Support for different font families/weights from TextMeasurement
    /// - [ ] Advanced text shaping (ligatures, complex scripts)
    /// - [ ] Bidirectional text support (RTL languages)
    /// - [ ] Text decoration measurements (underline, strikethrough)
    fn computeTextSize(self: *LayoutEngine, index: u32, available_size: Size) Size {
        const text_style = self.text_styles[index];
        
        // NOTE: This duplicates logic from text.zig - should be unified
        // when we implement proper TextMeasurement integration
        
        // Calculate width using real character widths (same as in text.zig)
        var total_width: f32 = 0;
        for (text_style.text) |char| {
            const char_width_ratio = getCharWidthRatio(char);
            total_width += char_width_ratio * text_style.font_size;
        }
        
        const line_height = text_style.font_size * 1.25; // Realistic line height
        
        // Handle line wrapping with proper word boundaries
        if (total_width <= available_size.width or available_size.width <= 0) {
            // Single line - use actual measured width
            return Size{ .width = total_width, .height = line_height };
        } else {
            // Multi-line - implement proper word wrapping
            const lines = self.calculateWrappedLines(text_style.text, text_style.font_size, available_size.width);
            return Size{ 
                .width = available_size.width, 
                .height = line_height * @as(f32, @floatFromInt(lines))
            };
        }
    }
    
    /// Get character width ratio (matches text.zig implementation exactly)
    fn getCharWidthRatio(char: u8) f32 {
        return switch (char) {
            // Narrow characters
            'i', 'l' => 0.22,
            'I' => 0.28,
            '1' => 0.35,
            '|' => 0.25,
            '!', '.', ',', ':', ';' => 0.28,
            '\'' => 0.18,
            '"' => 0.35,
            
            // Wide characters
            'm' => 0.83,
            'w' => 0.78,
            'M', 'W' => 0.87,
            
            // Spaces
            ' ' => 0.28,
            '\t' => 1.12,
            
            // Numbers (excluding '1' which is already defined above)
            '0', '2'...'9' => 0.56,
            
            // Common punctuation
            '-' => 0.33,
            '_' => 0.50,
            '=', '+' => 0.58,
            '*' => 0.39,
            '/', '\\' => 0.28,
            '(', ')' => 0.33,
            '[', ']' => 0.28,
            '{', '}' => 0.35,
            '<', '>' => 0.58,
            
            // Uppercase letters
            'A' => 0.67,
            'B' => 0.67,
            'C' => 0.72,
            'D' => 0.72,
            'E' => 0.67,
            'F' => 0.61,
            'G' => 0.78,
            'H' => 0.72,
            'J' => 0.50,
            'K' => 0.67,
            'L' => 0.56,
            'N' => 0.72,
            'O' => 0.78,
            'P' => 0.67,
            'Q' => 0.78,
            'R' => 0.72,
            'S' => 0.67,
            'T' => 0.61,
            'U' => 0.72,
            'V' => 0.67,
            'X' => 0.67,
            'Y' => 0.67,
            'Z' => 0.61,
            
            // Lowercase letters
            'a' => 0.56,
            'b' => 0.56,
            'c' => 0.50,
            'd' => 0.56,
            'e' => 0.56,
            'f' => 0.28,
            'g' => 0.56,
            'h' => 0.56,
            'j' => 0.22,
            'k' => 0.50,
            'n' => 0.56,
            'o' => 0.56,
            'p' => 0.56,
            'q' => 0.56,
            'r' => 0.33,
            's' => 0.50,
            't' => 0.28,
            'u' => 0.56,
            'v' => 0.50,
            'x' => 0.50,
            'y' => 0.50,
            'z' => 0.50,
            
            // Default for any other character
            else => 0.55,
        };
    }
    
    /// Calculate number of lines needed for text wrapping with word boundaries
    fn calculateWrappedLines(self: *LayoutEngine, text: []const u8, font_size: f32, max_width: f32) u32 {
        _ = self;
        
        if (text.len == 0) return 1;
        
        var lines: u32 = 1;
        var current_line_width: f32 = 0;
        var word_width: f32 = 0;
        var i: usize = 0;
        
        while (i < text.len) {
            const char = text[i];
            const char_width = getCharWidthRatio(char) * font_size;
            
            if (char == ' ' or char == '\n' or i == text.len - 1) {
                // End of word - check if it fits
                word_width += char_width;
                
                if (current_line_width + word_width > max_width and current_line_width > 0) {
                    // Word doesn't fit, wrap to next line
                    lines += 1;
                    current_line_width = word_width;
                } else {
                    current_line_width += word_width;
                }
                
                if (char == '\n') {
                    lines += 1;
                    current_line_width = 0;
                }
                
                word_width = 0;
            } else {
                word_width += char_width;
            }
            
            i += 1;
        }
        
        return lines;
    }
    
    /// Position an element and its children
    fn positionElement(self: *LayoutEngine, index: u32, position: Point) void {
        if (index >= self.element_count) return;
        
        const style_cold = self.layout_styles_cold[index];
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
            const content_rect = style_cold.padding.shrinkRect(self.computed_rects[index]);
            self.positionChildren(index, content_rect);
        }
    }
    
    /// Position all children of a container with proper flex layout - data-oriented design
    fn positionChildren(self: *LayoutEngine, parent_index: u32, content_rect: Rect) void {
        const style = self.layout_styles[parent_index];
        const style_cold = self.layout_styles_cold[parent_index];
        
        // First pass: calculate total intrinsic size and flex properties
        var total_intrinsic_size: f32 = 0;
        var total_flex_grow: f32 = 0;
        var total_flex_shrink: f32 = 0;
        var child_count: u32 = 0;
        
        var child_index = self.first_child_indices[parent_index];
        while (child_index != INVALID_ELEMENT_ID) {
            const child_size = self.computed_sizes[child_index];
            const child_style = self.layout_styles[child_index];
            
            total_intrinsic_size += switch (style.direction) {
                .row, .row_reverse => child_size.width,
                .column, .column_reverse => child_size.height,
            };
            
            total_flex_grow += child_style.flex_grow;
            total_flex_shrink += child_style.flex_shrink;
            child_count += 1;
            
            child_index = self.next_sibling_indices[child_index];
        }
        
        if (child_count == 0) return;
        
        // Add gaps to total intrinsic size
        const total_gap = if (child_count > 1) style_cold.gap * @as(f32, @floatFromInt(child_count - 1)) else 0.0;
        total_intrinsic_size += total_gap;
        
        const available_space = switch (style.direction) {
            .row, .row_reverse => content_rect.width,
            .column, .column_reverse => content_rect.height,
        };
        
        // Calculate flex space (available - intrinsic)
        const flex_space = available_space - total_intrinsic_size;
        
        // Calculate flex unit size for grow/shrink
        var flex_grow_unit: f32 = 0;
        var flex_shrink_unit: f32 = 0;
        
        if (flex_space > 0 and total_flex_grow > 0) {
            flex_grow_unit = flex_space / total_flex_grow;
        } else if (flex_space < 0 and total_flex_shrink > 0) {
            flex_shrink_unit = flex_space / total_flex_shrink;
        }
        
        // Calculate starting position based on main axis alignment
        var current_pos = switch (style.main_axis_alignment) {
            .start => 0.0,
            .center => @max(0, flex_space * 0.5),
            .end => @max(0, flex_space),
            .space_between => 0.0,
            .space_around => if (child_count > 0) @max(0, flex_space) / @as(f32, @floatFromInt(child_count * 2)) else 0.0,
            .space_evenly => if (child_count > 0) @max(0, flex_space) / @as(f32, @floatFromInt(child_count + 1)) else 0.0,
        };
        
        // Calculate spacing between children
        var spacing = style_cold.gap;
        if (flex_space > 0) {
            switch (style.main_axis_alignment) {
                .space_between => {
                    if (child_count > 1) {
                        spacing = style_cold.gap + flex_space / @as(f32, @floatFromInt(child_count - 1));
                    }
                },
                .space_around => {
                    spacing = style_cold.gap + flex_space / @as(f32, @floatFromInt(child_count));
                    current_pos += flex_space / @as(f32, @floatFromInt(child_count * 2));
                },
                .space_evenly => {
                    spacing = style_cold.gap + flex_space / @as(f32, @floatFromInt(child_count + 1));
                    current_pos = flex_space / @as(f32, @floatFromInt(child_count + 1));
                },
                else => {},
            }
        }
        
        // Second pass: position each child with flex adjustments
        child_index = self.first_child_indices[parent_index];
        while (child_index != INVALID_ELEMENT_ID) {
            var child_size = self.computed_sizes[child_index];
            const child_style = self.layout_styles[child_index];
            
            // Apply flex grow/shrink
            var main_size = switch (style.direction) {
                .row, .row_reverse => child_size.width,
                .column, .column_reverse => child_size.height,
            };
            
            if (flex_grow_unit > 0 and child_style.flex_grow > 0) {
                main_size += flex_grow_unit * child_style.flex_grow;
            } else if (flex_shrink_unit < 0 and child_style.flex_shrink > 0) {
                main_size += flex_shrink_unit * child_style.flex_shrink;
                main_size = @max(0, main_size); // Don't shrink below 0
            }
            
            // Update child size with flex adjustments
            switch (style.direction) {
                .row, .row_reverse => child_size.width = main_size,
                .column, .column_reverse => child_size.height = main_size,
            }
            
            // Calculate child position
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
            
            // Update computed size with flex adjustments and position the element
            self.computed_sizes[child_index] = child_size;
            self.positionElement(child_index, child_pos);
            
            child_index = self.next_sibling_indices[child_index];
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