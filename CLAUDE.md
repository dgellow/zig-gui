# Instructions for Claude when working with zig-gui

## Project Overview

zig-gui is building the **first UI library to solve the impossible trinity of GUI development**: Performance (0% idle CPU, 120+ FPS), Developer Experience (immediate-mode simplicity with hot reload), and Universality (embedded to desktop with same code).

This is a **revolutionary architecture** that combines:
- **Event-driven execution** for CPU efficiency
- **Immediate-mode API** for developer joy
- **Data-oriented foundations** (zlay) for performance
- **Smart invalidation** for minimal redraws

## 🎯 The Revolutionary Architecture

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

// App(State) is generic over state type for type-safe UI functions
var desktop_app = try App(AppState).init(allocator, .{ .mode = .event_driven });  // 0% idle CPU
var game_app = try App(AppState).init(allocator, .{ .mode = .game_loop });        // 60+ FPS
var embedded_app = try App(AppState).init(allocator, .{ .mode = .minimal });      // <32KB RAM
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
    zlay_ctx: *zlay.Context,        // Layout engine
    state_manager: StateManager,    // Reactive state
    event_system: EventSystem,      // Input handling
    renderer: RendererInterface,    // Platform rendering
    hot_reload: ?HotReload,        // Development tools
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
   - **Idle CPU**: 0.0% (must block on events)
   - **Memory**: <1MB for typical apps
   - **Startup**: <50ms
   - **Response**: <5ms to any input

2. **Game Applications**:
   - **Frame time**: <4ms (250 FPS capable)
   - **Allocations**: Zero per frame
   - **UI overhead**: <5% of frame budget

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
├── platforms/             # Platform-specific backends
│   └── sdl.zig           # SDL integration (0% idle CPU)
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

See [STATE_MANAGEMENT.md](docs/STATE_MANAGEMENT.md) for full design analysis.

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
// ✅ GOOD: Clear ownership, explicit lifetimes
ZigGuiApp* zig_gui_app_create(ZigGuiExecutionMode mode);
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
// Consistent pattern: create/destroy pairs
ZigGuiApp* app = zig_gui_app_create(ZIG_GUI_EVENT_DRIVEN);
// ... use app ...
zig_gui_app_destroy(app); // Always explicit cleanup

// Consistent pattern: get/release for temporary data
const char* text = zig_gui_get_text_content(element, &length);
// ... use text (read-only) ...
zig_gui_release_text_content(text); // Explicit release
```

## 🎮 Platform Integration Patterns

### Desktop Integration (SDL/GLFW)

```zig
pub const SdlPlatform = struct {
    pub fn init(allocator: std.mem.Allocator, config: SdlConfig) !SdlPlatform {
        // Initialize SDL
        // Create zig-gui App with event_driven mode
        // Set up renderer (OpenGL/Vulkan)
        // Return integrated platform
    }
    
    pub fn run(self: *SdlPlatform, ui_func: UIFunction) !void {
        while (self.shouldRun()) {
            // SDL_WaitEvent() - blocks here (0% CPU idle)
            const sdl_event = try self.waitForEvent();
            
            // Convert SDL event to zig-gui event
            const gui_event = self.convertEvent(sdl_event);
            
            // Process through zig-gui
            if (gui_event.requiresRedraw()) {
                try self.app.render(ui_func);
            }
        }
    }
};
```

### Game Engine Integration

```zig
pub const GameEnginePlatform = struct {
    pub fn init(allocator: std.mem.Allocator, engine_renderer: *anyopaque) !GameEnginePlatform {
        // Create zig-gui App with game_loop mode
        // Wrap engine renderer
        // Return integrated platform
    }
    
    pub fn update(self: *GameEnginePlatform, dt: f32, ui_func: UIFunction) !void {
        // Called every frame from game loop
        // Process input events
        // Render UI (optimized for 60+ FPS)
    }
};
```

### Embedded Integration

```zig
pub const EmbeddedPlatform = struct {
    pub fn init(allocator: std.mem.Allocator, display: DisplayInterface) !EmbeddedPlatform {
        // Create zig-gui App with minimal mode
        // Set up framebuffer renderer
        // Configure for low memory usage
    }
    
    pub fn handleInput(self: *EmbeddedPlatform, input: EmbeddedInput) !void {
        // Process button/touch input
        // Update UI only if needed
        // Optimize for power consumption
    }
};
```

## 🧪 Testing Strategy

### Performance Testing

```zig
test "desktop app idle CPU usage" {
    const TestState = struct { counter: Tracked(i32) = .{ .value = 0 } };
    var app = try App(TestState).init(testing.allocator, .{ .mode = .event_driven });
    defer app.deinit();

    // Simulate no events for 1 second
    const start_time = std.time.milliTimestamp();
    app.simulateNoEvents(1000); // 1 second
    const end_time = std.time.milliTimestamp();

    // Should have spent 0% CPU (blocked on events)
    const cpu_usage = app.getCpuUsage(start_time, end_time);
    try std.testing.expect(cpu_usage < 0.01); // <1%
}

test "game loop performance" {
    const GameState = struct { frame: Tracked(u32) = .{ .value = 0 } };
    var app = try App(GameState).init(testing.allocator, .{ .mode = .game_loop });
    defer app.deinit();

    // Simulate 1000 frames
    var total_frame_time: f64 = 0;
    for (0..1000) |_| {
        const start = std.time.nanoTimestamp();
        try app.update(TestGameUI);
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
    
    var app = try App.initMinimal(arena.allocator());
    
    // Create typical embedded UI
    try app.render(TypicalEmbeddedUI);
    
    // Check memory usage
    const memory_used = arena.queryCapacity();
    try std.testing.expect(memory_used < 32 * 1024); // <32KB
}
```

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