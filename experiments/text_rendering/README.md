# Text Rendering Design

**Status**: Design exploration complete. Ready for implementation.

## Executive Summary

After 13 experiments and comprehensive research, we recommend a **Hybrid Interface** design:

1. **Simple core API** (5 required functions) for basic text rendering
2. **Optional extensions** (null vtable entries) for advanced features
3. **Zero allocation** in the render path
4. **Unified interface** across embedded (32KB) and desktop (1MB)

This directory contains the experiments, decisions, and specifications for zig-gui's text rendering system.

---

## Design Space

Our unique constraint: **32KB embedded to 1MB desktop** in a single codebase.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        TEXT RENDERING DESIGN SPACE                          │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  RASTERIZATION APPROACH                                                     │
│  ───────────────────────                                                    │
│                                                                             │
│  Pre-baked ◄──────────────────────────────────────────────► Runtime         │
│  Bitmap                                                      Vector         │
│                                                                             │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐      │
│  │ Fixed    │  │ RLE      │  │ SDF      │  │ CPU      │  │ GPU      │      │
│  │ Bitmap   │  │ Compress │  │ Atlas    │  │ Raster   │  │ Vector   │      │
│  │ Atlas    │  │ Bitmap   │  │          │  │          │  │          │      │
│  └──────────┘  └──────────┘  └──────────┘  └──────────┘  └──────────┘      │
│       │              │             │             │             │            │
│       ▼              ▼             ▼             ▼             ▼            │
│   Embedded      Embedded       Desktop       Desktop       Desktop         │
│   Simple        Quality        GPU+SW        SW Only       GPU Only        │
│                                                                             │
│  CODE SIZE:    ~1KB         ~3KB          ~5KB         ~20KB        ~10KB  │
│  RAM:          Font only    Font+decode   Atlas        Cache+Atlas  Atlas  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### "Bring Your Own" Philosophy

zig-gui uses pluggable interfaces for areas where requirements vary dramatically:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         "BRING YOUR OWN" STACK                              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────────┐   ┌─────────────────┐   ┌─────────────────┐           │
│  │      BYOR       │   │      BYOT       │   │      BYOL       │           │
│  │    Renderer     │   │      Text       │   │  Line Breaker   │           │
│  └────────┬────────┘   └────────┬────────┘   └────────┬────────┘           │
│           │                     │                     │                     │
│     ┌─────┴─────┐         ┌─────┴─────┐         ┌─────┴─────┐              │
│     ▼           ▼         ▼           ▼         ▼           ▼              │
│  ┌──────┐  ┌──────┐  ┌──────┐  ┌──────┐  ┌──────┐  ┌──────┐               │
│  │OpenGL│  │Softw.│  │Bitmap│  │ STB  │  │Simple│  │ UAX  │               │
│  │Vulkan│  │Raster│  │ Font │  │ SDF  │  │Greedy│  │ #14  │               │
│  │Metal │  │      │  │      │  │      │  │      │  │ ICU  │               │
│  └──────┘  └──────┘  └──────┘  └──────┘  └──────┘  └──────┘               │
│                                                                             │
│  Embedded: Software + Bitmap + Simple                                       │
│  Desktop:  OpenGL + STB + Greedy                                           │
│  i18n:     OpenGL + STB + UAX#14/ICU                                       │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Memory Budget Reality

From experiments:

| Configuration | Memory Used | % of Budget |
|--------------|-------------|-------------|
| Embedded minimal (8x8 1-bit) | 1.8 KB | 5.6% of 32KB |
| Embedded quality (12x20 AA) | 9 KB | 27.6% of 32KB |
| Desktop SW (512x512 atlas + cache) | 423 KB | 40.3% of 1MB |
| Desktop GPU (MSDF in VRAM) | 7 KB RAM | 0.7% of 1MB |

**Key finding**: We have more headroom than expected at both ends.

---

## Recommended Design: TextProvider Interface

```zig
pub const TextProvider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        // ═══════════════════════════════════════════════════════════════
        // UNIVERSAL (all tiers) - REQUIRED
        // ═══════════════════════════════════════════════════════════════

        measureText: *const fn (ptr: *anyopaque, text: []const u8, font_id: u16, size: f32) TextMetrics,
        getCharPositions: *const fn (ptr: *anyopaque, text: []const u8, font_id: u16, size: f32, out: []f32) usize,

        // ═══════════════════════════════════════════════════════════════
        // BIDI (optional, null = LTR only)
        // ═══════════════════════════════════════════════════════════════

        hitTest: ?*const fn (ptr: *anyopaque, text: []const u8, font_id: u16, size: f32, visual_x: f32) HitTestResult,
        getCaretInfo: ?*const fn (ptr: *anyopaque, text: []const u8, font_id: u16, size: f32, logical_index: usize) CaretInfo,

        // ═══════════════════════════════════════════════════════════════
        // EMBEDDED PATH (null for desktop providers)
        // ═══════════════════════════════════════════════════════════════

        renderDirect: ?*const fn (ptr: *anyopaque, text: []const u8, font_id: u16, size: f32, x: f32, y: f32, target: RenderTarget) void,

        // ═══════════════════════════════════════════════════════════════
        // ATLAS PATH (null for embedded direct-render)
        // ═══════════════════════════════════════════════════════════════

        getGlyphQuads: ?*const fn (ptr: *anyopaque, text: []const u8, font_id: u16, size: f32, origin: [2]f32, out_quads: []GlyphQuad) usize,
        getAtlas: ?*const fn (ptr: *anyopaque, page: u8) ?AtlasInfo,
        beginFrame: ?*const fn (ptr: *anyopaque) void,
        endFrame: ?*const fn (ptr: *anyopaque) void,

        // ═══════════════════════════════════════════════════════════════
        // EXTENSIONS (optional)
        // ═══════════════════════════════════════════════════════════════

        shapeText: ?*const fn (...) usize,
        loadFont: ?*const fn (...) ?u16,
    };

    pub const HitTestResult = struct {
        logical_index: usize,
        trailing: bool,
    };

    pub const CaretInfo = struct {
        primary_x: f32,
        secondary_x: ?f32,  // Split caret at RTL/LTR boundary
        is_rtl: bool,
    };
};

pub const AtlasInfo = struct {
    pixels: []const u8,
    width: u16,
    height: u16,
    format: AtlasFormat,
    generation: u32,
};

pub const AtlasFormat = enum {
    alpha,  // 1 byte/pixel - text glyphs
    rgba,   // 4 bytes/pixel - color emoji
};

pub const AtlasStrategy = enum {
    static,      // Pre-loaded, no eviction
    grid_lru,    // Fixed slots, O(1) eviction
    shelf_lru,   // Row-based eviction (default)
    multi_page,  // Grow when full
};

pub const TextProviderConfig = struct {
    primary_font: FontHandle,
    fallback_fonts: []const FontHandle = &.{},
    fallback_locale: ?[]const u8 = null,  // For Han unification
    missing_glyph: MissingGlyphBehavior = .render_notdef,
    atlas_strategy: AtlasStrategy = .shelf_lru,
    atlas_size: u16 = 1024,
    max_atlas_pages: u8 = 4,
};
```

### Provider Tiers

```
┌─────────────────────────────────────────────────────────────────┐
│                     TextProvider Interface                       │
└─────────────────────────────────────────────────────────────────┘
                               │
       ┌───────────────────────┼───────────────────────┐
       │                       │                       │
       ▼                       ▼                       ▼
┌─────────────────┐   ┌─────────────────┐   ┌─────────────────┐
│ BitmapProvider  │   │  StbProvider    │   │  SdfProvider    │
│ (Embedded)      │   │  (Desktop SW)   │   │  (Desktop GPU)  │
├─────────────────┤   ├─────────────────┤   ├─────────────────┤
│ • Comptime font │   │ • stb_truetype  │   │ • MSDF atlas    │
│ • RLE decode    │   │ • Glyph cache   │   │ • GPU shader    │
│ • No extensions │   │ • +charPositions│   │ • +loadFont     │
│                 │   │ • +loadFont     │   │                 │
│ ~3KB code       │   │ ~25KB code      │   │ ~10KB code      │
│ ~6KB data       │   │ ~400KB RAM      │   │ ~3MB VRAM       │
└─────────────────┘   └─────────────────┘   └─────────────────┘
```

---

## Recommended Design: LineBreaker Interface

```zig
pub const LineBreaker = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        iterate: *const fn (ptr: *anyopaque, text: []const u8) Iterator,
    };

    pub const BreakPoint = struct {
        index: u32,
        kind: BreakKind,
    };

    pub const BreakKind = enum(u8) {
        mandatory,   // \n - must break
        word,        // space - can break
        hyphen,      // soft hyphen
        ideograph,   // CJK char boundary
        emergency,   // anywhere (last resort)
    };

    pub const Iterator = struct {
        text: []const u8,
        pos: usize,
        impl_ptr: *anyopaque,
        nextFn: *const fn (*anyopaque, []const u8, *usize) ?BreakPoint,

        pub fn next(self: *Iterator) ?BreakPoint {
            return self.nextFn(self.impl_ptr, self.text, &self.pos);
        }
    };

    // Convenience methods (NOT in vtable)
    pub fn iterate(self: LineBreaker, text: []const u8) Iterator { ... }
    pub fn countBreaks(self: LineBreaker, text: []const u8) usize { ... }
    pub fn collectBreaks(self: LineBreaker, text: []const u8, out: []BreakPoint) usize { ... }
};
```

Ships with `SimpleBreaker` (ASCII, ~50 lines) and `GreedyBreaker` (CJK, ~150 lines).

---

## Key Design Decisions (Resolved)

### 1. Line Breaking ✓ (Experiments 07-09)

**Decision**: BYOL (Bring Your Own Line Breaker)

- Separate interface, consistent with BYOR/BYOT pattern
- Ships with SimpleBreaker and GreedyBreaker
- Users can bring UAX #14, ICU, or platform implementations
- Key insight: `measureText()` dominates execution time (85%+), not interface choice

### 2. Cursor/Selection ✓ (Experiments 10-11)

**Decision**: `getCharPositions()` returns grapheme positions + optional bidi extensions

- LTR: Binary search on positions (works)
- Bidi: Optional `hitTest()` and `getCaretInfo()` (binary search FAILS for RTL)
- Provider handles grapheme segmentation internally

### 3. Atlas Management ✓ (Experiment 12)

**Decision**: NO BYOFM + Split Interface + Strategy as Config

- Embedded: `renderDirect()` (no atlas)
- Desktop: `getGlyphQuads()` + configurable strategy
- CJK: Multi-page REQUIRED (Full Reset fails at 30-64% hit rate)

### 4. Font Fallback ✓ (Experiment 13)

**Decision**: User provides fallback chain + locale tag for Han unification

- Config: `fallback_fonts: []const FontHandle`
- Locale: `fallback_locale: "ja"` for correct CJK variant
- No BYOFF needed - config is enough

### 5. Atlas Texture Format ✓ (Design Session)

**Decision**: Per-page format flag

- Text pages: alpha (1 byte/pixel)
- Emoji pages: RGBA (4 bytes/pixel)
- `AtlasInfo.format = .alpha | .rgba`

### 6. SDF on Software Backend ✓ (Design Session)

**Decision**: SDF is GPU-only

- CPU SDF evaluation ~20x slower than bitmap
- Bitmap for embedded/software, SDF for GPU backends
- SDF deferred to Phase 3

### 7. Compile-time vs Runtime Font ✓ (Design Session)

**Decision**: Same interface supports both

- Interface receives `[]const u8` font data
- Caller decides source (`@embedFile` vs runtime load)

### 8. Compression Strategy ✓ (Experiment 06)

**Decision**: Raw as default, MCUFont opt-in

- Real AA fonts: 58% gray pixels → RLE EXPANDS data!
- Raw: simplest, fastest (17x), fits budget
- MCUFont: opt-in for space-constrained (22% smaller)

---

## Open Questions (Remaining)

### Implementation Gaps (Need Validation)

| # | Gap | Status | Notes |
|---|-----|--------|-------|
| 1 | Multi-font implementation | Needs Exp 14 | Load 3+ fonts, test atlas |
| 2 | Kerning | Needs Exp 14 | stb_truetype has it, untested |
| 3 | Draw system integration | Needs DESIGN.md | When to resolve text→quads? |
| 4 | C API | Not written | Write header, test from C |
| 5 | Emoji ZWJ sequences | Needs Exp 14 | 5 codepoints → 1 glyph |

### Out of Scope (Explicit Exclusions)

These features are **not part of the design** - not "deferred", but excluded:

| Feature | Why Excluded |
|---------|--------------|
| SDF/MSDF | Optimization for GPU; bitmap covers all targets adequately |
| Subpixel rendering | Platform-specific (DirectWrite, CoreText); not portable |
| Variable fonts | Specialized use case; standard fonts cover 99% of needs |

### In Design, Implementation Pending

These are **fully designed** in the interface but implementation is pending:

| Feature | Interface Support | Implementation Status |
|---------|-------------------|----------------------|
| Bidi (RTL) | `hitTest()`, `getCaretInfo()` optional in vtable | Needs HarfBuzz integration |
| Complex shaping | `shapeText()` optional in vtable | Needs HarfBuzz integration |
| Color emoji | `AtlasFormat.rgba` in AtlasInfo | Needs COLR/CBDT parsing |

---

## Complete System Architecture

The design covers the full system - there are no "phases", only implementation order:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         COMPLETE TEXT SYSTEM                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  PROVIDERS (implement TextProvider interface)                                │
│  ────────────────────────────────────────────                                │
│  BitmapProvider    - Embedded, comptime fonts, direct render                 │
│  StbProvider       - Desktop, runtime fonts, atlas, kerning                  │
│  ShapingProvider   - Full i18n, wraps HarfBuzz, bidi support                 │
│                                                                              │
│  FEATURES (all designed, implementation varies by provider)                  │
│  ──────────────────────────────────────────────────────────                  │
│  • measureText()        - All providers (required)                           │
│  • getCharPositions()   - All providers (required, returns graphemes)        │
│  • getGlyphQuads()      - Atlas providers (with kerning)                     │
│  • renderDirect()       - Embedded provider                                  │
│  • hitTest()            - Shaping provider (for bidi)                        │
│  • getCaretInfo()       - Shaping provider (for split caret)                 │
│  • shapeText()          - Shaping provider (for Arabic, Devanagari)          │
│  • loadFont()           - Runtime providers                                  │
│                                                                              │
│  LINE BREAKING (separate interface, BYOL)                                    │
│  ─────────────────────────────────────────                                   │
│  SimpleBreaker     - ASCII spaces                                            │
│  GreedyBreaker     - CJK support                                             │
│  User-provided     - UAX #14, ICU, platform                                  │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Implementation Order

1. Define types in `src/text.zig` (full interface)
2. Implement `BitmapProvider` (embedded target)
3. Implement `StbProvider` (desktop target, multi-font, kerning, graphemes)
4. Integrate with GUI and draw system
5. Write C API header and test
6. Implement `ShapingProvider` when HarfBuzz integration needed

---

## Experiments

| # | Name | Key Finding |
|---|------|-------------|
| 01 | Bitmap baseline | 12 ns/char, 37% budget for 8-bit font |
| 02 | RLE compression | MCUFont 4.9x compression (synthetic) |
| 03 | Interface design | Design E (hybrid) wins |
| 04 | Memory budget | Both tiers have headroom |
| 05 | stb_truetype | C interop works, glyph cache validated |
| 06 | Embedded E2E | **RLE EXPANDS real fonts!** Raw as default |
| 07 | Line breaker | BYOL pattern validated |
| 08 | Interface compare | Buffer overflow in long text! |
| 09 | Realistic test | measureText() dominates (85%+) |
| 10 | Cursor/selection | getCharPositions sufficient for LTR |
| 11 | Bidi validation | Binary search FAILS, need hitTest |
| 12 | Atlas management | Multi-page required for CJK |
| 13 | Font fallback | User chain + locale for Han unification |
| **14** | **TODO** | Multi-font + kerning + graphemes + full pipeline |

Run experiments:
```bash
cd experiments/text_rendering
zig run 01_bitmap_baseline.zig
```

---

## Bidi Support

**Interface fully supports bidi.** Implementation requires HarfBuzz.

The interface includes optional `hitTest()` and `getCaretInfo()` specifically because experiment 11 proved that binary search fails for RTL text:

```
For mixed RTL/LTR (e.g., "Hello שלום World"):
- Binary search on positions FAILS → need hitTest()
- Selection produces multiple rectangles
- Split caret needed at boundary → need getCaretInfo()
```

When `ShapingProvider` is implemented (wrapping HarfBuzz), these methods will be non-null and bidi will work. The interface doesn't change.

---

## References

### Primary Sources
- [State of Text Rendering 2024](https://behdad.org/text2024/) - Behdad Esfahbod
- [Inside the fastest font renderer](https://medium.com/@raphlinus/inside-the-fastest-font-renderer-in-the-world-75ae5270c445) - Raph Levien
- [GPU text with vector textures](https://wdobbie.com/post/gpu-text-rendering-with-vector-textures/) - Will Dobbie

### Libraries
- [stb_truetype](https://github.com/nothings/stb/blob/master/stb_truetype.h) - C rasterizer
- [mcufont](https://github.com/mcufont/mcufont) - Embedded compression
- [cosmic-text](https://github.com/pop-os/cosmic-text) - Rust text layout
- [fontdue](https://github.com/mooman219/fontdue) - Fast Rust rasterizer

### Line Breaking
- [UAX #14](http://www.unicode.org/reports/tr14/) - Unicode Line Breaking
- [CSS text-wrap: pretty](https://developer.chrome.com/blog/css-text-wrap-pretty) - Chrome
- [icu_segmenter](https://crates.io/crates/icu_segmenter) - Official Unicode Rust impl
