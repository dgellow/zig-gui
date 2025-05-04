pub const Rect = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,

    pub fn zero() Rect {
        return Rect{ .x = 0, .y = 0, .width = 0, .height = 0 };
    }

    pub fn size(self: *const Rect) Size {
        return Size{ .width = self.width, .height = self.height };
    }
};

pub const Point = struct {
    x: f32,
    y: f32,

    pub fn zero() Point {
        return Point{ .x = 0, .y = 0 };
    }
};

pub const Size = struct {
    width: f32,
    height: f32,

    pub fn zero() Size {
        return Size{ .width = 0, .height = 0 };
    }
};

pub const EdgeInsets = struct {
    left: f32,
    top: f32,
    right: f32,
    bottom: f32,

    pub fn zero() EdgeInsets {
        return EdgeInsets{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    }
};
