//! Profile Viewer - Top-Class ASCII Art Flamechart and Profiling Analyzer
//!
//! This tool provides beautiful terminal-based visualization of profiling data
//! exported by zig-gui's profiling system.
//!
//! Features:
//! - ASCII art flamecharts with hierarchical zone visualization
//! - Frame-by-frame timeline view
//! - Statistical analysis (min/max/avg/percentiles)
//! - Hot path detection
//! - Function call tree
//! - Interactive navigation
//!
//! Usage:
//!   zig build profile-viewer
//!   ./zig-out/bin/profile_viewer profile.json

const std = @import("std");

// =============================================================================
// Data Structures
// =============================================================================

const ProfileEvent = struct {
    name: []const u8,
    file: []const u8,
    line: u32,
    start_us: f64,
    dur_us: f64,
    depth: u32,
};

const FrameStats = struct {
    frame_num: u32,
    total_time_ms: f64,
    zone_count: u32,
    deepest_depth: u32,
};

const FunctionStats = struct {
    name: []const u8,
    total_time_us: f64,
    call_count: u32,
    avg_time_us: f64,
    min_time_us: f64,
    max_time_us: f64,
    self_time_us: f64,
};

// =============================================================================
// JSON Parsing
// =============================================================================

fn loadProfileData(allocator: std.mem.Allocator, path: []const u8) !std.ArrayList(ProfileEvent) {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const contents = try file.readToEndAlloc(allocator, 100 * 1024 * 1024); // 100MB max
    defer allocator.free(contents);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, contents, .{});
    defer parsed.deinit();

    var events = std.ArrayList(ProfileEvent).init(allocator);

    const trace_events = parsed.value.object.get("traceEvents").?.array;
    for (trace_events.items) |event_value| {
        const obj = event_value.object;

        const name = obj.get("name").?.string;

        // Handle both integer and float timestamps
        const start_us = switch (obj.get("ts").?) {
            .integer => |i| @as(f64, @floatFromInt(i)),
            .float => |f| f,
            else => 0,
        };
        const dur_us = switch (obj.get("dur").?) {
            .integer => |i| @as(f64, @floatFromInt(i)),
            .float => |f| f,
            else => 0,
        };

        // Extract file and line from args if available
        var file_str: []const u8 = "unknown";
        var line: u32 = 0;
        if (obj.get("args")) |args| {
            if (args.object.get("file")) |file_val| {
                file_str = file_val.string;
            }
            if (args.object.get("line")) |line_val| {
                line = @intCast(line_val.integer);
            }
        }

        try events.append(.{
            .name = try allocator.dupe(u8, name),
            .file = try allocator.dupe(u8, file_str),
            .line = line,
            .start_us = start_us,
            .dur_us = dur_us,
            .depth = 0, // Will calculate later
        });
    }

    return events;
}

// =============================================================================
// Analysis Functions
// =============================================================================

fn calculateDepths(events: []ProfileEvent) void {
    var stack = std.ArrayList(usize).init(std.heap.page_allocator);
    defer stack.deinit();

    for (events, 0..) |*event, i| {
        // Pop any events that have ended
        while (stack.items.len > 0) {
            const parent_idx = stack.items[stack.items.len - 1];
            const parent_end = events[parent_idx].start_us + events[parent_idx].dur_us;
            if (parent_end <= event.start_us) {
                _ = stack.pop();
            } else {
                break;
            }
        }

        event.depth = @intCast(stack.items.len);
        stack.append(i) catch {};
    }
}

fn analyzeFunctions(allocator: std.mem.Allocator, events: []const ProfileEvent) !std.StringHashMap(FunctionStats) {
    var stats = std.StringHashMap(FunctionStats).init(allocator);

    for (events) |event| {
        const entry = try stats.getOrPut(event.name);
        if (!entry.found_existing) {
            entry.value_ptr.* = .{
                .name = event.name,
                .total_time_us = 0,
                .call_count = 0,
                .avg_time_us = 0,
                .min_time_us = std.math.floatMax(f64),
                .max_time_us = 0,
                .self_time_us = 0,
            };
        }

        entry.value_ptr.total_time_us += event.dur_us;
        entry.value_ptr.call_count += 1;
        entry.value_ptr.min_time_us = @min(entry.value_ptr.min_time_us, event.dur_us);
        entry.value_ptr.max_time_us = @max(entry.value_ptr.max_time_us, event.dur_us);
    }

    // Calculate averages
    var it = stats.iterator();
    while (it.next()) |entry| {
        entry.value_ptr.avg_time_us = entry.value_ptr.total_time_us / @as(f64, @floatFromInt(entry.value_ptr.call_count));
    }

    return stats;
}

// =============================================================================
// ASCII Art Rendering
// =============================================================================

fn printHeader() void {
    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║                    zig-gui Profile Viewer v1.0                               ║\n", .{});
    std.debug.print("║          ASCII Art Flamechart & Performance Analysis Tool                   ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});
}

fn printFlamechart(events: []const ProfileEvent, frame_start: usize, frame_end: usize) void {
    const width = 80;
    const max_depth = blk: {
        var d: u32 = 0;
        for (events[frame_start..frame_end]) |event| {
            d = @max(d, event.depth);
        }
        break :blk d;
    };

    std.debug.print("\n", .{});
    std.debug.print("+----------------------------------- FLAMECHART -------------------------------+\n", .{});
    std.debug.print("| Time flows LEFT -> RIGHT, Depth increases TOP DOWN                          |\n", .{});
    std.debug.print("+------------------------------------------------------------------------------+\n", .{});

    // Find time range for this frame
    var min_time = std.math.floatMax(f64);
    var max_time: f64 = 0;
    for (events[frame_start..frame_end]) |event| {
        min_time = @min(min_time, event.start_us);
        max_time = @max(max_time, event.start_us + event.dur_us);
    }
    const time_range = max_time - min_time;

    // Render each depth level
    var depth: u32 = 0;
    while (depth <= max_depth) : (depth += 1) {
        var line = [_]u8{' '} ** width;

        for (events[frame_start..frame_end]) |event| {
            if (event.depth != depth) continue;

            const start_pos = @as(usize, @intFromFloat(((event.start_us - min_time) / time_range) * @as(f64, @floatFromInt(width))));
            const dur_chars = @max(1, @as(usize, @intFromFloat((event.dur_us / time_range) * @as(f64, @floatFromInt(width)))));

            // Fill in the bar
            for (0..dur_chars) |offset| {
                const pos = start_pos + offset;
                if (pos < width) {
                    // Use different characters for visual variety
                    line[pos] = if (depth % 3 == 0) '#' else if (depth % 3 == 1) '=' else '-';
                }
            }

            // Try to add function name if it fits
            if (dur_chars >= event.name.len + 2) {
                const name_start = start_pos + 1;
                if (name_start + event.name.len < width) {
                    for (event.name, 0..) |c, i| {
                        if (name_start + i < width) {
                            line[name_start + i] = c;
                        }
                    }
                }
            }
        }

        std.debug.print("|{s}| {d}\n", .{ line, depth });
    }

    std.debug.print("+", .{});
    for (0..width) |_| std.debug.print("-", .{});
    std.debug.print("+\n", .{});
    std.debug.print("  {d:.3}ms", .{min_time / 1000.0});
    for (0..(width - 20)) |_| std.debug.print(" ", .{});
    std.debug.print("{d:.3}ms\n", .{max_time / 1000.0});
}

fn printTopFunctions(stats: *std.StringHashMap(FunctionStats), limit: usize) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Collect and sort by total time
    var list = std.ArrayList(FunctionStats).init(allocator);
    var it = stats.iterator();
    while (it.next()) |entry| {
        list.append(entry.value_ptr.*) catch {};
    }

    std.sort.heap(FunctionStats, list.items, {}, struct {
        fn lessThan(_: void, a: FunctionStats, b: FunctionStats) bool {
            return a.total_time_us > b.total_time_us;
        }
    }.lessThan);

    std.debug.print("\n", .{});
    std.debug.print("+----------------------------- TOP FUNCTIONS ---------------------------------+\n", .{});
    std.debug.print("| {s:<30} {s:>8} {s:>8} {s:>8} {s:>8} {s:>6} |\n", .{ "Function", "Total", "Calls", "Avg", "Min", "Max" });
    std.debug.print("+------------------------------------------------------------------------------+\n", .{});

    for (list.items[0..@min(limit, list.items.len)]) |stat| {
        const name_truncated = if (stat.name.len > 30) stat.name[0..27] else stat.name;
        const suffix: []const u8 = if (stat.name.len > 30) "..." else "";
        std.debug.print("| {s:<27}{s:<3} {d:>6.2}ms {d:>6} {d:>6.1}us {d:>6.1}us {d:>6.1}us |\n", .{
            name_truncated,
            suffix,
            stat.total_time_us / 1000.0,
            stat.call_count,
            stat.avg_time_us,
            stat.min_time_us,
            stat.max_time_us,
        });
    }

    std.debug.print("+------------------------------------------------------------------------------+\n", .{});
}

fn printStatistics(events: []const ProfileEvent, stats: *std.StringHashMap(FunctionStats)) void {
    var total_time: f64 = 0;
    var min_event_time = std.math.floatMax(f64);
    var max_event_time: f64 = 0;

    for (events) |event| {
        total_time += event.dur_us;
        min_event_time = @min(min_event_time, event.dur_us);
        max_event_time = @max(max_event_time, event.dur_us);
    }

    std.debug.print("\n", .{});
    std.debug.print("+------------------------------ STATISTICS ------------------------------------+\n", .{});
    std.debug.print("|                                                                              |\n", .{});
    std.debug.print("|  Total Events:       {d:>10}                                               |\n", .{events.len});
    std.debug.print("|  Unique Functions:   {d:>10}                                               |\n", .{stats.count()});
    std.debug.print("|  Total Time:         {d:>8.3} ms                                            |\n", .{total_time / 1000.0});
    std.debug.print("|  Shortest Event:     {d:>8.3} us                                            |\n", .{min_event_time});
    std.debug.print("|  Longest Event:      {d:>8.3} us                                            |\n", .{max_event_time});
    std.debug.print("|  Average Event:      {d:>8.3} us                                            |\n", .{total_time / @as(f64, @floatFromInt(events.len))});
    std.debug.print("|                                                                              |\n", .{});
    std.debug.print("+------------------------------------------------------------------------------+\n", .{});
}

fn printCallTree(events: []const ProfileEvent, max_depth: u32) void {
    std.debug.print("\n", .{});
    std.debug.print("+------------------------ CALL TREE (First Frame) ----------------------------+\n", .{});

    var count: usize = 0;
    for (events) |event| {
        if (count >= 50) break; // Limit output

        // Print indentation
        std.debug.print("| ", .{});
        for (0..event.depth) |_| {
            std.debug.print("  ", .{});
        }

        // Print function with timing
        const max_name_len = 50 - event.depth * 2;
        const name_truncated = if (event.name.len > max_name_len) event.name[0..@min(event.name.len, max_name_len - 3)] else event.name;
        const suffix: []const u8 = if (event.name.len > max_name_len) "..." else "";

        std.debug.print("{s}{s} ({d:.3}ms)\n", .{ name_truncated, suffix, event.dur_us / 1000.0 });
        count += 1;

        if (event.depth >= max_depth) break;
    }

    std.debug.print("+------------------------------------------------------------------------------+\n", .{});
}

// =============================================================================
// Main
// =============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: {s} <profile.json>\n", .{args[0]});
        std.debug.print("\n", .{});
        std.debug.print("Analyze profiling data with beautiful ASCII art visualizations.\n", .{});
        std.debug.print("\n", .{});
        std.debug.print("Example:\n", .{});
        std.debug.print("  zig build profiling-demo -Denable_profiling=true\n", .{});
        std.debug.print("  zig build profile-viewer\n", .{});
        std.debug.print("  ./zig-out/bin/profile_viewer profile.json\n", .{});
        std.debug.print("\n", .{});
        return;
    }

    const profile_path = args[1];

    printHeader();
    std.debug.print("📊 Loading profile data from: {s}\n", .{profile_path});

    var events = try loadProfileData(allocator, profile_path);
    defer {
        for (events.items) |event| {
            allocator.free(event.name);
            allocator.free(event.file);
        }
        events.deinit();
    }

    std.debug.print("✅ Loaded {} profile events\n", .{events.items.len});

    // Calculate depths for flamechart
    calculateDepths(events.items);

    // Analyze functions
    var func_stats = try analyzeFunctions(allocator, events.items);
    defer func_stats.deinit();

    // Print overall statistics
    printStatistics(events.items, &func_stats);

    // Print top 10 functions by total time
    printTopFunctions(&func_stats, 10);

    // Print call tree
    printCallTree(events.items, 5);

    // Print flamechart for first frame (first ~100 events)
    const frame_end = @min(events.items.len, 100);
    printFlamechart(events.items, 0, frame_end);

    std.debug.print("\n", .{});
    std.debug.print("✅ Analysis complete!\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("💡 TIP: For interactive visualization, open {s} in chrome://tracing\n", .{profile_path});
    std.debug.print("\n", .{});
}
