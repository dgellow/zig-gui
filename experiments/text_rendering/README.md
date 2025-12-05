# Text Rendering Design Exploration

This directory contains experiments and prototypes for zig-gui's text rendering system.

## Research Summary

### The Design Space

Our unique constraint: **32KB embedded to 1MB desktop** in a single codebase. Most solutions optimize for one end.

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
│  QUALITY:      Fixed        Fixed         Scalable     Any size     Any    │
│  FEATURES:     ASCII        +Kerning      +Outline     Full TTF     Full   │
│                                                                             │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  FONT DATA STORAGE                                                          │
│  ─────────────────                                                          │
│                                                                             │
│  Embedded in binary ◄────────────────────────────────────► Runtime loaded   │
│                                                                             │
│  @embedFile()        Compressed blob      Memory-mapped      Streamed       │
│  comptime known      runtime decompress   file I/O           network/IFT    │
│                                                                             │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  GLYPH LIFECYCLE                                                            │
│  ───────────────                                                            │
│                                                                             │
│  All at init ◄───────────────────────────────────────────► On-demand        │
│                                                                             │
│  Static atlas         Dynamic atlas        Per-frame raster   Streaming     │
│  (ImGui classic)      (ImGui 1.92+)        (no cache)         (IFT/WOFF2)   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### The "Bring Your Own" Philosophy

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
│     │           │         │           │         │           │              │
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

### Approaches from Research

#### 1. Bitmap Atlas (Classic Dear ImGui)

**How it works**: Pre-rasterize glyphs at build time, pack into texture atlas.

**Sources**:
- [Dear ImGui FONTS.md](https://skia.googlesource.com/external/github.com/ocornut/imgui/+/refs/heads/master/docs/FONTS.md)
- [Unity font assets](https://docs.unity3d.com/Manual/UIE-font-asset.html)

**Pros**:
- Simple: just texture lookups
- Fast: no runtime rasterization
- Predictable memory usage
- Works on any GPU

**Cons**:
- Fixed sizes (blurry when scaled)
- Large atlases for Unicode coverage
- Must pre-generate for each size

**Best for**: Games, ASCII-only embedded, known font sizes

---

#### 2. SDF/MSDF (Valve 2007, Chlumsky 2015)

**How it works**: Store distance-to-edge in texture. GPU shader reconstructs sharp edges at any scale.

**Sources**:
- [Red Blob Games SDF tutorial](https://www.redblobgames.com/x/2403-distance-field-fonts/)
- [awesome-msdf collection](https://github.com/Blatko1/awesome-msdf)
- [msdf-c single header](https://github.com/aspect-x/msdf_c)

**Pros**:
- Scalable to any size
- Small texture for full charset
- Cheap outlines/shadows
- ~3x smaller than bitmap at same quality

**Cons**:
- Requires GPU shader
- Corners can be soft (SDF) or need MSDF
- Generation step required
- Not great for very small sizes (<12px)

**Best for**: Desktop GPU, games with varying text sizes

---

#### 3. Runtime CPU Rasterization

**Libraries**:
- [stb_truetype](https://github.com/nothings/stb/blob/master/stb_truetype.h) - ~20KB, C, proven
- [fontdue](https://github.com/mooman219/fontdue) - Rust, "fastest in world", ~7.6x faster than FreeType
- [font-rs](https://github.com/raphlinus/font-rs) - Raph Levien's original, SIMD optimized
- [swash](https://github.com/dfrg/swash) - Rust, full OpenType, variable fonts, hinting

**Pros**:
- Any font, any size
- Small code footprint (stb_truetype ~20KB)
- Works without GPU

**Cons**:
- CPU cost per glyph
- Needs glyph cache for performance
- Cache management complexity

**Best for**: Desktop software rendering, dynamic content

---

#### 4. Direct GPU Vector Rendering

**Sources**:
- [Will Dobbie's vector textures](https://wdobbie.com/post/gpu-text-rendering-with-vector-textures/)
- [Loop-Blinn GPU curves](https://developer.nvidia.com/gpugems/gpugems3/part-iv-image-effects/chapter-25-rendering-vector-art-gpu)
- [Evan Wallace's easy approach](https://medium.com/@evanwallace/easy-scalable-text-rendering-on-the-gpu-c3f4d782c5ac)
- [Vello](https://lib.rs/crates/vello) - Raph Levien's compute shader renderer

**How it works**: Send bezier curves to GPU, evaluate in shader.

**Pros**:
- Perfect quality at any scale
- No atlas texture
- Handles complex paths (icons, emoji)

**Cons**:
- Complex shaders
- Higher GPU cost per glyph
- Harder to implement
- Not available on all GPUs

**Best for**: High-end desktop, when quality matters most

---

#### 5. Compressed Bitmap (MCUFont)

**Source**: [mcufont](https://github.com/mcufont/mcufont)

**How it works**: RLE-compress pre-rendered glyphs. Decompress on-the-fly during render.

**Pros**:
- High quality anti-aliased fonts in ~5KB
- ~3KB decoder code
- Kerning, word-wrap included
- Very low RAM (decode directly to framebuffer)

**Cons**:
- Fixed sizes
- Compression tool required
- Limited to pre-selected charset

**Best for**: Embedded systems needing quality text

---

#### 6. Hybrid/Tiered (What we should explore)

**Concept**: Different strategies for different tiers, unified interface.

```
                    ┌─────────────────┐
                    │   TextProvider  │ ← Unified interface
                    │    Interface    │
                    └────────┬────────┘
                             │
         ┌───────────────────┼───────────────────┐
         │                   │                   │
         ▼                   ▼                   ▼
┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐
│  BitmapProvider │ │   SdfProvider   │ │  VectorProvider │
│  (Embedded)     │ │   (Desktop)     │ │  (High-end)     │
├─────────────────┤ ├─────────────────┤ ├─────────────────┤
│ MCUFont decode  │ │ MSDF atlas      │ │ Vello/Pathfinder│
│ or raw bitmap   │ │ + CPU fallback  │ │ compute shaders │
│                 │ │ (stb_truetype)  │ │                 │
│ ~3KB code       │ │ ~25KB code      │ │ ~50KB code      │
│ ~4KB RAM        │ │ ~256KB RAM      │ │ ~64KB RAM       │
└─────────────────┘ └─────────────────┘ └─────────────────┘
```

---

### Key Insights from Research

#### 1. The Rust ecosystem is maturing fast

[Behdad's State of Text 2024](https://behdad.org/text2024/) describes the "Oxidize" initiative:
- **fontations**: Unified Rust font framework
- **rustybuzz**: HarfBuzz port
- **swash**: Full OpenType + hinting
- **cosmic-text**: Complete text layout

We could leverage these or port concepts to Zig.

#### 2. Atlas texture management is the hidden complexity

The interface isn't just `measureText()` and `rasterize()`. Real systems need:
- Atlas creation/growth
- Glyph eviction (LRU)
- Texture upload notification to renderer
- Multi-page atlas support

Dear ImGui 1.92's [dynamic font system](https://deepwiki.com/ocornut/imgui/4.1-platform-backends) shows how complex this gets.

#### 3. Text layout != Text rendering

They're separate concerns:
- **Layout**: Line breaking, bidi, shaping → positions
- **Rendering**: Rasterization, atlas, GPU upload

[cosmic-text](https://github.com/pop-os/cosmic-text) handles both; we might want to split them.

#### 4. Embedded needs are different

From [MCUFont](https://www.hackster.io/news/mcufont-aims-to-put-high-quality-typography-on-microcontrollers-with-a-clever-two-part-approach-453c78702f84):
- Decode directly to framebuffer (no intermediate buffer)
- Character set reduction is key
- RLE on antialiased = huge savings

---

## Experiments

### Experiment 1: Bitmap Font Baseline (`01_bitmap_baseline.zig`)

Establish baseline with simplest possible approach:
- Fixed 8x16 bitmap font (ASCII)
- Direct framebuffer write
- Measure: code size, render time, memory

```bash
zig run experiments/text_rendering/01_bitmap_baseline.zig
```

### Experiment 2: RLE Compression (`02_rle_compression.zig`)

Test MCUFont-style compression:
- Compress sample font with RLE
- Measure compression ratio
- Measure decode-to-framebuffer speed
- Calculate break-even point vs raw bitmap

```bash
zig run experiments/text_rendering/02_rle_compression.zig
```

### Experiment 3: Interface Design (`03_interface_design.zig`)

Prototype different API surfaces:
- Design A: Allocating (current DESIGN.md draft)
- Design B: Atlas-centric
- Design C: Callback-based
- Design D: Minimal embedded
- Design E: Hybrid (recommended)

```bash
zig run experiments/text_rendering/03_interface_design.zig
```

### Experiment 4: Memory Budget Calculator (`04_memory_budget.zig`)

Concrete numbers for:
- Embedded 32KB budget
- Desktop 1MB budget (RAM vs VRAM separation)
- What can we afford at each tier?

```bash
zig run experiments/text_rendering/04_memory_budget.zig
```

### Experiment 5: stb_truetype Integration (`05_stb_integration.zig`)

Validates Design E with a real font library:
- Wraps stb_truetype via C interop
- Implements glyph cache with LRU eviction
- Measures rasterization speed
- Demonstrates zero-allocation getGlyphQuads

```bash
cd experiments/text_rendering
zig build-exe -lc -lm -I. stb_truetype_impl.c 05_stb_integration.zig -femit-bin=05_stb_integration
./05_stb_integration
```

### Experiment 6: Embedded E2E with Real Fonts (`06_embedded_e2e.zig`)

**Critical finding that changed our compression strategy!**

Tests the full embedded pipeline with real TTF font data:
- Rasterizes glyphs using stb_truetype (simulates build-time)
- Compresses with three algorithms (none, RLE, MCUFont)
- Decodes and renders (simulates runtime)
- Measures real-world compression and performance

```bash
cd experiments/text_rendering
zig build-exe -lc -I. stb_truetype_impl.c 06_embedded_e2e.zig -femit-bin=06_embedded_e2e
./06_embedded_e2e
```

**Key Discovery - Real vs Synthetic Font Data:**

| Metric | Synthetic (Exp 2) | Real Font (Exp 6) |
|--------|-------------------|-------------------|
| Black (0) | ~85% | **39.7%** |
| White (255) | ~10% | **2.5%** |
| Intermediate | ~5% | **57.8%** |

**Compression Results (16px DejaVu Sans, 95 ASCII):**

| Algorithm | Size | Ratio | Decode Speed |
|-----------|------|-------|--------------|
| None (raw) | 7,079 B | 1.0x | 124 ns |
| SimpleRLE | 10,004 B | **0.7x** (EXPANSION!) | 1,028 ns |
| MCUFont | 5,542 B | **1.3x** | 2,143 ns |

**Decision: Raw as Default, Auto-Detection in Build Tool**

| Default | Rationale |
|---------|-----------|
| `none` (raw) | Simplest, fastest (17x), zero risk, fits budget |

- **Build tool auto-detects**: If >80% black+white → RLE, else → raw
- **MCUFont opt-in**: For users who need every byte (22% smaller, 17x slower)
- **SimpleRLE warning**: Only for 1-bit fonts, expands AA data

### Experiment 7: Line Breaking Interface (`07_line_breaker.zig`)

Validates the BYOL (Bring Your Own Line Breaker) pattern:
- Defines minimal `LineBreaker` interface (1 function)
- Implements `SimpleBreaker` for ASCII/Latin (~50 lines)
- Implements `GreedyBreaker` with CJK support (~150 lines)
- Demonstrates `wrapText()` composing LineBreaker + TextProvider
- Zero allocation in hot path

```bash
zig run experiments/text_rendering/07_line_breaker.zig
```

### Experiment 8: Line Breaker Interface Comparison (`08_linebreaker_interface.zig`)

Compares 5 different interface designs for line breaking:
- **Design A: Buffer-based** - Caller provides output buffer (current choice)
- **Design B: Iterator-based** - Returns iterator yielding breaks on demand
- **Design C: Callback-based** - Calls user function for each break
- **Design D: Integrated** - Line breaking as TextProvider extension
- **Design E: Streaming** - Incremental processing for large texts

```bash
zig run experiments/text_rendering/08_linebreaker_interface.zig
```

**Initial Results (198 byte text, synthetic):**

| Design | Time (ns) | VTable | Initial Verdict |
|--------|-----------|--------|-----------------|
| A: Buffer | 1495 | 8 bytes | Fastest |
| B: Iterator | 1822 | 8 bytes | Slightly slower |

**CRITICAL: Realistic testing revealed buffer overflow!**

| Scenario | Design A | Design B | Finding |
|----------|----------|----------|---------|
| Short (198B) | 1495 ns | 1822 ns | A faster |
| CJK-like | 1138 ns | 1707 ns | A 33% faster |
| **Long (2250B)** | **37 lines** | **64 lines** | **A WRONG!** |

Long text has 450 break opportunities > 256 buffer → Design A truncates!

**Updated Decision: Hybrid Interface**
- **Primary**: `iterate()` - always correct, handles any text
- **Optional**: `findBreakPoints()` - fast path for small embedded texts

Key lesson: Synthetic tests hid the bug - just like experiment 06 with mcufont!

### Experiment 9: Truly Realistic Line Breaker (`09_realistic_linebreak.zig`)

Comprehensive validation with realistic scenarios:
- **Realistic measureText**: Cache simulation, kerning, variable widths
- **13 real-world scenarios**: UI labels, error messages, URLs, CJK, long docs
- **Additional interfaces**: Two-Pass (Design F), Stateful (Design G)
- **Full edge cases**: Empty, single char, no breaks, all spaces

```bash
zig run experiments/text_rendering/09_realistic_linebreak.zig
```

**Critical Finding: measureText() dominates execution time!**

| Scenario | Time (ns) | measureText calls |
|----------|-----------|-------------------|
| Button label (6B) | 82 | 0 |
| Error message (94B) | 4,325 | 18 |
| Long document (4500B) | 235,983 | 900 |

**Interface Comparison on Long Text:**
- Iterator (B): 237,904 ns
- Two-Pass (F): 469,566 ns (2x slower due to double scan + allocation)

**Final Interface Decision: Single-Method + Utilities**

After analyzing all use cases (embedded, desktop, mobile, gamedev, C API), we chose the simplest possible interface:

```zig
/// LineBreaker interface - implementers provide ONE method
pub const LineBreaker = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        iterate: *const fn (ptr: *anyopaque, text: []const u8) Iterator,
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

    // Convenience methods built on iterate() - NOT in vtable:
    pub fn iterate(self, text) Iterator { ... }
    pub fn countBreaks(self, text) usize { ... }
    pub fn collectBreaks(self, text, out) usize { ... }
};
```

| Use Case | Solution | Rationale |
|----------|----------|-----------|
| **Embedded** | `collectBreaks()` into fixed buffer | Known max text, fast path |
| **Desktop** | `iterate()` directly | Lazy eval, no allocation |
| **C API** | Iterator, Callback, or Buffer | All wrap single `iterate()` |

Key insight: **measureText() dominates execution time (85%+), not the interface choice!**
Simplest interface wins - one method in vtable = easiest to implement correctly.

### Experiment 10: Text Input Cursor & Selection (`10_text_input_cursor.zig`)

Validates the text input workflow:
- Click → find character index under cursor (hit testing)
- Arrow keys → move cursor by one logical position
- Shift+Arrow → extend selection
- Double-click → select word
- Triple-click → select line

```bash
zig run experiments/text_rendering/10_text_input_cursor.zig
```

**Key Findings:**

| Workflow | Current Interface | Solution |
|----------|-------------------|----------|
| Click → char index | `getCharPositions()` | Binary search on positions |
| Cursor rendering | `positions[cursor.focus]` | Direct lookup |
| Selection highlight | `positions[start..end]` | Range of positions |
| Word/line selection | TextField handles | ASCII: split on spaces/`\n` |

**Interface Assessment:**
- **LTR (Phase 1-2)**: Current `getCharPositions()` is **sufficient**
- **Bidi (Phase 3)**: Need `hitTest(text, x) -> {index, trailing}` as optional extension

**Caching Strategy:**
```
TextField caches positions internally:
- Invalidate on text change
- Recompute lazily on next hit test / render
- O(n) cost amortized over many cursor operations
```

**Critical Limitation - Bidi Deferred:**

For RTL text (Arabic, Hebrew), visual position ≠ logical position:
```
Logical: H e l l o   ש ל ו ם   W o r l d
Visual:  H e l l o   ם ו ל ש   W o r l d
                     ← RTL →
```

Bidi requires:
- Shaping (reorder characters for display)
- Bidirectional hit testing (click x → logical index)
- Split cursor (caret at RTL/LTR boundary)

**Decision: Defer bidi to Phase 3**, but document now that:
1. `getCharPositions()` returns **visual** positions (correct)
2. For bidi, add optional `hitTest(text, visual_x) -> HitTestResult`
3. Provider handles bidi complexity internally

### Experiment 11: Cursor Interface Validation (`11_cursor_interface.zig`)

**Comprehensive validation of cursor/selection interface with actual bidi testing.**

This experiment follows the proven pattern from experiment 09 - realistic scenarios with actual implementations and measurements instead of guesswork.

```bash
zig run experiments/text_rendering/11_cursor_interface.zig
```

**What It Tests:**

| Test | Purpose | Finding |
|------|---------|---------|
| Grapheme iteration | Byte vs codepoint vs grapheme | Grapheme-based REQUIRED |
| Selection rendering | Single rect vs multiple | Bidi needs multiple rects |
| Bidi hit testing | Binary search vs bounds check | Binary search FAILS for RTL |
| Touch vs mouse | Interface differences | Same interface, UX layer handles |
| CaretInfo necessity | When split caret needed | Only for bidi boundaries |

**Actual Bidi Test Results:**

Simulated "Hello שלום World" with proper bidi layout:
```
Logical: H e l l o   ש ל ו ם   W o r l d
Visual:  H e l l o   ם ו ל ש   W o r l d
                     ← RTL →
```

- **Hit test at x=60**: Binary search returns index 9 (WRONG), proper bounds check returns 8 (CORRECT)
- **Selection [4,8)**: Produces 2 rectangles, not 1 (visual is non-contiguous)
- **Grapheme "Aé👍B"**: 8 bytes but only 4 grapheme positions needed

**Final Interface (validated):**

```zig
pub const TextProvider = struct {
    vtable: *const VTable,

    pub const VTable = struct {
        // REQUIRED - Core
        measureText: *const fn (ptr, text: []const u8) f32,

        // REQUIRED - Returns GRAPHEME positions (not bytes)
        getCharPositions: *const fn (ptr, text, out: []f32) usize,

        // OPTIONAL - For bidi (null = LTR only)
        hitTest: ?*const fn (ptr, text, x: f32) HitTestResult,
        getCaretInfo: ?*const fn (ptr, text, index: usize) CaretInfo,
    };

    pub const HitTestResult = struct {
        logical_index: usize,
        trailing: bool,
    };

    pub const CaretInfo = struct {
        primary_x: f32,
        secondary_x: ?f32,  // Split caret (null if not needed)
        is_rtl: bool,
    };
};
```

**Key Design Decisions:**

| Decision | Rationale |
|----------|-----------|
| `getCharPositions` returns grapheme count | Provider handles encoding complexity |
| `hitTest` is optional | Binary search works for LTR; bidi providers implement |
| `getCaretInfo` is optional | Only needed for split caret at bidi boundaries |
| No CharInfo array | Avoids 12 bytes/char overhead for embedded |

### Experiment 12: Atlas Management When Full (`12_atlas_management.zig`)

**Comprehensive validation of atlas management strategies across all targets.**

This experiment simulates real-world glyph access patterns to compare atlas management strategies. It validates the interface design decision from our 2025 state-of-the-art survey.

```bash
zig run experiments/text_rendering/12_atlas_management.zig
```

**Strategies Tested:**

| Strategy | Description | Source |
|----------|-------------|--------|
| Full Reset | Clear everything when full | Current impl |
| Grid LRU | Fixed slots, O(1) eviction | VEFontCache |
| Shelf LRU | Row-based eviction | WebRender |
| Multi-Page | Grow when full | Unity/ImGui |
| Direct Render | No atlas (per-frame) | MCUFont |

**13 Realistic Scenarios:**

| Category | Scenarios | Unique Glyphs |
|----------|-----------|---------------|
| Embedded | thermostat, menu, config input | 15-95 |
| Desktop | settings, text editor, email | 80-300 |
| CJK | Chinese news, Japanese chat | 2500-3000 |
| Game | HUD, leaderboard, MMO chat | 40-500 |
| Stress | Unicode torture, font switching | 300-10000 |

**Key Results:**

| Target | Winner | Finding |
|--------|--------|---------|
| Embedded | **Direct Render** | No atlas overhead, fits budget |
| Desktop | Shelf LRU / Multi-Page | Shelf for SW, Multi-Page for text-heavy |
| CJK | **Multi-Page** | Full Reset fails (constant stutter) |
| Games | Grid LRU | O(1) eviction, predictable |

**Critical Finding - Full Reset Fails CJK:**

| Scenario | Full Reset Hit% | Multi-Page Hit% |
|----------|-----------------|-----------------|
| Chinese news | 63.9% | **99.5%** |
| Japanese chat | 30.1% | **62.4%** |
| MMO chat | 48.2% | **99.7%** |

**Interface Decision (Validated):**

| Decision | Rationale |
|----------|-----------|
| ✗ BYOFM (Bring Your Own Font Management) | Too complex for marginal benefit |
| ✓ Split Interface | Universal + Rendering Layer |
| ✓ Atlas Strategy as Config | `.atlas_strategy = .shelf_lru` |

**Final Proposed Interface:**

```zig
pub const TextProvider = struct {
    vtable: *const VTable,

    pub const VTable = struct {
        // UNIVERSAL (all tiers)
        measureText: *const fn (...) TextMetrics,
        getCharPositions: *const fn (...) usize,

        // EMBEDDED PATH (null for desktop)
        renderDirect: ?*const fn (ptr, text, x, y, target: RenderTarget) void,

        // ATLAS PATH (null for embedded direct-render)
        getGlyphQuads: ?*const fn (...) usize,
        getAtlas: ?*const fn (ptr, page: u8) ?AtlasInfo,
        beginFrame: ?*const fn (ptr) void,
        endFrame: ?*const fn (ptr) void,
    };
};

pub const AtlasStrategy = enum {
    static,       // No eviction, pre-loaded
    grid_lru,     // Fixed slots, O(1) eviction
    shelf_lru,    // Row-based eviction
    multi_page,   // Grow when full
};
```

### Experiment 13: Font Fallback (`13_font_fallback.zig`)

**Comprehensive validation of font fallback approaches across all targets.**

Tests "user provides fallback chain" approach (Dear ImGui style) against 26 realistic scenarios with two strategies: simple linear search vs locale-aware search (for Han unification).

```bash
zig run experiments/text_rendering/13_font_fallback.zig
```

**Strategies Tested:**

| Strategy | Description | Handles Han? |
|----------|-------------|--------------|
| Linear | Search chain in order | ✗ No |
| Locale-Aware | Prefer locale-matching font for CJK | ✓ Yes |

**26 Realistic Scenarios:**

| Category | Scenarios | Key Challenge |
|----------|-----------|---------------|
| Embedded | thermostat, degree symbol, euro | Single font, special chars |
| Desktop Latin | quotes, accents, math, code, emoji | 3-font chain |
| CJK | JP in EN app, zh-Hans, zh-Hant, Han unification | Locale matters! |
| International | Arabic, Hebrew, Devanagari | Script-specific fonts |
| Games | HUD, leaderboard, MMO chat | Performance + i18n |
| Edge cases | missing glyph, PUA icons, variation selectors | Graceful degradation |

**Key Results:**

| Finding | Detail |
|---------|--------|
| Han unification | 4 scenarios where locale-aware was better |
| Avg lookups | ~2.3-2.5 per codepoint (very fast) |
| Critical failures | 3 scenarios (missing € and some CJK) |

**Critical Finding - Han Unification:**

Same codepoint U+76F4 (直) renders differently per locale:
- `ja` locale → Japanese font variant (correct strokes)
- `zh-Hans` locale → Simplified Chinese variant
- Linear search → Wrong font for 30% of CJK scenarios

**Interface Decision (Validated):**

| Decision | Rationale |
|----------|-----------|
| ✓ User provides fallback chain | Simple, predictable, embedded-friendly |
| ✓ Locale tag for Han unification | `fallback_locale: "ja"` in config |
| ✗ BYOFF (Bring Your Own Font Fallback) | Config is enough |
| ✗ Platform font query | Too complex, not needed |

**Final Proposed Config:**

```zig
pub const TextProviderConfig = struct {
    primary_font: FontHandle,
    fallback_fonts: []const FontHandle = &.{},

    // For Han unification - which CJK variant to prefer
    fallback_locale: ?[]const u8 = null,

    // What to do when no font has the glyph
    missing_glyph: MissingGlyphBehavior = .render_notdef,
};

pub const MissingGlyphBehavior = enum {
    render_notdef,    // Show □
    skip,             // Don't render
    replacement_char, // Show U+FFFD �
};
```

---

## Open Questions to Resolve

1. **~~Where does line breaking live?~~** ✓ RESOLVED & VALIDATED (2025)
   - **Answer: BYOL (Bring Your Own Line Breaker)**
   - Separate `LineBreaker` interface, consistent with BYOR/BYOT pattern
   - Ships with `SimpleBreaker` (ASCII) and `GreedyBreaker` (CJK)
   - Users can bring UAX #14, ICU, or platform implementations
   - See experiment 07 and DESIGN_OPTIONS.md

   **Validated against 2024-2025 research:**
   - Industry: CSS `text-wrap: pretty` (Chrome, Safari, Firefox) uses tiered strategies
   - Unicode: `icu_segmenter` Rust crate is 1.2MB+ for full UAX #14 (too big for embedded)
   - Production: cosmic-text uses external `unicode-linebreak` crate (same BYOL pattern)
   - Academia: Knuth-Plass still active (ACM DocEng 2024 paper on similarity problems)

2. **~~How do we handle text input cursors?~~** ✓ FULLY RESOLVED (Experiments 10 + 11)
   - **LTR**: `getCharPositions()` + binary search (validated experiment 10)
   - **Bidi**: Optional `hitTest()` and `getCaretInfo()` in vtable (validated experiment 11)
   - **Graphemes**: Provider returns grapheme positions, not byte positions
   - See experiments 10 and 11 for full analysis and actual bidi testing

3. **~~Atlas management when full?~~** ✓ FULLY RESOLVED (Experiment 12)
   - **Decision: NO BYOFM** (Bring Your Own Font Management) - too complex
   - **Decision: Split Interface** - Universal layer + mutually exclusive Rendering layers
   - **Decision: Atlas Strategy as Config** - `.atlas_strategy = .shelf_lru` etc.

   **Key findings from experiment 12:**
   - **Embedded**: Direct render wins (no atlas overhead)
   - **Desktop**: Shelf LRU or Multi-Page (depending on text volume)
   - **CJK**: Multi-Page REQUIRED (Full Reset fails with 30-64% hit rate)
   - **Games**: Grid LRU (O(1) eviction, predictable)

   **Validated against 2025 state-of-the-art:**
   - Browser: WebRender uses etagere (shelf allocator), Chromium/Skia multi-atlas
   - Game engines: Unity TextMeshPro multi-atlas auto-grow, Unreal Slate pre-load
   - UI frameworks: Dear ImGui 1.92+ dynamic multi-atlas, VEFontCache grid LRU
   - Rust ecosystem: cosmic-text delegates to renderer, Vello compute shader

   See experiment 12 for full simulation with 13 realistic scenarios.

4. **~~Font fallback: whose responsibility?~~** ✓ FULLY RESOLVED (Experiment 13)
   - **Decision: User provides fallback chain** (like Dear ImGui, Unity)
   - **Decision: Add locale tag for Han unification** (`fallback_locale: "ja"`)
   - **Decision: NO BYOFF** (Bring Your Own Font Fallback) - config is enough

   **Key findings from experiment 13:**
   - **Embedded**: Single font, no fallback needed
   - **Desktop Latin**: 3-font chain (primary + symbols + emoji) covers 95%
   - **CJK**: MUST use locale-aware fallback for Han unification
   - **Games**: Pre-load fonts, cache fallback results

   **Han unification validated**: Same codepoint U+76F4 (直) renders differently
   per locale - locale-aware strategy correctly picks right font variant.

   **2025 state-of-the-art validated:**
   - Browsers: Chrome/Firefox hard-coded script-to-font maps
   - OS APIs: DirectWrite, CoreText, fontconfig (NOT needed for most apps)
   - Game engines: Unity/ImGui user-provided chains
   - Rust: cosmic-text uses Chrome/Firefox static lists

   See experiment 13 for 26 realistic scenarios across all targets.

5. **Atlas texture format?**
   - Alpha-only (1 channel, smaller)
   - RGBA (color emoji)
   - Both? Separate atlases?

6. **Can SDF work on software backend?**
   - CPU SDF evaluation is possible but slow
   - Worth supporting? Or mandate bitmap for SW?

7. **Compile-time vs runtime font selection?**
   - Embedded: @embedFile() comptime fonts
   - Desktop: runtime loading
   - Can same interface support both?

---

## References

### Primary Sources
- [State of Text Rendering 2024](https://behdad.org/text2024/) - Behdad Esfahbod
- [Inside the fastest font renderer](https://medium.com/@raphlinus/inside-the-fastest-font-renderer-in-the-world-75ae5270c445) - Raph Levien
- [GPU text with vector textures](https://wdobbie.com/post/gpu-text-rendering-with-vector-textures/) - Will Dobbie
- [SDF font basics](https://www.redblobgames.com/x/2403-distance-field-fonts/) - Red Blob Games

### Libraries to Study
- [mcufont](https://github.com/mcufont/mcufont) - Embedded compression
- [fontdue](https://github.com/mooman219/fontdue) - Fast Rust rasterizer
- [swash](https://github.com/dfrg/swash) - Full Rust font stack
- [cosmic-text](https://github.com/pop-os/cosmic-text) - Rust text layout
- [stb_truetype](https://github.com/nothings/stb/blob/master/stb_truetype.h) - C rasterizer
- [msdf-c](https://github.com/aspect-x/msdf_c) - Single-header MSDF

### Game Engine Approaches
- [Dear ImGui fonts](https://github.com/ocornut/imgui/blob/master/docs/FONTS.md)
- [Unity font assets](https://docs.unity3d.com/Manual/UIE-font-asset.html)
- [Unreal font overview](https://docs.unrealengine.com/4.26/en-US/InteractiveExperiences/UMG/UserGuide/Fonts/Overview)

### Line Breaking Research (2024-2025)
- [UAX #14: Unicode Line Breaking Algorithm](http://www.unicode.org/reports/tr14/) - Official Unicode spec
- [icu_segmenter](https://crates.io/crates/icu_segmenter) - Official Rust implementation (Unicode org)
- [CSS text-wrap: pretty](https://developer.chrome.com/blog/css-text-wrap-pretty) - Chrome implementation
- [WebKit text-wrap: pretty](https://webkit.org/blog/16547/better-typography-with-text-wrap-pretty/) - Safari's enhanced implementation
- [Similarity Problems in Paragraph Justification](https://dl.acm.org/doi/10.1145/3685650.3685666) - ACM DocEng 2024
- [Raph Levien: Text Layout is a Loose Hierarchy](https://raphlinus.github.io/text/2020/10/26/text-layout.html) - Architecture insights
