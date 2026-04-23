#ifndef CMUX_GHOSTTY_VT_BRIDGE_H
#define CMUX_GHOSTTY_VT_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

bool cmux_ghostty_vt_can_create_terminal(void);

typedef struct {
    uint16_t cols;
    uint16_t rows;
    uint64_t total_rows;
    uint64_t scrollback_rows;
    bool cursor_visible;
    int32_t active_screen;
} CMUXGhosttyVTCheckpointMetadata;

void *cmux_ghostty_vt_builder_create(uint16_t cols, uint16_t rows, size_t max_scrollback);
void cmux_ghostty_vt_builder_destroy(void *builder);
bool cmux_ghostty_vt_builder_resize(void *builder, uint16_t cols, uint16_t rows);
void cmux_ghostty_vt_builder_ingest(void *builder, const uint8_t *data, size_t len);
bool cmux_ghostty_vt_builder_capture(
    void *builder,
    CMUXGhosttyVTCheckpointMetadata *metadata_out,
    uint8_t **bytes_out,
    size_t *len_out
);
void cmux_ghostty_vt_bytes_free(uint8_t *bytes, size_t len);

#endif
