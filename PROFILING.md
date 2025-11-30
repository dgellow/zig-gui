# zig-gui Profiling & Tracing System

**World-class, zero-cost profiling infrastructure for performance-critical applications**

## Overview

This profiling system is designed with technical excellence in mind, drawing inspiration from:
- **[Tracy Profiler](https://github.com/wolfpld/tracy)**: Real-time, nanosecond resolution, ~15ns overhead per zone
- **[ImGui Profiler](https://vittorioromeo.com/index/blog/sfex_profiler.html)**: Lightweight hierarchical profiling in ~500 lines
- **[Flutter DevTools](https://docs.flutter.dev/tools/devtools/performance)**: Frame-based analysis with timeline visualization
- **[Clang -ftime-trace](https://opensource.adobe.com/lagrange-docs/dev/compilation-profiling/)**: Compile-time conditional compilation

## Design Principles

### 1. Zero-Cost in Production
```zig
// With profiling DISABLED (default):
// - Compiles to NOTHING (dead code elimination)
// - Zero runtime overhead
// - Zero binary size increase

// With profiling ENABLED (-Denable_profiling):
// - ~15-50ns per zone (Tracy-level performance)
// - Minimal memory footprint (ring buffer)
// - Thread-safe atomic operations
```

### 2. Hierarchical Zone-Based Tracking
```zig
fn renderUI(gui: *GUI) !void {
    profiler.zone(@src(), "renderUI", .{});
    defer profiler.endZone();

    {
        profiler.zone(@src(), "layout", .{});
        defer profiler.endZone();
        // Layout calculations here
    }

    {
        profiler.zone(@src(), "draw", .{});
        defer profiler.endZone();
        // Drawing commands here
    }
}
```

### 3. Frame-Based Analysis
```zig
// Automatic frame detection
profiler.frameStart();
defer profiler.frameEnd();

// Frame statistics
const stats = profiler.getFrameStats();
std.debug.print("Frame {}: {d:.3}ms\n", .{stats.frame_number, stats.duration_ms});
```

### 4. Multiple Profiling Backends
- **CPU Timing**: Nanosecond-precision using RDTSC/monotonic time
- **Memory Tracking**: Allocation counts, sizes, hot paths
- **Frame Analysis**: FPS, frame times, jank detection
- **Custom Metrics**: User-defined counters and values

### 5. Export Formats
- **JSON**: Chrome Tracing (chrome://tracing)
- **CSV**: Excel/data analysis
- **Binary**: Custom format for minimal overhead
- **Live View**: Real-time in-app visualization

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│ Application Code                                                │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │ profiler.zone(@src(), "myFunction", .{});                │  │
│  │ defer profiler.endZone();                                │  │
│  │ // Your code here                                        │  │
│  └──────────────────────────────────────────────────────────┘  │
│                           ↓                                     │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │ Compile-Time Switch (build option)                       │  │
│  │  - ENABLED: Real instrumentation                         │  │
│  │  - DISABLED: Empty inline functions (optimized away)     │  │
│  └──────────────────────────────────────────────────────────┘  │
│                           ↓                                     │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │ Profiler Core (if enabled)                               │  │
│  │  - Thread-local ring buffers (lock-free)                 │  │
│  │  - Atomic frame counters                                 │  │
│  │  - Zone stack tracking                                   │  │
│  │  - High-resolution timers (RDTSC/monotonic)              │  │
│  └──────────────────────────────────────────────────────────┘  │
│                           ↓                                     │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │ Analysis & Export                                         │  │
│  │  - Frame statistics                                       │  │
│  │  - Hot path detection                                     │  │
│  │  - JSON/CSV export                                        │  │
│  │  - Real-time visualization                                │  │
│  └──────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

## Performance Characteristics

Based on [Tracy Profiler](https://github.com/wolfpld/tracy) benchmarks:

| Operation | Overhead | Notes |
|-----------|----------|-------|
| Zone start | ~15-25ns | RDTSC + buffer write |
| Zone end | ~15-25ns | RDTSC + buffer write |
| Total per zone | ~30-50ns | Comparable to function call overhead |
| Frame marker | ~50ns | Atomic increment + timestamp |
| Memory disabled | **0ns** | Dead code elimination |

## Usage Examples

### Basic Profiling

```zig
const profiler = @import("profiler");

pub fn main() !void {
    profiler.init(allocator, .{
        .max_zones_per_frame = 10_000,
        .max_frames_in_history = 600, // 10 seconds at 60 FPS
    });
    defer profiler.deinit();

    while (app.running) {
        profiler.frameStart();
        defer profiler.frameEnd();

        try processInput();
        try update(dt);
        try render();
    }

    // Export results
    try profiler.exportJSON("profile.json");
}
```

### Function Profiling

```zig
fn complexCalculation(data: []const f32) f32 {
    profiler.zone(@src(), "complexCalculation", .{});
    defer profiler.endZone();

    var result: f32 = 0;
    for (data) |value| {
        result += std.math.sqrt(value);
    }
    return result;
}
```

### Conditional Profiling

```zig
fn hotPath(gui: *GUI) !void {
    // Only profile in debug builds
    if (profiler.enabled) {
        profiler.zone(@src(), "hotPath", .{});
        defer profiler.endZone();
    }

    // Critical performance code
}
```

### Memory Profiling

```zig
fn allocateResources() !void {
    profiler.zone(@src(), "allocate", .{});
    defer profiler.endZone();

    const data = try profiler.trackedAlloc(allocator, u8, 1024);
    defer profiler.trackedFree(allocator, data);
}
```

### Custom Metrics

```zig
// Track specific values
profiler.counter("widgets_rendered", widget_count);
profiler.gauge("memory_usage_mb", @as(f64, memory_bytes) / 1024.0 / 1024.0);
profiler.plot("fps", current_fps);
```

## Build Configuration

### Enable Profiling
```bash
# Development build with profiling
zig build -Denable_profiling=true

# Release build (profiling disabled by default)
zig build -Doptimize=ReleaseFast

# Profile mode (optimized + profiling)
zig build -Doptimize=ReleaseFast -Denable_profiling=true
```

### In build.zig
```zig
const enable_profiling = b.option(bool, "enable_profiling", "Enable profiling") orelse false;

const profiler_mod = b.addModule("profiler", .{
    .root_source_file = b.path("src/profiler.zig"),
});

const options = b.addOptions();
options.addOption(bool, "enable_profiling", enable_profiling);
profiler_mod.addOptions("build_options", options);
```

## Visualization

### Chrome Tracing
```bash
# Export to JSON
zig build run -- --export-profile profile.json

# Open in Chrome
chrome://tracing
# Click "Load" and select profile.json
```

### Real-Time In-App Overlay
```zig
if (profiler.enabled) {
    try profiler.renderOverlay(gui);
    // Shows:
    // - Current FPS
    // - Frame time graph
    // - Hot functions list
    // - Memory usage
}
```

## Integration with zig-gui

```zig
// src/app.zig
fn runGameLoop(self: *Self, ui_function: UIFunction(State), state: *State) !void {
    const prof = profiler.zone(@src(), "gameLoop", .{});
    defer prof.end();

    while (self.isRunning()) {
        profiler.frameStart();
        defer profiler.frameEnd();

        {
            const p = profiler.zone(@src(), "processEvents", .{});
            defer p.end();
            self.processEvents();
        }

        {
            const p = profiler.zone(@src(), "render", .{});
            defer p.end();
            try self.renderFrameInternal(ui_function, state);
            self.platform.present();
        }
    }
}
```

## Future Enhancements

- [ ] GPU profiling (Vulkan/OpenGL queries)
- [ ] Network profiling (event transmission to external viewer)
- [ ] Call graph generation
- [ ] Flame graph export
- [ ] Statistical analysis (P95, P99 latencies)
- [ ] Regression detection
- [ ] Integration with Tracy profiler server

## Standalone Library

The profiling system is designed to be extracted as a standalone library:

```
zig-profiler/
├── build.zig
├── src/
│   ├── profiler.zig       # Core API
│   ├── zone.zig           # Zone tracking
│   ├── frame.zig          # Frame analysis
│   ├── timer.zig          # High-precision timing
│   ├── export_json.zig    # Chrome Tracing export
│   ├── export_csv.zig     # CSV export
│   └── ringbuffer.zig     # Lock-free ring buffer
├── examples/
│   ├── basic.zig
│   └── gui_integration.zig
└── README.md
```

## References

- [Tracy Profiler](https://github.com/wolfpld/tracy) - Real-time frame profiler with nanosecond resolution
- [ImGui Profiler](https://vittorioromeo.com/index/blog/sfex_profiler.html) - Lightweight hierarchical profiling
- [Flutter DevTools](https://docs.flutter.dev/tools/devtools/performance) - Frame-based performance analysis
- [Clang -ftime-trace](https://opensource.adobe.com/lagrange-docs/dev/compilation-profiling/) - Compile-time profiling
- [Chrome Tracing](https://docs.google.com/document/d/1CvAClvFfyA5R-PhYUmn5OOQtYMH4h6I0nSsKchNAySU/preview) - JSON trace event format
