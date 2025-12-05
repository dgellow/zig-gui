# Text Rendering Design Options

**Status**: Design exploration complete. Ready for implementation decision.

## Executive Summary

After researching modern text rendering approaches and running experiments, we recommend a **Hybrid Interface** design (Design E) that provides:

1. **Simple core API** (5 required functions) for basic text rendering
2. **Optional extensions** (null vtable entries) for advanced features
3. **Zero allocation** in the render path
4. **Unified interface** across embedded and desktop

This approach supports our full target range: 32KB embedded to 1MB desktop.

---

## Research Findings

### Key Insights

1. **The Rust ecosystem is the new state of art**
   - [fontations](https://behdad.org/text2024/) is unifying font handling
   - [cosmic-text](https://github.com/pop-os/cosmic-text) provides complete text layout
   - [swash](https://github.com/dfrg/swash) offers full OpenType support
   - We can port concepts to Zig or interface with these via C bindings

2. **Atlas management is the hidden complexity**
   - The interface isn't just `measureText()` and `rasterize()`
   - Real systems need: atlas creation, glyph eviction, texture upload notifications
   - Dear ImGui 1.92's dynamic fonts show how complex this gets

3. **Compression makes embedded viable**
   - [MCUFont](https://github.com/mcufont/mcufont) achieves ~4-5x compression on AA fonts
   - A 12x20 antialiased ASCII font fits in ~6KB compressed
   - Leaves plenty of room in 32KB budget

4. **GPU text is moving to direct vector rendering**
   - [Vello](https://lib.rs/crates/vello) uses compute shaders for vector paths
   - [Will Dobbie's approach](https://wdobbie.com/post/gpu-text-rendering-with-vector-textures/) stores beziers in texture
   - SDF/MSDF remain practical for most use cases

### Memory Budget Reality

From our experiments:

| Configuration | Memory Used | % of Budget |
|--------------|-------------|-------------|
| Embedded minimal (8x8 1-bit) | 1.8 KB | 5.6% of 32KB |
| Embedded quality (12x20 AA) | 9 KB | 27.6% of 32KB |
| Desktop SW (512x512 atlas + cache) | 423 KB | 40.3% of 1MB |
| Desktop GPU (MSDF in VRAM) | 7 KB RAM | 0.7% of 1MB |

**Key finding**: We have more headroom than expected at both ends.

---

## Recommended Design: Hybrid Interface

### Core Interface (Required)

```zig
pub const TextProvider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        // Core (required) ─────────────────────────────────

        /// Measure text bounds for layout
        measureText: *const fn (
            ptr: *anyopaque,
            text: []const u8,
            font_id: u16,
            size: f32,
        ) TextMetrics,

        /// Get positioned glyph quads for rendering
        /// Caller provides output buffer (zero allocation)
        getGlyphQuads: *const fn (
            ptr: *anyopaque,
            text: []const u8,
            font_id: u16,
            size: f32,
            origin: [2]f32,
            out_quads: []GlyphQuad,
            out_atlas_id: *u16,
        ) usize,

        /// Get atlas texture info
        getAtlas: *const fn (ptr: *anyopaque, atlas_id: u16) ?AtlasInfo,

        /// Frame lifecycle
        beginFrame: *const fn (ptr: *anyopaque) void,
        endFrame: *const fn (ptr: *anyopaque) void,

        // Extensions (optional, null = not supported) ─────

        /// For text input cursor placement
        getCharPositions: ?*const fn (...) usize,

        /// For complex scripts (Arabic, Devanagari)
        shapeText: ?*const fn (...) usize,

        /// For runtime font loading
        loadFont: ?*const fn (...) ?u16,
    };
};
```

### Why This Design

| Requirement | How Addressed |
|-------------|---------------|
| Zero allocation in render loop | `getGlyphQuads` writes to caller's buffer |
| Atlas texture caching | `getAtlas` returns generation counter |
| Embedded simplicity | Extensions are null, only 5 functions needed |
| Desktop features | Extensions enable shaping, runtime fonts |
| C API compatibility | vtable maps cleanly to function pointers |

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

## Line Breaking: BYOL (Bring Your Own Line Breaker)

Line breaking follows the same "Bring Your Own" philosophy as rendering (BYOR) and text (BYOT).

### Why BYOL?

Line breaking complexity varies dramatically:

| Use Case | Complexity | Solution |
|----------|------------|----------|
| Embedded ASCII | Trivial | Split on spaces |
| Desktop Latin | Simple | Word boundaries + punctuation |
| Desktop CJK | Medium | Any ideograph boundary |
| Desktop i18n | Complex | UAX #14 (40+ page spec) |
| Platform-native | External | ICU, macOS CTLine, Win32 |

Building all this into zig-gui would:
- Bloat embedded builds
- Never satisfy i18n requirements fully
- Duplicate platform APIs

### LineBreaker Interface

```zig
pub const LineBreaker = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Find valid break positions in text.
        /// Caller provides output buffer (zero allocation).
        findBreakPoints: *const fn (
            ptr: *anyopaque,
            text: []const u8,
            out_breaks: []BreakPoint,
        ) usize,
    };

    pub const BreakPoint = struct {
        index: u32,       // Byte offset (break allowed AFTER this index)
        kind: BreakKind,
    };

    pub const BreakKind = enum(u8) {
        mandatory,   // \n, paragraph separator
        word,        // Space, punctuation
        hyphen,      // Soft hyphen
        ideograph,   // CJK character boundary
        emergency,   // Anywhere (last resort)
    };
};
```

### Tiered Implementations

```
┌─────────────────────────────────────────────────────────────────┐
│                     LineBreaker Interface                        │
└─────────────────────────────────────────────────────────────────┘
                               │
       ┌───────────────────────┼───────────────────────┐
       │                       │                       │
       ▼                       ▼                       ▼
┌─────────────────┐   ┌─────────────────┐   ┌─────────────────┐
│ SimpleBreaker   │   │ GreedyBreaker   │   │ User-Provided   │
│ (Built-in)      │   │ (Built-in)      │   │                 │
├─────────────────┤   ├─────────────────┤   ├─────────────────┤
│ • ASCII spaces  │   │ • + CJK support │   │ • UAX #14 impl  │
│ • \n mandatory  │   │ • + punctuation │   │ • ICU wrapper   │
│ • ~50 lines     │   │ • ~150 lines    │   │ • Platform API  │
│                 │   │                 │   │                 │
│ Embedded ✓      │   │ Desktop ✓       │   │ i18n ✓          │
└─────────────────┘   └─────────────────┘   └─────────────────┘
```

### GUI Integration

Word wrap composes `LineBreaker` + `TextProvider`:

```zig
fn wrapText(
    text: []const u8,
    max_width: f32,
    line_breaker: LineBreaker,
    text_provider: TextProvider,
    font_id: u16,
    size: f32,
) []Line {
    // 1. Get break points from line_breaker
    var breaks: [256]LineBreaker.BreakPoint = undefined;
    const break_count = line_breaker.findBreakPoints(text, &breaks);

    // 2. Measure segments using text_provider
    // 3. Accumulate until overflow
    // 4. Return line positions
}
```

### Memory Budget

```
LineBreaker.BreakPoint:  8 bytes
LineBreaker.VTable:      8 bytes  (1 function pointer)
LineBreaker:            16 bytes

Typical buffer (64 break points): 512 bytes
```

---

## Implementation Plan

### Phase 1: Core Infrastructure

1. **Define types** in `src/text.zig`:
   - `TextProvider` interface
   - `TextMetrics`, `GlyphQuad`, `AtlasInfo`
   - `TextStyle` for font/size selection

2. **Implement `BitmapProvider`**:
   - Comptime font embedding via `@embedFile`
   - RLE decompression (MCUFont-style)
   - Fixed-size ASCII atlas
   - Validates embedded constraints

3. **Integrate with GUI**:
   - `gui.text()` uses provider for measurement
   - Draw system generates text commands
   - Backend renders via `getGlyphQuads`

### Phase 2: Desktop Provider

4. **Implement `StbProvider`**:
   - Wrap stb_truetype.h (or port to Zig)
   - Dynamic glyph cache (LRU)
   - Atlas packing with overflow pages
   - Runtime font loading

5. **Add cursor support**:
   - Implement `getCharPositions`
   - Enable text input fields

### Phase 3: Advanced Features

6. **GPU rendering path**:
   - SDF/MSDF atlas generation
   - Shader for SDF rendering
   - Or: explore Vello-style compute

7. **Complex script shaping** (optional):
   - Interface with HarfBuzz/RustyBuzz
   - Or: simple kerning-only fallback

---

## Open Decisions

### 1. ~~Line Breaking~~ ✓ RESOLVED

**Decision**: BYOL (Bring Your Own Line Breaker)

Separate `LineBreaker` interface, consistent with BYOR/BYOT philosophy.
- Ships with `SimpleBreaker` (ASCII) and `GreedyBreaker` (CJK)
- Users can bring UAX #14, ICU, or platform implementations
- GUI provides `wrapText()` helper that composes LineBreaker + TextProvider

See "Line Breaking: BYOL" section above for full specification.

### 2. Font Fallback

**Options**:
- A) User provides fallback chain
- B) Built-in Unicode coverage detection
- C) Platform font discovery

**Recommendation**: A (user responsibility). Built-in fallback adds complexity for marginal benefit.

### 3. Color Emoji

**Options**:
- A) Support via RGBA atlas pages
- B) Not supported initially
- C) Separate emoji provider

**Recommendation**: B initially, A later. Color emoji can be added via atlas format flag.

### 4. stb_truetype vs Zig Port

**Options**:
- A) Wrap stb_truetype.h via C import
- B) Port stb_truetype to Zig
- C) Use fontdue concepts (port from Rust)

**Recommendation**: A initially (faster), consider B later for pure-Zig builds.

---

## Experiment Results

All experiments are runnable:

```bash
cd /home/user/zig-gui
zig run experiments/text_rendering/01_bitmap_baseline.zig
zig run experiments/text_rendering/02_rle_compression.zig
zig run experiments/text_rendering/03_interface_design.zig
zig run experiments/text_rendering/04_memory_budget.zig
```

### Key Metrics

| Experiment | Key Finding |
|------------|-------------|
| 01_bitmap_baseline | 12 ns/char render, 37% budget for 8-bit font |
| 02_rle_compression | MCUFont achieves 4.9x compression |
| 03_interface_design | Design E balances simplicity + extensibility |
| 04_memory_budget | Both embedded and desktop have headroom |

---

## References

### Primary Sources
- [State of Text Rendering 2024](https://behdad.org/text2024/)
- [Inside the fastest font renderer](https://medium.com/@raphlinus/inside-the-fastest-font-renderer-in-the-world-75ae5270c445)
- [GPU text with vector textures](https://wdobbie.com/post/gpu-text-rendering-with-vector-textures/)

### Libraries to Study
- [mcufont](https://github.com/mcufont/mcufont) - Embedded compression
- [fontdue](https://github.com/mooman219/fontdue) - Fast Rust rasterizer
- [cosmic-text](https://github.com/pop-os/cosmic-text) - Rust text layout
- [stb_truetype](https://github.com/nothings/stb/blob/master/stb_truetype.h) - C rasterizer

---

## Compression Strategy (Updated from Experiment 6)

**Critical finding:** Real antialiased font data is very different from synthetic test data!

```
┌─────────────────────────────────────────────────────────────────┐
│              PIXEL DISTRIBUTION: SYNTHETIC vs REAL               │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  Synthetic (Experiment 2):     Real Font (Experiment 6):        │
│  ┌─────────────────────┐      ┌─────────────────────┐          │
│  │██████████████████░░│ 85%  │████████░░░░░░░░░░░░░│ 40% Black │
│  │██░░░░░░░░░░░░░░░░░░│ 10%  │░░░░░░░░░░░░░░░░░░░░░│  2% White │
│  │░░░░░░░░░░░░░░░░░░░░│  5%  │▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓│ 58% Gray  │
│  └─────────────────────┘      └─────────────────────┘          │
│                                                                  │
│  RLE works great!              RLE EXPANDS data!                │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

**Compression Results (16px DejaVu Sans, 95 ASCII):**

| Algorithm | Size | Ratio | Decode | Best For |
|-----------|------|-------|--------|----------|
| None | 7,079 B | 1.0x | 124 ns | Simple, fast |
| SimpleRLE | 10,004 B | 0.7x | 1,028 ns | **1-bit fonts only** |
| MCUFont | 5,542 B | 1.3x | 2,143 ns | 8-bit AA fonts |

### Decision: Raw as Default, Auto-Detection in Build Tool

**Default: `none` (raw storage)**

Rationale:
1. **Fits in budget** - 26% of 32KB, plenty of room for app code
2. **Simplest** - No encoder tool complexity, no decoder code to ship
3. **Fastest** - 124ns decode vs 2,143ns for MCUFont (17x faster)
4. **Zero risk** - Cannot accidentally expand data like SimpleRLE does
5. **Less code** - No compression bugs possible

**Opt-in: MCUFont for space-constrained builds**

```zig
// build.zig
const FontCompression = enum {
    none,      // Default: simple, fast, safe
    mcufont,   // Opt-in: saves ~22%, slower decode
    // Note: simple_rle NOT recommended - expands AA font data
};
```

**Build Tool: Auto-Detection**

The font encoding tool analyzes pixel distribution and recommends/selects:

```
$ zig-gui-font encode input.ttf -o font.bin

Analyzing pixel distribution...
  Black (0):      39.7%
  White (255):     2.5%
  Intermediate:   57.8%

Recommendation: raw (high intermediate pixel ratio)
Using: raw
Output: font.bin (7,079 bytes)
```

```
┌─────────────────────────────────────────────────────────────────┐
│                    AUTO-DETECTION LOGIC                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  Analyze pixel distribution:                                     │
│                                                                  │
│  If black + white > 80%:                                        │
│    → Use SimpleRLE (long runs, good compression)                │
│    → Typical for: 1-bit fonts, high-contrast renders            │
│                                                                  │
│  If intermediate > 20%:                                         │
│    → Use raw (RLE would expand)                                 │
│    → Typical for: antialiased fonts                             │
│                                                                  │
│  Override available: --compression=mcufont                       │
│    → For users who need every byte                              │
│    → Accept slower decode (17x) for 22% size reduction          │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

All options fit comfortably in 32KB budget (~26% used).

---

## Next Steps

1. **Get team alignment** on this design
2. **Start Phase 1** with `BitmapProvider`
3. **Create test font** using MCUFont encoder
4. **Integrate** with existing draw system
5. **Iterate** based on real usage

The experiments in this directory serve as a foundation for implementation.
