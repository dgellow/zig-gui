# Instructions for Claude when working with zlay

## Project Overview

zlay is a data-oriented GUI layout library written in Zig. It is designed to be extremely performant, memory-efficient, and easy to use. The library provides a simple API for creating and managing UI layouts with a focus on maximum performance and flexibility.

zlay is intended for use in a wide range of contexts including:
- Game development (where performance is critical)
- Resource-constrained environments (embedded systems, microcontrollers)
- Desktop and mobile applications
- Any context requiring predictable, extremely fast layout calculation

Key features:
- Data-oriented design focused on extreme performance
- Hierarchical layout system with containers and components
- Minimal but flexible styling system that affects layout
- Simple API with zero dependencies
- C API header for integration with other languages
- Renderer-agnostic with clear boundaries

## Library Boundaries

zlay follows a "bring your own X" philosophy, focusing purely on the layout calculations while allowing integrators to provide their own rendering, input handling, and other systems. This separation of concerns keeps the library focused and highly optimized.

### What's IN Scope for zlay:
- Layout engine (positioning and sizing elements)
- Element hierarchy management
- Basic styling properties that affect layout (padding, margin, alignment)
- Position and size calculations with constraints
- Text measurement abstractions (but not implementation)
- Hit testing (which element is at x,y)
- Clipping region calculation
- Scrollable container layouts (content size, visible area)

### What's OUT of Scope for zlay:
- Actual rendering implementation (handled by pluggable renderers)
- Image loading/handling (only dimensions matter for layout)
- Event handling/dispatching (beyond basic hit testing)
- Animation system (though layout properties can be animated externally)
- State management (selected, checked, etc.)
- Custom component behaviors
- Asset management

### Extension Points:
- Pluggable text measurement
- Pluggable rendering
- Clean interfaces for connecting to event systems

## Technical Debt and Issue Tracking

All technical debt, known issues, and planned improvements are tracked in `TECHNICAL_DEBT.md`. When making changes or adding features, you MUST:

1. Check `TECHNICAL_DEBT.md` first to see if the change aligns with planned improvements
2. Update `TECHNICAL_DEBT.md` if the change addresses an existing issue
3. Add new items to `TECHNICAL_DEBT.md` if you identify additional issues or improvements

## Performance Requirements

zlay is designed to be extremely performant. All changes must maintain or improve the performance characteristics:

1. Element creation: Should be < 5μs per element
2. Layout computation: Should be < 10μs per element
3. Minimal memory allocations: Use arena allocators and memory pools where possible
4. Efficient rendering: Minimize state changes and draw calls

Always run benchmarks after significant changes:
```bash
zig build benchmark
```

And performance tests:
```bash
zig build test-perf
```

## Code Organization

- `src/zlay.zig`: Main entry point and public API
- `src/context.zig`: Context management and element tracking
- `src/element.zig`: Element definitions and properties
- `src/layout.zig`: Layout algorithms
- `src/renderer.zig`: Renderer abstraction
- `src/style.zig`: Styling system
- `src/color.zig`: Color utilities
- `src/zlay.h`: C API header
- `src/tests.zig`: Performance-specific tests
- `src/benchmark.zig`: Benchmarking code

## Coding Guidelines

1. **Memory Management**:
   - Prefer arena allocators for short-lived allocations
   - Be explicit about ownership of allocated memory
   - Avoid unnecessary allocations in performance-critical paths

2. **Error Handling**:
   - Use Zig's error system consistently
   - Provide descriptive error messages
   - Handle all potential error cases

3. **Documentation**:
   - Add doc comments to all public APIs
   - Keep examples up to date
   - Document performance characteristics and guarantees

4. **Testing**:
   - Write tests for all new features
   - Include performance tests for performance-critical code
   - Use the testing system to validate memory usage

## Common Tasks

### Adding a New Component

1. Add the component type to `Element.Type` in `element.zig`
2. Implement layout handling in `layout.zig`
3. Add rendering support in `renderer.zig`
4. Update the C API in `zlay.h` if needed
5. Add tests for the new component
6. Document the component in relevant files

### Optimizing Performance

1. Run benchmarks to establish baseline: `zig build benchmark`
2. Identify bottlenecks using tools like `valgrind` or Zig's built-in profiling
3. Make targeted optimizations
4. Re-run benchmarks to verify improvements
5. Document optimization in code comments and update `TECHNICAL_DEBT.md`

### Adding to C API

1. Update `zlay.h` with new functions or types
2. Implement the C API wrapper functions in `c_api.zig`
3. Add tests for the C API
4. Update documentation and examples

## Testing Requirements

All code changes must be tested:

1. Unit tests for individual functions
2. Integration tests for components working together
3. Performance tests for performance-critical code
4. Memory usage tests to verify no leaks or excessive allocations

Run all tests with:
```bash
zig build test-all
```

## Open Issues and Priorities

Check `TECHNICAL_DEBT.md` for the complete and current list of open issues and priorities.

Top current priorities:
1. Improve layout algorithm performance
2. Implement full text measurement support
3. Add comprehensive input handling system
4. Enhance memory efficiency

## Work Log

### 2025-05-07: Enhancing Text Measurement Robustness

#### Issues Addressed:
1. Examples were crashing due to null text measurement handling
2. Added proper fallbacks for text measurement functions
3. Fixed multiline text measurement issues
4. Enhanced API with better initialization options

#### Changes Made:

##### 1. Added fallback to `measureMultilineText` in context.zig:
```zig
pub fn measureMultilineText(
    self: *Context, 
    text: []const u8, 
    font_name: ?[]const u8, 
    font_size: f32,
    line_height: f32
) !Text.TextSize {
    if (self.text_measurement == null) {
        // Fallback approximation when no text measurement is available
        // Count the number of lines
        var line_count: usize = 1;
        for (text) |c| {
            if (c == '\n') line_count += 1;
        }
        
        // Determine average line length to estimate width
        const avg_line_len = @as(f32, @floatFromInt(text.len)) / @as(f32, @floatFromInt(line_count));
        const approx_width = avg_line_len * 8.0; // rough approximation
        const approx_height = font_size * 1.2 * @as(f32, @floatFromInt(line_count)); // rough approximation
        
        return Text.TextSize.init(approx_width, approx_height);
    }
    
    // Existing implementation...
}
```

##### 2. Simplified multiline text measurement in layout_algorithm.zig:
```zig
// Get a default line height - either from text measurement or fallback
const line_height = if (ctx.text_measurement) |measurement|
    measurement.getLineHeight(font_name, font_size)
else
    font_size * 1.2; // Fallback line height approximation
    
// Use the context's multiline text measurement (which now has fallback)
text_size = try ctx.measureMultilineText(
    element.text.?, 
    font_name, 
    font_size, 
    line_height
);
```

##### 3. Added safety checks for text measurement functions:
- Added empty text check to `measureText` in TextMeasurementCache
- Added empty text check to `measureMultilineText` in TextMeasurementCache
- Added empty text check to the DefaultTextMeasurement implementation

##### 4. Added new initialization mode in zlay.zig:
```zig
/// Initialize a new zlay context with minimal configuration (no text measurement)
/// Useful for simple layouts or when debugging issues with text measurement
pub fn initMinimal(allocator: std.mem.Allocator) !Context {
    return Context.initWithOptions(allocator, .{
        .use_element_pool = false,
        .use_string_pool = false,
        .use_text_measurement = false,  // No text measurement
        .use_text_measurement_cache = false,  // No caching
    });
}
```

##### 5. Updated examples to use minimal initialization:
- Modified advanced_layout.zig, scrollable.zig, and simple.zig to use the safer initialization method
- All examples now run without crashing

##### 6. Enhanced build script:
- Added a helpful default `run` step that lists available examples
- All examples can now be run with their respective commands

#### Test Results:
- All examples now run successfully
- All tests pass (using `zig build test`)
- Performance tests can still be run using `zig build test-perf`

#### Future Improvements:
1. Further enhance the text measurement system with better fallbacks
2. Fix layout calculations to properly handle zero-sized elements
3. Optimize memory usage in the element pool
4. Add more documentation about text measurement options