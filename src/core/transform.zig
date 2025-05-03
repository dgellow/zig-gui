const Point = @import("geometry.zig").Point;
const Rect = @import("geometry.zig").Rect;

pub const Transform = struct {
    // Using 3x3 matrix in row-major order
    // [a c e]
    // [b d f]
    // [0 0 1]
    a: f32 = 1.0, // scale x
    b: f32 = 0.0, // skew y
    c: f32 = 0.0, // skew x
    d: f32 = 1.0, // scale y
    e: f32 = 0.0, // translate x
    f: f32 = 0.0, // translate y

    // Create identity transform
    pub fn identity() Transform {
        return .{};
    }

    // Create translation transform
    pub fn translation(tx: f32, ty: f32) Transform {
        return .{
            .e = tx,
            .f = ty,
        };
    }

    // Create scaling transform
    pub fn scaling(sx: f32, sy: f32) Transform {
        return .{
            .a = sx,
            .d = sy,
        };
    }

    // Create rotation transform (angle in radians)
    pub fn rotation(angle: f32) Transform {
        const c = @cos(angle);
        const s = @sin(angle);
        return .{
            .a = c,
            .b = s,
            .c = -s,
            .d = c,
        };
    }

    // Transform a point
    pub fn transformPoint(self: Transform, point: Point) Point {
        return .{
            .x = self.a * point.x + self.c * point.y + self.e,
            .y = self.b * point.x + self.d * point.y + self.f,
        };
    }

    // Combine two transforms
    pub fn concat(self: Transform, other: Transform) Transform {
        return .{
            .a = self.a * other.a + self.c * other.b,
            .b = self.b * other.a + self.d * other.b,
            .c = self.a * other.c + self.c * other.d,
            .d = self.b * other.c + self.d * other.d,
            .e = self.a * other.e + self.c * other.f + self.e,
            .f = self.b * other.e + self.d * other.f + self.f,
        };
    }

    // Invert the transform
    pub fn invert(self: Transform) ?Transform {
        const det = self.a * self.d - self.b * self.c;

        // Check if matrix is invertible
        if (@abs(det) < 1e-6) {
            return null;
        }

        const inv_det = 1.0 / det;

        return .{
            .a = self.d * inv_det,
            .b = -self.b * inv_det,
            .c = -self.c * inv_det,
            .d = self.a * inv_det,
            .e = (self.c * self.f - self.d * self.e) * inv_det,
            .f = (self.b * self.e - self.a * self.f) * inv_det,
        };
    }

    // Create a transform for mapping from one rectangle to another
    pub fn rectToRect(src: Rect, dst: Rect) Transform {
        const sx = dst.width / src.width;
        const sy = dst.height / src.height;
        const tx = dst.x - src.x * sx;
        const ty = dst.y - src.y * sy;

        return .{
            .a = sx,
            .d = sy,
            .e = tx,
            .f = ty,
        };
    }
};
