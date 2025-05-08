const std = @import("std");
const testing = std.testing;
pub const c = @cImport({
    @cInclude("clay.h");
});

const ClayString = extern struct {
    const Self = @This();

    length: i32,
    chars: [*c]const u8,

    pub fn new(str: []const u8) Self {
        return .{ .length = @intCast(str.len), .chars = str.ptr };
    }

    pub fn to_clay(self: Self) c.Clay_String {
        return c.Clay_String{
            .length = self.length,
            .chars = self.chars,
        };
    }

    // pub fn slice(self: Self) []const u8 {
    //     if (self.length <= 0) {
    //         return "";
    //     }
    //     return self.chars[0..@intCast(self.length)];
    // }
};

pub fn id(key: []const u8) c.Clay_ElementId {
    return idi(key, 0);
}

pub fn idi(key: []const u8, index: u32) c.Clay_ElementId {
    const str = ClayString.new(key);
    const hash_string = c.Clay__HashString(str.to_clay(), index, 0);

    return .{
        .id = hash_string.id,
        .offset = hash_string.offset,
        .baseId = hash_string.baseId,
        .stringId = str.to_clay(),
    };
}

const ClayElement = struct {
    id: c.Clay_ElementId,
    layout: ?c.Clay_LayoutConfig,
    backgroundColor: ?c.Clay_Color,
    cornerRadius: ?c.Clay_CornerRadius,
    image: ?c.Clay_ImageElementConfig,
    floating: ?c.Clay_FloatingElementConfig,
    custom: ?c.Clay_CustomElementConfig,
    clip: ?c.Clay_ClipElementConfig,
    border: ?c.Clay_BorderElementConfig,
    userData: ?*anyopaque,

    children: ?[]const ClayElement,

    pub fn elem_decl(self: *const ClayElement) c.Clay_ElementDeclaration {
        const elem = c.Clay_ElementDeclaration{};
        elem.id = self.id;
        if (self.layout) |layout| {
            elem.layout = layout;
        }
        if (self.backgroundColor) |bg_color| {
            elem.backgroundColor = bg_color;
        }
        if (self.cornerRadius) |corner_radius| {
            elem.cornerRadius = corner_radius;
        }
        if (self.image) |image| {
            elem.image = image;
        }
        if (self.floating) |floating| {
            elem.floating = floating;
        }
        if (self.custom) |custom| {
            elem.custom = custom;
        }
        if (self.clip) |clip| {
            elem.clip = clip;
        }
        if (self.border) |border| {
            elem.border = border;
        }
        if (self.userData) |user_data| {
            elem.userData = user_data;
        }
        return elem;
    }
};

/// Replicate the CLAY macro, in a way usable in Zig.
///
/// Original C code:
// /* This macro looks scary on the surface, but is actually quite simple.
//   It turns a macro call like this:

//   CLAY({
//     .id = CLAY_ID("Container"),
//     .backgroundColor = { 255, 200, 200, 255 }
//   }) {
//       ...children declared here
//   }

//   Into calls like this:

//   Clay_OpenElement();
//   Clay_ConfigureOpenElement((Clay_ElementDeclaration) {
//     .id = CLAY_ID("Container"),
//     .backgroundColor = { 255, 200, 200, 255 }
//   });
//   ...children declared here
//   Clay_CloseElement();

//   The for loop will only ever run a single iteration, putting Clay__CloseElement() in the increment of the loop
//   means that it will run after the body - where the children are declared. It just exists to make sure you don't forget
//   to call Clay_CloseElement().
// */
// #define CLAY(...)                                                                                                                                           \
//     for (                                                                                                                                                   \
//         CLAY__ELEMENT_DEFINITION_LATCH = (Clay__OpenElement(), Clay__ConfigureOpenElement(CLAY__CONFIG_WRAPPER(Clay_ElementDeclaration, __VA_ARGS__)), 0);  \
//         CLAY__ELEMENT_DEFINITION_LATCH < 1;                                                                                                                 \
//         CLAY__ELEMENT_DEFINITION_LATCH=1, Clay__CloseElement()                                                                                              \
//     )

pub fn clay(elem: ClayElement) void {
    c.Clay__OpenElement();
    c.Clay__ConfigureOpenElement(elem.elem_decl());
    if (elem.children) |children| {
        for (children) |child| {
            clay(child);
        }
    }
    c.Clay__CloseElement();
}

test "clay" {
    const min_memory_size = c.Clay_MinMemorySize();
    const memory = std.heap.c_allocator.alloc(u8, min_memory_size) catch unreachable;
    const arena = c.Clay_CreateArenaWithCapacityAndMemory(min_memory_size, @ptrCast(memory));

    const S = struct {
        pub fn handle_error(error_data: c.Clay_ErrorData) callconv(.c) void {
            std.debug.print("Error: {s}\n", .{error_data.errorText.chars});
            unreachable;
        }
    };

    const error_handler = c.Clay_ErrorHandler{
        .errorHandlerFunction = S.handle_error,
    };

    const dimensions = c.Clay_Dimensions{
        .width = 200,
        .height = 200,
    };

    _ = c.Clay_Initialize(
        arena,
        dimensions,
        error_handler,
    );

    c.Clay_SetLayoutDimensions(dimensions);
    c.Clay_SetPointerState(.{ .x = 0, .y = 0 }, false);

    c.Clay_BeginLayout();

    clay(
        .{
            .id = id("Container"),
            .backgroundColor = c.Clay_Color{ .r = 255, .g = 200, .b = 200, .a = 255 },
            .children = &[_]ClayElement{
                .{
                    .id = id("Child"),
                    .backgroundColor = c.Clay_Color{ .r = 0, .g = 255, .b = 0, .a = 255 },
                    .layout = c.Clay_LayoutConfig{
                        .sizing = .{
                            .width = c.CLAY_SIZING_GROW,
                            .height = 100,
                        },
                        .padding = .{
                            .left = 10,
                            .top = 10,
                            .right = 10,
                            .bottom = 10,
                        },
                    },
                },
            },
        },
    );
    const render_commands = c.Clay_EndLayout();

    testing.expectEqual(1, render_commands.length);
}
