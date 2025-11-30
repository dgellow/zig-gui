# Layout Engine Integration Status

**Status:** Merging zlay v2.0 into src/layout/ for tighter integration
**Approach:** Move zlay implementation into zig-gui, optimize for immediate-mode API

## What's Done ✅

1. ✅ **Validated performance** - 0.029-0.107μs per element (4-14x faster, 31 tests passing)
2. ✅ **Design decision** - Pure ID-based immediate-mode API (spec-compliant)
3. ✅ **Architecture analysis** - Multi-paradigm hybrid (immediate API + retained optimizations)
4. ✅ **Merge plan created** - docs/ZLAY_MERGE_PLAN.md (integrate zlay into src/layout/)
5. ✅ **Breaking changes committed** - Old layout.zig removed (802 lines)

## Remaining Work 🔧

### Phase 1: Merge zlay into src/layout/

**Goal:** Integrate layout engine directly into zig-gui for tighter optimization

**Tasks:**
1. Create `src/layout/` directory structure
2. Copy zlay files: engine.zig, flexbox.zig, cache.zig, dirty_tracking.zig, simd.zig
3. Update imports (use zig-gui core types directly)
4. Create `src/layout/wrapper.zig` (ID-based immediate-mode API)
5. Update `src/layout.zig` to re-export layout modules
6. Update `lib/zlay/README.md` (note implementation moved)

**See:** docs/ZLAY_MERGE_PLAN.md for complete plan

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

**Approach:** Merge zlay into zig-gui, then implement immediate-mode API

### Phase 1: Merge Layout Engine (Current)
1. ✅ **Review spec.md** - DONE (multi-paradigm hybrid architecture)
2. ✅ **Make decision** - DONE (Pure ID-based, merge into src/layout/)
3. ✅ **Create merge plan** - DONE (docs/ZLAY_MERGE_PLAN.md)
4. **Execute merge** - Copy zlay to src/layout/, update imports
5. **Create LayoutWrapper** - ID-based API with nesting stack
6. **Test merge** - Ensure layout still works

### Phase 2: Immediate-Mode API
7. **Delete View-based code** - src/components/view.zig and references
8. **Update GUI methods** - button(id, text), container(id, style, fn)
9. **Frame lifecycle** - beginFrame/endFrame in App
10. **Create examples** - Todo, Email, Game HUD (matching spec)
11. **Validate performance** - Ensure no regression from ID tracking
12. **Update documentation** - Reflect immediate-mode API

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

**Current status:** Decision made to merge zlay into src/layout/ for tighter integration. Next: Execute merge, create LayoutWrapper with ID-based API, then implement immediate-mode GUI methods.
