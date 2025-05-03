pub const FontHandle = struct {
    id: u64,

    pub const invalid = FontHandle{ .id = 0 };

    pub fn isValid(self: FontHandle) bool {
        return self.id != 0;
    }
};
