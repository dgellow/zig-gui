#ifndef ZLAY_H
#define ZLAY_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* --- Types --- */

typedef struct ZlayContext ZlayContext;
typedef struct ZlayRenderer ZlayRenderer;

typedef enum {
    ZLAY_ELEMENT_CONTAINER,
    ZLAY_ELEMENT_BOX,
    ZLAY_ELEMENT_TEXT,
    ZLAY_ELEMENT_BUTTON,
    ZLAY_ELEMENT_IMAGE,
    ZLAY_ELEMENT_INPUT,
    ZLAY_ELEMENT_SLIDER,
    ZLAY_ELEMENT_TOGGLE,
    ZLAY_ELEMENT_CUSTOM
} ZlayElementType;

typedef enum {
    ZLAY_ALIGN_START,
    ZLAY_ALIGN_CENTER,
    ZLAY_ALIGN_END,
    ZLAY_ALIGN_SPACE_BETWEEN,
    ZLAY_ALIGN_SPACE_AROUND,
    ZLAY_ALIGN_SPACE_EVENLY
} ZlayAlign;

typedef struct {
    uint8_t r;
    uint8_t g;
    uint8_t b;
    uint8_t a;
} ZlayColor;

typedef struct {
    ZlayColor* background_color;
    ZlayColor* border_color;
    ZlayColor* text_color;
    
    float border_width;
    float corner_radius;
    
    float padding_left;
    float padding_right;
    float padding_top;
    float padding_bottom;
    
    float margin_left;
    float margin_right;
    float margin_top;
    float margin_bottom;
    
    float font_size;
    const char* font_name;
    
    ZlayAlign align_h;
    ZlayAlign align_v;
    
    float flex_grow;
    float flex_shrink;
    float* flex_basis;
} ZlayStyle;

/* --- Context Functions --- */

/**
 * Create a new zlay context
 * @return A pointer to the context or NULL on failure
 */
ZlayContext* zlay_create_context(void);

/**
 * Destroy a zlay context
 * @param ctx The context to destroy
 */
void zlay_destroy_context(ZlayContext* ctx);

/**
 * Begin a new frame, clearing previous layout
 * @param ctx The context
 * @return 0 on success, non-zero on failure
 */
int zlay_begin_frame(ZlayContext* ctx);

/**
 * Begin a new element
 * @param ctx The context
 * @param type The element type
 * @param id Optional ID string (can be NULL)
 * @return Element index or -1 on failure
 */
int zlay_begin_element(ZlayContext* ctx, ZlayElementType type, const char* id);

/**
 * End the current element
 * @param ctx The context
 * @return 0 on success, non-zero on failure
 */
int zlay_end_element(ZlayContext* ctx);

/**
 * Set style for the current element
 * @param ctx The context
 * @param style The style to apply
 * @return 0 on success, non-zero on failure
 */
int zlay_set_style(ZlayContext* ctx, const ZlayStyle* style);

/**
 * Set text for the current element
 * @param ctx The context
 * @param text The text to set
 * @return 0 on success, non-zero on failure
 */
int zlay_set_text(ZlayContext* ctx, const char* text);

/**
 * Compute layout
 * @param ctx The context
 * @param width The container width
 * @param height The container height
 * @return 0 on success, non-zero on failure
 */
int zlay_compute_layout(ZlayContext* ctx, float width, float height);

/**
 * Render the current layout
 * @param ctx The context
 * @return 0 on success, non-zero on failure
 */
int zlay_render(ZlayContext* ctx);

/**
 * Get element by ID
 * @param ctx The context
 * @param id The element ID
 * @return Element index or -1 if not found
 */
int zlay_get_element_by_id(ZlayContext* ctx, const char* id);

/**
 * Get element position and size
 * @param ctx The context
 * @param element_idx The element index
 * @param x Output parameter for x position
 * @param y Output parameter for y position
 * @param width Output parameter for width
 * @param height Output parameter for height
 * @return 0 on success, non-zero on failure
 */
int zlay_get_element_rect(ZlayContext* ctx, int element_idx, float* x, float* y, float* width, float* height);

/* --- Color Helpers --- */

/**
 * Create a color from RGB values (alpha = 255)
 */
ZlayColor zlay_rgb(uint8_t r, uint8_t g, uint8_t b);

/**
 * Create a color from RGBA values
 */
ZlayColor zlay_rgba(uint8_t r, uint8_t g, uint8_t b, uint8_t a);

/* --- Renderer Interface --- */

/**
 * Set the renderer for a context
 * @param ctx The context
 * @param renderer The renderer to use
 */
void zlay_set_renderer(ZlayContext* ctx, ZlayRenderer* renderer);

/**
 * Create a custom renderer instance
 * @return A new renderer instance or NULL on failure
 */
ZlayRenderer* zlay_create_renderer(
    void* user_data,
    void (*begin_frame)(ZlayRenderer* renderer),
    void (*end_frame)(ZlayRenderer* renderer),
    void (*clear)(ZlayRenderer* renderer, ZlayColor color),
    void (*draw_rect)(ZlayRenderer* renderer, float x, float y, float width, float height, ZlayColor fill),
    void (*draw_rounded_rect)(ZlayRenderer* renderer, float x, float y, float width, float height, float radius, ZlayColor fill),
    void (*draw_text)(ZlayRenderer* renderer, const char* text, float x, float y, float font_size, ZlayColor color),
    void (*draw_image)(ZlayRenderer* renderer, uint32_t image_id, float x, float y, float width, float height),
    void (*clip_begin)(ZlayRenderer* renderer, float x, float y, float width, float height),
    void (*clip_end)(ZlayRenderer* renderer)
);

/**
 * Destroy a renderer instance
 * @param renderer The renderer to destroy
 */
void zlay_destroy_renderer(ZlayRenderer* renderer);

#ifdef __cplusplus
}
#endif

#endif /* ZLAY_H */