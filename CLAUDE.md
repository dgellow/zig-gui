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

## References

- `DESIGN.md` - Complete technical design
- `BENCHMARKS.md` - Performance measurements (source of truth)
- `src/layout/engine.zig` - Layout implementation
- `src/tracked.zig` - State management implementation
