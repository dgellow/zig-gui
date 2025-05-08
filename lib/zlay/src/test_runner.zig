const std = @import("std");
const zlay = @import("zlay.zig");

test {
    std.testing.refAllDeclsRecursive(zlay);
}