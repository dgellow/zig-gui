//! GUI + Draw System Integration Demo
//!
//! Demonstrates the BYOR pipeline with a Linear-style issue tracker UI.
//! Shows complex layouts, rich colors, tags, avatars, and comment threads.
//!
//! Run with: zig build gui-demo

const std = @import("std");
const gui_mod = @import("zig-gui");

const DrawList = gui_mod.draw.DrawList;
const DrawData = gui_mod.draw.DrawData;
const SoftwareBackend = gui_mod.draw.SoftwareBackend;
const Color = gui_mod.Color;
const Rect = gui_mod.Rect;

// Color palette (Linear-inspired dark theme)
const colors = struct {
    const bg_dark = Color.fromRGB(13, 13, 15); // Main background
    const bg_sidebar = Color.fromRGB(23, 23, 27); // Sidebar
    const bg_card = Color.fromRGB(30, 30, 35); // Cards/panels
    const bg_hover = Color.fromRGB(40, 40, 48); // Hover states
    const bg_input = Color.fromRGB(38, 38, 45); // Input fields

    const border = Color.fromRGB(50, 50, 58); // Borders
    const border_light = Color.fromRGB(70, 70, 80); // Light borders

    const text_primary = Color.fromRGB(230, 230, 235); // Primary text
    const text_secondary = Color.fromRGB(140, 140, 150); // Secondary text
    const text_muted = Color.fromRGB(90, 90, 100); // Muted text

    // Status colors
    const status_todo = Color.fromRGB(130, 130, 140); // Gray
    const status_in_progress = Color.fromRGB(245, 166, 35); // Orange
    const status_done = Color.fromRGB(72, 187, 120); // Green
    const status_cancelled = Color.fromRGB(200, 80, 80); // Red

    // Priority colors
    const priority_urgent = Color.fromRGB(239, 68, 68); // Red
    const priority_high = Color.fromRGB(249, 115, 22); // Orange
    const priority_medium = Color.fromRGB(234, 179, 8); // Yellow
    const priority_low = Color.fromRGB(107, 114, 128); // Gray

    // Accent colors
    const accent_blue = Color.fromRGB(59, 130, 246);
    const accent_purple = Color.fromRGB(139, 92, 246);
    const accent_cyan = Color.fromRGB(34, 211, 238);
    const accent_pink = Color.fromRGB(236, 72, 153);

    // Avatar colors
    const avatar_1 = Color.fromRGB(99, 102, 241); // Indigo
    const avatar_2 = Color.fromRGB(16, 185, 129); // Emerald
    const avatar_3 = Color.fromRGB(244, 63, 94); // Rose
    const avatar_4 = Color.fromRGB(251, 146, 60); // Orange
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const width: u32 = 1200;
    const height: u32 = 800;

    var backend = try SoftwareBackend.initAlloc(allocator, width, height);
    defer backend.deinit(allocator);
    backend.clear_color = colors.bg_dark.toHex();

    var draw = DrawList.init(allocator);
    defer draw.deinit();

    // ═══════════════════════════════════════════════════════════════════
    // SIDEBAR (left navigation)
    // ═══════════════════════════════════════════════════════════════════
    const sidebar_width: f32 = 220;

    // Sidebar background
    draw.addFilledRect(
        Rect{ .x = 0, .y = 0, .width = sidebar_width, .height = @floatFromInt(height) },
        colors.bg_sidebar,
    );

    // Workspace icon (top-left logo area)
    draw.addFilledRectEx(
        Rect{ .x = 16, .y = 16, .width = 36, .height = 36 },
        colors.accent_purple,
        8,
    );
    // "Z" in logo (simplified as small square)
    draw.addFilledRect(
        Rect{ .x = 24, .y = 24, .width = 20, .height = 20 },
        colors.bg_dark,
    );
    draw.addFilledRect(
        Rect{ .x = 28, .y = 28, .width = 12, .height = 4 },
        colors.accent_purple,
    );
    draw.addFilledRect(
        Rect{ .x = 28, .y = 36, .width = 12, .height = 4 },
        colors.accent_purple,
    );

    // Workspace name placeholder
    draw.addFilledRectEx(
        Rect{ .x = 62, .y = 22, .width = 90, .height = 12 },
        colors.text_primary,
        2,
    );
    draw.addFilledRectEx(
        Rect{ .x = 62, .y = 38, .width = 60, .height = 8 },
        colors.text_muted,
        2,
    );

    // Search bar
    draw.addFilledRectEx(
        Rect{ .x = 16, .y = 70, .width = sidebar_width - 32, .height = 32 },
        colors.bg_input,
        6,
    );
    draw.addFilledRectEx(
        Rect{ .x = 28, .y = 80, .width = 80, .height = 10 },
        colors.text_muted,
        2,
    );

    // Navigation items
    const nav_items = [_]struct { icon_color: Color, selected: bool }{
        .{ .icon_color = colors.accent_blue, .selected = false }, // Inbox
        .{ .icon_color = colors.text_secondary, .selected = false }, // My Issues
        .{ .icon_color = colors.accent_purple, .selected = true }, // Active Sprint
        .{ .icon_color = colors.text_secondary, .selected = false }, // Backlog
        .{ .icon_color = colors.text_secondary, .selected = false }, // Projects
        .{ .icon_color = colors.text_secondary, .selected = false }, // Views
    };

    var nav_y: f32 = 120;
    for (nav_items) |item| {
        // Selection highlight
        if (item.selected) {
            draw.addFilledRectEx(
                Rect{ .x = 8, .y = nav_y, .width = sidebar_width - 16, .height = 32 },
                colors.bg_hover,
                6,
            );
            // Left accent bar
            draw.addFilledRect(
                Rect{ .x = 8, .y = nav_y + 6, .width = 3, .height = 20 },
                colors.accent_purple,
            );
        }

        // Icon placeholder
        draw.addFilledRectEx(
            Rect{ .x = 24, .y = nav_y + 8, .width = 16, .height = 16 },
            item.icon_color,
            4,
        );

        // Label placeholder
        draw.addFilledRectEx(
            Rect{ .x = 48, .y = nav_y + 11, .width = 70 + @as(f32, @floatFromInt(@mod(@as(u32, @intFromFloat(nav_y)), 3))) * 20, .height = 10 },
            if (item.selected) colors.text_primary else colors.text_secondary,
            2,
        );

        nav_y += 36;
    }

    // Section divider
    nav_y += 16;
    draw.addFilledRect(
        Rect{ .x = 16, .y = nav_y, .width = sidebar_width - 32, .height = 1 },
        colors.border,
    );
    nav_y += 20;

    // Teams section header
    draw.addFilledRectEx(
        Rect{ .x = 16, .y = nav_y, .width = 50, .height = 8 },
        colors.text_muted,
        2,
    );
    nav_y += 20;

    // Team items with colored icons
    const team_colors = [_]Color{ colors.accent_cyan, colors.accent_pink, colors.avatar_2 };
    for (team_colors) |color| {
        draw.addFilledRectEx(
            Rect{ .x = 24, .y = nav_y + 6, .width = 14, .height = 14 },
            color,
            3,
        );
        draw.addFilledRectEx(
            Rect{ .x = 46, .y = nav_y + 9, .width = 80, .height = 8 },
            colors.text_secondary,
            2,
        );
        nav_y += 30;
    }

    // ═══════════════════════════════════════════════════════════════════
    // MAIN CONTENT AREA
    // ═══════════════════════════════════════════════════════════════════
    const content_x = sidebar_width;
    const content_width = @as(f32, @floatFromInt(width)) - sidebar_width;

    // Header bar
    draw.addFilledRect(
        Rect{ .x = content_x, .y = 0, .width = content_width, .height = 56 },
        colors.bg_sidebar,
    );
    draw.addFilledRect(
        Rect{ .x = content_x, .y = 55, .width = content_width, .height = 1 },
        colors.border,
    );

    // Breadcrumb
    draw.addFilledRectEx(
        Rect{ .x = content_x + 24, .y = 20, .width = 60, .height = 10 },
        colors.text_muted,
        2,
    );
    draw.addFilledRectEx(
        Rect{ .x = content_x + 92, .y = 20, .width = 8, .height = 10 },
        colors.text_muted,
        2,
    );
    draw.addFilledRectEx(
        Rect{ .x = content_x + 108, .y = 20, .width = 80, .height = 10 },
        colors.text_secondary,
        2,
    );

    // Issue ID badge
    draw.addFilledRectEx(
        Rect{ .x = content_x + 24, .y = 36, .width = 56, .height = 14 },
        colors.bg_input,
        4,
    );
    draw.addFilledRectEx(
        Rect{ .x = content_x + 30, .y = 40, .width = 44, .height = 6 },
        colors.text_muted,
        2,
    );

    // Right side header buttons
    draw.addFilledRectEx(
        Rect{ .x = content_x + content_width - 140, .y = 14, .width = 28, .height = 28 },
        colors.bg_input,
        6,
    );
    draw.addFilledRectEx(
        Rect{ .x = content_x + content_width - 104, .y = 14, .width = 28, .height = 28 },
        colors.bg_input,
        6,
    );
    draw.addFilledRectEx(
        Rect{ .x = content_x + content_width - 68, .y = 14, .width = 52, .height = 28 },
        colors.accent_purple,
        6,
    );

    // ═══════════════════════════════════════════════════════════════════
    // ISSUE DETAIL VIEW (two-column layout)
    // ═══════════════════════════════════════════════════════════════════
    const detail_x = content_x + 24;
    const detail_width = content_width - 320; // Leave room for right panel
    const panel_x = content_x + content_width - 280;
    const panel_width: f32 = 260;

    // Issue title (large text placeholder)
    draw.addFilledRectEx(
        Rect{ .x = detail_x, .y = 80, .width = 450, .height = 24 },
        colors.text_primary,
        3,
    );

    // Status row
    var status_x = detail_x;
    const status_y: f32 = 120;

    // Status dropdown
    draw.addFilledRectEx(
        Rect{ .x = status_x, .y = status_y, .width = 100, .height = 28 },
        colors.bg_card,
        6,
    );
    draw.addFilledRectEx(
        Rect{ .x = status_x + 8, .y = status_y + 6, .width = 14, .height = 14 },
        colors.status_in_progress,
        7, // Circle
    );
    draw.addFilledRectEx(
        Rect{ .x = status_x + 28, .y = status_y + 10, .width = 60, .height = 8 },
        colors.text_secondary,
        2,
    );
    status_x += 112;

    // Priority badge
    draw.addFilledRectEx(
        Rect{ .x = status_x, .y = status_y, .width = 80, .height = 28 },
        colors.bg_card,
        6,
    );
    // Priority bars
    draw.addFilledRect(Rect{ .x = status_x + 10, .y = status_y + 8, .width = 3, .height = 12 }, colors.priority_high);
    draw.addFilledRect(Rect{ .x = status_x + 15, .y = status_y + 8, .width = 3, .height = 12 }, colors.priority_high);
    draw.addFilledRect(Rect{ .x = status_x + 20, .y = status_y + 11, .width = 3, .height = 9 }, colors.text_muted);
    draw.addFilledRectEx(
        Rect{ .x = status_x + 30, .y = status_y + 10, .width = 36, .height = 8 },
        colors.text_secondary,
        2,
    );
    status_x += 92;

    // Assignee
    draw.addFilledRectEx(
        Rect{ .x = status_x, .y = status_y, .width = 110, .height = 28 },
        colors.bg_card,
        6,
    );
    draw.addFilledRectEx(
        Rect{ .x = status_x + 8, .y = status_y + 4, .width = 20, .height = 20 },
        colors.avatar_1,
        10,
    );
    draw.addFilledRectEx(
        Rect{ .x = status_x + 34, .y = status_y + 10, .width = 66, .height = 8 },
        colors.text_secondary,
        2,
    );

    // ═══════════════════════════════════════════════════════════════════
    // DESCRIPTION SECTION
    // ═══════════════════════════════════════════════════════════════════
    const desc_y: f32 = 170;

    // Section header
    draw.addFilledRectEx(
        Rect{ .x = detail_x, .y = desc_y, .width = 80, .height = 10 },
        colors.text_muted,
        2,
    );

    // Description text lines (simulated paragraphs)
    var line_y = desc_y + 24;
    const line_widths = [_]f32{ 520, 480, 510, 440, 380, 490, 420, 200 };
    for (line_widths) |w| {
        draw.addFilledRectEx(
            Rect{ .x = detail_x, .y = line_y, .width = w, .height = 8 },
            colors.text_secondary,
            2,
        );
        line_y += 18;
    }

    // Code block
    line_y += 8;
    draw.addFilledRectEx(
        Rect{ .x = detail_x, .y = line_y, .width = 500, .height = 80 },
        colors.bg_input,
        6,
    );
    draw.addStrokeRect(
        Rect{ .x = detail_x, .y = line_y, .width = 500, .height = 80 },
        colors.border,
        1,
    );
    // Code lines
    draw.addFilledRectEx(
        Rect{ .x = detail_x + 12, .y = line_y + 12, .width = 200, .height = 8 },
        colors.accent_cyan,
        2,
    );
    draw.addFilledRectEx(
        Rect{ .x = detail_x + 12, .y = line_y + 28, .width = 280, .height = 8 },
        colors.text_secondary,
        2,
    );
    draw.addFilledRectEx(
        Rect{ .x = detail_x + 12, .y = line_y + 44, .width = 160, .height = 8 },
        colors.accent_purple,
        2,
    );
    draw.addFilledRectEx(
        Rect{ .x = detail_x + 12, .y = line_y + 60, .width = 240, .height = 8 },
        colors.text_secondary,
        2,
    );

    // ═══════════════════════════════════════════════════════════════════
    // COMMENTS SECTION
    // ═══════════════════════════════════════════════════════════════════
    line_y += 110;

    // Comments header with count badge
    draw.addFilledRectEx(
        Rect{ .x = detail_x, .y = line_y, .width = 70, .height = 10 },
        colors.text_muted,
        2,
    );
    draw.addFilledRectEx(
        Rect{ .x = detail_x + 78, .y = line_y - 2, .width = 20, .height = 14 },
        colors.bg_input,
        7,
    );
    draw.addFilledRectEx(
        Rect{ .x = detail_x + 84, .y = line_y + 2, .width = 8, .height = 6 },
        colors.text_muted,
        2,
    );

    line_y += 24;

    // Comment 1
    drawComment(&draw, detail_x, line_y, colors.avatar_2, 380, true);
    line_y += 90;

    // Comment 2
    drawComment(&draw, detail_x, line_y, colors.avatar_3, 320, false);
    line_y += 80;

    // Comment 3
    drawComment(&draw, detail_x, line_y, colors.avatar_1, 420, false);
    line_y += 100;

    // Add comment input
    draw.addFilledRectEx(
        Rect{ .x = detail_x, .y = line_y, .width = detail_width - 40, .height = 44 },
        colors.bg_input,
        8,
    );
    draw.addStrokeRect(
        Rect{ .x = detail_x, .y = line_y, .width = detail_width - 40, .height = 44 },
        colors.border,
        1,
    );
    draw.addFilledRectEx(
        Rect{ .x = detail_x + 14, .y = line_y + 16, .width = 120, .height = 10 },
        colors.text_muted,
        2,
    );

    // ═══════════════════════════════════════════════════════════════════
    // RIGHT PANEL (Properties)
    // ═══════════════════════════════════════════════════════════════════

    // Panel background
    draw.addFilledRect(
        Rect{ .x = panel_x - 16, .y = 56, .width = 1, .height = @as(f32, @floatFromInt(height)) - 56 },
        colors.border,
    );

    var prop_y: f32 = 80;

    // Labels section
    draw.addFilledRectEx(
        Rect{ .x = panel_x, .y = prop_y, .width = 40, .height = 8 },
        colors.text_muted,
        2,
    );
    prop_y += 16;

    // Label tags
    const label_colors = [_]struct { bg: Color, text_w: f32 }{
        .{ .bg = Color.fromRGB(59, 130, 246), .text_w = 50 }, // Blue - "frontend"
        .{ .bg = Color.fromRGB(236, 72, 153), .text_w = 30 }, // Pink - "bug"
        .{ .bg = Color.fromRGB(34, 197, 94), .text_w = 65 }, // Green - "performance"
    };
    var label_x = panel_x;
    for (label_colors) |label| {
        const tag_width = label.text_w + 16;
        draw.addFilledRectEx(
            Rect{ .x = label_x, .y = prop_y, .width = tag_width, .height = 22 },
            label.bg,
            11,
        );
        draw.addFilledRectEx(
            Rect{ .x = label_x + 8, .y = prop_y + 7, .width = label.text_w, .height = 8 },
            Color.fromRGBA(255, 255, 255, 220),
            2,
        );
        label_x += tag_width + 6;
    }

    prop_y += 44;

    // Project
    drawProperty(&draw, panel_x, prop_y, colors.accent_purple, 70, panel_width);
    prop_y += 50;

    // Milestone
    drawProperty(&draw, panel_x, prop_y, colors.accent_cyan, 90, panel_width);
    prop_y += 50;

    // Due date
    draw.addFilledRectEx(
        Rect{ .x = panel_x, .y = prop_y, .width = 50, .height = 8 },
        colors.text_muted,
        2,
    );
    prop_y += 16;
    draw.addFilledRectEx(
        Rect{ .x = panel_x, .y = prop_y, .width = 100, .height = 10 },
        colors.priority_high, // Orange to indicate approaching
        2,
    );
    prop_y += 30;

    // Estimate
    draw.addFilledRectEx(
        Rect{ .x = panel_x, .y = prop_y, .width = 45, .height = 8 },
        colors.text_muted,
        2,
    );
    prop_y += 16;
    draw.addFilledRectEx(
        Rect{ .x = panel_x, .y = prop_y, .width = 30, .height = 10 },
        colors.text_secondary,
        2,
    );
    prop_y += 30;

    // Subscribers section
    draw.addFilledRectEx(
        Rect{ .x = panel_x, .y = prop_y, .width = 65, .height = 8 },
        colors.text_muted,
        2,
    );
    prop_y += 16;

    // Subscriber avatars (stacked)
    const subscriber_colors = [_]Color{ colors.avatar_1, colors.avatar_2, colors.avatar_3, colors.avatar_4 };
    var avatar_x = panel_x;
    for (subscriber_colors) |color| {
        draw.addFilledRectEx(
            Rect{ .x = avatar_x, .y = prop_y, .width = 28, .height = 28 },
            colors.bg_sidebar, // Border/background
            14,
        );
        draw.addFilledRectEx(
            Rect{ .x = avatar_x + 2, .y = prop_y + 2, .width = 24, .height = 24 },
            color,
            12,
        );
        avatar_x += 22; // Overlap
    }

    // +N more indicator
    draw.addFilledRectEx(
        Rect{ .x = avatar_x, .y = prop_y, .width = 28, .height = 28 },
        colors.bg_input,
        14,
    );
    draw.addFilledRectEx(
        Rect{ .x = avatar_x + 8, .y = prop_y + 10, .width = 12, .height = 8 },
        colors.text_muted,
        2,
    );

    prop_y += 50;

    // Activity section
    draw.addFilledRectEx(
        Rect{ .x = panel_x, .y = prop_y, .width = 45, .height = 8 },
        colors.text_muted,
        2,
    );
    prop_y += 18;

    // Activity items
    for (0..4) |_| {
        draw.addFilledRectEx(
            Rect{ .x = panel_x, .y = prop_y, .width = 8, .height = 8 },
            colors.border_light,
            4,
        );
        draw.addFilledRectEx(
            Rect{ .x = panel_x + 16, .y = prop_y, .width = 140, .height = 6 },
            colors.text_muted,
            2,
        );
        prop_y += 20;
    }

    // ═══════════════════════════════════════════════════════════════════
    // RENDER
    // ═══════════════════════════════════════════════════════════════════

    const draw_data = DrawData{
        .commands = draw.getCommands(),
        .display_size = .{ .width = @floatFromInt(width), .height = @floatFromInt(height) },
    };

    std.debug.print("Frame generated {d} draw commands\n", .{draw_data.commandCount()});
    std.debug.print("Display size: {d}x{d}\n", .{ width, height });

    const iface = backend.interface();
    iface.beginFrame(&draw_data);
    iface.render(&draw_data);
    iface.endFrame();

    // Output
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const output_path = if (args.len > 1) args[1] else "gui_demo.ppm";

    const file = try std.fs.cwd().createFile(output_path, .{});
    defer file.close();

    try backend.writePPM(file.writer());

    std.debug.print("Rendered to {s}\n", .{output_path});
}

fn drawComment(draw: *DrawList, x: f32, y: f32, avatar_color: Color, text_width: f32, with_reaction: bool) void {
    // Avatar
    draw.addFilledRectEx(
        Rect{ .x = x, .y = y, .width = 32, .height = 32 },
        avatar_color,
        16,
    );

    // Author name
    draw.addFilledRectEx(
        Rect{ .x = x + 44, .y = y + 2, .width = 80, .height = 10 },
        colors.text_primary,
        2,
    );

    // Timestamp
    draw.addFilledRectEx(
        Rect{ .x = x + 132, .y = y + 4, .width = 50, .height = 8 },
        colors.text_muted,
        2,
    );

    // Comment text
    draw.addFilledRectEx(
        Rect{ .x = x + 44, .y = y + 22, .width = text_width, .height = 8 },
        colors.text_secondary,
        2,
    );
    draw.addFilledRectEx(
        Rect{ .x = x + 44, .y = y + 36, .width = text_width - 60, .height = 8 },
        colors.text_secondary,
        2,
    );

    // Reaction emoji (if present)
    if (with_reaction) {
        draw.addFilledRectEx(
            Rect{ .x = x + 44, .y = y + 54, .width = 36, .height = 22 },
            colors.bg_input,
            11,
        );
        draw.addFilledRectEx(
            Rect{ .x = x + 52, .y = y + 60, .width = 10, .height = 10 },
            colors.status_in_progress,
            5,
        );
        draw.addFilledRectEx(
            Rect{ .x = x + 66, .y = y + 62, .width = 8, .height = 6 },
            colors.text_muted,
            2,
        );
    }
}

fn drawProperty(draw: *DrawList, x: f32, y: f32, icon_color: Color, text_width: f32, panel_width: f32) void {
    _ = panel_width;

    // Label
    draw.addFilledRectEx(
        Rect{ .x = x, .y = y, .width = 50, .height = 8 },
        colors.text_muted,
        2,
    );

    // Value with icon
    draw.addFilledRectEx(
        Rect{ .x = x, .y = y + 16, .width = 14, .height = 14 },
        icon_color,
        3,
    );
    draw.addFilledRectEx(
        Rect{ .x = x + 20, .y = y + 18, .width = text_width, .height = 10 },
        colors.text_secondary,
        2,
    );
}
