// Core GUI types
pub const GUI = @import("gui.zig").GUI;
pub const GUIConfig = @import("gui.zig").GUIConfig;
pub const bind = @import("gui.zig").bind;
pub const RendererInterface = @import("renderer.zig").RendererInterface;

// Geometry and rendering primitives
pub const Rect = @import("core/geometry.zig").Rect;
pub const Point = @import("core/geometry.zig").Point;
pub const Paint = @import("core/paint.zig").Paint;
pub const ImageHandle = @import("core/image.zig").ImageHandle;
pub const Path = @import("core/path.zig").Path;
pub const ImageFormat = @import("core/image.zig").ImageFormat;
pub const FontHandle = @import("core/font.zig").FontHandle;
pub const Transform = @import("core/transform.zig").Transform;
pub const Color = @import("core/color.zig").Color;
pub const EdgeInsets = @import("core/geometry.zig").EdgeInsets;

// State management - Tracked Signals
// See docs/STATE_MANAGEMENT.md for design rationale
const tracked = @import("tracked.zig");
pub const Tracked = tracked.Tracked;
pub const computeStateVersion = tracked.computeStateVersion;
pub const stateChanged = tracked.stateChanged;
pub const findChangedFields = tracked.findChangedFields;
pub const captureFieldVersions = tracked.captureFieldVersions;

pub const components = struct {
    pub const View = @import("components/view.zig").View;
    pub const Container = @import("components/container.zig").Container;
    pub const Box = @import("components/box.zig").Box;
};
