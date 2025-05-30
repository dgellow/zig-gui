# Memory Layout Documentation Guide

When documenting performance-critical structs in zig-gui, use this structured format:

## Documentation Pattern

```zig
/// Brief description of the struct's purpose
/// 
/// @memory-layout {
///   size: XX bytes
///   align: X bytes
///   cache-lines: X.X (how many per 64-byte cache line)
///   access-pattern: sequential|random|strided
///   hot-path: yes|no
/// }
/// 
/// @performance {                    // Optional - only for critical paths
///   target-time: <Xμs per operation
///   allocations: X per frame
///   cache-misses: expected pattern
/// }
pub const MyStruct = struct {
    // Group fields by access pattern, not logical grouping
    // Comment each group's purpose
    
    // Most frequently accessed fields first
    field1: Type,
    field2: Type,
    
    // Less frequently accessed fields
    field3: Type,
    
    comptime {
        // Verify size assumptions for critical structs
        if (@sizeOf(@This()) != expected_size) {
            @compileError("Size assumption violated!");
        }
    }
};
```

## When to Use This Pattern

Apply this documentation to structs that:
- Are used in hot paths (>1000 times per frame)
- Are stored in large arrays (>100 elements)
- Have been optimized for cache efficiency
- Have specific memory layout requirements

## Examples of Structs That Need This:
- `LayoutStyle` - accessed for every UI element
- `LayoutEngine` - main data structure
- `TextStyle` - if optimized for cache
- Any SoA array element types

## Structs That DON'T Need This:
- One-off configuration structs
- API boundary structs (unless performance critical)
- Small utility structs
- Structs with obvious/simple layout

## Key Principles

1. **Document what matters**: Size, alignment, cache utilization
2. **Verify assumptions**: Use comptime checks
3. **Group by access**: Fields accessed together should be adjacent
4. **Hot/cold separation**: Split structs when necessary

## Tools

Use the provided helpers in `memory_layout.zig`:
- `comptime_verify_layout()` - Verify size/alignment
- `cache_line_info()` - Generate cache utilization info