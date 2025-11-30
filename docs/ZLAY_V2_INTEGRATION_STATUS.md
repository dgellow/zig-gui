# zlay v2.0 Integration Status

**Status:** Core imports complete, View-based API adaptation layer needed

## What's Done ✅

1. **layout.zig replaced** - Thin wrapper importing zlay v2.0 (143 lines)
2. **GUI.zig imports updated** - Using zlay v2.0 LayoutEngine
3. **root.zig exports updated** - Exporting zlay v2.0 types
4. **docs/LAYOUT.md created** - Usage guide for new API
5. **Committed and pushed** - Breaking changes committed

## Remaining Work 🔧

### View-based API Adaptation Layer

**Problem:** GUI.zig expects View-based layout API, but zlay v2.0 uses index-based API.

**Current GUI.zig calls:**
```zig
// Line 190, 302
self.layout_engine.markDirty(view);  // Expects *View

// Line 246
if (self.layout_engine.needsLayout()) { ... }  // Returns bool

// Line 250
try self.layout_engine.calculateLayout(root);  // Expects root *View
```

**New zlay v2.0 API:**
```zig
markDirty(index: u32)              // Expects element index
getDirtyCount() usize              // Returns count, not bool
computeLayout(width, height)       // Expects dimensions, not root
```

### Solution Options

**Option 1: Add View mapping to LayoutWrapper** (Recommended)
```zig
pub const LayoutWrapper = struct {
    engine: LayoutEngine,
    id_map: std.StringHashMap(u32),
    view_map: std.AutoHashMap(*const View, u32),  // NEW: View → index mapping

    pub fn markDirtyView(self: *LayoutWrapper, view: *View) void {
        const index = self.view_map.get(view) orelse return;
        self.engine.markDirty(index);
    }

    pub fn needsLayout(self: *const LayoutWrapper) bool {
        return self.engine.getDirtyCount() > 0;
    }

    pub fn calculateLayout(self: *LayoutWrapper, root: *View) !void {
        try self.engine.computeLayout(root.rect.width, root.rect.height);
    }

    pub fn registerView(self: *LayoutWrapper, view: *View, index: u32) !void {
        try self.view_map.put(view, index);
    }
};
```

**Option 2: Refactor GUI.zig to use IDs directly**
- Remove View-based API completely
- Use string IDs everywhere
- More breaking changes, but cleaner long-term

### Files That Need Updates

1. **src/layout.zig** - Add View mapping to LayoutWrapper
2. **src/gui.zig** - Update to use new API (either via wrapper or direct IDs)
3. **src/components/view.zig** - Review if View needs layout index field
4. **examples/** - Update all examples to new API

### Testing Plan

1. Add View mapping to LayoutWrapper
2. Compile and fix any errors
3. Run existing tests
4. Update examples one by one
5. Verify performance is maintained

## Performance Validation

**Already validated** via lib/zlay/HONEST_VALIDATION_RESULTS.md:
- Email Client: 0.073μs per element (5.7x faster)
- Game HUD: 0.107μs per element (3.9x faster)
- Stress Test: 0.032μs per element (13.1x faster)

**Still need to validate:**
- Integration overhead (View mapping)
- Real-world zig-gui examples
- Memory usage with View mapping

## Next Steps

1. **Decide on approach** - Option 1 (View mapping) vs Option 2 (pure ID-based)
2. **Implement adapter layer** - Based on chosen approach
3. **Fix compilation errors** - Update GUI.zig and components
4. **Update examples** - Verify everything works
5. **Validate performance** - Ensure no regression from mapping overhead
6. **Update documentation** - Reflect actual API after adaptation

## Breaking Changes Summary

**Already broken (committed):**
- Old layout.zig API completely removed
- LayoutParams → FlexStyle
- LengthConstraint removed
- Old LayoutEngine.init signature changed

**May break further:**
- If choosing Option 2, View-based API would be removed from GUI
- Examples would need significant updates
- Components may need to track layout IDs

---

**Current status:** Aggressive breaking changes committed. Adaptation layer needed for full integration.
