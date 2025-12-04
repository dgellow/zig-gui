//! GUI + Draw System Integration Demo
//!
//! Demonstrates the complete BYOR pipeline with a realistic Settings UI:
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

    // Larger canvas for a realistic UI
    const width: u32 = 640;
    const height: u32 = 480;

    var gui = try GUI.init(allocator, GUIConfig{
        .window_width = width,
        .window_height = height,
    });
    defer gui.deinit();

    // Create software backend for pixel rendering
    var backend = try SoftwareBackend.initAlloc(allocator, width, height);
    defer backend.deinit(allocator);
    backend.clear_color = 0xFF16213e; // Deep blue background

    // === Build a realistic Settings UI ===

    try gui.beginFrame();

    // ─────────────────────────────────────────────────────────────────
    // Application Header
    // ─────────────────────────────────────────────────────────────────
    try gui.text("Settings", .{});
    gui.newLine();
    gui.separator();

    // ─────────────────────────────────────────────────────────────────
    // Menu Bar
    // ─────────────────────────────────────────────────────────────────
    gui.beginRow();
    gui.button("File");
    gui.button("Edit");
    gui.button("View");
    gui.button("Tools");
    gui.button("Help");
    gui.endRow();

    gui.separator();
    gui.newLine();

    // ─────────────────────────────────────────────────────────────────
    // Section: General
    // ─────────────────────────────────────────────────────────────────
    try gui.text("General", .{});
    gui.newLine();

    gui.beginRow();
    _ = gui.checkbox("auto_save", true);
    try gui.text("Auto-save on exit", .{});
    gui.endRow();

    gui.beginRow();
    _ = gui.checkbox("auto_update", true);
    try gui.text("Check for updates automatically", .{});
    gui.endRow();

    gui.beginRow();
    _ = gui.checkbox("telemetry", false);
    try gui.text("Send anonymous usage data", .{});
    gui.endRow();

    gui.newLine();
    gui.separator();
    gui.newLine();

    // ─────────────────────────────────────────────────────────────────
    // Section: Appearance
    // ─────────────────────────────────────────────────────────────────
    try gui.text("Appearance", .{});
    gui.newLine();

    gui.beginRow();
    _ = gui.checkbox("dark_mode", true);
    try gui.text("Dark mode", .{});
    gui.endRow();

    gui.beginRow();
    _ = gui.checkbox("animations", true);
    try gui.text("Enable animations", .{});
    gui.endRow();

    gui.beginRow();
    _ = gui.checkbox("high_contrast", false);
    try gui.text("High contrast mode", .{});
    gui.endRow();

    gui.newLine();
    gui.separator();
    gui.newLine();

    // ─────────────────────────────────────────────────────────────────
    // Section: Privacy & Security
    // ─────────────────────────────────────────────────────────────────
    try gui.text("Privacy & Security", .{});
    gui.newLine();

    gui.beginRow();
    _ = gui.checkbox("remember_login", true);
    try gui.text("Remember login", .{});
    gui.endRow();

    gui.beginRow();
    _ = gui.checkbox("2fa", false);
    try gui.text("Two-factor authentication", .{});
    gui.endRow();

    gui.beginRow();
    _ = gui.checkbox("clear_history", false);
    try gui.text("Clear history on exit", .{});
    gui.endRow();

    gui.newLine();
    gui.separator();
    gui.newLine();

    // ─────────────────────────────────────────────────────────────────
    // Section: Advanced
    // ─────────────────────────────────────────────────────────────────
    try gui.text("Advanced", .{});
    gui.newLine();

    gui.beginRow();
    _ = gui.checkbox("dev_mode", false);
    try gui.text("Developer mode", .{});
    gui.endRow();

    gui.beginRow();
    _ = gui.checkbox("logging", true);
    try gui.text("Enable logging", .{});
    gui.endRow();

    gui.newLine();
    gui.separator();
    gui.newLine();

    // ─────────────────────────────────────────────────────────────────
    // Action Buttons
    // ─────────────────────────────────────────────────────────────────
    gui.beginRow();
    gui.button("Reset to Defaults");
    gui.button("Import");
    gui.button("Export");
    gui.endRow();

    gui.newLine();

    gui.beginRow();
    gui.button("Apply");
    gui.button("Cancel");
    gui.button("OK");
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
