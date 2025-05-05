# Cross-Platform GUI Library Specification

This document outlines the architecture, core components, design principles, and vision for Zig-GUI, a collection of libraries that work with Clay.h to deliver high-performance UI solutions across platforms. It serves as an inspirational document rather than a strict specification.

## Project Vision

Zig-GUI is a collection of libraries that complement and extend the Clay.h immediate-mode GUI library. While Clay.h excels at layout and rendering, Zig-GUI provides Zig-native capabilities that enhance the developer experience and system capabilities:

1. **State Management**: Zig-idiomatic reactive state that integrates with Clay's immediate-mode rendering
2. **Asset Pipeline**: Type-safe loading and management of fonts, images, and audio resources
3. **Platform Adapters**: Platform-specific integration for diverse targets
4. **Domain-Specific Components**: Higher-level UI components for specialized applications
5. **Performance Tooling**: Profiling and optimization tools

The combined system targets a wide range of applications, from resource-constrained embedded systems (like the Teensy 4.1) to full-featured desktop and mobile applications.

## Boundaries and Responsibilities

### Clay.h Responsibilities

Clay.h is the foundation of the UI system, providing:

- Layout calculations and positioning
- Rendering primitives and display
- Input event handling and bubbling
- Widget declaration and composition
- Immediate-mode UI paradigm
- Memory management for UI elements

### Zig-GUI Responsibilities

Zig-GUI complements Clay by providing:

- Zig-idiomatic state management
- Type-safe resource handling
- Platform-specific integration
- Higher-level composition patterns
- Domain-specific components and utilities
- Performance optimization tools
- Reactive programming model

## Architecture Overview

```zig
// Top-level namespace organization
pub const gui = struct {
    // Clay bindings and core integration
    pub const clay = @import("clay.zig");

    // State management system
    pub const state = @import("state.zig");

    // Asset loading and management
    pub const assets = @import("assets.zig");

    // Platform integration
    pub const platform = @import("platform.zig");

    // Standard components built on Clay
    pub const components = @import("components.zig");

    // Domain-specific extensions
    pub const extensions = struct {
        pub const audio = @import("extensions/audio.zig");
        pub const data = @import("extensions/data.zig");
        pub const charts = @import("extensions/charts.zig");
    };

    // Performance tools
    pub const perf = @import("perf.zig");
};
```

The architecture emphasizes:

1. **Modularity**: Each library can be used independently
2. **Composition**: Libraries combine naturally without tight coupling
3. **Performance**: Data-oriented design with minimal indirection
4. **Explicit Management**: Clear ownership of resources and memory
5. **Platform Flexibility**: Works across desktop, mobile, and embedded targets

## Clay Integration

Zig-GUI integrates with Clay.h through idiomatic Zig bindings:

```zig
// Simplified example
const std = @import("std");
const gui = @import("gui");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize Clay with our SDL renderer
    var clay_ctx = try gui.clay.init(allocator, .{
        .width = 800,
        .height = 600,
        .title = "Zig-GUI App",
    });
    defer clay_ctx.deinit();

    // Create application state
    var app_state = try gui.state.Store.init(allocator);
    defer app_state.deinit();

    // Create state variables
    const counter = try app_state.create(i32, "counter", 0);

    // Main loop
    while (!clay_ctx.shouldClose()) {
        // Begin frame
        try clay_ctx.beginFrame();

        // Render UI with Clay's immediate-mode API
        gui.clay.container(.{
            .id = "main_container",
            .padding = gui.clay.EdgeInsets.all(20),
        }, {
            // Text showing counter value
            gui.clay.text(.{
                .content = try std.fmt.allocPrint(
                    allocator,
                    "Count: {d}",
                    .{counter.get()}
                ),
            });

            // Button that increments counter
            if (gui.clay.button(.{ .label = "Increment" })) {
                try counter.update(counter.get() + 1);
            }
        });

        // End frame
        try clay_ctx.endFrame();
    }
}
```

This approach leverages Clay's strengths in layout and rendering while adding Zig-GUI's state management and other capabilities.

## State Management System

The state management system is designed to work seamlessly with Clay's immediate-mode approach while providing reactive capabilities in a Zig-idiomatic way.

```zig
pub const state = struct {
    // Main store that contains application state
    pub const Store = struct {
        allocator: std.mem.Allocator,
        values: std.StringHashMap(Value),
        observers: std.StringHashMap(std.ArrayList(Observer)),

        pub fn init(allocator: std.mem.Allocator) !Store {
            return Store{
                .allocator = allocator,
                .values = std.StringHashMap(Value).init(allocator),
                .observers = std.StringHashMap(std.ArrayList(Observer)).init(allocator),
            };
        }

        pub fn deinit(self: *Store) void {
            // Clean up all resources
            var iter = self.values.iterator();
            while (iter.next()) |entry| {
                entry.value_ptr.deinit(self.allocator);
            }
            self.values.deinit();

            var obs_iter = self.observers.iterator();
            while (obs_iter.next()) |entry| {
                entry.value_ptr.deinit();
            }
            self.observers.deinit();
        }

        // Create a typed state value
        pub fn create(self: *Store, comptime T: type, key: []const u8, initial: T) !*State(T) {
            // Create typed state and store in internal map
            const value = try Value.create(self.allocator, T, initial);
            try self.values.put(try self.allocator.dupe(u8, key), value);

            return State(T){
                .store = self,
                .key = try self.allocator.dupe(u8, key),
            };
        }

        // Internal implementation details...
    };

    // Type-safe state handle
    pub fn State(comptime T: type) type {
        return struct {
            store: *Store,
            key: []const u8,

            pub fn get(self: @This()) T {
                const value = self.store.values.get(self.key).?;
                return value.get(T);
            }

            pub fn update(self: @This(), new_value: T) !void {
                try self.store.updateValue(self.key, new_value);
            }

            pub fn observe(self: @This(), callback: *const fn(T) void) !ObserverHandle {
                return try self.store.addObserver(self.key, T, callback);
            }
        };
    }

    // Derived state that depends on other state values
    pub fn derived(store: *Store, comptime T: type, comptime deps: []const []const u8, compute_fn: anytype) !*State(T) {
        // Implementation would set up dependency tracking and auto-recalculation
    }

    // Transaction for batching multiple updates
    pub const Transaction = struct {
        store: *Store,
        changes: std.ArrayList(Change),

        pub fn begin(store: *Store) !Transaction {
            return Transaction{
                .store = store,
                .changes = std.ArrayList(Change).init(store.allocator),
            };
        }

        pub fn update(self: *Transaction, comptime T: type, key: []const u8, value: T) !void {
            try self.changes.append(Change{
                .key = key,
                .value = try Value.create(self.store.allocator, T, value),
            });
        }

        pub fn commit(self: *Transaction) !void {
            // Atomically apply all changes and notify observers once
            // Implementation details...
        }

        pub fn deinit(self: *Transaction) void {
            self.changes.deinit();
        }
    };
};
```

Key features of the state management system:

1. **Type Safety**: Fully type-checked state operations
2. **Efficient Updates**: Only re-renders components when state actually changes
3. **Explicit Dependencies**: Clear declaration of state dependencies
4. **Batched Updates**: Transaction system for atomic state changes
5. **Minimal Overhead**: Direct state access in the immediate-mode rendering cycle

This approach fits Clay's immediate-mode paradigm because state values are directly accessed during rendering, but adds reactivity through the observer pattern.

### State Management Usage Examples

#### Basic State Creation and Usage

```zig
// Initialize state store
var state_store = try gui.state.Store.init(allocator);
defer state_store.deinit();

// Create different types of state
const counter = try state_store.create(i32, "counter", 0);
const username = try state_store.create([]const u8, "username", "Guest");
const settings = try state_store.create(AppSettings, "settings", .{
    .theme = .dark,
    .font_size = 16,
    .volume = 0.8,
});

// Read state values
const current_count = counter.get();
std.debug.print("Count: {d}\n", .{current_count});

// Update state values
try counter.update(current_count + 1);
try username.update("JohnDoe");
try settings.update(.{
    .theme = .light,
    .font_size = 18,
    .volume = 0.7,
});
```

#### Observing State Changes

```zig
// Create a state value
const volume = try state_store.create(f32, "volume", 0.5);

// Create an observer that runs when the value changes
const observer = try volume.observe(struct {
    fn onVolumeChange(new_value: f32) void {
        std.debug.print("Volume changed to: {d:.2}\n", .{new_value});

        // Update audio system with new volume
        audio_system.setVolume(new_value);
    }
}.onVolumeChange);

// Updates will trigger the observer
try volume.update(0.8); // Prints "Volume changed to: 0.80"
```

#### Using Derived State

```zig
// Create base state values
const width = try state_store.create(f32, "width", 100.0);
const height = try state_store.create(f32, "height", 50.0);

// Create derived state that calculates area automatically
const area = try gui.state.derived(
    &state_store,
    f32,
    &[_][]const u8{ "width", "height" },
    struct {
        fn calculate(w: f32, h: f32) f32 {
            return w * h;
        }
    }.calculate
);

// Area automatically updates when width or height changes
std.debug.print("Initial area: {d:.2}\n", .{area.get()}); // 5000.00
try width.update(200.0);
std.debug.print("Updated area: {d:.2}\n", .{area.get()}); // 10000.00
```

#### Using Transactions for Batched Updates

```zig
// Create state values
const position_x = try state_store.create(f32, "position_x", 0.0);
const position_y = try state_store.create(f32, "position_y", 0.0);
const is_moving = try state_store.create(bool, "is_moving", false);

// Start a transaction for batched updates
var transaction = try gui.state.Transaction.begin(&state_store);
defer transaction.deinit();

// Update multiple values atomically
try transaction.update(f32, "position_x", 100.0);
try transaction.update(f32, "position_y", 50.0);
try transaction.update(bool, "is_moving", true);

// Commit all changes at once - observers only notified once
try transaction.commit();
```

#### Integration with Clay UI

```zig
// Handle UI events with state updates
gui.clay.container(.{ .id = "controls" }, {
    // Display current state
    gui.clay.text(.{
        .content = try std.fmt.allocPrint(
            allocator,
            "Volume: {d:.0}%",
            .{volume.get() * 100}
        ),
    });

    // Create slider that updates state
    if (gui.clay.slider(.{
        .id = "volume_slider",
        .min = 0.0,
        .max = 1.0,
        .value = volume.get(),
    })) |new_value| {
        // Update state when slider changes
        try volume.update(new_value);
    }

    // Button that mutes by setting volume to 0
    if (gui.clay.button(.{ .label = "Mute" })) {
        try volume.update(0.0);
    }
});
```

#### Complex Component with State Integration

```zig
// Define a reusable component that integrates with state
fn audioPlayer(allocator: std.mem.Allocator, track_state: *gui.state.State(Track)) !void {
    const track = track_state.get();

    // Container with player controls
    gui.clay.container(.{
        .id = CLAY_ID("audio_player"),
        .padding = CLAY_PADDING_ALL(16),
        .backgroundColor = { 30, 30, 40, 255 },
        .cornerRadius = CLAY_CORNER_RADIUS(8),
    }) {
        // Track information
        CLAY_TEXT(track.title, CLAY_TEXT_CONFIG({
            .fontSize = 24,
            .textColor = { 255, 255, 255, 255 },
        }));

        CLAY_TEXT(track.artist, CLAY_TEXT_CONFIG({
            .fontSize = 16,
            .textColor = { 200, 200, 200, 255 },
        }));

        // Progress bar
        gui.clay.progressBar(.{
            .id = CLAY_ID("track_progress"),
            .progress = track.current_position / track.duration,
            .height = 8,
        });

        // Transport controls in a row
        gui.clay.container(.{
            .id = CLAY_ID("transport_controls"),
            .layout = {
                .direction = .horizontal,
                .alignment = { .x = .center, .y = .center },
                .childGap = 16,
            },
        }) {
            // Previous button
            if (gui.clay.iconButton(.{
                .id = CLAY_ID("prev_button"),
                .icon = "prev",
            })) {
                try audio_system.previousTrack();
                // State will be updated by the audio system
            }

            // Play/Pause button
            if (gui.clay.iconButton(.{
                .id = CLAY_ID("play_button"),
                .icon = track.is_playing ? "pause" : "play",
            })) {
                var updated_track = track;
                updated_track.is_playing = !track.is_playing;
                try track_state.update(updated_track);

                if (updated_track.is_playing) {
                    try audio_system.play();
                } else {
                    try audio_system.pause();
                }
            }

            // Next button
            if (gui.clay.iconButton(.{
                .id = CLAY_ID("next_button"),
                .icon = "next",
            })) {
                try audio_system.nextTrack();
                // State will be updated by the audio system
            }
        }
    }
}
```

## Asset Management

The asset management system provides type-safe resource handling:

```zig
pub const assets = struct {
    pub const Manager = struct {
        allocator: std.mem.Allocator,
        resources: std.StringHashMap(Resource),
        clay_ctx: *clay.Context,

        pub fn init(allocator: std.mem.Allocator, clay_ctx: *clay.Context) Manager {
            return .{
                .allocator = allocator,
                .resources = std.StringHashMap(Resource).init(allocator),
                .clay_ctx = clay_ctx,
            };
        }

        pub fn loadFont(self: *Manager, path: []const u8) !Font {
            // Load font and register with Clay
        }

        pub fn loadImage(self: *Manager, path: []const u8) !Image {
            // Load image and register with Clay
        }

        pub fn loadJson(self: *Manager, path: []const u8) !JsonResource {
            // Load and parse JSON data
        }

        // Additional resource loading methods...

        pub fn deinit(self: *Manager) void {
            // Clean up all resources
            var iter = self.resources.valueIterator();
            while (iter.next()) |resource| {
                resource.deinit(self.allocator);
            }
            self.resources.deinit();
        }
    };

    pub const Font = struct {
        // Font handle that integrates with Clay
    };

    pub const Image = struct {
        // Image handle that integrates with Clay
    };

    // Other resource types...
};
```

The asset system works directly with Clay's resource handling mechanisms, providing a more type-safe interface.

## Specialized Component Libraries

Building on Clay's core layout and rendering capabilities, Zig-GUI provides domain-specific components:

```zig
// Audio visualization and control components
pub const audio = struct {
    pub fn waveform(allocator: std.mem.Allocator, samples: []const f32, options: WaveformOptions) !void {
        // Render audio waveform using Clay primitives
    }

    pub fn spectrum(allocator: std.mem.Allocator, frequencies: []const f32, options: SpectrumOptions) !void {
        // Render frequency spectrum using Clay primitives
    }

    pub fn transport(allocator: std.mem.Allocator, state: *TransportState, options: TransportOptions) !void {
        // Render transport controls (play, stop, etc.)
    }

    // Additional audio-specific components...
};

// Data visualization components
pub const data = struct {
    pub fn table(allocator: std.mem.Allocator, data: anytype, options: TableOptions) !void {
        // Render data table using Clay primitives
    }

    pub fn chart(allocator: std.mem.Allocator, data: anytype, options: ChartOptions) !void {
        // Render various chart types
    }

    // Additional data components...
};
```

These specialized components build on Clay's capabilities while adding domain-specific knowledge and optimizations.

## Platform Integration

Zig-GUI provides platform-specific integration modules:

```zig
pub const platform = struct {
    pub const sdl = struct {
        pub fn init(allocator: std.mem.Allocator) !SdlContext {
            // Initialize SDL and create Clay context
        }
    };

    pub const glfw = struct {
        pub fn init(allocator: std.mem.Allocator) !GlfwContext {
            // Initialize GLFW and create Clay context
        }
    };

    pub const teensy = struct {
        pub fn init(allocator: std.mem.Allocator, display: *Display) !TeensyContext {
            // Initialize Teensy display and create Clay context
        }
    };

    // Additional platforms...
};
```

Each platform module initializes Clay with the appropriate renderer and event handlers.

## Performance Optimization

Performance is a top priority for Zig-GUI. Key optimization strategies include:

1. **Zero Allocation Rendering**: Working with Clay's immediate-mode approach to minimize allocations
2. **Memory Pooling**: Using object pools for frequently created/destroyed components
3. **Incremental Updates**: Only recalculating layout and state when necessary
4. **Data-Oriented Design**: Organizing data for optimal cache usage
5. **Specialized Renderers**: Platform-specific optimizations for rendering
6. **Profiling Tools**: Built-in performance measurement utilities

```zig
pub const perf = struct {
    pub const Profiler = struct {
        allocator: std.mem.Allocator,
        samples: std.ArrayList(Sample),
        active_markers: std.StringHashMap(u64),

        pub fn init(allocator: std.mem.Allocator) Profiler {
            // Initialize profiler
        }

        pub fn beginMark(self: *Profiler, name: []const u8) void {
            // Mark beginning of operation for timing
        }

        pub fn endMark(self: *Profiler, name: []const u8) void {
            // Mark end of operation and record duration
        }

        pub fn report(self: *Profiler) !void {
            // Generate performance report
        }
    };
};
```

The performance tools help identify and address bottlenecks in real applications.

## Design Philosophy

Zig-GUI adheres to these core principles:

1. **Clay for Layout and Rendering**: Leverage Clay's strengths instead of reinventing them
2. **Zig-Idiomatic APIs**: Provide interfaces that feel natural to Zig developers
3. **Data-Oriented Design**: Optimize for performance and memory efficiency
4. **Explicit over Implicit**: Favor clear, explicit control flow and data management
5. **Composition over Inheritance**: Build complex systems through composition
6. **Performance First**: Prioritize runtime performance in all design decisions
7. **Cross-Platform Consistency**: Maintain consistent behavior across platforms
8. **Memory Consciousness**: Design for constrained environments
9. **Minimal Dependencies**: Limit external dependencies for better portability
10. **Clear Responsibility Boundaries**: Define explicit integration points with Clay

By adhering to these principles, Zig-GUI provides a powerful complement to Clay that extends its capabilities while maintaining its performance characteristics.

## Example: Music Tracker Application

Here's how Zig-GUI might be used for a music tracker application on a Teensy 4.1:

```zig
const std = @import("std");
const gui = @import("gui");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Initialize Clay with Teensy display
    var display = try initTeensyDisplay();
    var context = try gui.platform.teensy.init(allocator, &display);
    defer context.deinit();

    // Initialize application state
    var app_state = try gui.state.Store.init(allocator);
    defer app_state.deinit();

    // Create tracker-specific state
    const pattern = try app_state.create(tracker.Pattern, "current_pattern", tracker.Pattern.empty());
    const transport = try app_state.create(tracker.TransportState, "transport", .{});

    // Load assets
    var assets = try gui.assets.Manager.init(allocator, &context);
    const font = try assets.loadFont(@embedFile("assets/font.ttf"));

    // Main loop
    while (true) {
        // Process hardware inputs
        try processTeensyInputs(&context, &app_state);

        // Begin frame
        try context.beginFrame();

        // Main UI layout
        gui.clay.container(.{
            .id = "main_layout",
            .layout = .{
                .direction = .vertical,
                .padding = gui.clay.EdgeInsets.all(4),
            },
        }, {
            // Transport controls
            gui.audio.transport(allocator, transport, .{
                .font = font,
                .show_tempo = true,
            });

            // Pattern editor
            tracker.patternEditor(allocator, pattern, .{
                .rows_visible = 16,
                .font = font,
            });

            // Mixer view
            tracker.mixerView(allocator, .{
                .font = font,
            });
        });

        // End frame
        try context.endFrame();

        // Update audio engine
        try updateAudio(transport.get(), pattern.get());
    }
}
```

This example demonstrates how Zig-GUI complements Clay to create a specialized, high-performance application for embedded hardware.

## Conclusion

Zig-GUI is not a replacement for Clay.h but rather a set of libraries that enhance and extend its capabilities. By focusing on state management, asset handling, and specialized components, Zig-GUI provides a complete solution for building high-performance UIs across platforms, from embedded devices to desktop applications.

The combination of Clay's immediate-mode rendering and layout with Zig-GUI's type-safe, performance-oriented extensions
creates a powerful toolkit for developers who need precise control over their UI systems while maintaining excellent
performance characteristics.
