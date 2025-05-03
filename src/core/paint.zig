const Color = @import("color.zig").Color;
const ImageHandle = @import("image.zig").ImageHandle;
const Point = @import("geometry.zig").Point;

pub const Paint = struct {
    // Color information
    color: Color = Color.fromRGBA(0, 0, 0, 255), // Default: solid black

    // Fill properties
    fill_type: FillType = .solid,
    gradient: ?Gradient = null,
    pattern: ?ImageHandle = null,

    // Stroke properties
    stroke_width: f32 = 1.0,
    stroke_color: ?Color = null, // null means no stroke
    stroke_style: StrokeStyle = .solid,

    // Blending
    blend_mode: BlendMode = .normal,

    // Other properties
    anti_alias: bool = true,
    opacity: f32 = 1.0, // 0.0-1.0
    filter: ?Filter = null,

    // Helper functions for creating common paint configurations
    pub fn solid(color: Color) Paint {
        return .{ .color = color };
    }

    pub fn stroke(color: Color, width: f32) Paint {
        return .{
            .color = .{ .r = 0, .g = 0, .b = 0, .a = 0 }, // Transparent fill
            .stroke_color = color,
            .stroke_width = width,
        };
    }

    pub fn textPaint(color: Color, font_size: f32) Paint {
        return .{
            .color = color,
            .text_size = font_size,
        };
    }

    // Helper to create a copy with modified properties
    pub fn withOpacity(self: Paint, new_opacity: f32) Paint {
        var copy = self;
        copy.opacity = new_opacity;
        return copy;
    }
};

pub const FillType = enum {
    solid,
    gradient,
    pattern,
};

pub const StrokeStyle = enum {
    solid,
    dashed,
    dotted,
};

pub const BlendMode = enum {
    normal,
    multiply,
    screen,
    overlay,
    darken,
    lighten,
    // Other blend modes as needed
};

pub const Gradient = struct {
    type: GradientType,
    stops: []const GradientStop,
    start_point: Point,
    end_point: Point,

    pub const GradientType = enum {
        linear,
        radial,
    };

    pub const GradientStop = struct {
        position: f32, // 0.0-1.0
        color: Color,
    };
};

pub const Filter = struct {
    // Potential filter properties
    blur_radius: f32 = 0.0,
    // Other filter properties as needed
};
