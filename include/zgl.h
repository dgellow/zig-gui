/**
 * zgl.h - zig-gui Public C API
 *
 * High-performance UI library combining:
 * - Event-driven execution (0% idle CPU)
 * - Immediate-mode API
 * - Flexbox layout engine
 * - Universal targeting (embedded to desktop)
 *
 * Architecture:
 *   Layer 0: Style (data structures only)
 *   Layer 1: Layout Engine (pure layout computation)
 *   Layer 2: GUI Context (immediate-mode widgets)
 */

#ifndef ZGL_H
#define ZGL_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

/* ============================================================================
 * Version Information
 * ============================================================================ */

#define ZGL_API_VERSION_MAJOR 1
#define ZGL_API_VERSION_MINOR 0
#define ZGL_API_VERSION ((ZGL_API_VERSION_MAJOR << 16) | ZGL_API_VERSION_MINOR)

/* Runtime version check */
uint32_t zgl_get_version(void);

/* Get maximum elements (configurable at build time for embedded) */
uint32_t zgl_max_elements(void);

/* Struct size checks for ABI compatibility */
size_t zgl_style_size(void);
size_t zgl_rect_size(void);

/* ============================================================================
 * Layer 0: Core Types (ABI Stable)
 * ============================================================================ */

/**
 * Opaque handle types - u32 for WASM compatibility.
 * These are indices into internal arrays, not pointers.
 */
typedef uint32_t ZglNode;
typedef uint32_t ZglId;

/** Sentinel value for "no node" / "no parent" / "invalid" */
#define ZGL_NULL ((ZglNode)0xFFFFFFFF)

/**
 * Result rectangle (16 bytes, cache-line friendly).
 * Contains computed position and size after layout.
 */
typedef struct {
    float x;
    float y;
    float width;
    float height;
} ZglRect;

/* ============================================================================
 * Layer 0: Style Constants
 * ============================================================================ */

/** Flex direction: how children are laid out */
#define ZGL_ROW      0  /**< Children laid out horizontally */
#define ZGL_COLUMN   1  /**< Children laid out vertically */

/** Main-axis alignment (justify-content in CSS) */
#define ZGL_JUSTIFY_START         0  /**< Pack items at start */
#define ZGL_JUSTIFY_CENTER        1  /**< Center items */
#define ZGL_JUSTIFY_END           2  /**< Pack items at end */
#define ZGL_JUSTIFY_SPACE_BETWEEN 3  /**< Distribute with space between */
#define ZGL_JUSTIFY_SPACE_AROUND  4  /**< Distribute with space around */
#define ZGL_JUSTIFY_SPACE_EVENLY  5  /**< Distribute with equal space */

/** Cross-axis alignment (align-items in CSS) */
#define ZGL_ALIGN_START   0  /**< Align to start of cross axis */
#define ZGL_ALIGN_CENTER  1  /**< Center on cross axis */
#define ZGL_ALIGN_END     2  /**< Align to end of cross axis */
#define ZGL_ALIGN_STRETCH 3  /**< Stretch to fill cross axis */

/* ============================================================================
 * Layer 0: Style Structure
 * ============================================================================ */

/** Use for "auto" dimensions (content-sized) */
#define ZGL_AUTO (-1.0f)

/** Use for "no constraint" on min/max */
#define ZGL_NONE (1e30f)

/**
 * Style structure (56 bytes, cache-line aligned).
 * Plain C struct with no methods. Fully serializable.
 *
 * Note: direction/justify/align use uint8_t for ABI stability (C enums vary in size).
 * Use ZGL_ROW, ZGL_COLUMN, etc. constants for values.
 */
typedef struct {
    /* === Flexbox properties (4 bytes) === */
    uint8_t direction;       /**< Row (0) or column (1) layout */
    uint8_t justify;         /**< Main-axis alignment (ZGL_JUSTIFY_*) */
    uint8_t align;           /**< Cross-axis alignment (ZGL_ALIGN_*) */
    uint8_t _reserved;       /**< Padding for alignment */

    /* === Flex item properties (8 bytes) === */
    float flex_grow;         /**< Growth factor (0.0 = don't grow) */
    float flex_shrink;       /**< Shrink factor (1.0 = can shrink) */

    /* === Dimensions (24 bytes) === */
    float width;             /**< Width (ZGL_AUTO = content-sized) */
    float height;            /**< Height (ZGL_AUTO = content-sized) */
    float min_width;         /**< Minimum width (0.0 = no minimum) */
    float min_height;        /**< Minimum height (0.0 = no minimum) */
    float max_width;         /**< Maximum width (ZGL_NONE = no maximum) */
    float max_height;        /**< Maximum height (ZGL_NONE = no maximum) */

    /* === Spacing (20 bytes) === */
    float gap;               /**< Gap between children */
    float padding_top;       /**< Top padding */
    float padding_right;     /**< Right padding */
    float padding_bottom;    /**< Bottom padding */
    float padding_left;      /**< Left padding */
} ZglStyle;

/** Default style initializer (C99 designated initializers) */
#define ZGL_STYLE_DEFAULT ((ZglStyle){ \
    .direction = ZGL_COLUMN, \
    .justify = ZGL_JUSTIFY_START, \
    .align = ZGL_ALIGN_STRETCH, \
    ._reserved = 0, \
    .flex_grow = 0.0f, \
    .flex_shrink = 1.0f, \
    .width = ZGL_AUTO, \
    .height = ZGL_AUTO, \
    .min_width = 0.0f, \
    .min_height = 0.0f, \
    .max_width = ZGL_NONE, \
    .max_height = ZGL_NONE, \
    .gap = 0.0f, \
    .padding_top = 0.0f, \
    .padding_right = 0.0f, \
    .padding_bottom = 0.0f, \
    .padding_left = 0.0f, \
})

/* ============================================================================
 * Layer 0: Error Handling
 * ============================================================================ */

/** Error codes for fallible operations */
typedef enum {
    ZGL_OK = 0,                    /**< Success */
    ZGL_ERROR_OUT_OF_MEMORY = 1,   /**< Allocation failed */
    ZGL_ERROR_CAPACITY_EXCEEDED = 2, /**< Max nodes reached */
    ZGL_ERROR_INVALID_NODE = 3,    /**< Node handle is invalid */
    ZGL_ERROR_CYCLE_DETECTED = 4,  /**< Would create cycle in tree */
} ZglError;

/** Get last error from failed operation */
ZglError zgl_get_last_error(void);

/** Get human-readable error message */
const char* zgl_error_string(ZglError error);

/* ============================================================================
 * Layer 1: Layout Engine (Pure Computation)
 *
 * The layout engine is a pure function: (tree, styles) -> rects
 * No rendering, no input handling, no platform dependencies.
 * ============================================================================ */

/** Opaque layout engine handle */
typedef struct ZglLayout ZglLayout;

/* --- Lifecycle --- */

/**
 * Create a layout engine with given capacity.
 * @param max_nodes Maximum number of nodes (elements) in the tree
 * @return Layout engine handle, or NULL on allocation failure
 */
ZglLayout* zgl_layout_create(uint32_t max_nodes);

/**
 * Destroy layout engine and free all memory.
 * @param layout Layout engine to destroy (may be NULL)
 */
void zgl_layout_destroy(ZglLayout* layout);

/* --- Tree Building --- */

/**
 * Add a node to the tree.
 * @param layout Layout engine
 * @param parent Parent node (ZGL_NULL creates a root node)
 * @param style Style for the new node
 * @return Node handle, or ZGL_NULL on error (check zgl_get_last_error())
 */
ZglNode zgl_layout_add(ZglLayout* layout, ZglNode parent, const ZglStyle* style);

/**
 * Remove a node and all its descendants.
 * Freed indices are recycled for future allocations.
 * @param layout Layout engine
 * @param node Node to remove
 */
void zgl_layout_remove(ZglLayout* layout, ZglNode node);

/**
 * Update a node's style.
 * Marks the node dirty for recomputation.
 * @param layout Layout engine
 * @param node Node to update
 * @param style New style
 */
void zgl_layout_set_style(ZglLayout* layout, ZglNode node, const ZglStyle* style);

/**
 * Move a node to a new parent.
 * Marks both old and new parent dirty.
 * @param layout Layout engine
 * @param node Node to move
 * @param new_parent New parent (ZGL_NULL to make root)
 */
void zgl_layout_reparent(ZglLayout* layout, ZglNode node, ZglNode new_parent);

/* --- Computation --- */

/**
 * Compute layout for all dirty nodes.
 * This is the main "work" function - call once per frame.
 * @param layout Layout engine
 * @param available_width Available width constraint
 * @param available_height Available height constraint
 */
void zgl_layout_compute(ZglLayout* layout, float available_width, float available_height);

/* --- Queries --- */

/**
 * Get computed rectangle for a node.
 * @param layout Layout engine
 * @param node Node to query
 * @return Computed rectangle (zero rect if node invalid)
 */
ZglRect zgl_layout_get_rect(const ZglLayout* layout, ZglNode node);

/**
 * Get parent of a node.
 * @param layout Layout engine
 * @param node Node to query
 * @return Parent node, or ZGL_NULL for root or invalid node
 */
ZglNode zgl_layout_get_parent(const ZglLayout* layout, ZglNode node);

/**
 * Get first child of a node.
 * @param layout Layout engine
 * @param node Node to query
 * @return First child, or ZGL_NULL if no children
 */
ZglNode zgl_layout_get_first_child(const ZglLayout* layout, ZglNode node);

/**
 * Get next sibling of a node.
 * @param layout Layout engine
 * @param node Node to query
 * @return Next sibling, or ZGL_NULL if last child
 */
ZglNode zgl_layout_get_next_sibling(const ZglLayout* layout, ZglNode node);

/* --- Statistics --- */

/**
 * Get number of nodes currently in tree.
 * @param layout Layout engine
 * @return Node count
 */
uint32_t zgl_layout_node_count(const ZglLayout* layout);

/**
 * Get number of dirty nodes (will be computed on next zgl_layout_compute).
 * @param layout Layout engine
 * @return Dirty node count
 */
uint32_t zgl_layout_dirty_count(const ZglLayout* layout);

/**
 * Get cache hit rate since last reset.
 * @param layout Layout engine
 * @return Hit rate (0.0 to 1.0)
 */
float zgl_layout_cache_hit_rate(const ZglLayout* layout);

/**
 * Reset statistics counters.
 * @param layout Layout engine
 */
void zgl_layout_reset_stats(ZglLayout* layout);

/* ============================================================================
 * Layer 2: GUI Context (Immediate-Mode Widgets)
 *
 * Builds on Layer 1, adds immediate-mode widget API with automatic
 * reconciliation between frames.
 * ============================================================================ */

/** Opaque GUI context handle */
typedef struct ZglGui ZglGui;

/** GUI creation configuration */
typedef struct {
    uint32_t max_widgets;    /**< Maximum widgets (default: 4096) */
    float viewport_width;    /**< Initial viewport width */
    float viewport_height;   /**< Initial viewport height */
} ZglGuiConfig;

/** Default GUI configuration */
#define ZGL_GUI_CONFIG_DEFAULT ((ZglGuiConfig){ \
    .max_widgets = 4096, \
    .viewport_width = 800.0f, \
    .viewport_height = 600.0f, \
})

/* --- Lifecycle --- */

/**
 * Create a GUI context.
 * @param config Configuration (may be NULL for defaults)
 * @return GUI context handle, or NULL on failure
 */
ZglGui* zgl_gui_create(const ZglGuiConfig* config);

/**
 * Destroy GUI context and free all memory.
 * @param gui GUI context to destroy (may be NULL)
 */
void zgl_gui_destroy(ZglGui* gui);

/* --- Frame Lifecycle --- */

/**
 * Begin a new frame.
 * Clears "seen" tracking for widgets. Call at start of each frame.
 * @param gui GUI context
 */
void zgl_gui_begin_frame(ZglGui* gui);

/**
 * End frame.
 * Removes widgets not seen this frame, computes layout.
 * @param gui GUI context
 */
void zgl_gui_end_frame(ZglGui* gui);

/**
 * Update viewport size (e.g., on window resize).
 * @param gui GUI context
 * @param width New viewport width
 * @param height New viewport height
 */
void zgl_gui_set_viewport(ZglGui* gui, float width, float height);

/* --- Widget ID System --- */

/**
 * Compute widget ID from string (runtime hash).
 * Thread-safe: pure function with no shared state.
 * @param label Widget label string
 * @return Widget ID
 */
ZglId zgl_id(const char* label);

/**
 * Compute widget ID from string + index (for loops).
 * Thread-safe: pure function with no shared state.
 * @param label Base label string
 * @param index Loop index
 * @return Widget ID
 */
ZglId zgl_id_index(const char* label, uint32_t index);

/**
 * Combine two IDs (for hierarchical scoping).
 * Thread-safe: pure function with no shared state.
 * @param parent Parent scope ID
 * @param child Child ID
 * @return Combined ID
 */
ZglId zgl_id_combine(ZglId parent, ZglId child);

/**
 * Push ID scope onto stack.
 * All subsequent widget IDs will be combined with this scope.
 * @param gui GUI context
 * @param id Scope ID to push
 */
void zgl_gui_push_id(ZglGui* gui, ZglId id);

/**
 * Pop ID scope from stack.
 * @param gui GUI context
 */
void zgl_gui_pop_id(ZglGui* gui);

/* --- Widget Declaration --- */

/**
 * Declare a widget.
 * Widget ID = current_scope XOR id. Creates widget if new,
 * updates if existing, marks as "seen" this frame.
 * Use zgl_gui_clicked() etc. to query interaction state.
 * @param gui GUI context
 * @param id Widget ID
 * @param style Widget style
 */
void zgl_gui_widget(ZglGui* gui, ZglId id, const ZglStyle* style);

/**
 * Begin a container widget.
 * Pushes onto parent stack - subsequent widgets become children.
 * @param gui GUI context
 * @param id Container ID
 * @param style Container style
 */
void zgl_gui_begin(ZglGui* gui, ZglId id, const ZglStyle* style);

/**
 * End a container widget.
 * Pops parent stack.
 * @param gui GUI context
 */
void zgl_gui_end(ZglGui* gui);

/* --- Queries --- */

/**
 * Get computed rect for a widget.
 * @param gui GUI context
 * @param id Widget ID
 * @return Computed rectangle (zero if widget not found)
 */
ZglRect zgl_gui_get_rect(const ZglGui* gui, ZglId id);

/**
 * Check if point is inside widget.
 * @param gui GUI context
 * @param id Widget ID
 * @param x X coordinate
 * @param y Y coordinate
 * @return true if point is inside widget bounds
 */
bool zgl_gui_hit_test(const ZglGui* gui, ZglId id, float x, float y);

/* --- Input State --- */

/**
 * Update mouse position.
 * Call before begin_frame with current mouse state.
 * @param gui GUI context
 * @param x Mouse X position
 * @param y Mouse Y position
 * @param down true if mouse button is pressed
 */
void zgl_gui_set_mouse(ZglGui* gui, float x, float y, bool down);

/**
 * Check if widget was clicked this frame.
 * @param gui GUI context
 * @param id Widget ID
 * @return true if widget was clicked
 */
bool zgl_gui_clicked(const ZglGui* gui, ZglId id);

/**
 * Check if widget is hovered.
 * @param gui GUI context
 * @param id Widget ID
 * @return true if mouse is over widget
 */
bool zgl_gui_hovered(const ZglGui* gui, ZglId id);

/**
 * Check if widget is being pressed.
 * @param gui GUI context
 * @param id Widget ID
 * @return true if mouse button is down over widget
 */
bool zgl_gui_pressed(const ZglGui* gui, ZglId id);

/* --- Direct Layout Access --- */

/**
 * Get underlying layout engine.
 * For advanced use cases that need direct layout manipulation.
 * @param gui GUI context
 * @return Layout engine handle
 */
ZglLayout* zgl_gui_get_layout(ZglGui* gui);

/* ============================================================================
 * Embedded Configuration (Optional)
 *
 * For embedded systems with severe memory constraints:
 * Compile with -DZGL_EMBEDDED to enable stack-allocated mode.
 * ============================================================================ */

#ifdef ZGL_EMBEDDED

#ifndef ZGL_MAX_NODES
#define ZGL_MAX_NODES 64
#endif

/**
 * Stack-allocated layout storage for embedded systems.
 * Avoids heap allocation entirely.
 */
typedef struct {
    uint8_t _storage[ZGL_MAX_NODES * 80]; /* 80 bytes per node */
} ZglLayoutEmbedded;

/**
 * Initialize layout engine from stack-allocated storage.
 * @param storage Pre-allocated storage
 * @return Layout engine handle (points into storage, do not free)
 */
ZglLayout* zgl_layout_init_embedded(ZglLayoutEmbedded* storage);

#endif /* ZGL_EMBEDDED */

#ifdef __cplusplus
}
#endif

#endif /* ZGL_H */
