// zig-gui: The Revolutionary UI Library
//
// Solving the impossible trinity of GUI development:
// - Performance: 0% idle CPU, 120+ FPS
// - Developer Experience: Immediate-mode simplicity with hot reload
// - Universality: Embedded to desktop with the same code
//
// State Management: Uses Tracked Signals (4 bytes per field, O(1) writes)
// See STATE_MANAGEMENT.md for design rationale.

// =============================================================================
// Core Application Types
// =============================================================================

/// App with typed state and hybrid execution modes
pub const App = @import("app.zig").App;

/// Application configuration
pub const AppConfig = @import("app.zig").AppConfig;

/// Execution modes: event_driven, game_loop, minimal, server_side
pub const ExecutionMode = @import("app.zig").ExecutionMode;

/// Performance statistics
pub const PerformanceStats = @import("app.zig").PerformanceStats;

/// Event types and data
pub const Event = @import("app.zig").Event;
pub const EventType = @import("app.zig").EventType;

/// Platform interface (vtable for runtime platform dispatch)
/// Enables C API compatibility and runtime platform selection
pub const PlatformInterface = @import("app.zig").PlatformInterface;

/// Headless platform for testing and server-side rendering
pub const HeadlessPlatform = @import("app.zig").HeadlessPlatform;

// =============================================================================
// GUI Types
// =============================================================================

/// Core GUI context
pub const GUI = @import("gui.zig").GUI;

/// GUI configuration
pub const GUIConfig = @import("gui.zig").GUIConfig;

/// Renderer interface for custom backends
pub const RendererInterface = @import("renderer.zig").RendererInterface;

// =============================================================================
// State Management - Tracked Signals
// =============================================================================
//
// Tracked(T) wraps any value with a version counter for reactive state.
// This is the recommended way to manage state in zig-gui applications.
//
// Example:
// ```zig
// const AppState = struct {
//     counter: Tracked(i32) = .{ .value = 0 },
//     name: Tracked([]const u8) = .{ .value = "World" },
// };
//
// fn myUI(gui: *GUI, state: *AppState) !void {
//     try gui.text("Counter: {}", .{state.counter.get()});
//     if (try gui.button("Increment")) {
//         state.counter.set(state.counter.get() + 1);
//     }
// }
// ```
//
// Performance characteristics:
// - Memory: 4 bytes per Tracked field (version counter)
// - Write: O(1) - just increment version
// - Read: O(1) - direct field access
// - Change detection: O(N) where N = field count (NOT data size)
//
// For O(1) global change detection, use Reactive(T) wrapper:
// ```zig
// var state = Reactive(MyState).init();
// state.set(.counter, 42);  // O(1) write
// if (state.changed(&v)) {  // O(1) check!
//     // re-render
// }
// ```
//
// See STATE_MANAGEMENT.md for full design rationale.

const tracked = @import("tracked.zig");

/// Tracked value wrapper for reactive state management
pub const Tracked = tracked.Tracked;

/// Reactive wrapper for O(1) global change detection (Option E optimization)
/// Use when you need fastest possible "did anything change?" checks
pub const Reactive = tracked.Reactive;

/// Compute combined version of all Tracked fields (O(N) where N = field count)
pub const computeStateVersion = tracked.computeStateVersion;

/// Check if any Tracked field changed since last check (O(N))
/// For O(1), use Reactive(T).changed() instead
pub const stateChanged = tracked.stateChanged;

/// Find which specific fields changed (for partial updates)
pub const findChangedFields = tracked.findChangedFields;

/// Capture current versions of all Tracked fields
pub const captureFieldVersions = tracked.captureFieldVersions;

/// Check if a Reactive state changed (O(1))
pub const reactiveChanged = tracked.reactiveChanged;

// =============================================================================
// Geometry and Rendering Primitives
// =============================================================================

pub const Rect = @import("core/geometry.zig").Rect;
pub const Point = @import("core/geometry.zig").Point;
pub const Size = @import("core/geometry.zig").Size;
pub const EdgeInsets = @import("core/geometry.zig").EdgeInsets;

pub const Paint = @import("core/paint.zig").Paint;
pub const Color = @import("core/color.zig").Color;
pub const Path = @import("core/path.zig").Path;
pub const Transform = @import("core/transform.zig").Transform;

pub const ImageHandle = @import("core/image.zig").ImageHandle;
pub const ImageFormat = @import("core/image.zig").ImageFormat;
pub const FontHandle = @import("core/font.zig").FontHandle;

// =============================================================================
// Components (moved to immediate-mode API - see spec.md)
// =============================================================================
//
// Old retained-mode components (View, Container, Box) removed.
// New immediate-mode API coming: gui.button(id, text), gui.container(id, style, fn), etc.

// =============================================================================
// Layout (integrated from zlay v2.0 - 4-14x faster!)
// =============================================================================

pub const layout = struct {
    /// High-performance data-oriented layout engine
    /// Performance: 0.029-0.107μs per element (validated with 31 tests)
    pub const LayoutEngine = @import("layout.zig").LayoutEngine;

    /// Convenience wrapper with ID-based API
    pub const LayoutWrapper = @import("layout.zig").LayoutWrapper;

    /// Flexbox style configuration
    pub const FlexStyle = @import("layout.zig").FlexStyle;

    /// Flexbox direction
    pub const FlexDirection = @import("layout.zig").FlexDirection;

    /// Main axis alignment
    pub const JustifyContent = @import("layout.zig").JustifyContent;

    /// Cross axis alignment
    pub const AlignItems = @import("layout.zig").AlignItems;

    /// Layout result
    pub const LayoutResult = @import("layout.zig").LayoutResult;

    /// Cache statistics
    pub const CacheStats = @import("layout.zig").CacheStats;
};

// =============================================================================
// Events
// =============================================================================

pub const events = struct {
    pub const EventManager = @import("events.zig").EventManager;
    pub const InputEvent = @import("events.zig").InputEvent;
    pub const Key = @import("events.zig").Key;
    pub const MouseButton = @import("events.zig").MouseButton;
    pub const KeyModifiers = @import("events.zig").KeyModifiers;
};

// =============================================================================
// Platform Backends
// =============================================================================

pub const platforms = struct {
    /// SDL platform backend - true 0% idle CPU via SDL_WaitEvent()
    pub const SdlPlatform = @import("platforms/sdl.zig").SdlPlatform;

    /// SDL platform configuration (window settings)
    pub const SdlConfig = @import("platforms/sdl.zig").SdlConfig;
};

// =============================================================================
// Profiling and Tracing
// =============================================================================
//
// Zero-cost profiling system inspired by Tracy, ImGui, and Flutter DevTools.
// - Compile-time toggleable (zero overhead when disabled)
// - Hierarchical zone-based profiling
// - Frame-based analysis
// - ~15-50ns overhead per zone (when enabled)
// - Multiple export formats (JSON, CSV, binary)
//
// Usage:
// ```zig
// const profiler = @import("zig-gui").profiler;
//
// pub fn main() !void {
//     try profiler.init(allocator, .{});
//     defer profiler.deinit();
//
//     while (app.running) {
//         profiler.frameStart();
//         defer profiler.frameEnd();
//
//         try render();
//     }
//
//     try profiler.exportJSON("profile.json");
// }
//
// fn myFunction() void {
//     profiler.zone(@src(), "myFunction", .{});
//     defer profiler.endZone();
//     // Your code here
// }
// ```
//
// Build with profiling enabled:
// ```bash
// zig build -Denable_profiling=true
// ```
//
// See PROFILING.md for full documentation.

pub const profiler = @import("profiler.zig");
