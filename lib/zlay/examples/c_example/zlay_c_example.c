#include "../../src/zlay.h"
#include <stdio.h>
#include <stdlib.h>

// Renderer implementation functions
void begin_frame(ZlayRenderer* renderer) {
    printf("Begin frame\n");
}

void end_frame(ZlayRenderer* renderer) {
    printf("End frame\n");
}

void clear(ZlayRenderer* renderer, ZlayColor color) {
    printf("Clear: rgba(%d, %d, %d, %d)\n", color.r, color.g, color.b, color.a);
}

void draw_rect(ZlayRenderer* renderer, float x, float y, float width, float height, ZlayColor fill) {
    printf("Draw rect: x=%.2f, y=%.2f, w=%.2f, h=%.2f, color=rgba(%d, %d, %d, %d)\n",
        x, y, width, height, fill.r, fill.g, fill.b, fill.a);
}

void draw_rounded_rect(ZlayRenderer* renderer, float x, float y, float width, float height, float radius, ZlayColor fill) {
    printf("Draw rounded rect: x=%.2f, y=%.2f, w=%.2f, h=%.2f, r=%.2f, color=rgba(%d, %d, %d, %d)\n",
        x, y, width, height, radius, fill.r, fill.g, fill.b, fill.a);
}

void draw_text(ZlayRenderer* renderer, const char* text, float x, float y, float font_size, ZlayColor color) {
    printf("Draw text: \"%s\" at x=%.2f, y=%.2f, size=%.2f, color=rgba(%d, %d, %d, %d)\n",
        text, x, y, font_size, color.r, color.g, color.b, color.a);
}

void draw_image(ZlayRenderer* renderer, uint32_t image_id, float x, float y, float width, float height) {
    printf("Draw image: id=%u, x=%.2f, y=%.2f, w=%.2f, h=%.2f\n",
        image_id, x, y, width, height);
}

void clip_begin(ZlayRenderer* renderer, float x, float y, float width, float height) {
    printf("Clip begin: x=%.2f, y=%.2f, w=%.2f, h=%.2f\n",
        x, y, width, height);
}

void clip_end(ZlayRenderer* renderer) {
    printf("Clip end\n");
}

int main() {
    printf("Zlay C API Example\n");
    printf("==================\n\n");
    
    // Create context
    ZlayContext* ctx = zlay_create_context();
    if (!ctx) {
        fprintf(stderr, "Failed to create context\n");
        return 1;
    }
    
    // Create renderer
    ZlayRenderer* renderer = zlay_create_renderer(
        NULL, begin_frame, end_frame, clear, 
        draw_rect, draw_rounded_rect, draw_text, 
        draw_image, clip_begin, clip_end
    );
    if (!renderer) {
        fprintf(stderr, "Failed to create renderer\n");
        zlay_destroy_context(ctx);
        return 1;
    }
    
    // Set renderer
    zlay_set_renderer(ctx, renderer);
    
    // Begin frame
    if (zlay_begin_frame(ctx) != 0) {
        fprintf(stderr, "Failed to begin frame\n");
        zlay_destroy_renderer(renderer);
        zlay_destroy_context(ctx);
        return 1;
    }
    
    // Create root container
    int root_idx = zlay_begin_element(ctx, ZLAY_ELEMENT_CONTAINER, "root");
    if (root_idx < 0) {
        fprintf(stderr, "Failed to create root element\n");
        zlay_destroy_renderer(renderer);
        zlay_destroy_context(ctx);
        return 1;
    }
    
    // Header
    int header_idx = zlay_begin_element(ctx, ZLAY_ELEMENT_CONTAINER, "header");
    if (header_idx >= 0) {
        // Set header style
        ZlayColor header_bg = zlay_rgb(50, 50, 200);
        ZlayStyle header_style = {0};
        header_style.background_color = &header_bg;
        header_style.padding_left = 10;
        header_style.padding_right = 10;
        header_style.padding_top = 10;
        header_style.padding_bottom = 10;
        zlay_set_style(ctx, &header_style);
        
        // Logo
        int logo_idx = zlay_begin_element(ctx, ZLAY_ELEMENT_BOX, "logo");
        if (logo_idx >= 0) {
            ZlayColor logo_bg = zlay_rgb(200, 50, 50);
            ZlayStyle logo_style = {0};
            logo_style.background_color = &logo_bg;
            logo_style.corner_radius = 5;
            zlay_set_style(ctx, &logo_style);
            zlay_end_element(ctx);
        }
        
        // Title
        int title_idx = zlay_begin_element(ctx, ZLAY_ELEMENT_TEXT, "title");
        if (title_idx >= 0) {
            ZlayColor title_color = zlay_rgb(255, 255, 255);
            ZlayStyle title_style = {0};
            title_style.text_color = &title_color;
            title_style.font_size = 24;
            zlay_set_style(ctx, &title_style);
            zlay_set_text(ctx, "Zlay C API Demo");
            zlay_end_element(ctx);
        }
        
        zlay_end_element(ctx); // end header
    }
    
    // Content
    int content_idx = zlay_begin_element(ctx, ZLAY_ELEMENT_CONTAINER, "content");
    if (content_idx >= 0) {
        ZlayColor content_bg = zlay_rgb(240, 240, 240);
        ZlayStyle content_style = {0};
        content_style.background_color = &content_bg;
        content_style.padding_left = 20;
        content_style.padding_right = 20;
        content_style.padding_top = 20;
        content_style.padding_bottom = 20;
        zlay_set_style(ctx, &content_style);
        
        // Button
        int button_idx = zlay_begin_element(ctx, ZLAY_ELEMENT_BUTTON, "button");
        if (button_idx >= 0) {
            ZlayColor button_bg = zlay_rgb(50, 150, 50);
            ZlayColor button_text = zlay_rgb(255, 255, 255);
            ZlayStyle button_style = {0};
            button_style.background_color = &button_bg;
            button_style.text_color = &button_text;
            button_style.corner_radius = 5;
            button_style.padding_left = 10;
            button_style.padding_right = 10;
            button_style.padding_top = 10;
            button_style.padding_bottom = 10;
            zlay_set_style(ctx, &button_style);
            zlay_set_text(ctx, "Click Me");
            zlay_end_element(ctx);
        }
        
        zlay_end_element(ctx); // end content
    }
    
    // Footer
    int footer_idx = zlay_begin_element(ctx, ZLAY_ELEMENT_CONTAINER, "footer");
    if (footer_idx >= 0) {
        ZlayColor footer_bg = zlay_rgb(50, 50, 50);
        ZlayStyle footer_style = {0};
        footer_style.background_color = &footer_bg;
        footer_style.padding_left = 10;
        footer_style.padding_right = 10;
        footer_style.padding_top = 10;
        footer_style.padding_bottom = 10;
        zlay_set_style(ctx, &footer_style);
        
        int footer_text_idx = zlay_begin_element(ctx, ZLAY_ELEMENT_TEXT, "footer_text");
        if (footer_text_idx >= 0) {
            ZlayColor text_color = zlay_rgb(200, 200, 200);
            ZlayStyle text_style = {0};
            text_style.text_color = &text_color;
            zlay_set_style(ctx, &text_style);
            zlay_set_text(ctx, "Zlay - A Zig Layout Library");
            zlay_end_element(ctx);
        }
        
        zlay_end_element(ctx); // end footer
    }
    
    zlay_end_element(ctx); // end root
    
    // Compute layout and render
    printf("\nComputing layout and rendering...\n\n");
    if (zlay_compute_layout(ctx, 800, 600) != 0) {
        fprintf(stderr, "Failed to compute layout\n");
    } else if (zlay_render(ctx) != 0) {
        fprintf(stderr, "Failed to render\n");
    }
    
    // Get element information
    float x, y, width, height;
    int button_idx = zlay_get_element_by_id(ctx, "button");
    if (button_idx >= 0) {
        if (zlay_get_element_rect(ctx, button_idx, &x, &y, &width, &height) == 0) {
            printf("\nButton position: x=%.2f, y=%.2f, w=%.2f, h=%.2f\n", x, y, width, height);
        }
    }
    
    // Cleanup
    printf("\nCleaning up...\n");
    zlay_destroy_renderer(renderer);
    zlay_destroy_context(ctx);
    
    printf("\nZlay C API Example completed successfully!\n");
    return 0;
}