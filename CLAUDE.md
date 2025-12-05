# Claude Instructions for zig-gui

## Project Overview

zig-gui is a high-performance UI library combining event-driven execution (0% idle CPU), immediate-mode API, and universal targeting (embedded to desktop).

**Full documentation:** See `DESIGN.md` for architecture, API reference, and technical details.

## Build & Test

**Finding Zig:**

1. First, check if `zig` is in PATH: `which zig`
2. If not found, check `/tmp/zig-linux-x86_64-0.13.0/zig`
3. If still not found, download and extract:
   ```bash
   cd /tmp
   curl -LO https://ziglang.org/download/0.13.0/zig-linux-x86_64-0.13.0.tar.xz
   tar -xf zig-linux-x86_64-0.13.0.tar.xz
   ```

**Build commands:**

```bash
zig build test                           # Run all tests
zig build                                # Build debug
zig build -Doptimize=ReleaseFast         # Build release
zig build -Denable_profiling=true        # Build with profiling
```

Replace `zig` with the full path if not in PATH.

## Code Organization

```
src/
├── root.zig           # Public API exports
├── app.zig            # App context, execution modes
├── gui.zig            # Core GUI context
├── tracked.zig        # State management (Tracked signals)
├── events.zig         # Event system
├── renderer.zig       # Renderer abstraction
├── layout.zig         # Re-exports layout engine
├── layout/            # Flexbox layout engine
│   └── engine.zig
├── style.zig          # Style system
├── animation.zig      # Animation system
├── platforms/         # Platform backends
│   └── sdl.zig
├── components/        # UI components
└── core/              # Core types (geometry, color, paint)
```

## Performance Targets

| Metric | Target |
|--------|--------|
| Desktop idle CPU | 0% |
| Layout per element | <10μs |
| Desktop memory | <1MB |
| Embedded RAM | <32KB |
| Embedded flash | <128KB |
| Input response | <5ms |

## Strict Rules

### 1. Event-Driven First

Desktop apps MUST block on events:

```zig
// CORRECT
while (app.isRunning()) {
    const event = try app.waitForEvent(); // Blocks (0% CPU)
    if (event.requiresRedraw()) try app.render();
}

// WRONG - burns CPU
while (app.isRunning()) {
    try app.render();
}
```

### 2. Ownership Model

Platform owns OS resources, App borrows via vtable:

```zig
var platform = try SdlPlatform.init(allocator, config);
defer platform.deinit();

var app = try App(State).init(allocator, platform.interface(), .{});
defer app.deinit();
```

### 3. State Management

Use `Tracked(T)` - 4 bytes overhead per field:

```zig
const AppState = struct {
    counter: Tracked(i32) = .{ .value = 0 },
};

fn myApp(gui: *GUI, state: *AppState) !void {
    if (try gui.button("Increment")) {
        state.counter.set(state.counter.get() + 1);
    }
}
```

### 4. No Over-Engineering

- Only make changes directly requested
- Don't add features beyond what was asked
- Don't add docstrings/comments to unchanged code
- Don't add error handling for impossible scenarios
- Three similar lines > premature abstraction
- If unused, delete completely

### 5. No Backwards-Compatibility Hacks

- Don't rename unused `_vars`
- Don't re-export unused types
- Don't add `// removed` comments

### 6. Design the Complete Solution

**Never design incomplete solutions or defer hard problems to "later phases".**

When designing interfaces or features:
- Design for the FULL requirements from the start (embedded + desktop + i18n)
- Include support for hard cases in the interface (bidi, emoji, CJK) even if implementation comes later
- Don't create interfaces that will need breaking changes when "Phase 2" arrives
- If a feature is out of scope, exclude it entirely - don't half-design it

```
// WRONG: "Phase 1 is LTR only, we'll add bidi later"
// This leads to interfaces that can't support bidi without breaking changes

// CORRECT: Design interface that supports bidi from day 1
// Implementation can be LTR-only initially, but interface is complete
pub const VTable = struct {
    getCharPositions: *const fn (...) usize,           // Works for all text
    hitTest: ?*const fn (...) HitTestResult,           // Optional, needed for bidi
    getCaretInfo: ?*const fn (...) CaretInfo,          // Optional, needed for bidi
};
```

The goal is **complete design, incremental implementation** - not phased design that accumulates technical debt.

## Validation Standards

### Honest Benchmarking

Performance claims must be validated:

1. **Measure complete operations** - not cherry-picked fast paths
2. **Use realistic scenarios** - email client (81 elements), game HUD (47 elements)
3. **Force cache invalidation** - vary constraints between iterations
4. **Compare fairly** - same operations across engines

```zig
// CORRECT: Forces actual computation
for (0..iterations) |iter| {
    const w = 1920.0 + @as(f32, @floatFromInt(iter % 10));
    try engine.computeLayout(w, 1080);
}

// WRONG: Measures cache hits
for (0..iterations) |_| {
    try engine.computeLayout(1920, 1080);
}
```

### Red Flags

Investigate immediately if you see:
- 100% cache hit rate
- Results faster than component benchmarks
- Orders of magnitude better than state-of-the-art
- Identical times across different workloads

### Validation Workflow

Before claiming any performance number:
1. Write the benchmark
2. Check for red flags
3. Verify measuring what you claim
4. Force worst-case scenarios
5. Document methodology

### Realistic Data Validation (CRITICAL)

**Synthetic tests can give completely misleading results.**

Both experiment 06 (font compression) and experiment 08 (line breaking) revealed the same pattern:

| Experiment | Synthetic Result | Realistic Result | Impact |
|------------|------------------|------------------|--------|
| 06: Compression | SimpleRLE compresses ~3x | SimpleRLE EXPANDS data (0.7x) | Wrong default choice |
| 08: Interface | Buffer-based fastest | Buffer-based TRUNCATES output | Incorrect lines |

**Root causes discovered:**
- Exp 06: Synthetic assumed 85% black pixels; real fonts have 58% gray (antialiasing)
- Exp 08: Short test text had 40 breaks; real CJK/long text has 450+ breaks

**Always test with:**
1. Real data (actual fonts, actual UI text, actual user content)
2. Edge cases (empty, very long, all-breaks, no-breaks)
3. Different densities (ASCII ~20% breaks vs CJK ~100% breaks)
4. Scale variations (short labels to long documents)

**Before finalizing any interface or algorithm:**
```
1. Identify synthetic assumptions
2. Find real-world counterexamples
3. Test with worst-case realistic data
4. Verify correctness, not just speed
```

## C API Rules

```c
// Platform first (owns OS resources)
ZigGuiPlatform* platform = zig_gui_sdl_platform_create(...);

// App borrows platform
ZigGuiApp* app = zig_gui_app_create(zig_gui_platform_interface(platform), ...);

// Destroy in reverse order
zig_gui_app_destroy(app);
zig_gui_platform_destroy(platform);
```

## Design Process for New Features

When designing new features or interfaces, follow this validated process:

### Phase 1: Survey State of the Art

Before making any decision, conduct a comprehensive survey:

```
1. Search academic papers (ACM, IEEE, arXiv)
2. Search industry implementations:
   - Browsers (Chrome, Firefox, Safari)
   - Game engines (Unity, Unreal, Dear ImGui)
   - UI frameworks (Qt, Flutter, Bevy)
   - Rust ecosystem (cosmic-text, fontique, swash)
3. Document findings with sources
4. Identify patterns and trade-offs
```

### Phase 2: Create Realistic Experiment

**Never decide based on theoretical analysis alone.**

Create an experiment file (e.g., `experiments/text_rendering/13_font_fallback.zig`) that:

```
1. Defines realistic scenarios (not synthetic tests!)
   - Embedded: thermostat, config input
   - Desktop: email, code editor, CJK
   - Games: HUD, leaderboard, MMO chat
   - Edge cases: missing glyphs, rare scripts

2. Implements multiple strategies to compare

3. Measures what matters:
   - Performance (lookups, cache hits)
   - Correctness (Han unification, .notdef)
   - User burden (config complexity)

4. Produces concrete recommendations
```

### Phase 3: Document Decision

After experiment validates the approach:

1. Update `README.md` with experiment summary
2. Update `DESIGN_OPTIONS.md` with full decision rationale
3. Include:
   - Options evaluated with verdicts
   - Final decision in ASCII box diagram
   - Updated interface/config
   - Recommendations by target
   - State-of-the-art validation table
   - Sources/references

### Example: Font Fallback Decision Process

```
Phase 1: Survey
├── Chrome: Hard-coded script-to-font map
├── Firefox: Dynamic search up to 32 fonts
├── DirectWrite/CoreText: Platform APIs
├── Dear ImGui: MergeMode font stacking
├── cosmic-text: Chrome/Firefox static lists
└── Finding: No universal standard

Phase 2: Experiment (13_font_fallback.zig)
├── 26 realistic scenarios
├── Linear vs Locale-Aware strategies
├── Han unification validation
└── Finding: User chain + locale tag works

Phase 3: Decision
├── User provides fallback chain ✓
├── Locale tag for Han unification ✓
├── NO BYOFF (pluggable fallback) ✗
└── Platform query (optional helper) ✗
```

### Key Principles

1. **Config over Interface**: When there's no consensus, make it config
   - Atlas strategy: `.shelf_lru` not BYOFM interface
   - Fallback locale: `"ja"` not BYOFF interface

2. **Survey Before Deciding**: Always check what industry does
   - Chrome, Firefox, Unity, ImGui often converge
   - Academic papers reveal edge cases

3. **Realistic Over Synthetic**:
   - Experiment 06: Synthetic said RLE works; real fonts expand!
   - Experiment 08: Short text worked; CJK truncated!
   - Experiment 13: Han unification only visible with locale test

4. **Document Everything**:
   - Future you will forget why
   - Others need to understand trade-offs
   - Sources allow verification

### Template for New Design Decisions

```markdown
### N. ~~Topic~~ ✓ RESOLVED (Experiment XX)

**Decision**: [One-line summary]

**Options Evaluated**:
| Option | Description | Verdict |
|--------|-------------|---------|
| A) ... | ... | ✓/✗ |

**Final Decision**:
[ASCII box with key points]

**Experiment XX Key Results**:
| Metric | Option A | Option B |
|--------|----------|----------|

**2025 State-of-the-Art Validation**:
| Source | Approach | Alignment |
|--------|----------|-----------|

**Sources**:
- Experiment: `experiments/.../XX_topic.zig`
- [Reference 1](url)
```

## References

- `DESIGN.md` - Complete technical design
- `BENCHMARKS.md` - Performance measurements (source of truth)
- `experiments/text_rendering/` - Design experiments and validation
- `src/layout/engine.zig` - Layout implementation
- `src/tracked.zig` - State management implementation
