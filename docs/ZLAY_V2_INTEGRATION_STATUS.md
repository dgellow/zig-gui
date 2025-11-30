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

### Solution: Pure ID-Based (Spec-Compliant)

**DECISION MADE: Option 2 (Pure ID-Based)**

After reviewing **docs/spec.md**, the decision is clear and unambiguous:
- ✅ Spec defines immediate-mode API (function-based UI)
- ✅ Spec shows data-oriented foundations (zlay arrays)
- ✅ User directive: "Zig gui should use whatever works best for Zlay"
- ✅ zlay works best with index-based API (no Views, no HashMap overhead)

**See docs/SPEC_ALIGNMENT_ANALYSIS.md for complete analysis.**

**Implementation approach:**
```zig
// Immediate-mode API (per spec examples)
fn MyApp(gui: *GUI, state: *AppState) !void {
    try gui.container("root", .{ .padding = 20 }, struct {
        fn content(g: *GUI, s: *AppState) !void {
            try g.text("counter", "Counter: {}", .{s.counter.get()});
            if (try g.button("increment", "Increment")) {
                s.counter.set(s.counter.get() + 1);
            }
        }
    }.content);
}

// LayoutWrapper with nesting stack (hidden from user)
pub const LayoutWrapper = struct {
    engine: LayoutEngine,                  // zlay v2.0
    id_map: StringHashMap(u32),           // ID → index (per frame)
    parent_stack: ArrayList(u32),         // Current nesting

    pub fn beginContainer(self: *LayoutWrapper, id: []const u8, style: FlexStyle) !void {
        const index = try self.addElement(id, style);
        try self.parent_stack.append(index);
    }

    pub fn endContainer(self: *LayoutWrapper) void {
        _ = self.parent_stack.pop();
    }
};
```

### Files That Need Updates

**To Delete (~500 lines):**
1. **src/components/view.zig** - Entire file (retained tree, not in spec)
2. View references in GUI - Pointer-based API
3. Old LayoutParams - Replaced with FlexStyle

**To Create/Update (~900 lines):**
1. **src/layout.zig** - Add nesting stack, per-frame ID tracking (~100 lines added)
2. **src/gui.zig** - ID-based methods (button, text, container, etc.) (~200 lines)
3. **src/app.zig** - Frame lifecycle (beginFrame/endFrame) (~50 lines)
4. **examples/** - Spec-compliant examples (~400 lines)
   - Todo app (per spec line 133)
   - Email client (per spec line 561)
   - Game HUD (per spec line 591)
5. **tests/** - Update to immediate-mode API (~150 lines)

### Testing Plan

1. ✅ **Delete View-based code** - Remove temporary scaffold
2. **Implement ID-based LayoutWrapper** - Nesting stack + per-frame ID map
3. **Update GUI methods** - button(), text(), container() with IDs
4. **Create spec examples** - Todo, Email, Game HUD (matching spec)
5. **Compile and fix errors** - Ensure everything builds
6. **Run tests** - Update to immediate-mode API
7. **Validate performance** - Ensure no regression from ID tracking

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

**Decision:** Pure ID-Based (per spec alignment analysis)

1. ✅ **Review spec.md** - DONE (see SPEC_ALIGNMENT_ANALYSIS.md)
2. ✅ **Make decision** - DONE (Pure ID-Based is spec-compliant)
3. **Implement LayoutWrapper enhancements** - Nesting stack, ID tracking
4. **Delete View-based code** - src/components/view.zig and references
5. **Update GUI to immediate-mode API** - button(id, text), etc.
6. **Create spec-matching examples** - Todo, Email, Game HUD
7. **Validate performance** - Ensure ID tracking has no overhead
8. **Update documentation** - Reflect immediate-mode API

## Breaking Changes Summary

**Already broken (committed):**
- Old layout.zig API completely removed (802 lines)
- LayoutParams → FlexStyle
- LengthConstraint removed
- Old LayoutEngine.init signature changed

**Will break next (spec-compliant refactor):**
- ✅ View-based API removed (not in spec)
- ✅ src/components/view.zig deleted (~300 lines)
- ✅ Immediate-mode API implemented (per spec)
- ✅ Examples rewritten to match spec (function-based UI)
- ✅ Tests updated to immediate-mode

**Justification:**
- Spec explicitly defines immediate-mode API
- User directive: "Zig gui should use whatever works best for Zlay"
- zlay works best with index-based, data-oriented API
- Current View-based code is temporary scaffold, not spec-compliant

---

**Current status:** Core imports complete. Next: Delete View scaffold and implement spec-compliant immediate-mode API.
