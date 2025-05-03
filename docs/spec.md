# Cross-Platform GUI Library Specification

This document outlines the project's architecture, core components, design principles, and overall vision. It is an inspirational document and not a strict specification or list of supported features and platforms.

## Core Architecture

The library is built on a modular architecture with clear separation of concerns. It follows a data-oriented design approach, prioritizing memory layout, cache efficiency, and explicit control over abstractions.

The primary components include:

```zig
pub const GUI = struct {
    allocator: std.mem.Allocator,
    renderer: *RendererInterface,
    layout_engine: *LayoutEngine,
    style_system: *StyleSystem,
    event_manager: *EventManager,
    state_store: *StateStore,
    animation_system: ?*AnimationSystem,  // Optional, can be null
    asset_manager: *AssetManager,

    root_view: *View,

    pub fn init(allocator: std.mem.Allocator, renderer: *RendererInterface, config: Config) !*GUI {
        // Implementation details...
    }

    pub fn deinit(self: *GUI) void {
        // Implementation details...
    }

    pub fn frame(self: *GUI, dt: f32) void {
        // Process input, update state, calculate layout, render
    }
};
```

The architecture emphasizes:

1. Clear ownership of memory through explicit allocator usage
2. Composition rather than inheritance
3. Interface-based polymorphism for extension
4. Explicit state management
5. Performance optimization through data-oriented design

### Responsibilities and Boundaries

The library focuses on providing the core infrastructure for GUI components, layout, and rendering abstraction. It explicitly does NOT take ownership of:

1. **Memory Management Strategy**: The library accepts allocators but doesn't dictate memory management approaches. Resource pooling, fragmentation handling, etc. are the responsibility of the application.

2. **Threading Model**: The library is thread-model agnostic, allowing integration with various environments that may have their own threading constraints (game engines, single-threaded embedded systems, etc.).

3. **Internationalization**: Basic text rendering is supported, but complex internationalization concerns (bidirectional text, locale-specific formatting) are primarily renderer responsibilities.

4. **Platform-Specific Input Methods**: Advanced input methods are expected to be integrated by the platform-specific implementations.

This clear separation of responsibilities aligns with Zig's philosophy of precise communication of intent and focusing on core functionality.

## Bring Your Own Renderer

The library uses a "bring your own renderer" approach with a well-defined interface. This provides flexibility to integrate with various rendering backends, from high-level graphics libraries to simple framebuffers.

```zig
pub const RendererInterface = struct {
    vtable: *const VTable,

    pub const VTable = struct {
        // Context management
        beginFrame: *const fn(self: *RendererInterface, width: f32, height: f32) void,
        endFrame: *const fn(self: *RendererInterface) void,

        // Drawing primitives
        drawRect: *const fn(self: *RendererInterface, rect: Rect, paint: Paint) void,
        drawRoundRect: *const fn(self: *RendererInterface, rect: Rect, radius: f32, paint: Paint) void,
        drawText: *const fn(self: *RendererInterface, text: []const u8, position: Point, paint: Paint) void,
        drawImage: *const fn(self: *RendererInterface, image_handle: ImageHandle, rect: Rect, paint: Paint) void,
        drawPath: *const fn(self: *RendererInterface, path: Path, paint: Paint) void,

        // Resource management
        createImage: *const fn(self: *RendererInterface, width: u32, height: u32, format: ImageFormat, data: ?[]const u8) ?ImageHandle,
        destroyImage: *const fn(self: *RendererInterface, handle: ImageHandle) void,
        createFont: *const fn(self: *RendererInterface, data: []const u8, size: f32) ?FontHandle,
        destroyFont: *const fn(self: *RendererInterface, handle: FontHandle) void,

        // State management
        save: *const fn(self: *RendererInterface) void,
        restore: *const fn(self: *RendererInterface) void,
        clip: *const fn(self: *RendererInterface, rect: Rect) void,
        transform: *const fn(self: *RendererInterface, transform: Transform) void,
    };
};
```

For platforms with limited resources, a minimal renderer interface requires only essential operations:

```zig
pub const MinimalRendererInterface = struct {
    vtable: *const VTable,

    pub const VTable = struct {
        beginFrame: *const fn(self: *MinimalRendererInterface, width: f32, height: f32) void,
        endFrame: *const fn(self: *MinimalRendererInterface) void,
        drawRect: *const fn(self: *MinimalRendererInterface, rect: Rect, color: Color) void,
        drawText: *const fn(self: *MinimalRendererInterface, text: []const u8, position: Point, color: Color, font_size: f32) void,
    };
};
```

An adapter pattern allows expansion of minimal renderers to support the full interface:

```zig
pub const RendererAdapter = struct {
    renderer_interface: RendererInterface,
    minimal_renderer: *MinimalRendererInterface,

    pub fn init(allocator: std.mem.Allocator, minimal_renderer: *MinimalRendererInterface) !*RendererAdapter {
        // Create adapter to implement advanced features on top of minimal ones
    }
};
```

This approach supports integration with:

- Skia for desktop and mobile platforms
- Direct framebuffer access for embedded displays like the Teensy 4.1
- Game engine renderers (SDL, Unreal, etc.)
- Custom rendering contexts

### Text Rendering Considerations

The text rendering interface is intentionally simple, delegating complex text shaping to renderer implementations. This allows:

1. Simple renderers to implement basic text rendering directly
2. Advanced renderers to incorporate specialized libraries like HarfBuzz when appropriate
3. Platform-specific text rendering to be used when available

The library doesn't impose complex text shaping as a requirement, maintaining flexibility for constrained environments.

## Component System

The component system uses a composition-based approach with type erasure for polymorphism:

```zig
pub const View = struct {
    id: u64,
    rect: Rect,
    parent: ?*View = null,
    children: std.ArrayList(*View),

    style: Style,
    layout_params: LayoutParams,

    data: *anyopaque,
    vtable: *const VTable,

    dirty_layout: bool = true,
    dirty_render: bool = true,

    pub const VTable = struct {
        build: *const fn(*View) void,
        layout: *const fn(*View, Size) Size,
        paint: *const fn(*View, *RenderContext) void,
        handleEvent: *const fn(*View, *Event) bool,
        deinit: *const fn(*View) void,
    };

    pub fn requestRebuild(self: *View) void {
        self.dirty_layout = true;
        self.dirty_render = true;

        // Propagate up to invalidate parent layouts
        var parent = self.parent;
        while (parent) |p| {
            p.dirty_layout = true;
            parent = p.parent;
        }
    }
};
```

Components follow a lifecycle of creation, layout, paint, event handling, and disposal. Each component implements the View interface through its vtable.

The library provides common components like containers, buttons, text fields, sliders, and layout components, each designed for optimal performance and memory usage.

## Layout System

The layout engine uses a Flexbox-inspired implementation as the primary layout mechanism:

```zig
pub const LayoutEngine = struct {
    allocator: std.mem.Allocator,
    dirty_views: std.AutoHashMap(u64, void),

    pub fn needsLayout(self: *LayoutEngine) bool {
        return self.dirty_views.count() > 0;
    }

    pub fn markDirty(self: *LayoutEngine, view: *View) void {
        self.dirty_views.put(view.id, {}) catch {};
    }

    pub fn calculateLayout(self: *LayoutEngine, root_view: *View) void {
        // Calculate layout for the entire view hierarchy
        self.calculateViewLayout(root_view, root_view.rect.size);
        self.dirty_views.clearRetainingCapacity();
    }
};

pub const LayoutParams = struct {
    width: LengthConstraint = .auto,
    height: LengthConstraint = .auto,
    min_width: ?f32 = null,
    min_height: ?f32 = null,
    max_width: ?f32 = null,
    max_height: ?f32 = null,

    flex_grow: f32 = 0.0,
    flex_shrink: f32 = 1.0,
    flex_basis: LengthConstraint = .auto,

    align_self: Alignment = .auto,

    margin: EdgeInsets = EdgeInsets.zero(),
    padding: EdgeInsets = EdgeInsets.zero(),

    position_type: PositionType = .relative,
    position: EdgeInsets = EdgeInsets.zero(),
};
```

### Layout Extension Points

While Flexbox is the primary layout mechanism, the architecture is designed to support alternative layout approaches through a plugin system:

```zig
pub const LayoutEngineExtension = struct {
    vtable: *const VTable,

    pub const VTable = struct {
        measureComponent: *const fn(*LayoutEngineExtension, *View, Size) Size,
        arrangeChildren: *const fn(*LayoutEngineExtension, *View, Rect) void,
        supportedLayoutType: *const fn(*LayoutEngineExtension) LayoutType,
    };
};
```

This allows future support for alternative layout systems, such as:

- Grid-based layouts
- Constraint-based layouts
- UE5-inspired layout slots
- Custom layout algorithms for specific components

The layout engine emphasizes:

- Incremental layout calculations
- Cache-friendly operations
- Minimal recalculations
- Support for complex layouts
- Consistent behavior across platforms

## State Management

State management uses a hybrid approach supporting both global and component-local state:

```zig
pub const StateStore = struct {
    allocator: std.mem.Allocator,

    global_store: std.StringHashMap(StateValue),
    local_stores: std.AutoHashMap(u64, *ComponentState),
    observers: std.StringHashMap(std.ArrayList(*StateObserver)),

    pub fn createState(self: *StateStore, comptime T: type, key: []const u8, initial_value: T) !StateHandle(T) {
        // Create type-safe state handle
    }

    pub fn get(self: *StateStore, comptime T: type, key: []const u8) ?T {
        // Type-safe state retrieval
    }

    pub fn set(self: *StateStore, key: []const u8, value: anytype) !void {
        // Type-safe state update with notifications
    }
};

pub fn StateHandle(comptime T: type) type {
    return struct {
        store: *StateStore,
        key: []const u8,

        pub fn get(self: *const @This()) ?T {
            return self.store.get(T, self.key);
        }

        pub fn set(self: *@This(), value: T) !void {
            try self.store.set(self.key, value);
        }

        pub fn observe(self: *@This(), callback: fn(*anyopaque, T) void, context: *anyopaque) !void {
            // Type-safe observation
        }
    };
}
```

Component-level state management takes inspiration from React hooks:

```zig
pub const ComponentState = struct {
    allocator: std.mem.Allocator,
    component_id: u64,
    states: std.ArrayList(anyopaque),

    pub fn useState(self: *ComponentState, comptime T: type, initial_value: T) !*T {
        // Create or retrieve component-local state
    }

    pub fn useEffect(self: *ComponentState, deps: anytype, callback: fn() ?fn() void) !void {
        // Effect hooks for side effects
    }
};
```

This approach provides type safety, efficient updates, and clear data flow.

## Event System

The event system handles input processing and UI event propagation:

```zig
pub const EventManager = struct {
    allocator: std.mem.Allocator,

    input_events: std.ArrayList(InputEvent),
    ui_events: std.ArrayList(UIEvent),

    listeners: std.AutoHashMap(EventType, std.ArrayList(*EventListener)),

    focused_view: ?*View = null,
    hovered_view: ?*View = null,

    pub fn processEvents(self: *EventManager) void {
        // Process raw input events
        for (self.input_events.items) |event| {
            self.processInputEvent(event);
        }
        self.input_events.clearRetainingCapacity();

        // Dispatch UI events
        for (self.ui_events.items) |event| {
            self.dispatchUIEvent(event);
        }
        self.ui_events.clearRetainingCapacity();
    }
};
```

The event flow follows a capture-bubble model:

1. Event capture phase (top-down)
2. Target phase at specific component
3. Bubble phase (bottom-up)
4. Global event dispatching

## Animation System (Optional)

The animation system provides efficient property animations as an optional module:

```zig
pub const AnimationSystem = struct {
    allocator: std.mem.Allocator,

    running_animations: std.ArrayList(*Animation),
    animation_pool: std.ArrayList(*Animation),

    pub fn animate(self: *AnimationSystem, target: *anyopaque, property: []const u8, end_value: anytype, duration_ms: u32) !*Animation {
        // Create and start animation
    }

    pub fn update(self: *AnimationSystem, dt: f32) void {
        // Update all active animations
        var i: usize = 0;
        while (i < self.running_animations.items.len) {
            const animation = self.running_animations.items[i];

            animation.advance(dt);

            if (animation.isComplete()) {
                // Return to pool and remove from active list
                _ = self.running_animations.orderedRemove(i);
                try self.animation_pool.append(animation);
            } else {
                i += 1;
            }
        }
    }
};

pub const Animation = struct {
    property: []const u8,
    target: *anyopaque,
    start_value: ValueUnion,
    end_value: ValueUnion,
    value_type: ValueType,
    duration: f32,
    current_time: f32 = 0,
    easing_function: fn(f32) f32 = linearEasing,
    on_complete: ?fn(*Animation) void = null,

    pub fn advance(self: *Animation, dt: f32) void {
        // Update animation progress and apply value
    }
};
```

The animation system features:

- Object pooling for zero-allocation animations
- Configurable easing functions
- Property type safety
- Completion callbacks
- Animation sequences and staggered animations

Applications that don't need animations can omit this system entirely, reducing memory and processing overhead.

## Styling and Theming

The styling system provides consistent visual theming:

```zig
pub const StyleSystem = struct {
    allocator: std.mem.Allocator,

    themes: std.StringHashMap(*Theme),
    active_theme: *Theme,

    style_cache: std.AutoHashMap(u64, *Style),

    pub fn getStyleForComponent(self: *StyleSystem, component_type: []const u8, state: ?[]const u8, custom_style: ?*Style) !*Style {
        // Compute and cache component style
    }
};

pub const Theme = struct {
    colors: ColorPalette,
    typography: Typography,
    metrics: Metrics,
    component_styles: std.StringHashMap(*ComponentStyle),
    platform_adaptations: PlatformAdaptations,
    color_scheme: ColorScheme = .light,
};

pub const PlatformAdaptations = struct {
    button_radius: f32,
    control_radius: f32,
    animation_speed_factor: f32,
    font_size_multiplier: f32,
    density_scale: f32,
    touch_target_min_size: Size,
    scroll_friction: f32,
    scroll_spring_stiffness: f32,
};
```

The styling approach maintains consistent branding while respecting platform conventions. The system supports light/dark mode switching and theme customization.

## Asset Management and Resource Loading

The asset management system handles resource loading with support for asynchronous operations:

```zig
pub const AssetManager = struct {
    allocator: std.mem.Allocator,

    loaded_assets: std.StringHashMap(*Asset),
    loading_requests: std.ArrayList(LoadingRequest),

    pub fn loadAsset(self: *AssetManager, path: []const u8, asset_type: AssetType) !AssetHandle {
        // Check if already loaded
        if (self.loaded_assets.get(path)) |asset| {
            return AssetHandle{
                .manager = self,
                .path = try self.allocator.dupe(u8, path),
                .state = .loaded,
                .asset = asset,
            };
        }

        // Create loading request
        const handle = AssetHandle{
            .manager = self,
            .path = try self.allocator.dupe(u8, path),
            .state = .loading,
            .asset = null,
        };

        try self.loading_requests.append(.{
            .path = handle.path,
            .asset_type = asset_type,
            .callback = null,
        });

        return handle;
    }

    pub fn processLoadingRequests(self: *AssetManager) !void {
        // Process queued asset loading requests
        // This can be called from application's main loop or a dedicated thread
    }
};

pub const AssetHandle = struct {
    manager: *AssetManager,
    path: []const u8,
    state: AssetState,
    asset: ?*Asset,

    pub fn isLoaded(self: *const AssetHandle) bool {
        return self.state == .loaded and self.asset != null;
    }

    pub fn getData(self: *const AssetHandle, comptime T: type) ?*T {
        if (!self.isLoaded()) return null;
        return @ptrCast(*T, @alignCast(@alignOf(T), self.asset.?.data));
    }

    pub fn addLoadCallback(self: *AssetHandle, callback: fn(*AssetHandle) void) !void {
        // Add callback for when loading completes
    }
};
```

Key aspects of the asset management system:

- Support for asynchronous loading without imposing a threading model
- Clear loading states and fallback mechanisms
- Type-safe access to asset data
- Resource reference counting
- Optional callbacks for load completion

This approach allows applications to implement their own loading strategies while providing a consistent interface for asset access.

## Platform Integration

The library uses a platform abstraction layer to handle platform-specific functionality:

```zig
pub const Platform = struct {
    vtable: *const VTable,

    pub const VTable = struct {
        // Window/display management
        createWindow: *const fn(title: []const u8, width: u32, height: u32) !*Window,
        getCurrentScreenSize: *const fn() Size,

        // Input handling
        pollEvents: *const fn(*EventManager) void,
        getPointerLocation: *const fn() Point,

        // Rendering
        createRenderer: *const fn(window: *Window) !*GraphicsAPI,
        swapBuffers: *const fn(window: *Window) void,

        // File system
        loadAsset: *const fn(path: []const u8, out_data: *[]u8) !void,

        // Clipboard
        setClipboardText: *const fn(text: []const u8) !void,
        getClipboardText: *const fn(allocator: std.mem.Allocator) ![]u8,
    };
};
```

This abstraction enables the library to run on various platforms while handling platform-specific behaviors appropriately.

### Threading Model Considerations

The library is explicitly thread-model agnostic. It doesn't impose any specific threading requirements, allowing it to be used in various environments:

- Single-threaded applications
- Game engines with their own threading models
- Desktop applications with UI thread requirements
- Embedded systems with or without threading support

Applications are responsible for ensuring proper synchronization if they access the UI from multiple threads. The library's interfaces are designed to facilitate integration with different threading approaches without assuming any particular model.

## Accessibility (Optional)

The library includes optional accessibility support through a dedicated system:

```zig
pub const Accessibility = struct {
    allocator: std.mem.Allocator,

    accessibility_tree: *AccessibilityNode,
    platform_api: *PlatformAccessibility,

    pub fn updateFromView(self: *Accessibility, view: *View) !void {
        // Build accessibility tree from view hierarchy
    }
};

pub const AccessibilityNode = struct {
    role: AccessibilityRole,
    label: ?[]const u8 = null,
    hint: ?[]const u8 = null,
    value: ?[]const u8 = null,
    enabled: bool = true,
    focused: bool = false,
    children: std.ArrayList(*AccessibilityNode),
    action_handlers: std.AutoHashMap(AccessibilityAction, fn(*AccessibilityNode) void),
    view_id: u64,
};
```

The accessibility system includes support for screen readers, keyboard navigation, focus management, and respects system accessibility settings. This system can be enabled or disabled based on application requirements.

## Design Philosophy

The library adheres to these core principles:

1. **Data-Oriented Design**: Optimizing memory layout and cache efficiency rather than focusing on object hierarchies.

2. **Performance First**: Making design decisions that prioritize runtime performance, with careful attention to allocations, cache usage, and CPU efficiency.

3. **Explicit Over Implicit**: Favoring explicit control and clearly visible data flow over magic or hidden behaviors.

4. **Composition Over Inheritance**: Building components via composition for better flexibility and code reuse.

5. **Cross-Platform Consistency**: Maintaining a consistent API and behavior across platforms while respecting platform-specific conventions.

6. **Memory Consciousness**: Designing for environments with limited memory, including embedded systems.

7. **Minimal Dependencies**: Keeping external dependencies to a minimum for better portability and compilation speed.

8. **Clear Responsibility Boundaries**: Following Zig's philosophy of communicating intent precisely by making it clear what the library is and isn't responsible for.

9. **Optional Complexity**: Core systems are mandatory, while complex systems (animations, accessibility) are optional to support constrained environments.

These principles guide all architectural decisions and implementation details throughout the library.

## Integration Example

Here's a simple example showing how to initialize and use the library:

```zig
const std = @import("std");
const gui = @import("gui");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a renderer (using Skia in this example)
    var renderer = try gui.renderer.createSkiaRenderer(allocator);
    defer renderer.deinit();

    // Initialize the GUI with minimal configuration
    var ui = try gui.GUI.init(allocator, &renderer.renderer_interface, .{
        .window_width = 800,
        .window_height = 600,
        .window_title = "Example Application",
        .enable_animations = true,  // Optional feature
    });
    defer ui.deinit();

    // Create a state for our counter
    const counter_state = try ui.state_store.createState(i32, "counter", 0);
    defer counter_state.deinit();

    // Create root container
    const container = try gui.Container.create(allocator);
    container.setStyle(.{
        .padding = gui.EdgeInsets{ .all = 20 },
        .background_color = gui.Color.fromRgba(240, 240, 240, 255),
    });
    ui.setRootView(&container.view);

    // Add counter display
    const counter_text = try gui.Text.create(allocator, "0");
    counter_text.setStyle(.{
        .font_size = 48,
        .margin = gui.EdgeInsets{ .bottom = 20 },
    });
    try container.addChild(&counter_text.view);

    // Bind counter state to text
    try gui.bind(&counter_text.view, "content", counter_state, intToString);

    // Add increment button
    const button = try gui.Button.create(allocator, "Increment");
    button.setOnClick(struct {
        fn onClick(_: *gui.Button) void {
            const current = counter_state.get() orelse 0;
            counter_state.set(current + 1) catch {};
        }
    }.onClick);
    try container.addChild(&button.view);

    // Main loop
    var running = true;
    var last_time = std.time.milliTimestamp();

    while (running) {
        // Calculate delta time
        const current_time = std.time.milliTimestamp();
        const dt = @intToFloat(f32, current_time - last_time) / 1000.0;
        last_time = current_time;

        // Update GUI
        ui.frame(dt);

        // Check for exit condition
        running = !ui.shouldExit();
    }
}

fn intToString(value: i32) []const u8 {
    // Convert int to string (simplified for example)
    return switch(value) {
        0 => "0",
        1 => "1",
        2 => "2",
        // etc.
        else => "many",
    };
}
```

## Performance Considerations

The library prioritizes performance through several key techniques:

1. **Batch Rendering**: Minimizing draw calls by combining similar UI elements.

2. **Geometry Caching**: Only regenerating geometry when elements change.

3. **Dirty Flagging**: Tracking which components need updating to avoid redundant work.

4. **Memory Pooling**: Using object pools to reduce allocation overhead.

5. **Data-Oriented Layout**: Organizing data for optimal cache usage.

6. **Incremental Layout**: Only recalculating layout for changed elements.

7. **Minimal Allocation**: Carefully managing memory allocations, especially in hot paths.

The emphasis on performance makes the library suitable for both high-end desktop applications and resource-constrained embedded systems.
