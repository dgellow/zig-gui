const std = @import("std");
const Point = @import("geometry.zig").Point;
const Rect = @import("geometry.zig").Rect;

pub const Path = struct {
    commands: std.ArrayList(Command),
    points: std.ArrayList(Point),

    pub fn init(allocator: std.mem.Allocator) Path {
        return .{
            .commands = std.ArrayList(Command).init(allocator),
            .points = std.ArrayList(Point).init(allocator),
        };
    }

    pub fn deinit(self: *Path) void {
        self.commands.deinit();
        self.points.deinit();
    }

    pub fn moveTo(self: *Path, x: f32, y: f32) !void {
        try self.commands.append(.move_to);
        try self.points.append(.{ .x = x, .y = y });
    }

    pub fn lineTo(self: *Path, x: f32, y: f32) !void {
        try self.commands.append(.line_to);
        try self.points.append(.{ .x = x, .y = y });
    }

    pub fn quadTo(self: *Path, cx: f32, cy: f32, x: f32, y: f32) !void {
        try self.commands.append(.quad_to);
        try self.points.append(.{ .x = cx, .y = cy });
        try self.points.append(.{ .x = x, .y = y });
    }

    pub fn cubicTo(self: *Path, cx1: f32, cy1: f32, cx2: f32, cy2: f32, x: f32, y: f32) !void {
        try self.commands.append(.cubic_to);
        try self.points.append(.{ .x = cx1, .y = cy1 });
        try self.points.append(.{ .x = cx2, .y = cy2 });
        try self.points.append(.{ .x = x, .y = y });
    }

    pub fn arcTo(self: *Path, rx: f32, ry: f32, angle: f32, large_arc: bool, sweep: bool, x: f32, y: f32) !void {
        try self.commands.append(.arc_to);
        // Store arc parameters - we're using point.x/y for parameters that aren't coordinates
        try self.points.append(.{ .x = rx, .y = ry });
        try self.points.append(.{ .x = angle, .y = @intFromBool(large_arc) });
        try self.points.append(.{ .x = @intFromBool(sweep), .y = 0 });
        try self.points.append(.{ .x = x, .y = y });
    }

    pub fn close(self: *Path) !void {
        try self.commands.append(.close);
    }

    pub fn reset(self: *Path) void {
        self.commands.clearRetainingCapacity();
        self.points.clearRetainingCapacity();
    }

    // Add rectangle to path
    pub fn addRect(self: *Path, rect: Rect) !void {
        try self.moveTo(rect.x, rect.y);
        try self.lineTo(rect.x + rect.width, rect.y);
        try self.lineTo(rect.x + rect.width, rect.y + rect.height);
        try self.lineTo(rect.x, rect.y + rect.height);
        try self.close();
    }

    // Add rounded rectangle to path
    pub fn addRoundRect(self: *Path, rect: Rect, radius: f32) !void {
        const r = @min(radius, @min(rect.width, rect.height) / 2.0);

        try self.moveTo(rect.x + r, rect.y);
        try self.lineTo(rect.x + rect.width - r, rect.y);
        try self.quadTo(rect.x + rect.width, rect.y, rect.x + rect.width, rect.y + r);
        try self.lineTo(rect.x + rect.width, rect.y + rect.height - r);
        try self.quadTo(rect.x + rect.width, rect.y + rect.height, rect.x + rect.width - r, rect.y + rect.height);
        try self.lineTo(rect.x + r, rect.y + rect.height);
        try self.quadTo(rect.x, rect.y + rect.height, rect.x, rect.y + rect.height - r);
        try self.lineTo(rect.x, rect.y + r);
        try self.quadTo(rect.x, rect.y, rect.x + r, rect.y);
        try self.close();
    }

    // Add circle to path
    pub fn addCircle(self: *Path, center_x: f32, center_y: f32, radius: f32) !void {
        const c = 0.551915024494; // Magic number for approximating a circle with cubic Béziers
        const ctrl = radius * c;

        try self.moveTo(center_x + radius, center_y);
        try self.cubicTo(center_x + radius, center_y + ctrl, center_x + ctrl, center_y + radius, center_x, center_y + radius);
        try self.cubicTo(center_x - ctrl, center_y + radius, center_x - radius, center_y + ctrl, center_x - radius, center_y);
        try self.cubicTo(center_x - radius, center_y - ctrl, center_x - ctrl, center_y - radius, center_x, center_y - radius);
        try self.cubicTo(center_x + ctrl, center_y - radius, center_x + radius, center_y - ctrl, center_x + radius, center_y);
        try self.close();
    }

    const Command = enum {
        move_to,
        line_to,
        quad_to,
        cubic_to,
        arc_to,
        close,
    };
};
