//! Draw System Demo - Outputs a PPM image
//!
//! Run with: zig build render-demo
//!
//! View the output with any image viewer that supports PPM format.

const std = @import("std");
const gui = @import("zig-gui");

const Color = gui.Color;
const DrawList = gui.draw.DrawList;
const DrawData = gui.draw.DrawData;
const SoftwareBackend = gui.draw.SoftwareBackend;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a 400x300 framebuffer
    const width: u32 = 400;
    const height: u32 = 300;

    var backend = try SoftwareBackend.initAlloc(allocator, width, height);
    defer backend.deinit(allocator);

    // Set a nice dark background
    backend.clear_color = 0xFF1a1a2e; // Dark blue-gray

    var draw_list = DrawList.init(allocator);
    defer draw_list.deinit();

    // === Build UI-like scene ===

    // Header bar
    draw_list.addFilledRect(
        .{ .x = 0, .y = 0, .width = 400, .height = 50 },
        Color.fromRGB(22, 33, 62), // Darker header
    );

    // Header title area (simulating text with a rectangle)
    draw_list.addFilledRect(
        .{ .x = 15, .y = 15, .width = 100, .height = 20 },
        Color.fromRGB(100, 100, 120),
    );

    // Primary button
    draw_list.addFilledRectEx(
        .{ .x = 30, .y = 80, .width = 140, .height = 45 },
        Color.fromRGB(66, 133, 244), // Google blue
        0,
    );
    draw_list.addStrokeRect(
        .{ .x = 30, .y = 80, .width = 140, .height = 45 },
        Color.fromRGB(100, 160, 255),
        2,
    );

    // Secondary button
    draw_list.addFilledRectEx(
        .{ .x = 30, .y = 140, .width = 140, .height = 45 },
        Color.fromRGB(52, 168, 83), // Google green
        0,
    );
    draw_list.addStrokeRect(
        .{ .x = 30, .y = 140, .width = 140, .height = 45 },
        Color.fromRGB(80, 200, 110),
        2,
    );

    // Danger button
    draw_list.addFilledRectEx(
        .{ .x = 30, .y = 200, .width = 140, .height = 45 },
        Color.fromRGB(234, 67, 53), // Google red
        0,
    );
    draw_list.addStrokeRect(
        .{ .x = 30, .y = 200, .width = 140, .height = 45 },
        Color.fromRGB(255, 100, 90),
        2,
    );

    // Side panel
    draw_list.addFilledRect(
        .{ .x = 200, .y = 60, .width = 180, .height = 220 },
        Color.fromRGB(30, 40, 60),
    );
    draw_list.addStrokeRect(
        .{ .x = 200, .y = 60, .width = 180, .height = 220 },
        Color.fromRGB(60, 80, 120),
        1,
    );

    // List items in side panel
    for (0..5) |i| {
        const y: f32 = 75 + @as(f32, @floatFromInt(i)) * 38;
        draw_list.addFilledRect(
            .{ .x = 210, .y = y, .width = 160, .height = 30 },
            Color.fromRGB(40, 55, 80),
        );
    }

    // Highlight one item (simulating hover)
    draw_list.addFilledRect(
        .{ .x = 210, .y = 75 + 38, .width = 160, .height = 30 },
        Color.fromRGB(60, 80, 120),
    );
    draw_list.addStrokeRect(
        .{ .x = 210, .y = 75 + 38, .width = 160, .height = 30 },
        Color.fromRGB(100, 140, 200),
        1,
    );

    // Diagonal accent line
    draw_list.addLine(
        .{ .x = 0, .y = 50 },
        .{ .x = 400, .y = 50 },
        Color.fromRGB(100, 100, 150),
        2,
    );

    // === Render ===
    const draw_data = DrawData{
        .commands = draw_list.getCommands(),
        .display_size = .{ .width = @floatFromInt(width), .height = @floatFromInt(height) },
    };

    const iface = backend.interface();
    iface.beginFrame(&draw_data);
    iface.render(&draw_data);
    iface.endFrame();

    // === Output PPM ===
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const output_path = if (args.len > 1) args[1] else "output.ppm";

    const file = try std.fs.cwd().createFile(output_path, .{});
    defer file.close();

    try backend.writePPM(file.writer());

    std.debug.print("Rendered {d} commands to {s} ({d}x{d})\n", .{
        draw_list.commandCount(),
        output_path,
        width,
        height,
    });
}
