# zig-gui C API Specification

**The C API that every C developer will love and trust for production use.**

## Design Philosophy

The zig-gui C API is designed around these core principles:

1. **Zero-overhead abstractions**: Direct mapping to Zig internals, no performance cost
2. **Memory safety**: Clear ownership, no hidden allocations, no double-frees
3. **Simplicity**: Intuitive function names, consistent patterns, minimal surface area
4. **ABI stability**: Versioned interface, backward compatibility guarantees
5. **Language friendliness**: Easy to bind from Python, Go, Rust, JavaScript, etc.

## Core Design Patterns

### 1. Consistent Naming Convention
```c
// Pattern: zig_gui_<module>_<action>
zig_gui_app_create()          // Create application
zig_gui_app_destroy()         // Destroy application
zig_gui_state_set_int()       // Set integer state
zig_gui_button()              // Render button
```

### 2. Clear Ownership Model
```c
// Create/destroy pairs - always explicit
ZigGuiApp* app = zig_gui_app_create(ZIG_GUI_EVENT_DRIVEN);
// ... use app ...
zig_gui_app_destroy(app); // Required cleanup

// No hidden allocations, no garbage collection
```

### 3. Explicit Error Handling
```c
// All fallible operations return error codes
ZigGuiError result = zig_gui_app_run(app, ui_function, user_data);
if (result != ZIG_GUI_OK) {
    // Handle error explicitly
    fprintf(stderr, "GUI error: %s\n", zig_gui_error_string(result));
}
```

### 4. Type Safety
```c
// Type-safe enums instead of magic numbers
typedef enum {
    ZIG_GUI_EVENT_DRIVEN,
    ZIG_GUI_GAME_LOOP,
    ZIG_GUI_MINIMAL
} ZigGuiExecutionMode;

// Type-safe state management
zig_gui_state_set_int(state, "counter", 42);
int counter = zig_gui_state_get_int(state, "counter", 0);
```

## Complete C Header File

```c
/**
 * zig-gui C API
 * 
 * The first UI library to solve the impossible trinity:
 * - Performance: 0% idle CPU, 120+ FPS when needed
 * - Developer Experience: Immediate-mode simplicity with hot reload
 * - Universality: Same code from microcontrollers to AAA games
 * 
 * Version: 1.0.0
 * License: MIT
 * 
 * This API is designed to be:
 * - Zero-overhead (direct mapping to Zig internals)
 * - Memory safe (clear ownership, no hidden allocations)
 * - ABI stable (versioned interface, backward compatible)
 * - Language friendly (easy bindings for Python, Go, Rust, JS, etc.)
 */

#ifndef ZIG_GUI_H
#define ZIG_GUI_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

// =============================================================================
// VERSION INFORMATION
// =============================================================================

#define ZIG_GUI_VERSION_MAJOR 1
#define ZIG_GUI_VERSION_MINOR 0
#define ZIG_GUI_VERSION_PATCH 0

/**
 * Get the version string of the zig-gui library.
 * @return Version string (e.g., "1.0.0")
 */
const char* zig_gui_version(void);

/**
 * Get the version as integers.
 * @param major Output parameter for major version
 * @param minor Output parameter for minor version  
 * @param patch Output parameter for patch version
 */
void zig_gui_version_numbers(int* major, int* minor, int* patch);

// =============================================================================
// ERROR HANDLING
// =============================================================================

/**
 * Error codes returned by zig-gui functions.
 */
typedef enum {
    ZIG_GUI_OK = 0,                    // Success
    ZIG_GUI_ERROR_OUT_OF_MEMORY,       // Memory allocation failed
    ZIG_GUI_ERROR_INVALID_PARAMETER,   // Invalid parameter passed
    ZIG_GUI_ERROR_PLATFORM_ERROR,      // Platform-specific error
    ZIG_GUI_ERROR_NOT_INITIALIZED,     // Library not initialized
    ZIG_GUI_ERROR_ALREADY_INITIALIZED, // Library already initialized
    ZIG_GUI_ERROR_STATE_NOT_FOUND,     // State key not found
    ZIG_GUI_ERROR_TYPE_MISMATCH,       // State type mismatch
    ZIG_GUI_ERROR_RENDERING_FAILED,    // Rendering operation failed
    ZIG_GUI_ERROR_HOT_RELOAD_FAILED,   // Hot reload operation failed
} ZigGuiError;

/**
 * Get a human-readable error message for an error code.
 * @param error The error code
 * @return Error message string (never NULL)
 */
const char* zig_gui_error_string(ZigGuiError error);

// =============================================================================
// CORE TYPES
// =============================================================================

/**
 * Execution modes for different use cases.
 */
typedef enum {
    ZIG_GUI_EVENT_DRIVEN,  // Desktop apps: 0% idle CPU, blocks on events
    ZIG_GUI_GAME_LOOP,     // Games: Continuous 60+ FPS rendering
    ZIG_GUI_MINIMAL,       // Embedded: Ultra-low resource usage
} ZigGuiExecutionMode;

/**
 * Platform backends for rendering.
 */
typedef enum {
    ZIG_GUI_BACKEND_SOFTWARE,    // Pure CPU rendering (no GPU)
    ZIG_GUI_BACKEND_OPENGL,      // OpenGL 3.3+ hardware acceleration
    ZIG_GUI_BACKEND_VULKAN,      // Vulkan high-performance rendering
    ZIG_GUI_BACKEND_DIRECT2D,    // Windows Direct2D
    ZIG_GUI_BACKEND_METAL,       // macOS/iOS Metal
    ZIG_GUI_BACKEND_FRAMEBUFFER, // Linux framebuffer (embedded)
    ZIG_GUI_BACKEND_CANVAS,      // WebAssembly Canvas
} ZigGuiBackend;

/**
 * Configuration for creating an application.
 */
typedef struct {
    ZigGuiExecutionMode mode;
    ZigGuiBackend backend;
    
    // Window configuration (ignored for embedded/web)
    int window_width;
    int window_height;
    const char* window_title;
    
    // Performance tuning
    int target_fps;              // For game loop mode (default: 60)
    int max_memory_kb;           // Memory budget (default: unlimited)
    
    // Development features
    bool enable_hot_reload;      // Enable hot reload (default: false)
    const char** watch_dirs;     // Directories to watch (NULL-terminated)
    
    // Platform-specific configuration
    void* platform_config;      // Platform-specific data
} ZigGuiConfig;

/**
 * Opaque handle to the GUI application.
 */
typedef struct ZigGuiApp ZigGuiApp;

/**
 * Opaque handle to application state.
 */
typedef struct ZigGuiState ZigGuiState;

/**
 * Event types that can trigger UI updates.
 */
typedef enum {
    ZIG_GUI_EVENT_REDRAW_NEEDED,  // UI needs to be redrawn
    ZIG_GUI_EVENT_INPUT,          // User input occurred
    ZIG_GUI_EVENT_TIMER,          // Timer expired
    ZIG_GUI_EVENT_CUSTOM,         // Custom application event
    ZIG_GUI_EVENT_QUIT,           // Application should quit
} ZigGuiEventType;

/**
 * Event data passed to the application.
 */
typedef struct {
    ZigGuiEventType type;
    void* data;                   // Event-specific data
    uint64_t timestamp;           // Event timestamp
} ZigGuiEvent;

/**
 * UI function signature for rendering the interface.
 * @param app The GUI application handle
 * @param state Application state
 * @param user_data User-provided data
 */
typedef void (*ZigGuiUIFunction)(ZigGuiApp* app, ZigGuiState* state, void* user_data);

// =============================================================================
// APPLICATION LIFECYCLE
// =============================================================================

/**
 * Create a new GUI application with default configuration.
 * @param mode Execution mode for the application
 * @return Application handle, or NULL on failure
 */
ZigGuiApp* zig_gui_app_create(ZigGuiExecutionMode mode);

/**
 * Create a new GUI application with custom configuration.
 * @param config Application configuration
 * @return Application handle, or NULL on failure
 */
ZigGuiApp* zig_gui_app_create_with_config(const ZigGuiConfig* config);

/**
 * Destroy a GUI application and free all resources.
 * @param app Application handle (can be NULL)
 */
void zig_gui_app_destroy(ZigGuiApp* app);

/**
 * Check if the application is still running.
 * @param app Application handle
 * @return true if running, false if should quit
 */
bool zig_gui_app_is_running(ZigGuiApp* app);

/**
 * Request the application to quit.
 * @param app Application handle
 */
void zig_gui_app_quit(ZigGuiApp* app);

/**
 * Run the application main loop.
 * @param app Application handle
 * @param ui_func Function to render the UI
 * @param user_data User data passed to ui_func
 * @return Error code
 */
ZigGuiError zig_gui_app_run(ZigGuiApp* app, ZigGuiUIFunction ui_func, void* user_data);

// =============================================================================
// EVENT HANDLING (Advanced)
// =============================================================================

/**
 * Wait for the next event (event-driven mode only).
 * This blocks until an event occurs, achieving 0% idle CPU usage.
 * @param app Application handle
 * @return Event data
 */
ZigGuiEvent zig_gui_app_wait_event(ZigGuiApp* app);

/**
 * Check for events without blocking (game loop mode).
 * @param app Application handle
 * @param event Output parameter for event data
 * @return true if event available, false if no events
 */
bool zig_gui_app_poll_event(ZigGuiApp* app, ZigGuiEvent* event);

/**
 * Process a single frame update (game loop mode).
 * @param app Application handle
 * @param ui_func Function to render the UI
 * @param user_data User data passed to ui_func
 * @return Error code
 */
ZigGuiError zig_gui_app_update_frame(ZigGuiApp* app, ZigGuiUIFunction ui_func, void* user_data);

// =============================================================================
// STATE MANAGEMENT
// =============================================================================

/**
 * Create a new state container.
 * @return State handle, or NULL on failure
 */
ZigGuiState* zig_gui_state_create(void);

/**
 * Destroy a state container and free all resources.
 * @param state State handle (can be NULL)
 */
void zig_gui_state_destroy(ZigGuiState* state);

/**
 * Clear all state values.
 * @param state State handle
 */
void zig_gui_state_clear(ZigGuiState* state);

// Integer state
ZigGuiError zig_gui_state_set_int(ZigGuiState* state, const char* key, int32_t value);
int32_t zig_gui_state_get_int(ZigGuiState* state, const char* key, int32_t default_value);

// Float state
ZigGuiError zig_gui_state_set_float(ZigGuiState* state, const char* key, float value);
float zig_gui_state_get_float(ZigGuiState* state, const char* key, float default_value);

// Boolean state
ZigGuiError zig_gui_state_set_bool(ZigGuiState* state, const char* key, bool value);
bool zig_gui_state_get_bool(ZigGuiState* state, const char* key, bool default_value);

// String state (copies the string)
ZigGuiError zig_gui_state_set_string(ZigGuiState* state, const char* key, const char* value);
const char* zig_gui_state_get_string(ZigGuiState* state, const char* key, const char* default_value);

// Generic data (copies the data)
ZigGuiError zig_gui_state_set_data(ZigGuiState* state, const char* key, const void* data, size_t size);
const void* zig_gui_state_get_data(ZigGuiState* state, const char* key, size_t* size);

/**
 * Check if a state key exists.
 * @param state State handle
 * @param key State key
 * @return true if key exists, false otherwise
 */
bool zig_gui_state_has_key(ZigGuiState* state, const char* key);

/**
 * Remove a state key.
 * @param state State handle
 * @param key State key to remove
 * @return Error code
 */
ZigGuiError zig_gui_state_remove(ZigGuiState* state, const char* key);

// =============================================================================
// FRAME RENDERING
// =============================================================================

/**
 * Begin a new frame for rendering.
 * Call this before any UI functions in event-driven mode.
 * @param app Application handle
 */
void zig_gui_begin_frame(ZigGuiApp* app);

/**
 * End the current frame and present to screen.
 * Call this after all UI functions in event-driven mode.
 * @param app Application handle
 */
void zig_gui_end_frame(ZigGuiApp* app);

// =============================================================================
// LAYOUT CONTAINERS
// =============================================================================

/**
 * Window configuration for top-level windows.
 */
typedef struct {
    const char* title;           // Window title
    int width, height;           // Window size (-1 for default)
    bool resizable;              // Can window be resized
    bool centered;               // Center window on screen
} ZigGuiWindowConfig;

/**
 * Begin a window container.
 * @param app Application handle
 * @param id Unique window identifier
 * @param config Window configuration (NULL for defaults)
 * @return true if window is open, false if closed
 */
bool zig_gui_window_begin(ZigGuiApp* app, const char* id, const ZigGuiWindowConfig* config);

/**
 * End the current window container.
 * @param app Application handle
 */
void zig_gui_window_end(ZigGuiApp* app);

/**
 * Container configuration for layout containers.
 */
typedef struct {
    float padding_left, padding_top, padding_right, padding_bottom;
    float spacing;               // Space between child elements
    bool horizontal;             // Layout direction (false = vertical)
} ZigGuiContainerConfig;

/**
 * Begin a container for layout.
 * @param app Application handle
 * @param config Container configuration (NULL for defaults)
 */
void zig_gui_container_begin(ZigGuiApp* app, const ZigGuiContainerConfig* config);

/**
 * End the current container.
 * @param app Application handle
 */
void zig_gui_container_end(ZigGuiApp* app);

/**
 * Begin a horizontal row container.
 * @param app Application handle
 */
void zig_gui_row_begin(ZigGuiApp* app);

/**
 * End the current row container.
 * @param app Application handle
 */
void zig_gui_row_end(ZigGuiApp* app);

/**
 * Begin a vertical column container.
 * @param app Application handle
 */
void zig_gui_column_begin(ZigGuiApp* app);

/**
 * End the current column container.
 * @param app Application handle
 */
void zig_gui_column_end(ZigGuiApp* app);

// =============================================================================
// BASIC UI ELEMENTS
// =============================================================================

/**
 * Display text.
 * @param app Application handle
 * @param text Text to display
 */
void zig_gui_text(ZigGuiApp* app, const char* text);

/**
 * Display formatted text.
 * @param app Application handle
 * @param format Printf-style format string
 * @param ... Format arguments
 */
void zig_gui_text_formatted(ZigGuiApp* app, const char* format, ...);

/**
 * Button style configuration.
 */
typedef struct {
    uint32_t background_color;   // RGBA color
    uint32_t text_color;         // RGBA color
    uint32_t border_color;       // RGBA color
    float border_width;          // Border thickness
    float border_radius;         // Corner radius
    float padding;               // Internal padding
} ZigGuiButtonStyle;

/**
 * Render a button.
 * @param app Application handle
 * @param text Button text
 * @return true if button was clicked, false otherwise
 */
bool zig_gui_button(ZigGuiApp* app, const char* text);

/**
 * Render a styled button.
 * @param app Application handle
 * @param text Button text
 * @param style Button style (NULL for default)
 * @return true if button was clicked, false otherwise
 */
bool zig_gui_button_styled(ZigGuiApp* app, const char* text, const ZigGuiButtonStyle* style);

/**
 * Render a checkbox.
 * @param app Application handle
 * @param text Checkbox label
 * @param checked Current state (modified if clicked)
 * @return true if checkbox was clicked, false otherwise
 */
bool zig_gui_checkbox(ZigGuiApp* app, const char* text, bool* checked);

/**
 * Text input configuration.
 */
typedef struct {
    size_t max_length;           // Maximum text length
    bool password;               // Hide text with asterisks
    const char* placeholder;     // Placeholder text
} ZigGuiTextInputConfig;

/**
 * Render a text input field.
 * @param app Application handle
 * @param buffer Text buffer (modified by user input)
 * @param buffer_size Size of text buffer
 * @param config Input configuration (NULL for defaults)
 * @return true if text was modified, false otherwise
 */
bool zig_gui_text_input(ZigGuiApp* app, char* buffer, size_t buffer_size, const ZigGuiTextInputConfig* config);

/**
 * Render a slider.
 * @param app Application handle
 * @param value Current value (modified by user input)
 * @param min Minimum value
 * @param max Maximum value
 * @return true if value was modified, false otherwise
 */
bool zig_gui_slider_float(ZigGuiApp* app, float* value, float min, float max);

/**
 * Render an integer slider.
 * @param app Application handle
 * @param value Current value (modified by user input)
 * @param min Minimum value
 * @param max Maximum value
 * @return true if value was modified, false otherwise
 */
bool zig_gui_slider_int(ZigGuiApp* app, int* value, int min, int max);

/**
 * Render a progress bar.
 * @param app Application handle
 * @param progress Progress value (0.0 to 1.0)
 */
void zig_gui_progress_bar(ZigGuiApp* app, float progress);

// =============================================================================
// ADVANCED UI ELEMENTS
// =============================================================================

/**
 * Color picker configuration.
 */
typedef struct {
    bool show_alpha;             // Show alpha channel
    bool show_preview;           // Show color preview
    bool show_hex_input;         // Show hex input field
} ZigGuiColorPickerConfig;

/**
 * Render a color picker.
 * @param app Application handle
 * @param color RGBA color (modified by user input)
 * @param config Color picker configuration (NULL for defaults)
 * @return true if color was modified, false otherwise
 */
bool zig_gui_color_picker(ZigGuiApp* app, uint32_t* color, const ZigGuiColorPickerConfig* config);

/**
 * List box configuration.
 */
typedef struct {
    int visible_items;           // Number of visible items
    bool multi_select;           // Allow multiple selection
} ZigGuiListBoxConfig;

/**
 * Render a list box.
 * @param app Application handle
 * @param items Array of item strings
 * @param item_count Number of items
 * @param selected Selected item index (modified by user input)
 * @param config List box configuration (NULL for defaults)
 * @return true if selection was modified, false otherwise
 */
bool zig_gui_list_box(ZigGuiApp* app, const char** items, int item_count, int* selected, const ZigGuiListBoxConfig* config);

/**
 * Render a dropdown/combo box.
 * @param app Application handle
 * @param items Array of item strings
 * @param item_count Number of items
 * @param selected Selected item index (modified by user input)
 * @return true if selection was modified, false otherwise
 */
bool zig_gui_dropdown(ZigGuiApp* app, const char** items, int item_count, int* selected);

// =============================================================================
// DATA VISUALIZATION
// =============================================================================

/**
 * Chart configuration.
 */
typedef struct {
    const char* title;           // Chart title
    const char* x_label;         // X-axis label
    const char* y_label;         // Y-axis label
    uint32_t line_color;         // Line color for line charts
    float line_width;            // Line thickness
    bool show_grid;              // Show grid lines
    bool show_legend;            // Show legend
} ZigGuiChartConfig;

/**
 * Data point for charts.
 */
typedef struct {
    float x, y;
} ZigGuiPoint;

/**
 * Render a line chart.
 * @param app Application handle
 * @param points Array of data points
 * @param point_count Number of points
 * @param config Chart configuration (NULL for defaults)
 */
void zig_gui_line_chart(ZigGuiApp* app, const ZigGuiPoint* points, int point_count, const ZigGuiChartConfig* config);

/**
 * Render a bar chart.
 * @param app Application handle
 * @param values Array of values
 * @param labels Array of labels (can be NULL)
 * @param count Number of values/labels
 * @param config Chart configuration (NULL for defaults)
 */
void zig_gui_bar_chart(ZigGuiApp* app, const float* values, const char** labels, int count, const ZigGuiChartConfig* config);

// =============================================================================
// STYLING AND THEMING
// =============================================================================

/**
 * Color constants for convenience.
 */
#define ZIG_GUI_COLOR_WHITE     0xFFFFFFFF
#define ZIG_GUI_COLOR_BLACK     0xFF000000
#define ZIG_GUI_COLOR_RED       0xFF0000FF
#define ZIG_GUI_COLOR_GREEN     0xFF00FF00
#define ZIG_GUI_COLOR_BLUE      0xFFFF0000
#define ZIG_GUI_COLOR_YELLOW    0xFF00FFFF
#define ZIG_GUI_COLOR_CYAN      0xFFFFFF00
#define ZIG_GUI_COLOR_MAGENTA   0xFFFF00FF

/**
 * Create an RGBA color value.
 * @param r Red component (0-255)
 * @param g Green component (0-255)
 * @param b Blue component (0-255)
 * @param a Alpha component (0-255)
 * @return RGBA color value
 */
uint32_t zig_gui_rgba(uint8_t r, uint8_t g, uint8_t b, uint8_t a);

/**
 * Create an RGB color value (full opacity).
 * @param r Red component (0-255)
 * @param g Green component (0-255)
 * @param b Blue component (0-255)
 * @return RGB color value
 */
uint32_t zig_gui_rgb(uint8_t r, uint8_t g, uint8_t b);

/**
 * Built-in themes.
 */
typedef enum {
    ZIG_GUI_THEME_LIGHT,         // Default light theme
    ZIG_GUI_THEME_DARK,          // Dark theme
    ZIG_GUI_THEME_HIGH_CONTRAST, // High contrast theme
    ZIG_GUI_THEME_CUSTOM,        // Custom theme
} ZigGuiTheme;

/**
 * Set the active theme.
 * @param app Application handle
 * @param theme Theme to activate
 */
void zig_gui_set_theme(ZigGuiApp* app, ZigGuiTheme theme);

/**
 * Load a custom theme from a file.
 * @param app Application handle
 * @param theme_file Path to theme file
 * @return Error code
 */
ZigGuiError zig_gui_load_theme_file(ZigGuiApp* app, const char* theme_file);

// =============================================================================
// HOT RELOAD (Development)
// =============================================================================

/**
 * Enable hot reload for development.
 * @param app Application handle
 * @param watch_dirs NULL-terminated array of directories to watch
 * @return Error code
 */
ZigGuiError zig_gui_enable_hot_reload(ZigGuiApp* app, const char** watch_dirs);

/**
 * Disable hot reload.
 * @param app Application handle
 */
void zig_gui_disable_hot_reload(ZigGuiApp* app);

/**
 * Check for and process hot reload updates.
 * Call this periodically in development mode.
 * @param app Application handle
 * @return Error code
 */
ZigGuiError zig_gui_process_hot_reload(ZigGuiApp* app);

// =============================================================================
// PERFORMANCE AND DEBUGGING
// =============================================================================

/**
 * Performance statistics.
 */
typedef struct {
    float frame_time_ms;         // Time to render last frame
    float cpu_usage_percent;     // CPU usage percentage
    size_t memory_usage_bytes;   // Current memory usage
    int frames_per_second;       // Current FPS
    size_t draw_calls;           // Number of draw calls last frame
} ZigGuiPerfStats;

/**
 * Get performance statistics.
 * @param app Application handle
 * @return Performance statistics
 */
ZigGuiPerfStats zig_gui_get_perf_stats(ZigGuiApp* app);

/**
 * Enable performance profiling.
 * @param app Application handle
 * @param enabled True to enable, false to disable
 */
void zig_gui_set_profiling_enabled(ZigGuiApp* app, bool enabled);

/**
 * Show debug overlay with performance information.
 * @param app Application handle
 * @param visible True to show, false to hide
 */
void zig_gui_show_debug_overlay(ZigGuiApp* app, bool visible);

// =============================================================================
// PLATFORM INTEGRATION
// =============================================================================

/**
 * Get the native window handle (platform-specific).
 * @param app Application handle
 * @return Native window handle (HWND on Windows, etc.)
 */
void* zig_gui_get_native_window(ZigGuiApp* app);

/**
 * Get the rendering context (platform-specific).
 * @param app Application handle
 * @return Rendering context (HDC, GL context, etc.)
 */
void* zig_gui_get_render_context(ZigGuiApp* app);

/**
 * Set a custom renderer (advanced use).
 * @param app Application handle
 * @param renderer Custom renderer implementation
 * @return Error code
 */
ZigGuiError zig_gui_set_custom_renderer(ZigGuiApp* app, void* renderer);

// =============================================================================
// UTILITY FUNCTIONS
// =============================================================================

/**
 * Load an image from file.
 * @param app Application handle
 * @param file_path Path to image file
 * @return Image handle, or NULL on failure
 */
void* zig_gui_load_image(ZigGuiApp* app, const char* file_path);

/**
 * Free an image.
 * @param app Application handle
 * @param image Image handle
 */
void zig_gui_free_image(ZigGuiApp* app, void* image);

/**
 * Render an image.
 * @param app Application handle
 * @param image Image handle
 * @param x X position
 * @param y Y position
 * @param width Width (or -1 for original)
 * @param height Height (or -1 for original)
 */
void zig_gui_image(ZigGuiApp* app, void* image, float x, float y, float width, float height);

/**
 * Load a font from file.
 * @param app Application handle
 * @param file_path Path to font file
 * @param size Font size
 * @return Font handle, or NULL on failure
 */
void* zig_gui_load_font(ZigGuiApp* app, const char* file_path, float size);

/**
 * Free a font.
 * @param app Application handle
 * @param font Font handle
 */
void zig_gui_free_font(ZigGuiApp* app, void* font);

/**
 * Set the current font.
 * @param app Application handle
 * @param font Font handle (NULL for default)
 */
void zig_gui_set_font(ZigGuiApp* app, void* font);

/**
 * Get text dimensions.
 * @param app Application handle
 * @param text Text to measure
 * @param width Output parameter for width
 * @param height Output parameter for height
 */
void zig_gui_text_size(ZigGuiApp* app, const char* text, float* width, float* height);

#ifdef __cplusplus
}
#endif

#endif // ZIG_GUI_H
```

## Usage Examples

### Basic Application

```c
#include "zig_gui.h"
#include <stdio.h>

typedef struct {
    int counter;
    char text_buffer[256];
} AppState;

void ui_function(ZigGuiApp* app, ZigGuiState* state, void* user_data) {
    AppState* app_state = (AppState*)user_data;
    
    zig_gui_window_begin(app, "main_window", &(ZigGuiWindowConfig){
        .title = "My App",
        .width = 400,
        .height = 300,
        .resizable = true,
        .centered = true
    });
    
    // Display counter
    zig_gui_text_formatted(app, "Counter: %d", app_state->counter);
    
    // Increment button
    if (zig_gui_button(app, "Increment")) {
        app_state->counter++;
    }
    
    // Text input
    if (zig_gui_text_input(app, app_state->text_buffer, sizeof(app_state->text_buffer), NULL)) {
        printf("Text changed: %s\n", app_state->text_buffer);
    }
    
    zig_gui_window_end(app);
}

int main() {
    // Create application (event-driven for 0% idle CPU)
    ZigGuiApp* app = zig_gui_app_create(ZIG_GUI_EVENT_DRIVEN);
    if (!app) {
        fprintf(stderr, "Failed to create GUI app\n");
        return 1;
    }
    
    // Create state
    AppState app_state = { .counter = 0 };
    strcpy(app_state.text_buffer, "Hello, World!");
    
    // Run main loop
    ZigGuiError result = zig_gui_app_run(app, ui_function, &app_state);
    if (result != ZIG_GUI_OK) {
        fprintf(stderr, "GUI error: %s\n", zig_gui_error_string(result));
    }
    
    // Cleanup
    zig_gui_app_destroy(app);
    return result == ZIG_GUI_OK ? 0 : 1;
}
```

### Game Integration

```c
#include "zig_gui.h"
#include "my_game_engine.h"

typedef struct {
    int health;
    int mana;
    int score;
    bool inventory_open;
} GameState;

void game_ui(ZigGuiApp* app, ZigGuiState* state, void* user_data) {
    GameState* game = (GameState*)user_data;
    
    // HUD overlay (no window)
    zig_gui_row_begin(app);
    
    // Health bar
    zig_gui_text("Health:");
    zig_gui_progress_bar(app, (float)game->health / 100.0f);
    
    // Mana bar  
    zig_gui_text("Mana:");
    zig_gui_progress_bar(app, (float)game->mana / 100.0f);
    
    // Score
    zig_gui_text_formatted(app, "Score: %d", game->score);
    
    zig_gui_row_end(app);
    
    // Inventory (only if open)
    if (game->inventory_open) {
        if (zig_gui_window_begin(app, "inventory", &(ZigGuiWindowConfig){
            .title = "Inventory",
            .width = 300,
            .height = 200
        })) {
            zig_gui_text("Your items here...");
            
            if (zig_gui_button(app, "Close")) {
                game->inventory_open = false;
            }
        }
        zig_gui_window_end(app);
    }
}

int main() {
    // Initialize game engine
    GameEngine* engine = game_engine_init();
    
    // Create GUI app in game loop mode
    ZigGuiApp* gui = zig_gui_app_create(ZIG_GUI_GAME_LOOP);
    
    GameState game_state = { .health = 100, .mana = 50, .score = 0 };
    
    // Game loop
    while (game_engine_is_running(engine)) {
        // Update game logic
        game_engine_update(engine);
        
        // Update game state
        game_state.health = game_engine_get_player_health(engine);
        game_state.mana = game_engine_get_player_mana(engine);
        game_state.score = game_engine_get_score(engine);
        
        // Render game
        game_engine_render(engine);
        
        // Render UI overlay (this takes <5% of frame time)
        zig_gui_app_update_frame(gui, game_ui, &game_state);
        
        // Present frame
        game_engine_present(engine);
    }
    
    zig_gui_app_destroy(gui);
    game_engine_cleanup(engine);
    return 0;
}
```

### Embedded System

```c
#include "zig_gui.h"
#include "teensy_display.h"

typedef struct {
    float temperature;
    float humidity;
    bool fan_on;
    int brightness;
} SensorData;

void sensor_ui(ZigGuiApp* app, ZigGuiState* state, void* user_data) {
    SensorData* sensors = (SensorData*)user_data;
    
    // Simple grid layout for embedded display
    zig_gui_column_begin(app);
    
    // Temperature display
    zig_gui_text_formatted(app, "Temp: %.1f°C", sensors->temperature);
    
    // Humidity display
    zig_gui_text_formatted(app, "Humidity: %.1f%%", sensors->humidity);
    
    // Fan control
    if (zig_gui_checkbox(app, "Fan", &sensors->fan_on)) {
        teensy_set_fan(sensors->fan_on);
    }
    
    // Brightness control
    if (zig_gui_slider_int(app, &sensors->brightness, 0, 255)) {
        teensy_set_brightness(sensors->brightness);
    }
    
    zig_gui_column_end(app);
}

int main() {
    // Initialize Teensy hardware
    teensy_init();
    
    // Create minimal GUI (uses <32KB RAM)
    ZigGuiConfig config = {
        .mode = ZIG_GUI_MINIMAL,
        .backend = ZIG_GUI_BACKEND_FRAMEBUFFER,
        .max_memory_kb = 32,
        .platform_config = &teensy_display_config
    };
    
    ZigGuiApp* app = zig_gui_app_create_with_config(&config);
    
    SensorData sensors = { 
        .temperature = 22.5f,
        .humidity = 45.0f,
        .fan_on = false,
        .brightness = 128
    };
    
    // Main loop (event-driven, wakes only on input)
    while (true) {
        // Read sensors (only when needed)
        if (teensy_should_update_sensors()) {
            sensors.temperature = teensy_read_temperature();
            sensors.humidity = teensy_read_humidity();
        }
        
        // Wait for input event (sleeps to save power)
        ZigGuiEvent event = zig_gui_app_wait_event(app);
        
        if (event.type == ZIG_GUI_EVENT_REDRAW_NEEDED) {
            zig_gui_begin_frame(app);
            sensor_ui(app, NULL, &sensors);
            zig_gui_end_frame(app);
        }
    }
    
    zig_gui_app_destroy(app);
    return 0;
}
```

## Language Binding Guidelines

The C API is designed to be easily wrapped by other languages:

### Python (ctypes example)

```python
import ctypes
from ctypes import c_char_p, c_int, c_bool, c_float, c_void_p, CFUNCTYPE

# Load library
zig_gui = ctypes.CDLL('./libzig_gui.so')

# Define function signatures
zig_gui.zig_gui_app_create.argtypes = [c_int]
zig_gui.zig_gui_app_create.restype = c_void_p

zig_gui.zig_gui_button.argtypes = [c_void_p, c_char_p]
zig_gui.zig_gui_button.restype = c_bool

# UI function type
UIFunction = CFUNCTYPE(None, c_void_p, c_void_p, c_void_p)

class App:
    def __init__(self, mode=0):  # 0 = EVENT_DRIVEN
        self.app = zig_gui.zig_gui_app_create(mode)
    
    def button(self, text):
        return zig_gui.zig_gui_button(self.app, text.encode('utf-8'))
    
    def run(self, ui_func):
        c_ui_func = UIFunction(ui_func)
        zig_gui.zig_gui_app_run(self.app, c_ui_func, None)
```

### Go (cgo example)

```go
package ziggui

/*
#cgo LDFLAGS: -lzig_gui
#include "zig_gui.h"

extern void go_ui_function_wrapper(ZigGuiApp* app, ZigGuiState* state, void* user_data);
*/
import "C"
import "unsafe"

type App struct {
    cApp *C.ZigGuiApp
    uiFunc func(*App)
}

func NewApp(mode int) *App {
    return &App{
        cApp: C.zig_gui_app_create(C.int(mode)),
    }
}

func (a *App) Button(text string) bool {
    cText := C.CString(text)
    defer C.free(unsafe.Pointer(cText))
    return bool(C.zig_gui_button(a.cApp, cText))
}

func (a *App) Run(uiFunc func(*App)) {
    a.uiFunc = uiFunc
    C.zig_gui_app_run(a.cApp, C.ZigGuiUIFunction(C.go_ui_function_wrapper), unsafe.Pointer(a))
}

//export go_ui_function_wrapper
func go_ui_function_wrapper(app *C.ZigGuiApp, state *C.ZigGuiState, userData unsafe.Pointer) {
    goApp := (*App)(userData)
    goApp.uiFunc(goApp)
}
```

## ABI Stability Guarantees

1. **Function signatures**: Never change existing function signatures
2. **Enum values**: Never change existing enum values, only add new ones at the end
3. **Struct layouts**: Only add new fields at the end of structs
4. **Version compatibility**: Support at least 2 major versions back
5. **Deprecation policy**: 1 version warning, removal in next major version

This C API provides the foundation for zig-gui to become the universal UI library that works seamlessly across all languages and platforms while maintaining the revolutionary performance characteristics and developer experience.