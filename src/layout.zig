//! High-Performance Layout System for zig-gui
//!
//! Data-oriented layout engine integrated directly into zig-gui.
//! Performance: 0.029-0.107μs per element (4-14x faster than Taffy/Yoga)
//!
//! Validated with 31 passing tests.
//! See BENCHMARKS.md for complete validation.

const std = @import("std");

// Core layout engine (data-oriented, cache-friendly)
pub const LayoutEngine = @import("layout/engine.zig").LayoutEngine;

// Flexbox algorithm and types
pub const FlexStyle = @import("layout/flexbox.zig").FlexStyle;
pub const FlexDirection = @import("layout/flexbox.zig").FlexDirection;
pub const JustifyContent = @import("layout/flexbox.zig").JustifyContent;
pub const AlignItems = @import("layout/flexbox.zig").AlignItems;
pub const LayoutResult = @import("layout/flexbox.zig").LayoutResult;

// Performance and debugging
pub const CacheStats = @import("layout/cache.zig").CacheStats;
pub const LayoutCacheEntry = @import("layout/cache.zig").LayoutCacheEntry;
pub const DirtyQueue = @import("layout/dirty_tracking.zig").DirtyQueue;

// Geometry types (from core)
pub const Rect = @import("core/geometry.zig").Rect;
pub const Point = @import("core/geometry.zig").Point;
pub const Size = @import("core/geometry.zig").Size;
pub const EdgeInsets = @import("core/geometry.zig").EdgeInsets;
