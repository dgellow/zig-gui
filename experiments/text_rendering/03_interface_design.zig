//! Experiment 3: TextProvider Interface Design Exploration
//!
//! Goal: Explore different API designs for the text rendering interface.
//! We want an interface that works for:
//!   - Embedded (32KB): Pre-baked bitmap fonts, decode to framebuffer
//!   - Desktop SW: Runtime TTF rasterization with caching
//!   - Desktop GPU: SDF/MSDF atlas with GPU shader
//!
//! Key questions:
//!   1. Who owns the atlas texture?
//!   2. How does the backend know when atlas is updated?
//!   3. Where does glyph caching live?
//!   4. How do we handle different text needs (layout vs rendering)?

const std = @import("std");

// ============================================================================
// Design Option A: BYOT with Allocation (Current Proposal)
// ============================================================================
//
// Pros: Simple interface, provider has full control
// Cons: Allocation per text draw is problematic for embedded

pub const DesignA = struct {
    pub const TextProvider = struct {
        ptr: *anyopaque,
        vtable: *const VTable,

        pub const VTable = struct {
            measureText: *const fn (ptr: *anyopaque, text: []const u8, style: TextStyle) TextMetrics,
            getCharPositions: *const fn (ptr: *anyopaque, text: []const u8, style: TextStyle, out: []f32) usize,
            rasterizeText: *const fn (ptr: *anyopaque, text: []const u8, style: TextStyle, allocator: std.mem.Allocator) ?RasterizedText,
            freeRasterized: *const fn (ptr: *anyopaque, rasterized: RasterizedText, allocator: std.mem.Allocator) void,
        };

        pub const TextStyle = struct {
            font_id: u16 = 0,
            size: f32 = 16,
            weight: u16 = 400,
        };

        pub const TextMetrics = struct {
            width: f32,
            height: f32,
            ascent: f32,
            descent: f32,
        };

        pub const RasterizedText = struct {
            pixels: []const u8,
            width: u32,
            height: u32,
            format: enum { rgba, alpha },
        };
    };

    // Analysis
    pub fn analyze() void {
        std.debug.print("\n=== Design A: BYOT with Allocation ===\n", .{});
        std.debug.print("Pros:\n", .{});
        std.debug.print("  + Simple, clean interface\n", .{});
        std.debug.print("  + Provider has full control over rasterization\n", .{});
        std.debug.print("  + Easy to implement different backends\n", .{});
        std.debug.print("Cons:\n", .{});
        std.debug.print("  - Allocation per text draw (embedded problem)\n", .{});
        std.debug.print("  - No atlas management - each text is independent\n", .{});
        std.debug.print("  - Backend has no way to cache GPU textures\n", .{});
        std.debug.print("  - No notification when atlas changes\n", .{});
    }
};

// ============================================================================
// Design Option B: Atlas-Centric (imgui-style)
// ============================================================================
//
// Provider manages a glyph atlas. Renderer gets UV coordinates.
// This is how Dear ImGui and most game engines work.

pub const DesignB = struct {
    pub const TextProvider = struct {
        ptr: *anyopaque,
        vtable: *const VTable,

        pub const VTable = struct {
            // Font management
            loadFont: *const fn (ptr: *anyopaque, data: []const u8, size_hint: f32) ?FontId,
            unloadFont: *const fn (ptr: *anyopaque, font_id: FontId) void,

            // Measurement
            measureText: *const fn (ptr: *anyopaque, text: []const u8, style: TextStyle) TextMetrics,

            // Get glyph quads for rendering
            // Returns UV coordinates into the atlas texture
            getGlyphQuads: *const fn (
                ptr: *anyopaque,
                text: []const u8,
                style: TextStyle,
                pos: Point,
                out_quads: []GlyphQuad,
            ) usize,

            // Atlas management
            getAtlas: *const fn (ptr: *anyopaque) AtlasInfo,
            isAtlasDirty: *const fn (ptr: *anyopaque) bool,
            markAtlasClean: *const fn (ptr: *anyopaque) void,

            // Frame lifecycle
            beginFrame: *const fn (ptr: *anyopaque) void,
            endFrame: *const fn (ptr: *anyopaque) void,
        };

        pub const FontId = u16;
        pub const TextStyle = struct {
            font_id: FontId = 0,
            size: f32 = 16,
        };
        pub const Point = struct { x: f32, y: f32 };
        pub const TextMetrics = struct {
            width: f32,
            height: f32,
            ascent: f32,
            descent: f32,
        };

        pub const GlyphQuad = struct {
            // Screen coordinates
            x0: f32,
            y0: f32,
            x1: f32,
            y1: f32,
            // UV coordinates in atlas
            u0: f32,
            v0: f32,
            u1: f32,
            v1: f32,
        };

        pub const AtlasInfo = struct {
            pixels: []const u8,
            width: u32,
            height: u32,
            format: AtlasFormat,
            generation: u32, // Increments on rebuild
        };

        pub const AtlasFormat = enum {
            alpha8, // Single channel (grayscale)
            rgba32, // Color (for emoji)
            sdf, // Signed distance field
            msdf, // Multi-channel SDF
        };
    };

    pub fn analyze() void {
        std.debug.print("\n=== Design B: Atlas-Centric ===\n", .{});
        std.debug.print("Pros:\n", .{});
        std.debug.print("  + Zero allocation in render loop\n", .{});
        std.debug.print("  + Backend can cache atlas as GPU texture\n", .{});
        std.debug.print("  + Clear dirty notification for texture updates\n", .{});
        std.debug.print("  + Matches imgui/game engine patterns\n", .{});
        std.debug.print("Cons:\n", .{});
        std.debug.print("  - More complex interface (10 functions vs 4)\n", .{});
        std.debug.print("  - Provider must manage atlas packing\n", .{});
        std.debug.print("  - Embedded might not need atlas abstraction\n", .{});
    }
};

// ============================================================================
// Design Option C: Callback-Based (reactive)
// ============================================================================
//
// GUI tells provider what it needs, provider calls back with results.
// Allows batching and deferred operations.

pub const DesignC = struct {
    pub const TextProvider = struct {
        ptr: *anyopaque,
        vtable: *const VTable,

        pub const VTable = struct {
            // Request text to be prepared (may be async)
            requestText: *const fn (
                ptr: *anyopaque,
                text: []const u8,
                style: TextStyle,
                callback_ctx: *anyopaque,
                callback: *const fn (ctx: *anyopaque, result: TextResult) void,
            ) RequestHandle,

            // Cancel a pending request
            cancelRequest: *const fn (ptr: *anyopaque, handle: RequestHandle) void,

            // Process pending work (call each frame)
            update: *const fn (ptr: *anyopaque) void,

            // Immediate measurement (always sync)
            measureText: *const fn (ptr: *anyopaque, text: []const u8, style: TextStyle) TextMetrics,
        };

        pub const RequestHandle = u32;
        pub const TextStyle = struct {
            font_id: u16 = 0,
            size: f32 = 16,
        };
        pub const TextMetrics = struct {
            width: f32,
            height: f32,
        };

        pub const TextResult = struct {
            quads: []const GlyphQuad,
            atlas_id: u16,
            atlas_generation: u32,
        };

        pub const GlyphQuad = struct {
            x0: f32,
            y0: f32,
            x1: f32,
            y1: f32,
            u0: f32,
            v0: f32,
            u1: f32,
            v1: f32,
        };
    };

    pub fn analyze() void {
        std.debug.print("\n=== Design C: Callback-Based ===\n", .{});
        std.debug.print("Pros:\n", .{});
        std.debug.print("  + Enables async font loading\n", .{});
        std.debug.print("  + Provider can batch operations\n", .{});
        std.debug.print("  + Good for streaming fonts (IFT)\n", .{});
        std.debug.print("Cons:\n", .{});
        std.debug.print("  - Complex callback management\n", .{});
        std.debug.print("  - Latency before text appears\n", .{});
        std.debug.print("  - Overkill for embedded\n", .{});
        std.debug.print("  - Hard to use from C API\n", .{});
    }
};

// ============================================================================
// Design Option D: Layered (separation of concerns)
// ============================================================================
//
// Split into three interfaces:
//   1. FontProvider: Load fonts, get metrics
//   2. GlyphRasterizer: Rasterize individual glyphs
//   3. TextLayout: Shape and position glyphs
//
// GUI composes them as needed.

pub const DesignD = struct {
    /// Low-level: Font data access
    pub const FontProvider = struct {
        ptr: *anyopaque,
        vtable: *const VTable,

        pub const VTable = struct {
            loadFont: *const fn (ptr: *anyopaque, data: []const u8) ?FontHandle,
            unloadFont: *const fn (ptr: *anyopaque, font: FontHandle) void,
            getFontMetrics: *const fn (ptr: *anyopaque, font: FontHandle, size: f32) FontMetrics,
            getGlyphIndex: *const fn (ptr: *anyopaque, font: FontHandle, codepoint: u21) ?GlyphIndex,
            getGlyphMetrics: *const fn (ptr: *anyopaque, font: FontHandle, glyph: GlyphIndex, size: f32) GlyphMetrics,
            getKerning: *const fn (ptr: *anyopaque, font: FontHandle, left: GlyphIndex, right: GlyphIndex, size: f32) f32,
        };

        pub const FontHandle = u16;
        pub const GlyphIndex = u16;
        pub const FontMetrics = struct {
            ascent: f32,
            descent: f32,
            line_gap: f32,
            units_per_em: u16,
        };
        pub const GlyphMetrics = struct {
            advance_width: f32,
            left_bearing: f32,
            width: f32,
            height: f32,
        };
    };

    /// Mid-level: Glyph rasterization
    pub const GlyphRasterizer = struct {
        ptr: *anyopaque,
        vtable: *const VTable,

        pub const VTable = struct {
            // Rasterize to provider-managed buffer
            // Returns UV coordinates if using atlas, or raw bitmap
            rasterizeGlyph: *const fn (
                ptr: *anyopaque,
                font: FontProvider.FontHandle,
                glyph: FontProvider.GlyphIndex,
                size: f32,
            ) GlyphImage,

            // Atlas access (may be null for immediate-mode rasterizers)
            getAtlas: *const fn (ptr: *anyopaque) ?AtlasInfo,
            isAtlasDirty: *const fn (ptr: *anyopaque) bool,

            // Frame lifecycle
            beginFrame: *const fn (ptr: *anyopaque) void,
            endFrame: *const fn (ptr: *anyopaque) void,
        };

        pub const GlyphImage = union(enum) {
            // Glyph is in atlas - use these UVs
            atlas: struct {
                u0: f32,
                v0: f32,
                u1: f32,
                v1: f32,
                width: f32,
                height: f32,
                bearing_x: f32,
                bearing_y: f32,
            },
            // Glyph is immediate bitmap - render directly
            bitmap: struct {
                pixels: []const u8,
                width: u32,
                height: u32,
                bearing_x: i16,
                bearing_y: i16,
            },
            // Glyph not available
            missing,
        };

        pub const AtlasInfo = DesignB.TextProvider.AtlasInfo;
    };

    /// High-level: Text shaping and layout
    pub const TextLayout = struct {
        ptr: *anyopaque,
        vtable: *const VTable,

        pub const VTable = struct {
            // Shape text into positioned glyphs
            shapeText: *const fn (
                ptr: *anyopaque,
                text: []const u8,
                font: FontProvider.FontHandle,
                size: f32,
                out_glyphs: []ShapedGlyph,
            ) usize,

            // Layout with word wrap
            layoutParagraph: *const fn (
                ptr: *anyopaque,
                text: []const u8,
                font: FontProvider.FontHandle,
                size: f32,
                max_width: f32,
                out_lines: []LayoutLine,
            ) usize,
        };

        pub const ShapedGlyph = struct {
            glyph_index: FontProvider.GlyphIndex,
            x_offset: f32,
            y_offset: f32,
            x_advance: f32,
            cluster: u32, // Index into original text
        };

        pub const LayoutLine = struct {
            start_glyph: u32,
            end_glyph: u32,
            width: f32,
            baseline_y: f32,
        };
    };

    pub fn analyze() void {
        std.debug.print("\n=== Design D: Layered ===\n", .{});
        std.debug.print("Pros:\n", .{});
        std.debug.print("  + Clear separation of concerns\n", .{});
        std.debug.print("  + Can swap any layer independently\n", .{});
        std.debug.print("  + Embedded can skip shaping layer\n", .{});
        std.debug.print("  + Desktop can use full HarfBuzz\n", .{});
        std.debug.print("Cons:\n", .{});
        std.debug.print("  - Most complex API surface\n", .{});
        std.debug.print("  - GUI must coordinate three interfaces\n", .{});
        std.debug.print("  - May be over-engineered\n", .{});
    }
};

// ============================================================================
// Design Option E: Hybrid (pragmatic compromise)
// ============================================================================
//
// Two-tier design:
//   - Simple tier: measureText + getGlyphQuads (covers 90% of use cases)
//   - Advanced tier: Optional shaping, layout, custom rasterization
//
// Embedded uses simple tier only. Desktop can opt into advanced.

pub const DesignE = struct {
    pub const TextProvider = struct {
        ptr: *anyopaque,
        vtable: *const VTable,

        pub const VTable = struct {
            // === Core (required) ===

            /// Measure text bounds
            measureText: *const fn (
                ptr: *anyopaque,
                text: []const u8,
                font_id: u16,
                size: f32,
            ) TextMetrics,

            /// Get positioned glyph quads for rendering
            /// Caller provides output buffer (no allocation)
            /// Returns number of quads written
            getGlyphQuads: *const fn (
                ptr: *anyopaque,
                text: []const u8,
                font_id: u16,
                size: f32,
                origin: [2]f32,
                out_quads: []GlyphQuad,
                out_atlas_id: *u16,
            ) usize,

            /// Get atlas texture info (may return null for immediate-mode)
            getAtlas: *const fn (ptr: *anyopaque, atlas_id: u16) ?AtlasInfo,

            // === Lifecycle ===

            /// Called each frame before rendering
            beginFrame: *const fn (ptr: *anyopaque) void,

            /// Called each frame after rendering
            endFrame: *const fn (ptr: *anyopaque) void,

            // === Optional extensions (null = not supported) ===

            /// Extended: Get individual character positions
            /// (For text input cursor placement)
            getCharPositions: ?*const fn (
                ptr: *anyopaque,
                text: []const u8,
                font_id: u16,
                size: f32,
                out_positions: []f32,
            ) usize,

            /// Extended: Complex script shaping
            /// (For Arabic, Devanagari, etc.)
            shapeText: ?*const fn (
                ptr: *anyopaque,
                text: []const u8,
                font_id: u16,
                size: f32,
                out_shaped: []ShapedGlyph,
            ) usize,

            /// Extended: Load font at runtime
            /// (Embedded uses compile-time fonts)
            loadFont: ?*const fn (
                ptr: *anyopaque,
                name: []const u8,
                data: []const u8,
            ) ?u16,
        };

        // Core types
        pub const TextMetrics = struct {
            width: f32,
            height: f32,
            ascent: f32,
            descent: f32,
        };

        pub const GlyphQuad = struct {
            // Screen position
            x0: f32,
            y0: f32,
            x1: f32,
            y1: f32,
            // Atlas UV (0-1 range)
            u0: f32,
            v0: f32,
            u1: f32,
            v1: f32,
            // Color multiplier (for color fonts)
            color: u32,
        };

        pub const AtlasInfo = struct {
            pixels: ?[]const u8, // null = GPU-only atlas
            width: u32,
            height: u32,
            format: Format,
            generation: u32,

            pub const Format = enum(u8) {
                alpha8,
                rgba32,
                sdf,
                msdf,
            };
        };

        // Extended types
        pub const ShapedGlyph = struct {
            glyph_id: u16,
            x_offset: i16,
            y_offset: i16,
            x_advance: u16,
            cluster: u32,
        };

        // Convenience wrappers
        pub fn measureText(self: TextProvider, text: []const u8, font_id: u16, size: f32) TextMetrics {
            return self.vtable.measureText(self.ptr, text, font_id, size);
        }

        pub fn hasShaping(self: TextProvider) bool {
            return self.vtable.shapeText != null;
        }

        pub fn hasRuntimeFonts(self: TextProvider) bool {
            return self.vtable.loadFont != null;
        }
    };

    pub fn analyze() void {
        std.debug.print("\n=== Design E: Hybrid (Recommended) ===\n", .{});
        std.debug.print("Pros:\n", .{});
        std.debug.print("  + Simple core API (4 required functions)\n", .{});
        std.debug.print("  + Optional extensions for advanced use\n", .{});
        std.debug.print("  + No allocation in render path\n", .{});
        std.debug.print("  + Embedded can use minimal impl\n", .{});
        std.debug.print("  + Desktop can use full-featured impl\n", .{});
        std.debug.print("  + Feature detection via null checks\n", .{});
        std.debug.print("Cons:\n", .{});
        std.debug.print("  - Optional functions add complexity\n", .{});
        std.debug.print("  - GUI must handle missing features gracefully\n", .{});
    }
};

// ============================================================================
// Comparison Analysis
// ============================================================================

fn compareDesigns() void {
    std.debug.print("\n=== Design Comparison ===\n\n", .{});

    const Header = struct {
        name: []const u8,
        embedded: []const u8,
        desktop: []const u8,
        complexity: []const u8,
    };

    const headers = [_]Header{
        .{ .name = "Design", .embedded = "Embedded", .desktop = "Desktop", .complexity = "Complexity" },
        .{ .name = "------", .embedded = "--------", .desktop = "-------", .complexity = "----------" },
        .{ .name = "A: BYOT", .embedded = "Poor", .desktop = "OK", .complexity = "Low" },
        .{ .name = "B: Atlas", .embedded = "Good", .desktop = "Good", .complexity = "Medium" },
        .{ .name = "C: Callback", .embedded = "Poor", .desktop = "Good", .complexity = "High" },
        .{ .name = "D: Layered", .embedded = "Good", .desktop = "Excellent", .complexity = "High" },
        .{ .name = "E: Hybrid", .embedded = "Good", .desktop = "Good", .complexity = "Medium" },
    };

    for (headers) |h| {
        std.debug.print("{s:<15} {s:<12} {s:<12} {s:<12}\n", .{
            h.name,
            h.embedded,
            h.desktop,
            h.complexity,
        });
    }

    std.debug.print("\nRecommendation: Design E (Hybrid)\n", .{});
    std.debug.print("  - Balances simplicity with extensibility\n", .{});
    std.debug.print("  - Core API is minimal and allocation-free\n", .{});
    std.debug.print("  - Extensions can be added as null vtable entries\n", .{});
    std.debug.print("  - Embedded and desktop share same interface\n", .{});
}

// ============================================================================
// Implementation Sketch
// ============================================================================

/// Example: Minimal embedded provider (Design E)
pub const EmbeddedTextProvider = struct {
    // Pre-baked font atlas (comptime embedded)
    atlas: []const u8,
    atlas_width: u32,
    atlas_height: u32,

    // Glyph metrics table
    glyphs: []const GlyphInfo,
    first_char: u8,

    const GlyphInfo = struct {
        x: u16, // Position in atlas
        y: u16,
        w: u8, // Size
        h: u8,
        xoff: i8, // Bearing
        yoff: i8,
        advance: u8,
    };

    pub fn interface(self: *EmbeddedTextProvider) DesignE.TextProvider {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    const vtable = DesignE.TextProvider.VTable{
        .measureText = measureTextImpl,
        .getGlyphQuads = getGlyphQuadsImpl,
        .getAtlas = getAtlasImpl,
        .beginFrame = beginFrameImpl,
        .endFrame = endFrameImpl,
        // Extensions not supported
        .getCharPositions = null,
        .shapeText = null,
        .loadFont = null,
    };

    fn measureTextImpl(ptr: *anyopaque, text: []const u8, _: u16, _: f32) DesignE.TextProvider.TextMetrics {
        const self: *EmbeddedTextProvider = @ptrCast(@alignCast(ptr));
        var width: f32 = 0;
        var max_height: f32 = 0;

        for (text) |char| {
            if (self.getGlyphInfo(char)) |info| {
                width += @floatFromInt(info.advance);
                max_height = @max(max_height, @as(f32, @floatFromInt(info.h)));
            }
        }

        return .{
            .width = width,
            .height = max_height,
            .ascent = max_height * 0.8,
            .descent = max_height * 0.2,
        };
    }

    fn getGlyphQuadsImpl(
        ptr: *anyopaque,
        text: []const u8,
        _: u16,
        _: f32,
        origin: [2]f32,
        out_quads: []DesignE.TextProvider.GlyphQuad,
        out_atlas_id: *u16,
    ) usize {
        const self: *EmbeddedTextProvider = @ptrCast(@alignCast(ptr));
        out_atlas_id.* = 0;

        var cursor_x = origin[0];
        const cursor_y = origin[1];
        var quad_count: usize = 0;

        for (text) |char| {
            if (quad_count >= out_quads.len) break;

            if (self.getGlyphInfo(char)) |info| {
                const x0 = cursor_x + @as(f32, @floatFromInt(info.xoff));
                const y0 = cursor_y + @as(f32, @floatFromInt(info.yoff));
                const x1 = x0 + @as(f32, @floatFromInt(info.w));
                const y1 = y0 + @as(f32, @floatFromInt(info.h));

                const inv_w = 1.0 / @as(f32, @floatFromInt(self.atlas_width));
                const inv_h = 1.0 / @as(f32, @floatFromInt(self.atlas_height));

                out_quads[quad_count] = .{
                    .x0 = x0,
                    .y0 = y0,
                    .x1 = x1,
                    .y1 = y1,
                    .u0 = @as(f32, @floatFromInt(info.x)) * inv_w,
                    .v0 = @as(f32, @floatFromInt(info.y)) * inv_h,
                    .u1 = @as(f32, @floatFromInt(info.x + info.w)) * inv_w,
                    .v1 = @as(f32, @floatFromInt(info.y + info.h)) * inv_h,
                    .color = 0xFFFFFFFF,
                };

                cursor_x += @floatFromInt(info.advance);
                quad_count += 1;
            }
        }

        return quad_count;
    }

    fn getAtlasImpl(ptr: *anyopaque, _: u16) ?DesignE.TextProvider.AtlasInfo {
        const self: *EmbeddedTextProvider = @ptrCast(@alignCast(ptr));
        return .{
            .pixels = self.atlas,
            .width = self.atlas_width,
            .height = self.atlas_height,
            .format = .alpha8,
            .generation = 0, // Never changes
        };
    }

    fn beginFrameImpl(_: *anyopaque) void {}
    fn endFrameImpl(_: *anyopaque) void {}

    fn getGlyphInfo(self: *EmbeddedTextProvider, char: u8) ?GlyphInfo {
        if (char < self.first_char) return null;
        const index = char - self.first_char;
        if (index >= self.glyphs.len) return null;
        return self.glyphs[index];
    }
};

// ============================================================================
// Main
// ============================================================================

pub fn main() !void {
    std.debug.print("Experiment 3: TextProvider Interface Design\n", .{});
    std.debug.print("============================================\n", .{});

    DesignA.analyze();
    DesignB.analyze();
    DesignC.analyze();
    DesignD.analyze();
    DesignE.analyze();

    compareDesigns();

    std.debug.print("\n=== Memory Footprint of Interface ===\n", .{});
    std.debug.print("Design A vtable: {} bytes\n", .{@sizeOf(DesignA.TextProvider.VTable)});
    std.debug.print("Design B vtable: {} bytes\n", .{@sizeOf(DesignB.TextProvider.VTable)});
    std.debug.print("Design E vtable: {} bytes\n", .{@sizeOf(DesignE.TextProvider.VTable)});
    std.debug.print("\n", .{});
    std.debug.print("GlyphQuad size: {} bytes\n", .{@sizeOf(DesignE.TextProvider.GlyphQuad)});
    std.debug.print("TextMetrics size: {} bytes\n", .{@sizeOf(DesignE.TextProvider.TextMetrics)});
}
