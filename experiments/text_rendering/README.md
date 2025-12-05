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

**Updated Recommendation:**
- **1-bit fonts**: SimpleRLE works great (~3x compression)
- **8-bit AA fonts**: MCUFont or raw (RLE expands due to no runs)
- Compile flag approach still valid

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

---

## Open Questions to Resolve

1. **~~Where does line breaking live?~~** ✓ RESOLVED
   - **Answer: BYOL (Bring Your Own Line Breaker)**
   - Separate `LineBreaker` interface, consistent with BYOR/BYOT pattern
   - Ships with `SimpleBreaker` (ASCII) and `GreedyBreaker` (CJK)
   - Users can bring UAX #14, ICU, or platform implementations
   - See experiment 07 and DESIGN_OPTIONS.md

2. **How do we handle text input cursors?**
   - `getCharPositions()` is O(n) for every cursor move
   - Cache char positions? Where?
   - Incremental updates?

3. **Font fallback: whose responsibility?**
   - User provides fallback chain?
   - Built-in Unicode coverage detection?
   - Platform font discovery?

4. **Atlas texture format?**
   - Alpha-only (1 channel, smaller)
   - RGBA (color emoji)
   - Both? Separate atlases?

5. **Can SDF work on software backend?**
   - CPU SDF evaluation is possible but slow
   - Worth supporting? Or mandate bitmap for SW?

6. **Compile-time vs runtime font selection?**
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
