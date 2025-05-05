const std = @import("std");
const testing = std.testing;
pub const clay = @cImport({
    @cInclude("clay.h");
});

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
const Element = struct {
    elem_decl: clay.Clay_ElementDeclaration,
    children: ?[]const Element,
};

pub fn decl(elem_decl: clay.Clay_ElementDeclaration, children: ?[]const Element) void {
    clay.Clay__OpenElement();
    clay.Clay__ConfigureOpenElement(elem_decl);
    if (children) |chs| {
        for (chs) |child| {
            decl(child.elem_decl, child.children);
        }
    }
    clay.Clay__CloseElement();
}

test "clay" {
    const min_memory_size = clay.Clay_MinMemorySize();
    const arena = clay.Clay_CreateArenaWithCapacityAndMemory(std.heap.c_allocator, min_memory_size);

    const S = struct {
        pub fn handle_error(error_data: clay.Clay_ErrorData) void {
            std.debug.print("Error: {s}\n", .{error_data.errorText.chars});
            unreachable;
        }
    };

    const error_handler = clay.Clay_ErrorHandler{
        .errorHandlerFunction = S.handle_error,
    };

    const dimensions = clay.Clay_Dimensions{
        .width = 200,
        .height = 200,
    };

    _ = clay.Clay_Initialize(
        arena,
        dimensions,
        error_handler,
    );

    clay.Clay_SetLayoutDimensions(dimensions);
    clay.Clay_SetPointerState(.{ .x = 0, .y = 0 }, false);

    clay.Clay_BeginLayout();

    decl(
        clay.Clay_ElementDeclaration{
            .id = clay.CLAY_ID("Container"),
            .backgroundColor = clay.Clay_Color{ .r = 255, .g = 200, .b = 200, .a = 255 },
        },
    );
    const render_commands = clay.Clay_EndLayout();

    testing.expectEqual(1, render_commands.length);
}
