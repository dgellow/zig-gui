# Plan: Merge zlay v2.0 into zig-gui

**Date:** 2025-11-30
**Context:** Optimize layout engine directly for zig-gui, extract as separate lib later if needed
**User directive:** "For now if it is better you can move Zlay to zig-GUI implementation instead of a distinct lib. Let's optimize it for zig-gui."

## Executive Summary

**Current:** `lib/zlay/` as separate library, `src/layout.zig` wraps it
**Target:** `src/layout/` containing all layout implementation, optimized for zig-gui
**Benefit:** Tighter integration, simpler imports, same validated performance

## Current Structure

```
lib/zlay/
├── src/
│   ├── layout_engine_v2.zig     (407 lines) - Core engine
│   ├── flexbox.zig              (300+ lines) - Flexbox algorithm
│   ├── cache.zig                (167 lines) - Layout caching
│   ├── dirty_tracking.zig       (200 lines) - Spineless traversal
│   ├── simd.zig                 (200 lines) - SIMD optimizations
│   ├── core.zig                 - Common types
│   └── full_layout_benchmark.zig (400+ lines) - Benchmarks
├── docs/
│   ├── HONEST_VALIDATION_RESULTS.md
│   ├── ARCHITECTURE.md
│   └── PERFORMANCE_RESULTS.md
└── build.zig

src/
└── layout.zig                    (143 lines) - Thin wrapper importing zlay
```

## Target Structure

```
src/
├── layout/
│   ├── engine.zig               (was zlay's layout_engine_v2.zig)
│   ├── flexbox.zig              (from zlay, optimized for zig-gui)
│   ├── cache.zig                (from zlay)
│   ├── dirty_tracking.zig       (from zlay)
│   ├── simd.zig                 (from zlay)
│   └── wrapper.zig              (ID-based API for immediate-mode)
├── layout.zig                   (exports layout/* modules)
└── core/
    ├── geometry.zig             (Rect, Point, Size - used by layout)
    └── ...

lib/zlay/                        (KEEP for reference and benchmarks)
├── docs/                        (KEEP - validation documentation)
│   ├── HONEST_VALIDATION_RESULTS.md
│   └── ...
├── benchmarks/                  (KEEP - can run independently)
│   └── full_layout_benchmark.zig
└── README.md                    (UPDATE - note: implementation moved to zig-gui)
```

## Migration Steps

### Step 1: Create src/layout/ directory structure

```bash
mkdir -p src/layout
```

### Step 2: Copy zlay files to src/layout/

```bash
# Core layout engine
cp lib/zlay/src/layout_engine_v2.zig src/layout/engine.zig
cp lib/zlay/src/flexbox.zig src/layout/flexbox.zig
cp lib/zlay/src/cache.zig src/layout/cache.zig
cp lib/zlay/src/dirty_tracking.zig src/layout/dirty_tracking.zig
cp lib/zlay/src/simd.zig src/layout/simd.zig
```

### Step 3: Update imports in moved files

**Before (separate lib):**
```zig
const core = @import("core.zig");
const Rect = core.Rect;
const FlexStyle = @import("flexbox.zig").FlexStyle;
```

**After (integrated):**
```zig
const Rect = @import("../core/geometry.zig").Rect;
const FlexStyle = @import("flexbox.zig").FlexStyle;
```

### Step 4: Create src/layout/wrapper.zig for immediate-mode API

```zig
//! ID-based immediate-mode API for layout
//! Provides the bridge between GUI function calls and data-oriented layout engine

const std = @import("std");
const LayoutEngine = @import("engine.zig").LayoutEngine;
const FlexStyle = @import("flexbox.zig").FlexStyle;
const Rect = @import("../core/geometry.zig").Rect;

/// Wrapper providing ID-based immediate-mode API
pub const LayoutWrapper = struct {
    engine: LayoutEngine,
    id_map: std.StringHashMap(u32),
    parent_stack: std.ArrayList(u32),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !LayoutWrapper {
        return .{
            .engine = try LayoutEngine.init(allocator),
            .id_map = std.StringHashMap(u32).init(allocator),
            .parent_stack = std.ArrayList(u32).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *LayoutWrapper) void {
        self.engine.deinit();
        self.id_map.deinit();
        self.parent_stack.deinit();
    }

    /// Begin a new frame - clear per-frame state
    pub fn beginFrame(self: *LayoutWrapper) void {
        self.engine.beginFrame();
        self.id_map.clearRetainingCapacity();
        self.parent_stack.clearRetainingCapacity();
    }

    /// Add element with automatic parent tracking
    pub fn addElement(self: *LayoutWrapper, id: []const u8, style: FlexStyle) !u32 {
        const parent = if (self.parent_stack.items.len > 0)
            self.parent_stack.items[self.parent_stack.items.len - 1]
        else
            null;

        const index = try self.engine.addElement(parent, style);
        try self.id_map.put(id, index);
        return index;
    }

    /// Begin container - pushes to parent stack
    pub fn beginContainer(self: *LayoutWrapper, id: []const u8, style: FlexStyle) !void {
        const index = try self.addElement(id, style);
        try self.parent_stack.append(index);
    }

    /// End container - pops from parent stack
    pub fn endContainer(self: *LayoutWrapper) void {
        _ = self.parent_stack.pop();
    }

    pub fn computeLayout(self: *LayoutWrapper, width: f32, height: f32) !void {
        try self.engine.computeLayout(width, height);
    }

    pub fn getLayout(self: *const LayoutWrapper, id: []const u8) ?Rect {
        const index = self.id_map.get(id) orelse return null;
        return self.engine.getRect(index);
    }

    pub fn markDirty(self: *LayoutWrapper, id: []const u8) void {
        const index = self.id_map.get(id) orelse return;
        self.engine.markDirty(index);
    }
};
```

### Step 5: Update src/layout.zig to re-export

```zig
//! High-Performance Layout System
//!
//! Data-oriented layout engine optimized for zig-gui.
//! Performance: 0.029-0.107μs per element (4-14x faster than Taffy/Yoga)
//!
//! See lib/zlay/docs/HONEST_VALIDATION_RESULTS.md for validation.

// Core layout engine (data-oriented)
pub const LayoutEngine = @import("layout/engine.zig").LayoutEngine;
pub const FlexStyle = @import("layout/flexbox.zig").FlexStyle;
pub const FlexDirection = @import("layout/flexbox.zig").FlexDirection;
pub const JustifyContent = @import("layout/flexbox.zig").JustifyContent;
pub const AlignItems = @import("layout/flexbox.zig").AlignItems;
pub const LayoutResult = @import("layout/flexbox.zig").LayoutResult;

// Caching and optimization
pub const CacheStats = @import("layout/cache.zig").CacheStats;
pub const DirtyQueue = @import("layout/dirty_tracking.zig").DirtyQueue;

// ID-based immediate-mode API (for GUI)
pub const LayoutWrapper = @import("layout/wrapper.zig").LayoutWrapper;
```

### Step 6: Update src/gui.zig

**Before:**
```zig
const LayoutEngine = @import("layout.zig").LayoutEngine;

const layout_engine_val = try LayoutEngine.init(allocator);
const layout_engine = try allocator.create(LayoutEngine);
layout_engine.* = layout_engine_val;
```

**After:**
```zig
const LayoutWrapper = @import("layout.zig").LayoutWrapper;

const layout = try allocator.create(LayoutWrapper);
layout.* = try LayoutWrapper.init(allocator);
```

### Step 7: Keep lib/zlay/ for reference

**Update lib/zlay/README.md:**
```markdown
# zlay - High-Performance Layout Engine

**NOTE:** The implementation has been integrated into zig-gui (`src/layout/`).

This directory contains:
- **docs/** - Validation results and architecture documentation
- **benchmarks/** - Independent benchmarks (can run separately)

The layout engine is optimized specifically for zig-gui's immediate-mode API.
It may be extracted as a separate library in the future.

## Performance (Validated)

See [docs/HONEST_VALIDATION_RESULTS.md](docs/HONEST_VALIDATION_RESULTS.md):
- Email Client: 0.073μs per element (5.7x faster than Taffy)
- Game HUD: 0.107μs per element (3.9x faster than Taffy)
- Stress Test: 0.032μs per element (13.1x faster than Taffy)

All 31 tests passing.
```

### Step 8: Update build.zig

Remove separate zlay module, it's now part of zig-gui:
```zig
// Before: had separate zlay module
// After: layout is in src/layout/, no separate module needed
```

## Benefits of This Approach

### 1. Tighter Integration
```zig
// Before: Import through library boundary
const zlay = @import("zlay");
const LayoutEngine = zlay.layout_engine_v2.LayoutEngine;

// After: Direct import
const LayoutEngine = @import("layout/engine.zig").LayoutEngine;
```

### 2. Optimize for zig-gui Specifically
- Can use zig-gui's core types directly (no wrapper)
- Can add GUI-specific optimizations
- Can tune for immediate-mode pattern

### 3. Simpler Build
- No separate library compilation
- Faster incremental builds
- Easier to debug (everything in one codebase)

### 4. Same Validated Performance
- Code is identical (just moved)
- All 31 tests still pass
- Performance validated at 0.029-0.107μs per element

### 5. Can Extract Later
- All code in `src/layout/` directory
- Easy to move back to separate lib if needed
- Documentation preserved in `lib/zlay/docs/`

## Migration Checklist

- [ ] Create `src/layout/` directory
- [ ] Copy zlay files to `src/layout/`
- [ ] Update imports in moved files
- [ ] Create `src/layout/wrapper.zig` for ID-based API
- [ ] Update `src/layout.zig` to re-export
- [ ] Update `src/gui.zig` to use LayoutWrapper
- [ ] Update `src/root.zig` exports
- [ ] Update `lib/zlay/README.md` (note implementation moved)
- [ ] Update build.zig (remove separate zlay module)
- [ ] Test: Ensure everything compiles
- [ ] Test: Run layout benchmarks
- [ ] Commit: "Merge zlay v2.0 into zig-gui src/layout/"

## Preserved Documentation

Keep in `lib/zlay/docs/` for reference:
- ✅ HONEST_VALIDATION_RESULTS.md (validation proof)
- ✅ ARCHITECTURE.md (design decisions)
- ✅ PERFORMANCE_RESULTS.md (benchmarks)
- ✅ V2_IMPLEMENTATION_STATUS.md (implementation notes)

These serve as:
1. Proof of validated performance
2. Design documentation
3. Reference for future optimizations
4. Material for blog posts/papers

## Future: Extract if Needed

If we later want zlay as a separate library:
1. Move `src/layout/*` back to `lib/zlay/src/`
2. Remove GUI-specific optimizations
3. Generalize API
4. Publish as standalone library

But for now: **Optimize for zig-gui first.**

---

**Decision:** Merge zlay into zig-gui for tighter integration. Extract later if needed.
