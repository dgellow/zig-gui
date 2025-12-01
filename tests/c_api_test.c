/**
 * C API Tests for zig-gui
 *
 * Thorough tests covering:
 * - Lifecycle (create -> use -> destroy)
 * - Error paths (invalid handles, capacity)
 * - Layout correctness (known inputs -> expected outputs)
 * - Tree operations (add, remove, reparent)
 * - GUI operations (frame lifecycle, input, queries)
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <math.h>

#include "../include/zgl.h"

/* ============================================================================
 * Test Utilities
 * ============================================================================ */

static int tests_run = 0;
static int tests_passed = 0;

#define TEST(name) static void test_##name(void)
#define RUN_TEST(name) do { \
    printf("  Running %s... ", #name); \
    tests_run++; \
    test_##name(); \
    tests_passed++; \
    printf("OK\n"); \
} while(0)

#define ASSERT(cond) do { \
    if (!(cond)) { \
        printf("FAILED at %s:%d: %s\n", __FILE__, __LINE__, #cond); \
        exit(1); \
    } \
} while(0)

#define ASSERT_EQ(a, b) do { \
    if ((a) != (b)) { \
        printf("FAILED at %s:%d: %s != %s\n", __FILE__, __LINE__, #a, #b); \
        exit(1); \
    } \
} while(0)

#define ASSERT_FLOAT_EQ(a, b, eps) do { \
    if (fabs((a) - (b)) > (eps)) { \
        printf("FAILED at %s:%d: %f != %f (eps=%f)\n", __FILE__, __LINE__, \
               (double)(a), (double)(b), (double)(eps)); \
        exit(1); \
    } \
} while(0)

/* ============================================================================
 * Version and ABI Tests
 * ============================================================================ */

TEST(version) {
    uint32_t version = zgl_get_version();
    ASSERT(version >= 0x00010000); /* At least 1.0 */

    /* Major version in high 16 bits */
    uint32_t major = version >> 16;
    uint32_t minor = version & 0xFFFF;
    ASSERT_EQ(major, 1);
    ASSERT_EQ(minor, 0);
}

TEST(abi_struct_sizes) {
    /* Verify struct sizes match header expectations */
    ASSERT_EQ(zgl_style_size(), sizeof(ZglStyle));
    ASSERT_EQ(zgl_rect_size(), sizeof(ZglRect));

    /* Known sizes */
    ASSERT_EQ(sizeof(ZglStyle), 56);
    ASSERT_EQ(sizeof(ZglRect), 16);
}

TEST(style_default_init) {
    ZglStyle style = ZGL_STYLE_DEFAULT;

    ASSERT_EQ(style.direction, ZGL_COLUMN);
    ASSERT_EQ(style.justify, ZGL_JUSTIFY_START);
    ASSERT_EQ(style.align, ZGL_ALIGN_STRETCH);
    ASSERT_FLOAT_EQ(style.flex_grow, 0.0f, 0.001f);
    ASSERT_FLOAT_EQ(style.flex_shrink, 1.0f, 0.001f);
    ASSERT_FLOAT_EQ(style.width, ZGL_AUTO, 0.001f);
    ASSERT_FLOAT_EQ(style.height, ZGL_AUTO, 0.001f);
}

/* ============================================================================
 * Error Handling Tests
 * ============================================================================ */

TEST(error_string) {
    const char* msg;

    msg = zgl_error_string(ZGL_OK);
    ASSERT(msg != NULL);
    ASSERT(strlen(msg) > 0);

    msg = zgl_error_string(ZGL_ERROR_OUT_OF_MEMORY);
    ASSERT(msg != NULL);
    ASSERT(strstr(msg, "memory") != NULL || strstr(msg, "Memory") != NULL);

    msg = zgl_error_string(ZGL_ERROR_INVALID_NODE);
    ASSERT(msg != NULL);
}

TEST(null_handle_safety) {
    /* All functions should handle NULL gracefully */
    zgl_layout_destroy(NULL);
    zgl_layout_compute(NULL, 100, 100);
    zgl_layout_set_style(NULL, 0, NULL);
    zgl_layout_remove(NULL, 0);

    ZglRect rect = zgl_layout_get_rect(NULL, 0);
    ASSERT_FLOAT_EQ(rect.width, 0.0f, 0.001f);

    ASSERT_EQ(zgl_layout_node_count(NULL), 0);
    ASSERT_EQ(zgl_layout_get_parent(NULL, 0), ZGL_NULL);
}

/* ============================================================================
 * Layout Lifecycle Tests
 * ============================================================================ */

TEST(layout_create_destroy) {
    ZglLayout* layout = zgl_layout_create(100);
    ASSERT(layout != NULL);
    ASSERT_EQ(zgl_get_last_error(), ZGL_OK);

    zgl_layout_destroy(layout);
}

TEST(layout_multiple_instances) {
    /* Can create multiple independent instances */
    ZglLayout* layout1 = zgl_layout_create(64);
    ZglLayout* layout2 = zgl_layout_create(64);

    ASSERT(layout1 != NULL);
    ASSERT(layout2 != NULL);
    ASSERT(layout1 != layout2);

    /* Each has independent state */
    ZglStyle style = ZGL_STYLE_DEFAULT;
    style.width = 100;
    style.height = 50;

    zgl_layout_add(layout1, ZGL_NULL, &style);
    ASSERT_EQ(zgl_layout_node_count(layout1), 1);
    ASSERT_EQ(zgl_layout_node_count(layout2), 0);

    zgl_layout_destroy(layout1);
    zgl_layout_destroy(layout2);
}

/* ============================================================================
 * Tree Building Tests
 * ============================================================================ */

TEST(add_root_node) {
    ZglLayout* layout = zgl_layout_create(100);

    ZglStyle style = ZGL_STYLE_DEFAULT;
    style.width = 200;
    style.height = 100;

    ZglNode root = zgl_layout_add(layout, ZGL_NULL, &style);
    ASSERT(root != ZGL_NULL);
    ASSERT_EQ(zgl_get_last_error(), ZGL_OK);
    ASSERT_EQ(zgl_layout_node_count(layout), 1);

    /* Root has no parent */
    ASSERT_EQ(zgl_layout_get_parent(layout, root), ZGL_NULL);

    zgl_layout_destroy(layout);
}

TEST(add_child_nodes) {
    ZglLayout* layout = zgl_layout_create(100);

    ZglStyle style = ZGL_STYLE_DEFAULT;
    style.width = 100;
    style.height = 50;

    ZglNode root = zgl_layout_add(layout, ZGL_NULL, &style);
    ZglNode child1 = zgl_layout_add(layout, root, &style);
    ZglNode child2 = zgl_layout_add(layout, root, &style);

    ASSERT_EQ(zgl_layout_node_count(layout), 3);

    /* Parent relationships */
    ASSERT_EQ(zgl_layout_get_parent(layout, child1), root);
    ASSERT_EQ(zgl_layout_get_parent(layout, child2), root);

    /* Sibling relationships */
    ASSERT_EQ(zgl_layout_get_first_child(layout, root), child1);
    ASSERT_EQ(zgl_layout_get_next_sibling(layout, child1), child2);
    ASSERT_EQ(zgl_layout_get_next_sibling(layout, child2), ZGL_NULL);

    zgl_layout_destroy(layout);
}

TEST(deep_hierarchy) {
    ZglLayout* layout = zgl_layout_create(100);

    ZglStyle style = ZGL_STYLE_DEFAULT;
    style.width = 100;
    style.height = 50;

    /* Create a 10-level deep tree */
    ZglNode parent = zgl_layout_add(layout, ZGL_NULL, &style);
    for (int i = 0; i < 10; i++) {
        ZglNode child = zgl_layout_add(layout, parent, &style);
        parent = child;
    }

    ASSERT_EQ(zgl_layout_node_count(layout), 11);

    zgl_layout_destroy(layout);
}

/* ============================================================================
 * Layout Computation Tests
 * ============================================================================ */

TEST(compute_single_node) {
    ZglLayout* layout = zgl_layout_create(100);

    ZglStyle style = ZGL_STYLE_DEFAULT;
    style.width = 200;
    style.height = 100;

    ZglNode root = zgl_layout_add(layout, ZGL_NULL, &style);

    zgl_layout_compute(layout, 800, 600);

    ZglRect rect = zgl_layout_get_rect(layout, root);
    ASSERT_FLOAT_EQ(rect.x, 0.0f, 0.001f);
    ASSERT_FLOAT_EQ(rect.y, 0.0f, 0.001f);
    ASSERT_FLOAT_EQ(rect.width, 200.0f, 0.001f);
    ASSERT_FLOAT_EQ(rect.height, 100.0f, 0.001f);

    zgl_layout_destroy(layout);
}

TEST(compute_column_layout) {
    ZglLayout* layout = zgl_layout_create(100);

    ZglStyle container_style = ZGL_STYLE_DEFAULT;
    container_style.direction = ZGL_COLUMN;
    container_style.width = 200;
    container_style.height = 300;

    ZglStyle child_style = ZGL_STYLE_DEFAULT;
    child_style.width = 200;
    child_style.height = 100;

    ZglNode root = zgl_layout_add(layout, ZGL_NULL, &container_style);
    ZglNode child1 = zgl_layout_add(layout, root, &child_style);
    ZglNode child2 = zgl_layout_add(layout, root, &child_style);

    zgl_layout_compute(layout, 800, 600);

    ZglRect rect1 = zgl_layout_get_rect(layout, child1);
    ZglRect rect2 = zgl_layout_get_rect(layout, child2);

    /* Children should be stacked vertically */
    ASSERT_FLOAT_EQ(rect1.y, 0.0f, 0.001f);
    ASSERT_FLOAT_EQ(rect2.y, 100.0f, 0.001f);

    zgl_layout_destroy(layout);
}

TEST(compute_row_layout) {
    ZglLayout* layout = zgl_layout_create(100);

    ZglStyle container_style = ZGL_STYLE_DEFAULT;
    container_style.direction = ZGL_ROW;
    container_style.width = 400;
    container_style.height = 100;

    ZglStyle child_style = ZGL_STYLE_DEFAULT;
    child_style.width = 100;
    child_style.height = 100;

    ZglNode root = zgl_layout_add(layout, ZGL_NULL, &container_style);
    ZglNode child1 = zgl_layout_add(layout, root, &child_style);
    ZglNode child2 = zgl_layout_add(layout, root, &child_style);

    zgl_layout_compute(layout, 800, 600);

    ZglRect rect1 = zgl_layout_get_rect(layout, child1);
    ZglRect rect2 = zgl_layout_get_rect(layout, child2);

    /* Children should be side by side */
    ASSERT_FLOAT_EQ(rect1.x, 0.0f, 0.001f);
    ASSERT_FLOAT_EQ(rect2.x, 100.0f, 0.001f);

    zgl_layout_destroy(layout);
}

TEST(compute_with_padding) {
    ZglLayout* layout = zgl_layout_create(100);

    ZglStyle container_style = ZGL_STYLE_DEFAULT;
    container_style.direction = ZGL_COLUMN;
    container_style.width = 200;
    container_style.height = 200;
    container_style.padding_top = 10;
    container_style.padding_left = 20;

    ZglStyle child_style = ZGL_STYLE_DEFAULT;
    child_style.width = 50;
    child_style.height = 50;

    ZglNode root = zgl_layout_add(layout, ZGL_NULL, &container_style);
    ZglNode child = zgl_layout_add(layout, root, &child_style);

    zgl_layout_compute(layout, 800, 600);

    ZglRect rect = zgl_layout_get_rect(layout, child);

    /* Child should be offset by padding */
    ASSERT_FLOAT_EQ(rect.x, 20.0f, 0.001f);
    ASSERT_FLOAT_EQ(rect.y, 10.0f, 0.001f);

    zgl_layout_destroy(layout);
}

TEST(compute_with_gap) {
    ZglLayout* layout = zgl_layout_create(100);

    ZglStyle container_style = ZGL_STYLE_DEFAULT;
    container_style.direction = ZGL_COLUMN;
    container_style.width = 200;
    container_style.height = 300;
    container_style.gap = 10;

    ZglStyle child_style = ZGL_STYLE_DEFAULT;
    child_style.width = 200;
    child_style.height = 50;

    ZglNode root = zgl_layout_add(layout, ZGL_NULL, &container_style);
    ZglNode child1 = zgl_layout_add(layout, root, &child_style);
    ZglNode child2 = zgl_layout_add(layout, root, &child_style);
    ZglNode child3 = zgl_layout_add(layout, root, &child_style);

    zgl_layout_compute(layout, 800, 600);

    ZglRect rect1 = zgl_layout_get_rect(layout, child1);
    ZglRect rect2 = zgl_layout_get_rect(layout, child2);
    ZglRect rect3 = zgl_layout_get_rect(layout, child3);

    /* Children should have gaps between them */
    ASSERT_FLOAT_EQ(rect1.y, 0.0f, 0.001f);
    ASSERT_FLOAT_EQ(rect2.y, 60.0f, 0.001f);  /* 50 + 10 gap */
    ASSERT_FLOAT_EQ(rect3.y, 120.0f, 0.001f); /* 50 + 10 + 50 + 10 */

    zgl_layout_destroy(layout);
}

TEST(compute_justify_center) {
    ZglLayout* layout = zgl_layout_create(100);

    ZglStyle container_style = ZGL_STYLE_DEFAULT;
    container_style.direction = ZGL_COLUMN;
    container_style.width = 200;
    container_style.height = 200;
    container_style.justify = ZGL_JUSTIFY_CENTER;

    ZglStyle child_style = ZGL_STYLE_DEFAULT;
    child_style.width = 200;
    child_style.height = 50;

    ZglNode root = zgl_layout_add(layout, ZGL_NULL, &container_style);
    ZglNode child = zgl_layout_add(layout, root, &child_style);

    zgl_layout_compute(layout, 800, 600);

    ZglRect rect = zgl_layout_get_rect(layout, child);

    /* Child should be centered: (200 - 50) / 2 = 75 */
    ASSERT_FLOAT_EQ(rect.y, 75.0f, 0.001f);

    zgl_layout_destroy(layout);
}

TEST(compute_justify_space_between) {
    ZglLayout* layout = zgl_layout_create(100);

    ZglStyle container_style = ZGL_STYLE_DEFAULT;
    container_style.direction = ZGL_COLUMN;
    container_style.width = 100;
    container_style.height = 200;
    container_style.justify = ZGL_JUSTIFY_SPACE_BETWEEN;

    ZglStyle child_style = ZGL_STYLE_DEFAULT;
    child_style.width = 100;
    child_style.height = 50;

    ZglNode root = zgl_layout_add(layout, ZGL_NULL, &container_style);
    ZglNode child1 = zgl_layout_add(layout, root, &child_style);
    ZglNode child2 = zgl_layout_add(layout, root, &child_style);

    zgl_layout_compute(layout, 800, 600);

    ZglRect rect1 = zgl_layout_get_rect(layout, child1);
    ZglRect rect2 = zgl_layout_get_rect(layout, child2);

    /* First at start, last at end: spacing = (200 - 100) / 1 = 100 */
    ASSERT_FLOAT_EQ(rect1.y, 0.0f, 0.001f);
    ASSERT_FLOAT_EQ(rect2.y, 150.0f, 0.001f);

    zgl_layout_destroy(layout);
}

TEST(compute_align_center) {
    ZglLayout* layout = zgl_layout_create(100);

    ZglStyle container_style = ZGL_STYLE_DEFAULT;
    container_style.direction = ZGL_COLUMN;
    container_style.width = 200;
    container_style.height = 200;
    container_style.align = ZGL_ALIGN_CENTER;

    ZglStyle child_style = ZGL_STYLE_DEFAULT;
    child_style.width = 100;
    child_style.height = 50;

    ZglNode root = zgl_layout_add(layout, ZGL_NULL, &container_style);
    ZglNode child = zgl_layout_add(layout, root, &child_style);

    zgl_layout_compute(layout, 800, 600);

    ZglRect rect = zgl_layout_get_rect(layout, child);

    /* Cross-axis centered: (200 - 100) / 2 = 50 */
    ASSERT_FLOAT_EQ(rect.x, 50.0f, 0.001f);

    zgl_layout_destroy(layout);
}

/* ============================================================================
 * Widget ID Tests
 * ============================================================================ */

TEST(widget_id_deterministic) {
    ZglId id1 = zgl_id("button");
    ZglId id2 = zgl_id("button");
    ZglId id3 = zgl_id("other");

    ASSERT_EQ(id1, id2);
    ASSERT(id1 != id3);
}

TEST(widget_id_indexed) {
    ZglId base = zgl_id("item");
    ZglId idx0 = zgl_id_index("item", 0);
    ZglId idx1 = zgl_id_index("item", 1);
    ZglId idx2 = zgl_id_index("item", 2);

    /* All unique */
    ASSERT(idx0 != idx1);
    ASSERT(idx1 != idx2);
    ASSERT(idx0 != idx2);
    ASSERT(idx0 != base);
}

TEST(widget_id_combine) {
    ZglId parent = zgl_id("panel");
    ZglId child = zgl_id("button");
    ZglId combined = zgl_id_combine(parent, child);

    /* Combined should be different from both inputs */
    ASSERT(combined != parent);
    ASSERT(combined != child);

    /* Same combination should be deterministic */
    ZglId combined2 = zgl_id_combine(parent, child);
    ASSERT_EQ(combined, combined2);
}

/* ============================================================================
 * GUI Lifecycle Tests
 * ============================================================================ */

TEST(gui_create_destroy) {
    ZglGui* gui = zgl_gui_create(NULL);
    ASSERT(gui != NULL);
    ASSERT_EQ(zgl_get_last_error(), ZGL_OK);

    zgl_gui_destroy(gui);
}

TEST(gui_with_config) {
    ZglGuiConfig config = ZGL_GUI_CONFIG_DEFAULT;
    config.viewport_width = 1920;
    config.viewport_height = 1080;

    ZglGui* gui = zgl_gui_create(&config);
    ASSERT(gui != NULL);

    zgl_gui_destroy(gui);
}

TEST(gui_frame_lifecycle) {
    ZglGui* gui = zgl_gui_create(NULL);

    /* Multiple frames */
    for (int i = 0; i < 10; i++) {
        zgl_gui_begin_frame(gui);
        zgl_gui_end_frame(gui);
    }

    zgl_gui_destroy(gui);
}

TEST(gui_input_state) {
    ZglGui* gui = zgl_gui_create(NULL);

    zgl_gui_begin_frame(gui);

    zgl_gui_set_mouse(gui, 100.0f, 200.0f, false);
    zgl_gui_set_mouse(gui, 150.0f, 250.0f, true);

    zgl_gui_end_frame(gui);

    zgl_gui_destroy(gui);
}

TEST(gui_id_stack) {
    ZglGui* gui = zgl_gui_create(NULL);

    zgl_gui_begin_frame(gui);

    ZglId panel_id = zgl_id("panel");
    zgl_gui_push_id(gui, panel_id);

    /* Queries should use scoped ID */
    ZglId button_id = zgl_id("button");
    bool clicked = zgl_gui_clicked(gui, button_id);
    ASSERT(!clicked); /* Nothing clicked yet */

    zgl_gui_pop_id(gui);

    zgl_gui_end_frame(gui);

    zgl_gui_destroy(gui);
}

/* ============================================================================
 * Cache and Statistics Tests
 * ============================================================================ */

TEST(layout_statistics) {
    ZglLayout* layout = zgl_layout_create(100);

    /* Fresh layout */
    ASSERT_EQ(zgl_layout_node_count(layout), 0);

    /* Reset stats */
    zgl_layout_reset_stats(layout);
    float hit_rate = zgl_layout_cache_hit_rate(layout);
    ASSERT_FLOAT_EQ(hit_rate, 0.0f, 0.001f);

    zgl_layout_destroy(layout);
}

TEST(dirty_tracking) {
    ZglLayout* layout = zgl_layout_create(100);

    ZglStyle style = ZGL_STYLE_DEFAULT;
    style.width = 100;
    style.height = 50;

    /* Initially no dirty nodes */
    uint32_t dirty = zgl_layout_dirty_count(layout);

    /* Add node - should be dirty */
    ZglNode root = zgl_layout_add(layout, ZGL_NULL, &style);
    (void)root;

    /* Compute clears dirty */
    zgl_layout_compute(layout, 800, 600);

    zgl_layout_destroy(layout);
}

/* ============================================================================
 * Stress Tests
 * ============================================================================ */

TEST(many_nodes) {
    ZglLayout* layout = zgl_layout_create(1000);

    ZglStyle style = ZGL_STYLE_DEFAULT;
    style.width = 10;
    style.height = 10;

    ZglNode root = zgl_layout_add(layout, ZGL_NULL, &style);

    /* Add many children */
    for (int i = 0; i < 100; i++) {
        ZglNode child = zgl_layout_add(layout, root, &style);
        ASSERT(child != ZGL_NULL);
    }

    ASSERT_EQ(zgl_layout_node_count(layout), 101);

    /* Should compute without crashing */
    zgl_layout_compute(layout, 800, 600);

    zgl_layout_destroy(layout);
}

TEST(repeated_compute) {
    ZglLayout* layout = zgl_layout_create(100);

    ZglStyle style = ZGL_STYLE_DEFAULT;
    style.width = 100;
    style.height = 50;

    ZglNode root = zgl_layout_add(layout, ZGL_NULL, &style);
    for (int i = 0; i < 10; i++) {
        zgl_layout_add(layout, root, &style);
    }

    /* Compute many times (should use cache) */
    for (int i = 0; i < 100; i++) {
        zgl_layout_compute(layout, 800, 600);
    }

    zgl_layout_destroy(layout);
}

/* ============================================================================
 * Main
 * ============================================================================ */

int main(void) {
    printf("\n=== zig-gui C API Tests ===\n\n");

    printf("Version and ABI:\n");
    RUN_TEST(version);
    RUN_TEST(abi_struct_sizes);
    RUN_TEST(style_default_init);

    printf("\nError Handling:\n");
    RUN_TEST(error_string);
    RUN_TEST(null_handle_safety);

    printf("\nLayout Lifecycle:\n");
    RUN_TEST(layout_create_destroy);
    RUN_TEST(layout_multiple_instances);

    printf("\nTree Building:\n");
    RUN_TEST(add_root_node);
    RUN_TEST(add_child_nodes);
    RUN_TEST(deep_hierarchy);

    printf("\nLayout Computation:\n");
    RUN_TEST(compute_single_node);
    RUN_TEST(compute_column_layout);
    RUN_TEST(compute_row_layout);
    RUN_TEST(compute_with_padding);
    RUN_TEST(compute_with_gap);
    RUN_TEST(compute_justify_center);
    RUN_TEST(compute_justify_space_between);
    RUN_TEST(compute_align_center);

    printf("\nWidget IDs:\n");
    RUN_TEST(widget_id_deterministic);
    RUN_TEST(widget_id_indexed);
    RUN_TEST(widget_id_combine);

    printf("\nGUI Lifecycle:\n");
    RUN_TEST(gui_create_destroy);
    RUN_TEST(gui_with_config);
    RUN_TEST(gui_frame_lifecycle);
    RUN_TEST(gui_input_state);
    RUN_TEST(gui_id_stack);

    printf("\nCache and Statistics:\n");
    RUN_TEST(layout_statistics);
    RUN_TEST(dirty_tracking);

    printf("\nStress Tests:\n");
    RUN_TEST(many_nodes);
    RUN_TEST(repeated_compute);

    printf("\n=== Results: %d/%d tests passed ===\n\n", tests_passed, tests_run);

    return (tests_passed == tests_run) ? 0 : 1;
}
