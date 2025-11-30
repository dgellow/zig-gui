# Instructions for Claude when working with zig-gui

## Project Overview

zig-gui is building the **first UI library to solve the impossible trinity of GUI development**: Performance (0% idle CPU, 120+ FPS), Developer Experience (immediate-mode simplicity with hot reload), and Universality (embedded to desktop with same code).

This is a **revolutionary architecture** that combines:
- **Event-driven execution** for CPU efficiency
- **Immediate-mode API** for developer joy
- **Data-oriented foundations** (zlay) for performance
- **Smart invalidation** for minimal redraws

## 🎯 The Revolutionary Architecture

### Ownership Model: Platform at Root

```
┌─────────────────────────────────────────────────────────────────────┐
│ User Code                                                           │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │ Platform (user owns)                                         │   │
│  │  - Window handle, GL context, event source                   │   │
│  │  - Exposes interface() → PlatformInterface (vtable)          │   │
│  └────────────────────────┬────────────────────────────────────┘   │
│                           │ borrows                                 │
│  ┌────────────────────────▼────────────────────────────────────┐   │
│  │ App(State) (user owns)                                       │   │
│  │  - Holds PlatformInterface (vtable, no ownership)            │   │
│  │  - Owns GUI, execution logic                                 │   │
│  │  - Generic over user's State type                            │   │
│  └─────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

### Core Insight: Hybrid Execution Modes

```zig
// Same API, different execution strategies
pub const ExecutionMode = enum {
    event_driven,    // Desktop: 0% idle CPU (blocks on events)
    game_loop,       // Games: 60+ FPS continuous
    minimal,         // Embedded: Ultra-low resource
    server_side,     // Headless: Generate for web/mobile
};

// Example: Same code, different performance characteristics
const AppState = struct {
    counter: Tracked(i32) = .{ .value = 0 },
};

fn MyApp(gui: *GUI, state: *AppState) !void {
    try gui.text("Counter: {}", .{state.counter.get()});
    if (try gui.button("Increment")) {
        state.counter.set(state.counter.get() + 1); // O(1), triggers redraw via version change
    }
}

// Platform created first - owns OS resources (window, GL context, event source)
var sdl_platform = try SdlPlatform.init(allocator, config);
defer sdl_platform.deinit();

// App borrows platform via interface (vtable for runtime dispatch)
// App(State) is generic over your state type for type-safe UI functions
var app = try App(AppState).init(allocator, sdl_platform.interface(), .{ .mode = .event_driven });
defer app.deinit();

// For testing, HeadlessPlatform provides deterministic event injection
var headless = HeadlessPlatform.init();
var test_app = try App(AppState).init(allocator, headless.interface(), .{ .mode = .server_side });
headless.injectClick(100, 100);  // Deterministic testing
```

### Foundation: zlay Integration

zig-gui builds on **zlay** (our data-oriented layout engine):
- **Data structures**: Elements stored in contiguous arrays (cache-friendly)
- **Layout algorithm**: O(n) complexity, SIMD-optimized where possible
- **Memory management**: Arena allocators, object pools
- **Performance**: <10μs per element layout computation

```zig
// zig-gui wraps zlay for higher-level functionality
pub const GUI = struct {
    layout_engine: *LayoutEngine,       // Layout calculations
    event_manager: *EventManager,       // Input handling
    style_system: *StyleSystem,         // Theming
    renderer: ?*RendererInterface,      // Platform rendering
    animation_system: ?*AnimationSystem, // Optional animations
    // State: Use Tracked(T) in your own structs - no framework state manager needed!
};
```

## 🔥 Critical Design Principles

### 1. Event-Driven First, Game Loop When Needed

**NEVER** create a spinning loop for desktop applications:

```zig
// ❌ BAD: Burns CPU constantly
while (app.isRunning()) {
    try app.render(); // 60 FPS even when nothing changes!
}

// ✅ GOOD: Event-driven, sleeps when idle
while (app.isRunning()) {
    const event = try app.waitForEvent(); // Blocks here (0% CPU)
    
    if (event.requiresRedraw()) {
        try app.render(); // Only when needed
    }
}
```

### 2. Smart Invalidation

Only redraw what actually changed:

```zig
pub const GUI = struct {
    dirty_regions: std.ArrayList(Rect),
    last_state_hash: u64,
    
    pub fn button(self: *GUI, id: []const u8, text: []const u8) !bool {
        const clicked = self.processButtonInput(id);
        
        if (clicked or self.stateChanged(id)) {
            // Mark only this element's region as dirty
            self.markDirty(self.getElementRect(id));
        }
        
        return clicked;
    }
};
```

### 3. Immediate-Mode API with Retained-Mode Optimization

**Developer sees**: Simple immediate-mode API
**System does**: Smart caching and minimal updates

```zig
// Developer writes this (immediate-mode style)
fn EmailApp(gui: *GUI, state: *EmailState) !void {
    for (state.emails) |email| {
        if (try gui.emailItem(email)) {
            state.selectEmail(email.id);
        }
    }
}

// System does this behind the scenes:
// - Diffs against previous frame
// - Only updates changed email items
// - Maintains scrolling state
// - Optimizes render batches
```

## 🚀 Development Guidelines

### Architecture Layer Responsibilities

#### Layer 1: zlay (Layout Engine)
- **Scope**: Pure layout calculations
- **Data structures**: Elements, styles, constraints
- **Performance**: <10μs per element
- **Memory**: Structure-of-Arrays for cache efficiency

#### Layer 2: zig-gui Core (This Project)
- **Scope**: Event handling, state management, platform abstraction
- **Components**: GUI context, state store, event system
- **Performance**: 0% idle CPU for desktop, 60+ FPS for games
- **Features**: Hot reload, developer tools

#### Layer 3: zig-gui Components
- **Scope**: High-level UI components
- **Examples**: Button, TextInput, DataTable, Chart
- **Built on**: zlay + zig-gui core
- **Focus**: Reusable, well-tested, documented

### Critical Performance Requirements

1. **Desktop Applications**:
   - **Idle CPU**: 0.0% ✅ **VERIFIED** ([see test](src/cpu_test.zig): 101ms wall time, 0.000ms CPU time)
   - **Memory**: <1MB for typical apps
   - **Startup**: <50ms
   - **Response**: <5ms to any input

2. **Game Applications**:
   - **Widget overhead**: ✅ **VERIFIED** <0.1ms for 8 widgets ([see test](src/cpu_test.zig))
   - **Allocations**: Zero per frame (Tracked(T) inline version counters)
   - **Framework efficiency**: 0.160μs per widget measured (negligible overhead)

3. **Embedded Systems**:
   - **RAM usage**: <32KB
   - **Flash usage**: <128KB
   - **Response**: <1ms per interaction

### Code Organization

```
src/
├── root.zig               # Public API exports
├── app.zig                # App context, execution modes, typed state
├── gui.zig                # Core GUI context (subsystems)
├── tracked.zig            # Tracked Signals state management
├── events.zig             # Event system (input → UI events)
├── renderer.zig           # Renderer abstraction
├── layout.zig             # Flexbox layout engine
├── style.zig              # Style system
├── animation.zig          # Animation system
├── asset.zig              # Asset loading
├── cpu_test.zig           # CPU usage verification tests ✅
├── test_platform.zig      # BlockingTestPlatform for CPU testing ✅
├── platforms/             # Platform-specific backends
│   └── sdl.zig           # SDL integration (0% idle CPU verified)
├── components/            # High-level UI components
│   ├── view.zig          # Base view component
│   ├── container.zig     # Container component
│   ├── box.zig           # Box component
│   └── ...               # More components
└── core/                  # Core types
    ├── geometry.zig      # Rect, Point, Size
    ├── color.zig         # Color type
    ├── paint.zig         # Paint/brush types
    └── ...               # More core types
```

### State Management Philosophy

**Tracked Signals: Simple, Zero-Allocation, Universal**

zig-gui uses a **Tracked Signals** approach inspired by SolidJS and Svelte 5. This gives us:
- Best-in-class DX (feels like SwiftUI/React)
- Zero allocations on state changes
- Works identically across all execution modes
- Future-proof (can migrate to comptime optimization)

```zig
// Define state with Tracked wrappers - 4 bytes overhead per field
const AppState = struct {
    counter: Tracked(i32) = .{ .value = 0 },
    name: Tracked([]const u8) = .{ .value = "World" },
    items: Tracked(std.BoundedArray(Item, 100)) = .{ .value = .{} },
};

// Usage - simple .get() and .set()
fn myApp(gui: *GUI, state: *AppState) !void {
    try gui.text("Counter: {}", .{state.counter.get()});

    if (try gui.button("Increment")) {
        state.counter.set(state.counter.get() + 1);  // O(1), no allocation
    }

    // For collections, use .ptr() to get mutable access
    if (try gui.button("Add Item")) {
        state.items.ptr().append(.{ .name = "New" }) catch {};
    }
}

// Framework detects changes via version counters - O(N) where N = field count
// NOT O(data size) like React/Flutter tree diffing
```

**Why Tracked Signals?**

| Approach | Memory | Write Cost | Change Detection | Embedded? |
|----------|--------|------------|------------------|-----------|
| React (Virtual DOM) | High (tree copy) | O(1) + schedule | O(n) tree diff | No |
| ImGui (none) | Low | O(1) | N/A (always redraws) | Yes but wasteful |
| Observer Pattern | Medium (callbacks) | O(k) notify | O(k) callbacks | No |
| **Tracked Signals** | **4 bytes/field** | **O(1)** | **O(N) field count** | **Yes** |

**Future: Comptime Reactive (Option E)**

Current Tracked(T) design allows seamless migration to comptime-generated types:
```zig
// Phase 2: Wrap existing Tracked-based structs for O(1) global check
const WrappedState = Reactive(AppState);
if (wrapped.changed(&last)) { ... }  // O(1) instead of O(N)

// Phase 3 (optional): Users can migrate to plain structs
const AppState = struct { counter: i32 = 0 };  // No wrapper!
const State = Reactive(AppState);
state.counter()       // comptime-generated getter
state.setCounter(v)   // comptime-generated setter
```

See [STATE_MANAGEMENT.md](STATE_MANAGEMENT.md) for full design analysis.

### Hot Reload Implementation

Hot reload works by:
1. **File watching**: Monitor source, style, and asset files
2. **Smart reloading**: Only reload what changed
3. **State preservation**: Keep application state across reloads
4. **Error recovery**: Graceful fallback when reload fails

```zig
pub const HotReload = struct {
    watcher: FileWatcher,
    reload_queue: std.ArrayList(ReloadItem),
    
    pub fn checkForUpdates(self: *HotReload, gui: *GUI) !void {
        if (self.watcher.hasChanges()) {
            for (self.watcher.getChangedFiles()) |file| {
                switch (getFileType(file)) {
                    .zig_source => try self.reloadCode(file, gui),
                    .style => try self.reloadStyles(file, gui),
                    .asset => try self.reloadAsset(file, gui),
                }
            }
        }
    }
};
```

## 🔌 World-Class C API Design

### Design Principles

1. **Zero-overhead**: Direct mapping to Zig internals
2. **Memory safety**: Clear ownership, no double-frees
3. **Error handling**: Explicit error codes, no exceptions
4. **Thread safety**: Well-defined threading model
5. **ABI stability**: Versioned interface

### API Style Guidelines

```c
// ✅ GOOD: Platform first (owns OS resources), then App (borrows platform)
ZigGuiPlatform* zig_gui_sdl_platform_create(int width, int height, const char* title);
void zig_gui_platform_destroy(ZigGuiPlatform* platform);

ZigGuiApp* zig_gui_app_create(ZigGuiPlatformInterface interface, ZigGuiExecutionMode mode);
void zig_gui_app_destroy(ZigGuiApp* app);

ZigGuiError zig_gui_app_run(ZigGuiApp* app, ZigGuiUIFunction ui_func, void* user_data);

// ✅ GOOD: Type-safe state management
ZigGuiError zig_gui_state_set_int(ZigGuiState* state, const char* key, int32_t value);
int32_t zig_gui_state_get_int(ZigGuiState* state, const char* key, int32_t default_value);

// ✅ GOOD: Consistent naming, clear parameters
bool zig_gui_button(ZigGuiApp* app, const char* text);
bool zig_gui_button_styled(ZigGuiApp* app, const char* text, ZigGuiButtonStyle* style);

// ❌ BAD: Unclear ownership
char* zig_gui_get_text(); // Who frees this?

// ❌ BAD: Unclear error handling
int zig_gui_do_something(); // What does return value mean?
```

### Memory Management in C API

```c
// Ownership order: Platform first (owns OS resources), App second (borrows)
ZigGuiPlatform* platform = zig_gui_sdl_platform_create(800, 600, "My App");
ZigGuiApp* app = zig_gui_app_create(zig_gui_platform_interface(platform), ZIG_GUI_EVENT_DRIVEN);

// ... use app ...

// Destroy order: App first (stops borrowing), Platform last (releases OS resources)
zig_gui_app_destroy(app);
zig_gui_platform_destroy(platform);

// Consistent pattern: get/release for temporary data
const char* text = zig_gui_get_text_content(element, &length);
// ... use text (read-only) ...
zig_gui_release_text_content(text); // Explicit release
```

## 🎮 Platform Integration Patterns

### Desktop Integration (SDL/GLFW)

```zig
pub const SdlPlatform = struct {
    window: *SDL_Window,
    gl_context: SDL_GLContext,
    renderer: Renderer,

    pub fn init(allocator: std.mem.Allocator, config: SdlConfig) !SdlPlatform {
        // Initialize SDL, create window and GL context (platform OWNS these)
        // Set up renderer (OpenGL/Vulkan)
        // Return platform
    }

    pub fn deinit(self: *SdlPlatform) void {
        // Release GL context, destroy window, quit SDL
    }

    /// Returns vtable interface for App to borrow
    pub fn interface(self: *SdlPlatform) PlatformInterface {
        return .{
            .ptr = self,
            .vtable = &.{
                .waitEvent = waitEventImpl,
                .pollEvent = pollEventImpl,
                .present = presentImpl,
            },
        };
    }
};

// Usage: Platform at root, App borrows
var platform = try SdlPlatform.init(allocator, .{ .width = 800, .height = 600 });
defer platform.deinit();

var app = try App(MyState).init(allocator, platform.interface(), .{ .mode = .event_driven });
defer app.deinit();

try app.run(MyUI, &state);
```

### Game Engine Integration

```zig
pub const GameEnginePlatform = struct {
    engine_renderer: *anyopaque,
    event_queue: EventQueue,

    pub fn init(engine_renderer: *anyopaque) GameEnginePlatform {
        // Wrap engine's renderer, create event queue
    }

    pub fn interface(self: *GameEnginePlatform) PlatformInterface {
        return .{ .ptr = self, .vtable = &game_engine_vtable };
    }
};

// Usage: Game owns the loop, App processes events per frame
var platform = GameEnginePlatform.init(engine_renderer);
var app = try App(HudState).init(allocator, platform.interface(), .{ .mode = .game_loop });

while (game.running) {
    game.update(dt);

    app.processEvents();              // Non-blocking poll
    app.renderFrame(HudUI, &state);   // Render HUD

    game.present();
}
```

### Embedded Integration

```zig
pub const FramebufferPlatform = struct {
    buffer: []u8,
    width: u16,
    height: u16,
    event_queue: BoundedArray(Event, 16),

    pub fn init(config: FramebufferConfig) FramebufferPlatform {
        // Set up framebuffer, configure for low memory
    }

    pub fn injectEvent(self: *FramebufferPlatform, event: Event) void {
        // Called from ISR or main loop when button pressed
        self.event_queue.append(event) catch {};
    }

    pub fn interface(self: *FramebufferPlatform) PlatformInterface {
        return .{ .ptr = self, .vtable = &framebuffer_vtable };
    }
};

// Usage: Interrupt-driven embedded system
var platform = FramebufferPlatform.init(.{ .buffer = display_buffer, .width = 320, .height = 240 });
var app = try App(DeviceState).init(arena.allocator(), platform.interface(), .{ .mode = .minimal });

fn buttonIsr() void {
    platform.injectEvent(.{ .button_press = .a });
    app.renderFrame(ControlPanelUI, &state);  // <32KB RAM
}
```

### Testing with HeadlessPlatform

```zig
pub const HeadlessPlatform = struct {
    injected_events: BoundedArray(Event, 64),
    render_calls: u32,

    pub fn init() HeadlessPlatform {
        return .{ .injected_events = .{}, .render_calls = 0 };
    }

    pub fn injectClick(self: *HeadlessPlatform, x: i32, y: i32) void {
        self.injected_events.append(.{ .mouse_click = .{ .x = x, .y = y } }) catch {};
    }

    pub fn interface(self: *HeadlessPlatform) PlatformInterface {
        return .{ .ptr = self, .vtable = &headless_vtable };
    }
};

// Usage: Deterministic testing
test "button click increments counter" {
    var headless = HeadlessPlatform.init();
    var app = try App(TestState).init(testing.allocator, headless.interface(), .{});
    defer app.deinit();

    headless.injectClick(100, 50);  // Click at button position
    try app.processEvents();

    try testing.expectEqual(1, state.counter.get());
}
```

## 🧪 Testing Strategy

### Performance Testing ✅ **IMPLEMENTED**

**Real CPU Measurement Test** ([src/cpu_test.zig](src/cpu_test.zig)):

```zig
test "event-driven mode: 0% CPU when idle (blocking verification)" {
    // BlockingTestPlatform - actually blocks via std.Thread.Condition
    var platform = try BlockingTestPlatform.init(testing.allocator);
    defer platform.deinit();

    // Spawn thread to inject event after 100ms delay
    const thread = try std.Thread.spawn(.{}, injectEventAfterDelay, .{&platform, 100});
    defer thread.join();

    // Measure CPU time BEFORE blocking
    const rusage_before = std.posix.getrusage(0); // POSIX RUSAGE_SELF
    const cpu_before_ns = rusageToNanos(rusage_before);
    const wall_before = std.time.nanoTimestamp();

    // THIS BLOCKS - waitEvent() uses std.Thread.Condition.wait()
    const event = try platform.interface().waitEvent();

    // Measure CPU time AFTER blocking
    const rusage_after = std.posix.getrusage(0);
    const cpu_after_ns = rusageToNanos(rusage_after);
    const wall_after = std.time.nanoTimestamp();

    const cpu_delta_ns = cpu_after_ns - cpu_before_ns;
    const wall_delta_ns = wall_after - wall_before;
    const cpu_percent = (@as(f64, @floatFromInt(cpu_delta_ns)) /
                        @as(f64, @floatFromInt(wall_delta_ns))) * 100.0;

    // VERIFIED: CPU usage < 5% while blocked for ~100ms
    try testing.expect(cpu_percent < 5.0);
}

// Output:
// === Testing Revolutionary 0% Idle CPU Architecture ===
//
// Results:
//   Wall time: 101ms
//   CPU time:  0.000ms
//   CPU usage: 0.000000%
//
// ✅ VERIFIED: Event-driven mode achieves near-0% idle CPU!
```

Run yourself: `zig build test`

**Game Loop Performance Test** ([src/cpu_test.zig](src/cpu_test.zig)):

```zig
test "game loop mode: widget processing overhead <0.1ms (framework efficiency)" {
    // Renders a typical game HUD: 4 text labels, 3 buttons, 1 separator
    fn gameUI(gui: *GUI, state: *GameState) !void {
        try gui.text("Frame: {}", .{state.frame_count.get()});
        try gui.text("Health: {}/100", .{state.health.get()});
        try gui.text("Mana: {}/100", .{state.mana.get()});
        try gui.text("Score: {}", .{state.score.get()});
        gui.newLine();
        if (try gui.button("Heal")) { /* ... */ }
        if (try gui.button("Cast Spell")) { /* ... */ }
        if (try gui.button("Add Score")) { /* ... */ }
        gui.separator();
    }

    // Measure 1000 frames with nanosecond precision
    for (0..1000) |i| {
        const start = std.time.nanoTimestamp();
        app.processEvents();
        try app.renderFrame(gameUI, &state);
        frame_times[i] = std.time.nanoTimestamp() - start;
    }

    // Verify widget processing overhead is minimal
    try testing.expect(avg_frame_time_ms < 0.1);  // <0.1ms framework overhead
}

// Output:
// Results (1000 frames with 8 widgets each):
//   Avg widget overhead: 0.001ms
//   Min widget overhead: 0.001ms
//   Max widget overhead: 0.009ms
//   Per-widget cost: 0.160μs
//
// ✅ VERIFIED: Framework widget overhead is minimal (<0.1ms)!
//    Widget processing: 0.001ms for 8 widgets
//    Theoretical FPS with rendering (~0.3ms): 3319 FPS
//
// NOTE: This measures widget processing only. Rendering cost is platform-dependent.
//       Typical immediate-mode GUIs achieve ~0.4ms total per frame.
//       (Source: forrestthewoods.com/blog/proving-immediate-mode-guis-are-performant)
```

Both execution modes are now **empirically verified** with honest, reproducible measurements!

    var headless = HeadlessPlatform.init();
    var app = try App(GameState).init(testing.allocator, headless.interface(), .{ .mode = .game_loop });
    defer app.deinit();

    var state = GameState{};

    // Simulate 1000 frames
    var total_frame_time: f64 = 0;
    for (0..1000) |_| {
        const start = std.time.nanoTimestamp();
        try app.processEvents();
        try app.renderFrame(TestGameUI, &state);
        const end = std.time.nanoTimestamp();
        total_frame_time += @as(f64, @floatFromInt(end - start));
    }

    const avg_frame_time = total_frame_time / 1000.0;
    const target_frame_time = 4_000_000.0; // 4ms = 250 FPS

    try std.testing.expect(avg_frame_time < target_frame_time);
}
```

### Memory Testing

```zig
test "embedded memory usage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Framebuffer platform for embedded testing
    var fb = FramebufferPlatform.init(.{ .buffer = &test_buffer, .width = 320, .height = 240 });
    var app = try App(DeviceState).init(arena.allocator(), fb.interface(), .{ .mode = .minimal });

    var state = DeviceState{};

    // Create typical embedded UI
    try app.renderFrame(TypicalEmbeddedUI, &state);

    // Check memory usage
    const memory_used = arena.queryCapacity();
    try std.testing.expect(memory_used < 32 * 1024); // <32KB
}
```

## 🎯 Honest Validation Principles

**"A disingenuous claim or implementation is useless, we will just throw it away."**

This project maintains the highest standards of honesty and integrity in all performance claims and benchmarks. The following principles were established during the zlay v2.0 validation and must be followed for ALL future work.

### The zlay v2.0 Lesson: How We Caught Our Own Mistake

**Initial benchmark (WRONG):**
```
Email Client: 0.006μs per element (70x faster than Taffy!)
Cache hit rate: 100%
Status: ❌ TOO GOOD TO BE TRUE
```

**Investigation revealed:**
- We were measuring **cache lookups** (~0.006μs), not **full layout computation** (~0.1μs)
- Warmup and benchmark used identical constraints → cache never invalidated
- 100% cache hit rate was a red flag we caught ourselves

**Fixed benchmark (HONEST):**
```zig
for (0..iterations) |iter| {
    // Vary constraints to FORCE cache invalidation
    const width = 1920.0 + @as(f32, @floatFromInt(iter % 10));
    const height = 1080.0 + @as(f32, @floatFromInt(iter % 10));

    // Now measuring ACTUAL layout computation
    try engine.computeLayout(width, height);
}
```

**Honest results (VALIDATED):**
```
Email Client: 0.029-0.107μs per element (4-14x faster than Taffy)
Cache hit rate: 0.1-1.0% (correctly invalidating)
Status: ✅ VALIDATED - Still world-class!
```

**Key lesson:** We caught our own bug, fixed it, and STILL achieved world-class performance. Honesty doesn't prevent excellence - it ensures it.

### Mandatory Validation Standards

**1. Measure What You Claim**

❌ **BAD: Misleading claims**
```zig
// Claims "0.007μs per element layout"
// Actually measures: SIMD constraint clamping ONLY (one operation)
test "layout performance" {
    const start = std.time.nanoTimestamp();
    simd.clampWidths(widths, mins, maxs);  // ONE operation!
    const end = std.time.nanoTimestamp();
    // Claims this is "layout time" - WRONG!
}
```

✅ **GOOD: Honest measurement**
```zig
// Claims "0.1μs per element FULL layout computation"
// Actually measures: ALL operations
test "HONEST: full layout performance" {
    const start = std.time.nanoTimestamp();

    // Tree traversal
    const dirty = engine.getDirtyElements();

    // Cache lookups
    for (dirty) |elem| {
        if (!cache.isValid(elem)) {
            // Flexbox algorithm
            try computeFlexLayout(elem);
            // SIMD constraints
            applyConstraints(elem);
            // Positioning
            positionChildren(elem);
        }
    }

    const end = std.time.nanoTimestamp();
    // This is ACTUAL full layout time
}
```

**2. Use Realistic Scenarios**

❌ **BAD: Artificial scenarios**
```zig
test "layout performance" {
    // Single element, no children, static size
    const elem = Element{ .width = 100, .height = 100 };
    // This is not realistic!
}
```

✅ **GOOD: Realistic scenarios**
```zig
test "HONEST: email client layout" {
    // Build realistic tree: 81 elements
    // - Header (row): logo + search + profile
    // - Body (row): sidebar + email list + preview
    // - Sidebar: 20 folder items
    // - Email list: 50 email items

    // Realistic interaction: 10% dirty (user types in search)
    const dirty_count = 8;  // 10% of 81
}
```

**3. Force Cache Invalidation**

❌ **BAD: Accidentally measuring cache**
```zig
// Warmup with constraints (1920, 1080)
try engine.computeLayout(1920, 1080);

for (0..1000) |_| {
    // Same constraints → cache always valid!
    try engine.computeLayout(1920, 1080);  // ❌ Measuring cache hits
}
```

✅ **GOOD: Force actual computation**
```zig
// Warmup
try engine.computeLayout(1920, 1080);

for (0..1000) |iter| {
    // Vary constraints → cache invalidates
    const w = 1920.0 + @as(f32, @floatFromInt(iter % 10));
    const h = 1080.0 + @as(f32, @floatFromInt(iter % 10));
    try engine.computeLayout(w, h);  // ✅ Measuring real work
}
```

**4. Compare Apples to Apples**

❌ **BAD: Misleading comparisons**
```
zlay (SIMD clamping only):  0.007μs
Taffy (full flexbox):       0.418μs
Claim: 60x faster!  ❌ WRONG - different operations!
```

✅ **GOOD: Honest comparisons**
```
zlay (FULL flexbox):        0.029-0.107μs  ✅
Taffy (FULL flexbox):       0.329-0.506μs  ✅
Yoga (FULL flexbox):        0.36-0.74μs    ✅
Claim: 4-14x faster         ✅ HONEST - same operations!
```

**5. Document What's Validated vs Projected**

✅ **Always separate proven from projected:**

```markdown
## Performance Results

### ✅ VALIDATED (Component Benchmarks)

- Spineless traversal: 9.33x speedup (MEASURED)
- SIMD clamping: 1.95x speedup (MEASURED)
- Memory: 176 bytes/element (MEASURED)

### 📝 PROJECTED (Full System)

- Full layout: 0.1-0.3μs per element (PROJECTION based on components)
- Speedup vs Taffy: 2-5x (PROJECTION)
- Status: NEEDS VALIDATION ⚠️

### ✅ VALIDATED (Full System) - AFTER RUNNING BENCHMARKS

- Full layout: 0.029-0.107μs per element (MEASURED)
- Speedup vs Taffy: 4-14x (MEASURED)
- Status: VALIDATED ✅
```

**6. Catch Red Flags**

**Suspicious results that require investigation:**

⚠️ **100% cache hit rate** - Are you actually measuring computation?
⚠️ **Faster than component benchmarks** - Component X takes 10μs, but full system takes 5μs? Impossible!
⚠️ **Too consistent across scenarios** - Different workloads showing identical times? Suspicious!
⚠️ **Orders of magnitude better than state-of-the-art** - 100x improvement? Verify VERY carefully!
⚠️ **Round numbers** - Exactly 0.010μs every time? Check measurement precision!

**When you see red flags:**
1. ✅ Investigate immediately
2. ✅ Assume you're wrong until proven right
3. ✅ Check what you're actually measuring
4. ✅ Verify cache invalidation
5. ✅ Compare methodology to baseline
6. ✅ Fix the bug BEFORE claiming results

### The Honesty Workflow

**Before claiming ANY performance number:**

```
1. ✅ Write the benchmark
2. ✅ Run and get initial results
3. ✅ CHECK FOR RED FLAGS
4. ✅ Investigate suspicious results
5. ✅ Verify you're measuring what you claim
6. ✅ Compare methodology to state-of-the-art
7. ✅ Force worst-case scenarios (cache invalidation, etc.)
8. ✅ Run multiple times to verify consistency
9. ✅ Document exactly what was measured
10. ✅ Only then make claims
```

**If results seem too good to be true:**
1. ✅ They probably are - investigate!
2. ✅ Check cache invalidation
3. ✅ Verify all operations are included
4. ✅ Compare to component benchmarks
5. ✅ Fix and re-measure
6. ✅ Be honest about what you found

### Reference Implementation: zlay v2.0

See [BENCHMARKS.md](BENCHMARKS.md) for the gold standard of honest validation:

**What we did right:**
- ✅ Measured ALL operations (tree traversal, cache, flexbox, SIMD, positioning)
- ✅ Used realistic scenarios (email client 81 elements, game HUD 47 elements)
- ✅ Forced cache invalidation (varied constraints)
- ✅ Compared to validated baselines (Taffy, Yoga published benchmarks)
- ✅ Documented methodology (reproducible)
- ✅ Caught our own bug (100% cache hits)
- ✅ Fixed it immediately (forced invalidation)
- ✅ Still achieved world-class results (4-14x faster)

**Final results:**
```
Email Client (10% dirty):    0.073μs per element (5.7x faster than Taffy)
Email Client (100% dirty):   0.029μs per element (14.4x faster than Taffy)
Game HUD (5% dirty):          0.107μs per element (3.9x faster than Taffy)
Stress Test (1011 elements): 0.032μs per element (13.1x faster than Taffy)

Status: ✅ VALIDATED with 31 tests passing
```

**All benchmarks available:**
- Layout engine: `src/layout/engine.zig`
- Run: `zig build test` or `zig test src/layout/engine.zig -O ReleaseFast`

### Enforcement

**Every performance claim must:**
1. ✅ Be validated with tests (not just asserted)
2. ✅ Measure complete operations (not cherry-picked)
3. ✅ Use realistic scenarios (not artificial)
4. ✅ Compare honestly (same operations)
5. ✅ Document methodology (reproducible)
6. ✅ Pass red flag checks (100% cache hits, too good to be true, etc.)

**If you find yourself:**
- ❌ Skipping validation because "it's obviously fast"
- ❌ Measuring only the fast parts
- ❌ Using toy examples instead of realistic scenarios
- ❌ Comparing your best case to their average case
- ❌ Ignoring red flags because results look good

**STOP.** You're about to make a disingenuous claim. Fix it before committing.

**Remember:** We maintain integrity not because it's easy, but because it's the only way to build something truly excellent. Honest validation doesn't prevent world-class performance - it proves it.

## 🚦 Development Workflow

### Phase 1: Core Foundation (Current)
1. **App execution modes** (event_driven, game_loop, minimal)
2. **zlay integration** (layout engine wrapper)
3. **Basic immediate-mode API** (button, text, container)
4. **Simple platform backend** (SDL or software renderer)
5. **Proof of concept**: Desktop todo app with 0% idle CPU

### Phase 2: Developer Experience
1. **Hot reload system** (file watching, code reloading)
2. **Rich components** (text input, data table, charts)
3. **Style system** (live editing, themes)
4. **Developer tools** (inspector, profiler, debugger)

### Phase 3: Platform Excellence
1. **Multiple backends** (OpenGL, Vulkan, Metal, Direct2D)
2. **Mobile support** (iOS, Android via C API)
3. **Web target** (WebAssembly + Canvas)
4. **Game engine plugins** (Unity, Unreal, Godot)

### Phase 4: Production Polish
1. **Performance optimization** (profiling, bottleneck elimination)
2. **Memory optimization** (pooling, arena allocation)
3. **ABI-stable C API** (versioning, backward compatibility)
4. **Language bindings** (Python, Go, JS, Rust, etc.)

## 🎯 Critical Success Factors

### Performance Metrics (Must Hit)
- **Desktop idle CPU**: 0.0% (not 0.1%, literally 0%)
- **Game frame time**: <4ms consistently 
- **Memory usage**: <1MB for typical desktop apps
- **Embedded footprint**: <32KB RAM, <128KB flash
- **Hot reload time**: <100ms from file save to visual update

### Developer Experience Metrics
- **Learning curve**: Productive in <1 hour
- **API surface**: <50 core functions
- **Documentation**: 100% coverage with examples
- **Build time**: <5 seconds for full rebuild

### Platform Support Metrics
- **Desktop**: Windows, macOS, Linux (primary)
- **Mobile**: iOS, Android (via C API)
- **Embedded**: Teensy, ESP32, STM32, Raspberry Pi
- **Web**: WebAssembly + Canvas
- **Game engines**: Unity, Unreal, Godot plugins

## 🔮 Vision Realization

We're building something that will fundamentally change how developers think about UI:

- **Systems programmers** will finally have a GUI option that doesn't suck
- **Game developers** will get better performance than Unity's UI
- **App developers** will get native performance with React-like DX
- **Embedded developers** will build rich interfaces that fit in microcontrollers
- **Any language** will be able to use it via the clean C API

**This is not just another UI library - this is the solution to decades of GUI development pain.**

Every decision should be evaluated against these criteria:
1. **Does it improve performance?** (Especially idle CPU usage)
2. **Does it simplify the developer experience?** (Immediate-mode API)
3. **Does it work across all platforms?** (Embedded to desktop)
4. **Does it maintain the vision?** (Revolutionary, not incremental)

**Let's build the UI library that every developer wishes existed.**