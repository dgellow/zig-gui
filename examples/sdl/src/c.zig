pub const mod = @cImport({
    @cDefine("SDL_MAIN_HANDLED", {}); // We are providing our own entry point
    @cDefine("SDL_DISABLE_OLD_NAMES", {});
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3/SDL_revision.h");
    @cInclude("SDL3/SDL_main.h");
    @cInclude("SDL3/SDL_rect.h");
    @cInclude("SDL3/SDL_error.h");
});
