const std = @import("std");
const Color = @import("core/color.zig").Color;
const EdgeInsets = @import("core/geometry.zig").EdgeInsets;
const Size = @import("core/geometry.zig").Size;

/// Color scheme for themes (light or dark mode)
pub const ColorScheme = enum {
    light,
    dark,
};

/// Font weight values
pub const FontWeight = enum {
    thin,
    extra_light,
    light,
    regular,
    medium,
    semi_bold,
    bold,
    extra_bold,
    black,

    pub fn toNumber(self: FontWeight) f32 {
        return switch (self) {
            .thin => 100.0,
            .extra_light => 200.0,
            .light => 300.0,
            .regular => 400.0,
            .medium => 500.0,
            .semi_bold => 600.0,
            .bold => 700.0,
            .extra_bold => 800.0,
            .black => 900.0,
        };
    }
};

/// Text alignment
pub const TextAlign = enum {
    left,
    center,
    right,
    justify,
};

/// Font style
pub const FontStyle = enum {
    normal,
    italic,
    oblique,
};

/// Typography settings for a theme
pub const Typography = struct {
    font_family: ?[]const u8 = null,

    // Font sizes
    font_size_small: f32 = 12.0,
    font_size_medium: f32 = 14.0,
    font_size_large: f32 = 16.0,
    font_size_xlarge: f32 = 18.0,
    font_size_xxlarge: f32 = 24.0,

    // Font weights
    weight_normal: FontWeight = .regular,
    weight_bold: FontWeight = .bold,
    weight_heading: FontWeight = .semi_bold,

    // Line heights
    line_height_tight: f32 = 1.2,
    line_height_normal: f32 = 1.5,
    line_height_loose: f32 = 1.8,

    /// Create a copy of this typography
    pub fn clone(self: Typography, allocator: std.mem.Allocator) !Typography {
        return Typography{
            .font_family = try allocator.dupe(u8, self.font_family),
            .font_size_small = self.font_size_small,
            .font_size_medium = self.font_size_medium,
            .font_size_large = self.font_size_large,
            .font_size_xlarge = self.font_size_xlarge,
            .font_size_xxlarge = self.font_size_xxlarge,
            .weight_normal = self.weight_normal,
            .weight_bold = self.weight_bold,
            .weight_heading = self.weight_heading,
            .line_height_tight = self.line_height_tight,
            .line_height_normal = self.line_height_normal,
            .line_height_loose = self.line_height_loose,
        };
    }

    /// Free resources used by this typography
    pub fn deinit(self: *Typography, allocator: std.mem.Allocator) void {
        if (self.font_family) |font_family| {
            allocator.free(font_family);
        }
    }
};

/// Metrics for sizing and spacing
pub const Metrics = struct {
    // Spacing units
    spacing_xxsmall: f32 = 2.0,
    spacing_xsmall: f32 = 4.0,
    spacing_small: f32 = 8.0,
    spacing_medium: f32 = 16.0,
    spacing_large: f32 = 24.0,
    spacing_xlarge: f32 = 32.0,
    spacing_xxlarge: f32 = 48.0,

    // Border radii
    radius_small: f32 = 2.0,
    radius_medium: f32 = 4.0,
    radius_large: f32 = 8.0,
    radius_xlarge: f32 = 16.0,
    radius_circle: f32 = 9999.0,

    // Border widths
    border_width_thin: f32 = 1.0,
    border_width_medium: f32 = 2.0,
    border_width_thick: f32 = 4.0,

    // Shadow properties
    shadow_small_radius: f32 = 2.0,
    shadow_medium_radius: f32 = 4.0,
    shadow_large_radius: f32 = 8.0,

    // Misc
    icon_size_small: f32 = 16.0,
    icon_size_medium: f32 = 24.0,
    icon_size_large: f32 = 32.0,
};

/// Color palette for a theme
pub const ColorPalette = struct {
    // Primary colors
    primary: Color,
    primary_light: Color,
    primary_dark: Color,

    // Accent colors
    accent: Color,
    accent_light: Color,
    accent_dark: Color,

    // Neutral colors
    background: Color,
    surface: Color,
    erroneous: Color,

    // Text colors
    text_primary: Color,
    text_secondary: Color,
    text_hint: Color,
    text_disabled: Color,

    // Other UI colors
    divider: Color,
    disabled: Color,

    /// Create a default light color palette
    pub fn defaultLight() ColorPalette {
        return ColorPalette{
            .primary = Color.fromRGB(33, 150, 243),
            .primary_light = Color.fromRGB(66, 175, 255),
            .primary_dark = Color.fromRGB(30, 136, 229),

            .accent = Color.fromRGB(255, 64, 129),
            .accent_light = Color.fromRGB(255, 121, 168),
            .accent_dark = Color.fromRGB(200, 30, 93),

            .background = Color.fromRGB(250, 250, 250),
            .surface = Color.fromRGB(255, 255, 255),
            .erroneous = Color.fromRGB(244, 67, 54),

            .text_primary = Color.fromRGB(33, 33, 33),
            .text_secondary = Color.fromRGB(117, 117, 117),
            .text_hint = Color.fromRGB(180, 180, 180),
            .text_disabled = Color.fromRGB(200, 200, 200),

            .divider = Color.fromRGBA(0, 0, 0, 38),
            .disabled = Color.fromRGBA(0, 0, 0, 38),
        };
    }

    /// Create a default dark color palette
    pub fn defaultDark() ColorPalette {
        return ColorPalette{
            .primary = Color.fromRGB(33, 150, 243),
            .primary_light = Color.fromRGB(66, 175, 255),
            .primary_dark = Color.fromRGB(30, 136, 229),

            .accent = Color.fromRGB(255, 64, 129),
            .accent_light = Color.fromRGB(255, 121, 168),
            .accent_dark = Color.fromRGB(200, 30, 93),

            .background = Color.fromRGB(18, 18, 18),
            .surface = Color.fromRGB(30, 30, 30),
            .erroneous = Color.fromRGB(244, 67, 54),

            .text_primary = Color.fromRGB(255, 255, 255),
            .text_secondary = Color.fromRGB(200, 200, 200),
            .text_hint = Color.fromRGB(160, 160, 160),
            .text_disabled = Color.fromRGB(120, 120, 120),

            .divider = Color.fromRGBA(255, 255, 255, 38),
            .disabled = Color.fromRGBA(255, 255, 255, 38),
        };
    }
};

/// Platform-specific adaptations
pub const PlatformAdaptations = struct {
    button_radius: f32 = 4.0,
    control_radius: f32 = 2.0,
    animation_speed_factor: f32 = 1.0,
    font_size_multiplier: f32 = 1.0,
    density_scale: f32 = 1.0,
    touch_target_min_size: Size = .{ .width = 48.0, .height = 48.0 },
    scroll_friction: f32 = 0.015,
    scroll_spring_stiffness: f32 = 180.0,
};

/// Style for a component
pub const Style = struct {
    // Background
    background_color: ?Color = null,

    // Border
    border_color: ?Color = null,
    border_width: ?f32 = null,
    border_radius: ?f32 = null,

    // Padding and margin
    padding: EdgeInsets = EdgeInsets.zero(),
    margin: EdgeInsets = EdgeInsets.zero(),

    // Size constraints
    width: ?f32 = null,
    height: ?f32 = null,
    min_width: ?f32 = null,
    min_height: ?f32 = null,
    max_width: ?f32 = null,
    max_height: ?f32 = null,

    // Text styling
    font_family: ?[]const u8 = null,
    font_size: ?f32 = null,
    font_weight: ?FontWeight = null,
    font_style: ?FontStyle = null,
    text_color: ?Color = null,
    text_align: ?TextAlign = null,
    line_height: ?f32 = null,

    // Effects
    opacity: ?f32 = null,
    shadow_radius: ?f32 = null,
    shadow_color: ?Color = null,
    shadow_offset_x: ?f32 = null,
    shadow_offset_y: ?f32 = null,

    /// Create default style
    pub fn default() Style {
        return .{};
    }

    // Helper function to merge optional values
    inline fn mergeOpt(comptime T: type, dst: *?T, src: ?T) void {
        if (src != null) dst.* = src;
    }

    /// Merge two styles, with 'other' taking precedence
    pub fn merge(self: Style, other: Style, allocator: std.mem.Allocator) !Style {
        var result = self;

        // Background
        mergeOpt(Color, &result.background_color, other.background_color);

        // Border
        mergeOpt(Color, &result.border_color, other.border_color);
        mergeOpt(f32, &result.border_width, other.border_width);
        mergeOpt(f32, &result.border_radius, other.border_radius);

        // Padding and margin
        result.padding = result.padding.merge(other.padding);
        result.margin = result.margin.merge(other.margin);

        // Size constraints
        mergeOpt(f32, &result.width, other.width);
        mergeOpt(f32, &result.height, other.height);
        mergeOpt(f32, &result.min_width, other.min_width);
        mergeOpt(f32, &result.min_height, other.min_height);
        mergeOpt(f32, &result.max_width, other.max_width);
        mergeOpt(f32, &result.max_height, other.max_height);

        // Text styling
        if (other.font_family) |font_family| {
            result.font_family = try allocator.dupe(u8, font_family);
        }
        mergeOpt(f32, &result.font_size, other.font_size);
        mergeOpt(FontWeight, &result.font_weight, other.font_weight);
        mergeOpt(FontStyle, &result.font_style, other.font_style);
        mergeOpt(Color, &result.text_color, other.text_color);
        mergeOpt(TextAlign, &result.text_align, other.text_align);
        mergeOpt(f32, &result.line_height, other.line_height);

        // Effects
        mergeOpt(f32, &result.opacity, other.opacity);
        mergeOpt(f32, &result.shadow_radius, other.shadow_radius);
        mergeOpt(Color, &result.shadow_color, other.shadow_color);
        mergeOpt(f32, &result.shadow_offset_x, other.shadow_offset_x);
        mergeOpt(f32, &result.shadow_offset_y, other.shadow_offset_y);

        return result;
    }

    /// Clean up resources used by this style
    pub fn deinit(self: *Style, allocator: std.mem.Allocator) void {
        if (self.font_family) |font_family| {
            allocator.free(font_family);
        }
    }

    /// Clone this style
    pub fn clone(self: Style, allocator: std.mem.Allocator) !Style {
        var result = self;
        if (self.font_family) |font_family| {
            result.font_family = try allocator.dupe(u8, font_family);
        }
        return result;
    }
};

/// Component-specific styles
pub const ComponentStyle = struct {
    base: Style,
    states: std.StringHashMap(Style),

    /// Initialize a new component style
    pub fn init(allocator: std.mem.Allocator, base: Style) !*ComponentStyle {
        const component_style = try allocator.create(ComponentStyle);
        component_style.* = .{
            .base = base,
            .states = std.StringHashMap(Style).init(allocator),
        };
        return component_style;
    }

    /// Add a state-specific style
    pub fn addState(self: *ComponentStyle, state: []const u8, style: Style) !void {
        try self.states.put(state, style);
    }

    /// Get style for a specific state
    pub fn getStyleForState(self: *ComponentStyle, state: ?[]const u8, allocator: std.mem.Allocator) !Style {
        if (state == null) {
            return try self.base.clone(allocator);
        }

        if (self.states.get(state.?)) |state_style| {
            return try self.base.merge(state_style, allocator);
        }

        return try self.base.clone(allocator);
    }

    /// Clean up resources
    pub fn deinit(self: *ComponentStyle, allocator: std.mem.Allocator) void {
        self.base.deinit(allocator);

        var it = self.states.valueIterator();
        while (it.next()) |style| {
            style.deinit(allocator);
        }

        self.states.deinit();
        allocator.destroy(self);
    }
};

/// Theme definition
pub const Theme = struct {
    colors: ColorPalette,
    typography: Typography,
    metrics: Metrics,
    component_styles: std.StringHashMap(*ComponentStyle),
    platform_adaptations: PlatformAdaptations,
    color_scheme: ColorScheme = .light,

    /// Initialize a new theme
    pub fn init(allocator: std.mem.Allocator, color_scheme: ColorScheme) !*Theme {
        const theme = try allocator.create(Theme);

        theme.* = .{
            .colors = switch (color_scheme) {
                .light => ColorPalette.defaultLight(),
                .dark => ColorPalette.defaultDark(),
            },
            .typography = Typography{},
            .metrics = Metrics{},
            .component_styles = std.StringHashMap(*ComponentStyle).init(allocator),
            .platform_adaptations = PlatformAdaptations{},
            .color_scheme = color_scheme,
        };

        return theme;
    }

    /// Add a component style to the theme
    pub fn addComponentStyle(self: *Theme, component_type: []const u8, style: *ComponentStyle) !void {
        try self.component_styles.put(component_type, style);
    }

    /// Get component style from the theme
    pub fn getComponentStyle(self: *Theme, component_type: []const u8) ?*ComponentStyle {
        return self.component_styles.get(component_type);
    }

    /// Clean up resources
    pub fn deinit(self: *Theme, allocator: std.mem.Allocator) void {
        self.typography.deinit(allocator);

        var it = self.component_styles.valueIterator();
        while (it.next()) |component_style| {
            component_style.*.deinit(allocator);
        }

        self.component_styles.deinit();
        allocator.destroy(self);
    }
};

/// The style system manages themes and component styles
pub const StyleSystem = struct {
    allocator: std.mem.Allocator,

    themes: std.StringHashMap(*Theme),
    active_theme: *Theme,

    style_cache: std.AutoHashMap(u64, Style),

    /// Initialize style system
    pub fn init(allocator: std.mem.Allocator, theme_name: []const u8) !*StyleSystem {
        const system = try allocator.create(StyleSystem);
        system.* = .{
            .allocator = allocator,
            .themes = std.StringHashMap(*Theme).init(allocator),
            .style_cache = std.AutoHashMap(u64, Style).init(allocator),
            .active_theme = undefined, // Set below
        };

        // Create default light theme
        const default_theme = try Theme.init(allocator, .light);
        try system.themes.put("default", default_theme);

        // Create default dark theme
        const dark_theme = try Theme.init(allocator, .dark);
        try system.themes.put("dark", dark_theme);

        // Set active theme
        if (system.themes.get(theme_name)) |theme| {
            system.active_theme = theme;
        } else {
            system.active_theme = default_theme;
        }

        // Initialize with some default component styles
        try system.initDefaultComponentStyles();

        return system;
    }

    /// Clean up resources
    pub fn deinit(self: *StyleSystem) void {
        var theme_it = self.themes.valueIterator();
        while (theme_it.next()) |theme| {
            theme.*.deinit(self.allocator);
        }

        self.themes.deinit();
        self.style_cache.deinit();
        self.allocator.destroy(self);
    }

    /// Get the computed style for a component
    pub fn getStyleForComponent(self: *StyleSystem, component_type: []const u8, state: ?[]const u8, custom_style: ?Style) !Style {
        // Create a cache key
        var hasher = std.hash.Wyhash.init(0);
        std.hash.autoHash(&hasher, component_type);
        if (state) |s| {
            std.hash.autoHash(&hasher, s);
        }
        if (custom_style != null) {
            // Not caching custom styles for now, as they could vary widely
            std.hash.autoHash(&hasher, @intFromPtr(&custom_style));
        }

        const cache_key = hasher.final();

        // Try to get from cache if no custom style
        if (custom_style == null) {
            if (self.style_cache.get(cache_key)) |cached_style| {
                return try cached_style.clone(self.allocator);
            }
        }

        // Get theme style for component type
        var computed_style = Style.default();

        if (self.active_theme.getComponentStyle(component_type)) |component_style| {
            computed_style = try component_style.getStyleForState(state, self.allocator);
        }

        // Merge with custom style if provided
        if (custom_style) |custom| {
            computed_style = try computed_style.merge(custom, self.allocator);
        } else {
            // Store in cache if no custom style
            try self.style_cache.put(cache_key, try computed_style.clone(self.allocator));
        }

        return computed_style;
    }

    /// Set the active theme
    pub fn setActiveTheme(self: *StyleSystem, theme_name: []const u8) !void {
        if (self.themes.get(theme_name)) |theme| {
            self.active_theme = theme;
            self.style_cache.clearRetainingCapacity();
        } else {
            return error.ThemeNotFound;
        }
    }

    /// Add a new theme
    pub fn addTheme(self: *StyleSystem, name: []const u8, theme: *Theme) !void {
        try self.themes.put(name, theme);
    }

    /// Get the color scheme of the active theme
    pub fn getColorScheme(self: *StyleSystem) ColorScheme {
        return self.active_theme.color_scheme;
    }

    /// Initialize the style system with default component styles
    fn initDefaultComponentStyles(self: *StyleSystem) !void {
        // Example: Button styles
        {
            const button_style = try ComponentStyle.init(self.allocator, .{
                .background_color = self.active_theme.colors.primary,
                .border_radius = self.active_theme.metrics.radius_medium,
                .padding = .{ .left = 16.0, .right = 16.0, .top = 8.0, .bottom = 8.0 },
                .text_color = Color.fromRGB(255, 255, 255),
                .font_weight = .medium,
            });

            // Hover state
            try button_style.addState("hover", .{
                .background_color = self.active_theme.colors.primary_light,
            });

            // Pressed state
            try button_style.addState("pressed", .{
                .background_color = self.active_theme.colors.primary_dark,
            });

            // Disabled state
            try button_style.addState("disabled", .{
                .background_color = self.active_theme.colors.disabled,
                .text_color = self.active_theme.colors.text_disabled,
            });

            try self.active_theme.addComponentStyle("button", button_style);
        }

        // Example: Text styles
        {
            const text_style = try ComponentStyle.init(self.allocator, .{
                .text_color = self.active_theme.colors.text_primary,
                .font_size = self.active_theme.typography.font_size_medium,
                .font_weight = self.active_theme.typography.weight_normal,
                .line_height = self.active_theme.typography.line_height_normal,
            });

            try self.active_theme.addComponentStyle("text", text_style);
        }

        // Add more default component styles as needed...
    }
};
