const Rect = @import("core/geometry.zig").Rect;
const Point = @import("core/geometry.zig").Point;
const Paint = @import("core/paint.zig").Paint;
const ImageHandle = @import("core/image.zig").ImageHandle;
const ImageFormat = @import("core/image.zig").ImageFormat;
const Path = @import("core/path.zig").Path;
const FontHandle = @import("core/font.zig").FontHandle;
const Transform = @import("core/transform.zig").Transform;

const Self = @This();

vtable: *const VTable,

pub const VTable = struct {
    // Context management
    beginFrame: *const fn (self: *Self, width: f32, height: f32) void,
    endFrame: *const fn (self: *Self) void,

    // Drawing primitives
    drawRect: *const fn (self: *Self, rect: Rect, paint: Paint) void,
    drawRoundRect: *const fn (self: *Self, rect: Rect, radius: f32, paint: Paint) void,
    drawText: *const fn (self: *Self, text: []const u8, position: Point, paint: Paint) void,
    drawImage: *const fn (self: *Self, image_handle: ImageHandle, rect: Rect, paint: Paint) void,
    drawPath: *const fn (self: *Self, path: Path, paint: Paint) void,

    // Resource management
    createImage: *const fn (self: *Self, width: u32, height: u32, format: ImageFormat, data: ?[]const u8) ?ImageHandle,
    destroyImage: *const fn (self: *Self, handle: ImageHandle) void,
    createFont: *const fn (self: *Self, data: []const u8, size: f32) ?FontHandle,
    destroyFont: *const fn (self: *Self, handle: FontHandle) void,

    // State management
    save: *const fn (self: *Self) void,
    restore: *const fn (self: *Self) void,
    clip: *const fn (self: *Self, rect: Rect) void,
    transform: *const fn (self: *Self, transform: Transform) void,
};
