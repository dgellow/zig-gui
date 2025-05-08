const std = @import("std");

/// Text measurement interface.
/// This is a pluggable component that allows different text rendering backends
/// to provide text measurement functionality for the layout system.
pub const TextMeasurement = struct {
    /// Virtual function table for text measurement methods
    vtable: *const VTable,
    
    /// User data that will be passed to the vtable functions
    user_data: ?*anyopaque,
    
    /// Virtual function table definition
    pub const VTable = struct {
        /// Measure a single line of text
        /// Returns the width and height of the text when rendered with the given font and size
        measureText: *const fn (
            measurement: *TextMeasurement, 
            text: []const u8, 
            font_name: ?[]const u8, 
            font_size: f32
        ) TextSize,
        
        /// Measure multiple lines of text
        /// This can be more efficient for backends that can measure multiple lines at once
        /// Returns the width (of widest line) and total height of the text
        measureMultilineText: *const fn (
            measurement: *TextMeasurement, 
            text: []const u8, 
            font_name: ?[]const u8, 
            font_size: f32, 
            line_height: f32
        ) TextSize,
        
        /// Get the line height for a given font and size
        /// This is useful for calculating vertical spacing in multi-line text
        getLineHeight: *const fn (
            measurement: *TextMeasurement, 
            font_name: ?[]const u8, 
            font_size: f32
        ) f32,
        
        /// Get the baseline offset for a given font and size
        /// This is the distance from the top of the text to the baseline
        getBaseline: *const fn (
            measurement: *TextMeasurement, 
            font_name: ?[]const u8, 
            font_size: f32
        ) f32,
    };
    
    /// Call the measureText function
    pub inline fn measureText(
        self: *TextMeasurement, 
        text: []const u8, 
        font_name: ?[]const u8, 
        font_size: f32
    ) TextSize {
        return self.vtable.measureText(self, text, font_name, font_size);
    }
    
    /// Call the measureMultilineText function
    pub inline fn measureMultilineText(
        self: *TextMeasurement, 
        text: []const u8, 
        font_name: ?[]const u8, 
        font_size: f32, 
        line_height: f32
    ) TextSize {
        return self.vtable.measureMultilineText(self, text, font_name, font_size, line_height);
    }
    
    /// Call the getLineHeight function
    pub inline fn getLineHeight(
        self: *TextMeasurement, 
        font_name: ?[]const u8, 
        font_size: f32
    ) f32 {
        return self.vtable.getLineHeight(self, font_name, font_size);
    }
    
    /// Call the getBaseline function
    pub inline fn getBaseline(
        self: *TextMeasurement, 
        font_name: ?[]const u8, 
        font_size: f32
    ) f32 {
        return self.vtable.getBaseline(self, font_name, font_size);
    }
};

/// Size of text when rendered
pub const TextSize = struct {
    width: f32 = 0,
    height: f32 = 0,
    
    /// Create a new TextSize
    pub fn init(width: f32, height: f32) TextSize {
        return .{
            .width = width,
            .height = height,
        };
    }
};

/// Default text measurement implementation that uses approximations
/// This is a fallback implementation that doesn't require external dependencies
pub const DefaultTextMeasurement = struct {
    measurement: TextMeasurement,
    
    /// Default font metrics (approximations)
    const AVERAGE_CHAR_WIDTH: f32 = 0.5; // as a fraction of font size
    const LINE_HEIGHT_RATIO: f32 = 1.2; // as a fraction of font size
    const BASELINE_RATIO: f32 = 0.8; // as a fraction of font size
    
    /// VTable for the default implementation
    const vtable = TextMeasurement.VTable{
        .measureText = measureText,
        .measureMultilineText = measureMultilineText,
        .getLineHeight = getLineHeight,
        .getBaseline = getBaseline,
    };
    
    /// Create a new DefaultTextMeasurement
    pub fn init() DefaultTextMeasurement {
        return .{
            .measurement = .{
                .vtable = &vtable,
                .user_data = null,
            },
        };
    }
    
    /// Measure a single line of text
    fn measureText(
        _: *TextMeasurement, 
        text: []const u8, 
        _: ?[]const u8, // font_name
        font_size: f32
    ) TextSize {
        // Safety check for empty text
        if (text.len == 0) {
            return TextSize.init(0, 0);
        }
        
        // Simple approximation based on character count and font size
        const width = @as(f32, @floatFromInt(text.len)) * font_size * AVERAGE_CHAR_WIDTH;
        const height = font_size * LINE_HEIGHT_RATIO;
        
        return TextSize.init(width, height);
    }
    
    /// Measure multiline text
    fn measureMultilineText(
        measurement: *TextMeasurement, 
        text: []const u8, 
        font_name: ?[]const u8, 
        font_size: f32, 
        line_height: f32
    ) TextSize {
        // Count lines
        var line_count: usize = 1;
        for (text) |c| {
            if (c == '\n') line_count += 1;
        }
        
        // Find longest line for width
        var max_width: f32 = 0;
        var line_start: usize = 0;
        var i: usize = 0;
        
        while (i < text.len) : (i += 1) {
            if (text[i] == '\n' or i == text.len - 1) {
                const line_end = if (i == text.len - 1 and text[i] != '\n') i + 1 else i;
                const line_text = text[line_start..line_end];
                
                // Simple approximation for empty text
                if (line_text.len == 0) {
                    line_start = i + 1;
                    continue;
                }
                
                const line_size = measurement.measureText(line_text, font_name, font_size);
                max_width = @max(max_width, line_size.width);
                
                line_start = i + 1;
            }
        }
        
        // Calculate total height
        const total_height = @as(f32, @floatFromInt(line_count)) * line_height;
        
        return TextSize.init(max_width, total_height);
    }
    
    /// Get line height for a given font and size
    fn getLineHeight(
        _: *TextMeasurement, 
        _: ?[]const u8, // font_name
        font_size: f32
    ) f32 {
        return font_size * LINE_HEIGHT_RATIO;
    }
    
    /// Get baseline for a given font and size
    fn getBaseline(
        _: *TextMeasurement, 
        _: ?[]const u8, // font_name
        font_size: f32
    ) f32 {
        return font_size * BASELINE_RATIO;
    }
};

/// Cache key for text measurements
const TextMeasurementCacheKey = struct {
    /// Combined hash of text, font name, and font size
    hash: u64,
    
    pub fn init(text: []const u8, font_name: ?[]const u8, font_size: f32) TextMeasurementCacheKey {
        // Create a combined hash from all inputs
        var hasher = std.hash.Wyhash.init(0);
        
        // Hash the text
        hasher.update(text);
        
        // Hash the font name
        if (font_name) |name| {
            hasher.update(name);
        }
        
        // Convert f32 to bits for consistent hashing
        const font_size_bits = @as(u32, @bitCast(font_size));
        hasher.update(std.mem.asBytes(&font_size_bits));
        
        return .{
            .hash = hasher.final(),
        };
    }
    
    pub fn eql(a: TextMeasurementCacheKey, b: TextMeasurementCacheKey) bool {
        return a.hash == b.hash;
    }
};

/// Cache for text measurements to avoid repeated calculations
pub const TextMeasurementCache = struct {
    /// Underlying text measurement implementation
    measurement: *TextMeasurement,
    
    /// Allocator for the cache
    allocator: std.mem.Allocator,
    
    /// Hash map for text measurements
    cache: std.AutoHashMap(TextMeasurementCacheKey, TextSize),
    
    /// Create a new TextMeasurementCache
    pub fn init(allocator: std.mem.Allocator, measurement: *TextMeasurement) TextMeasurementCache {
        return .{
            .measurement = measurement,
            .allocator = allocator,
            .cache = std.AutoHashMap(TextMeasurementCacheKey, TextSize).init(allocator),
        };
    }
    
    /// Deinitialize the cache
    pub fn deinit(self: *TextMeasurementCache) void {
        self.cache.deinit();
    }
    
    /// Clear the cache
    pub fn clear(self: *TextMeasurementCache) void {
        self.cache.clearRetainingCapacity();
    }
    
    /// Measure text, using cached values if available
    pub fn measureText(
        self: *TextMeasurementCache, 
        text: []const u8, 
        font_name: ?[]const u8, 
        font_size: f32
    ) !TextSize {
        // Safety check for empty text
        if (text.len == 0) {
            return TextSize.init(0, 0);
        }
        
        const key = TextMeasurementCacheKey.init(text, font_name, font_size);
        
        // Check cache first
        if (self.cache.get(key)) |size| {
            return size;
        }
        
        // Measure and cache the result
        const size = self.measurement.measureText(text, font_name, font_size);
        try self.cache.put(key, size);
        
        return size;
    }
    
    /// Measure multiline text, using cached values if available
    pub fn measureMultilineText(
        self: *TextMeasurementCache, 
        text: []const u8, 
        font_name: ?[]const u8, 
        font_size: f32, 
        line_height: f32
    ) !TextSize {
        // Safety check for empty text
        if (text.len == 0) {
            return TextSize.init(0, 0);
        }
        
        // Create a hash key that includes all parameters
        var hasher = std.hash.Wyhash.init(0);
        
        // Hash the text
        hasher.update(text);
        
        // Hash the font name
        if (font_name) |name| {
            hasher.update(name);
        }
        
        // Hash font size and line height
        const font_size_bits = @as(u32, @bitCast(font_size));
        const line_height_bits = @as(u32, @bitCast(line_height));
        hasher.update(std.mem.asBytes(&font_size_bits));
        hasher.update(std.mem.asBytes(&line_height_bits));
        
        // Create the key
        const key = TextMeasurementCacheKey{ .hash = hasher.final() };
        
        // Check cache first
        if (self.cache.get(key)) |size| {
            return size;
        }
        
        // Measure and cache the result
        const size = self.measurement.measureMultilineText(text, font_name, font_size, line_height);
        try self.cache.put(key, size);
        
        return size;
    }
    
    /// Get line height for a given font and size
    pub fn getLineHeight(
        self: *TextMeasurementCache, 
        font_name: ?[]const u8, 
        font_size: f32
    ) f32 {
        return self.measurement.getLineHeight(font_name, font_size);
    }
    
    /// Get baseline for a given font and size
    pub fn getBaseline(
        self: *TextMeasurementCache, 
        font_name: ?[]const u8, 
        font_size: f32
    ) f32 {
        return self.measurement.getBaseline(font_name, font_size);
    }
};

test "default text measurement" {
    var default_measurement = DefaultTextMeasurement.init();
    
    // Test single line measurement
    const size1 = default_measurement.measurement.measureText("Hello, World!", null, 16.0);
    
    // Using the default approximation: width = text.len * font_size * AVERAGE_CHAR_WIDTH
    const expected_width = @as(f32, @floatFromInt("Hello, World!".len)) * 16.0 * DefaultTextMeasurement.AVERAGE_CHAR_WIDTH;
    const expected_height = 16.0 * DefaultTextMeasurement.LINE_HEIGHT_RATIO;
    
    try std.testing.expectApproxEqAbs(expected_width, size1.width, 0.001);
    try std.testing.expectApproxEqAbs(expected_height, size1.height, 0.001);
    
    // Test multiline measurement
    const multiline_text = 
        \\Hello, World!
        \\This is a test
        \\Of multiline text measurement
    ;
    
    const size2 = default_measurement.measurement.measureMultilineText(
        multiline_text,
        null,
        16.0,
        20.0
    );
    
    // Expected height is 3 lines * line_height
    const expected_multiline_height = 3 * 20.0;
    
    // Width should be the width of the longest line ("Of multiline text measurement")
    const longest_line = "Of multiline text measurement";
    const expected_multiline_width = @as(f32, @floatFromInt(longest_line.len)) * 16.0 * DefaultTextMeasurement.AVERAGE_CHAR_WIDTH;
    
    try std.testing.expectApproxEqAbs(expected_multiline_width, size2.width, 0.001);
    try std.testing.expectApproxEqAbs(expected_multiline_height, size2.height, 0.001);
}

test "text measurement cache" {
    // Create a default measurement
    var default_measurement = DefaultTextMeasurement.init();
    
    // Create a cache
    var cache = TextMeasurementCache.init(std.testing.allocator, &default_measurement.measurement);
    defer cache.deinit();
    
    // Test caching of single line text
    const text = "Hello, World!";
    const font_size = 16.0;
    
    // First measurement should be calculated
    const size1 = try cache.measureText(text, null, font_size);
    
    // Second measurement should be retrieved from cache (same result)
    const size2 = try cache.measureText(text, null, font_size);
    
    try std.testing.expectEqual(size1.width, size2.width);
    try std.testing.expectEqual(size1.height, size2.height);
    
    // Different text should calculate a new result
    const text2 = "Different text";
    const size3 = try cache.measureText(text2, null, font_size);
    
    try std.testing.expect(size1.width != size3.width);
    
    // Test multiline caching
    const multiline_text = 
        \\Hello, World!
        \\This is a test
    ;
    
    const line_height = 20.0;
    
    // First measurement
    const msize1 = try cache.measureMultilineText(multiline_text, null, font_size, line_height);
    
    // Second measurement (cached)
    const msize2 = try cache.measureMultilineText(multiline_text, null, font_size, line_height);
    
    try std.testing.expectEqual(msize1.width, msize2.width);
    try std.testing.expectEqual(msize1.height, msize2.height);
    
    // Clear cache
    cache.clear();
    
    // Should have to recalculate after clearing
    _ = try cache.measureText(text, null, font_size);
    
    // Cache should now have one entry
    try std.testing.expect(cache.cache.count() == 1);
}