# zlay - High-Performance Layout Engine

> **NOTE:** The implementation has been integrated into zig-gui at `src/layout/`.
>
> This directory now contains reference documentation and independent benchmarks.

## Performance (Validated)

See [docs/HONEST_VALIDATION_RESULTS.md](docs/HONEST_VALIDATION_RESULTS.md):

- **Email Client** (81 elements, 10% dirty): **0.073μs per element** (5.7x faster than Taffy)
- **Email Client** (81 elements, 100% dirty): **0.029μs per element** (14.4x faster than Taffy)
- **Game HUD** (47 elements, 5% dirty): **0.107μs per element** (3.9x faster than Taffy)
- **Stress Test** (1011 elements, 30% dirty): **0.032μs per element** (13.1x faster than Taffy)

**All 31 tests passing.**

## Architecture

### Data-Oriented Design
- **Spineless Traversal**: 9.33x speedup over traditional tree walking
- **SIMD Constraints**: 1.95x speedup on constraint clamping
- **Layout Caching**: 2-5x speedup on incremental updates
- **Memory Efficient**: 176 bytes per element

### Components

1. **engine.zig** - Core layout engine with spineless traversal
2. **flexbox.zig** - Complete flexbox algorithm implementation
3. **cache.zig** - Layout result caching for incremental updates
4. **dirty_tracking.zig** - Queue-based dirty node tracking
5. **simd.zig** - SIMD-optimized constraint operations

## Integrated into zig-gui

The layout engine is now part of zig-gui's `src/layout/` directory:

```zig
const layout = @import("layout.zig");

// Data-oriented engine
const LayoutEngine = layout.LayoutEngine;

// Immediate-mode wrapper
const LayoutWrapper = layout.LayoutWrapper;

// Use LayoutWrapper for ID-based immediate-mode API
var wrapper = try LayoutWrapper.init(allocator);
defer wrapper.deinit();

wrapper.beginFrame();
try wrapper.beginContainer("root", .{ .direction = .column });
_ = try wrapper.addElement("child1", .{ .height = 50 });
_ = try wrapper.addElement("child2", .{ .height = 30 });
wrapper.endContainer();

try wrapper.computeLayout(800, 600);
```

## Documentation

- [HONEST_VALIDATION_RESULTS.md](docs/HONEST_VALIDATION_RESULTS.md) - Complete performance validation
- [ARCHITECTURE.md](docs/ARCHITECTURE.md) - Design decisions and architecture
- [PERFORMANCE_RESULTS.md](docs/PERFORMANCE_RESULTS.md) - Component benchmarks
- [V2_IMPLEMENTATION_STATUS.md](docs/V2_IMPLEMENTATION_STATUS.md) - Implementation notes

## Why the Integration?

Merging zlay into zig-gui provides:

1. **Tighter Integration** - No library boundary overhead
2. **Optimized for Immediate-Mode** - Designed specifically for GUI function calls
3. **Simpler Build** - One codebase, faster compilation
4. **Same Performance** - All validated benchmarks maintained

The implementation can be extracted back to a standalone library if needed in the future.

## Benchmarks

The `src/` directory contains the reference implementation used for benchmarking:

```bash
# Run full layout benchmarks
zig test src/full_layout_benchmark.zig -O ReleaseFast

# Run component benchmarks
zig test src/performance_validation.zig -O ReleaseFast
```

All benchmarks are documented with honest validation methodology in the docs.
