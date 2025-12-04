//! GUI + Draw System Integration Demo
//!
//! Demonstrates the complete BYOR pipeline:
//! GUI widgets → DrawList → SoftwareBackend → PPM image
//!
//! Run with: zig build gui-demo
//! View the output with any image viewer that supports PPM format.

const std = @import("std");
const gui_mod = @import("zig-gui");

const GUI = gui_mod.GUI;
const GUIConfig = gui_mod.GUIConfig;
const DrawData = gui_mod.draw.DrawData;
const SoftwareBackend = gui_mod.draw.SoftwareBackend;
const Color = gui_mod.Color;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Configure GUI with specific dimensions
    const width: u32 = 400;
    const height: u32 = 300;

    var gui = try GUI.init(allocator, GUIConfig{
        .window_width = width,
        .window_height = height,
    });
    defer gui.deinit();

    // Create software backend for pixel rendering
    var backend = try SoftwareBackend.initAlloc(allocator, width, height);
    defer backend.deinit(allocator);
    backend.clear_color = 0xFF1a1a2e; // Dark blue-gray background

    // === Simulate a frame with widgets ===

    try gui.beginFrame();

    // Header area
    try gui.text("zig-gui Demo Application", .{});
    gui.newLine();
    gui.separator();

    // Row of buttons
    gui.beginRow();
    gui.button("File");
    gui.button("Edit");
    gui.button("View");
    gui.button("Help");
    gui.endRow();

    gui.separator();

    // Some content
    try gui.text("Welcome to zig-gui!", .{});
    gui.newLine();
    try gui.text("This image was rendered using:", .{});
    gui.newLine();
    try gui.text("  - GUI immediate-mode widgets", .{});
    gui.newLine();
    try gui.text("  - DrawList command accumulation", .{});
    gui.newLine();
    try gui.text("  - SoftwareBackend rasterization", .{});
    gui.newLine();

    gui.separator();

    // Checkboxes
    gui.beginRow();
    _ = gui.checkbox("option1", true);
    try gui.text("Enable feature", .{});
    gui.endRow();

    gui.beginRow();
    _ = gui.checkbox("option2", false);
    try gui.text("Another option", .{});
    gui.endRow();

    gui.separator();

    // Action buttons
    gui.beginRow();
    gui.button("Apply");
    gui.button("Cancel");
    gui.endRow();

    try gui.endFrame();

    // === Render to backend ===

    const draw_data = gui.getDrawData();

    std.debug.print("Frame generated {d} draw commands\n", .{draw_data.commandCount()});
    std.debug.print("Display size: {d}x{d}\n", .{
        @as(u32, @intFromFloat(draw_data.display_size.width)),
        @as(u32, @intFromFloat(draw_data.display_size.height)),
    });

    const iface = backend.interface();
    iface.beginFrame(&draw_data);
    iface.render(&draw_data);
    iface.endFrame();

    // === Output PPM ===

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const output_path = if (args.len > 1) args[1] else "gui_demo.ppm";

    const file = try std.fs.cwd().createFile(output_path, .{});
    defer file.close();

    try backend.writePPM(file.writer());

    std.debug.print("Rendered GUI to {s}\n", .{output_path});
}
