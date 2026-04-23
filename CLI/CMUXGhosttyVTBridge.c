#include "CMUXGhosttyVTBridge.h"

#include <stdlib.h>
#include <ghostty/vt/terminal.h>
#include <ghostty/vt/formatter.h>

typedef struct {
    GhosttyTerminal terminal;
} CMUXGhosttyVTBuilder;

bool cmux_ghostty_vt_can_create_terminal(void) {
    GhosttyTerminal terminal = NULL;
    GhosttyTerminalOptions options = {
        .cols = 2,
        .rows = 1,
        .max_scrollback = 0,
    };

    GhosttyResult result = ghostty_terminal_new(NULL, &terminal, options);
    if (terminal != NULL) {
        ghostty_terminal_free(terminal);
    }

    return result == GHOSTTY_SUCCESS;
}

void *cmux_ghostty_vt_builder_create(uint16_t cols, uint16_t rows, size_t max_scrollback) {
    CMUXGhosttyVTBuilder *builder = (CMUXGhosttyVTBuilder *)calloc(1, sizeof(CMUXGhosttyVTBuilder));
    if (builder == NULL) {
        return NULL;
    }

    GhosttyTerminalOptions options = {
        .cols = cols,
        .rows = rows,
        .max_scrollback = max_scrollback,
    };

    if (ghostty_terminal_new(NULL, &builder->terminal, options) != GHOSTTY_SUCCESS || builder->terminal == NULL) {
        free(builder);
        return NULL;
    }

    return builder;
}

void cmux_ghostty_vt_builder_destroy(void *builder_ptr) {
    CMUXGhosttyVTBuilder *builder = (CMUXGhosttyVTBuilder *)builder_ptr;
    if (builder == NULL) {
        return;
    }
    if (builder->terminal != NULL) {
        ghostty_terminal_free(builder->terminal);
    }
    free(builder);
}

bool cmux_ghostty_vt_builder_resize(void *builder_ptr, uint16_t cols, uint16_t rows) {
    CMUXGhosttyVTBuilder *builder = (CMUXGhosttyVTBuilder *)builder_ptr;
    if (builder == NULL || builder->terminal == NULL) {
        return false;
    }
    return ghostty_terminal_resize(builder->terminal, cols, rows, 0, 0) == GHOSTTY_SUCCESS;
}

void cmux_ghostty_vt_builder_ingest(void *builder_ptr, const uint8_t *data, size_t len) {
    CMUXGhosttyVTBuilder *builder = (CMUXGhosttyVTBuilder *)builder_ptr;
    if (builder == NULL || builder->terminal == NULL || data == NULL || len == 0) {
        return;
    }
    ghostty_terminal_vt_write(builder->terminal, data, len);
}

bool cmux_ghostty_vt_builder_capture(
    void *builder_ptr,
    CMUXGhosttyVTCheckpointMetadata *metadata_out,
    uint8_t **bytes_out,
    size_t *len_out
) {
    CMUXGhosttyVTBuilder *builder = (CMUXGhosttyVTBuilder *)builder_ptr;
    if (builder == NULL || builder->terminal == NULL || metadata_out == NULL || bytes_out == NULL || len_out == NULL) {
        return false;
    }

    uint16_t cols = 0;
    uint16_t rows = 0;
    uint64_t total_rows = 0;
    uint64_t scrollback_rows = 0;
    bool cursor_visible = false;
    GhosttyTerminalScreen active_screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY;

    if (ghostty_terminal_get(builder->terminal, GHOSTTY_TERMINAL_DATA_COLS, &cols) != GHOSTTY_SUCCESS) return false;
    if (ghostty_terminal_get(builder->terminal, GHOSTTY_TERMINAL_DATA_ROWS, &rows) != GHOSTTY_SUCCESS) return false;
    if (ghostty_terminal_get(builder->terminal, GHOSTTY_TERMINAL_DATA_TOTAL_ROWS, &total_rows) != GHOSTTY_SUCCESS) return false;
    if (ghostty_terminal_get(builder->terminal, GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS, &scrollback_rows) != GHOSTTY_SUCCESS) return false;
    if (ghostty_terminal_get(builder->terminal, GHOSTTY_TERMINAL_DATA_CURSOR_VISIBLE, &cursor_visible) != GHOSTTY_SUCCESS) return false;
    if (ghostty_terminal_get(builder->terminal, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &active_screen) != GHOSTTY_SUCCESS) return false;

    GhosttyFormatterScreenExtra screen_extra = {0};
    screen_extra.size = sizeof(GhosttyFormatterScreenExtra);
    screen_extra.cursor = true;
    screen_extra.style = true;
    screen_extra.hyperlink = true;
    screen_extra.protection = true;
    screen_extra.kitty_keyboard = true;
    screen_extra.charsets = true;

    GhosttyFormatterTerminalExtra terminal_extra = {0};
    terminal_extra.size = sizeof(GhosttyFormatterTerminalExtra);
    terminal_extra.palette = true;
    terminal_extra.modes = true;
    terminal_extra.scrolling_region = true;
    terminal_extra.tabstops = false;
    terminal_extra.pwd = true;
    terminal_extra.keyboard = true;
    terminal_extra.screen = screen_extra;

    GhosttyFormatterTerminalOptions formatter_options = {0};
    formatter_options.size = sizeof(GhosttyFormatterTerminalOptions);
    formatter_options.emit = GHOSTTY_FORMATTER_FORMAT_VT;
    formatter_options.unwrap = false;
    formatter_options.trim = false;
    formatter_options.extra = terminal_extra;
    formatter_options.selection = NULL;

    GhosttyFormatter formatter = NULL;
    if (ghostty_formatter_terminal_new(NULL, &formatter, builder->terminal, formatter_options) != GHOSTTY_SUCCESS || formatter == NULL) {
        return false;
    }

    uint8_t *formatted_bytes = NULL;
    size_t formatted_len = 0;
    GhosttyResult format_result = ghostty_formatter_format_alloc(formatter, NULL, &formatted_bytes, &formatted_len);
    ghostty_formatter_free(formatter);

    if (format_result != GHOSTTY_SUCCESS || formatted_bytes == NULL) {
        return false;
    }

    metadata_out->cols = cols;
    metadata_out->rows = rows;
    metadata_out->total_rows = total_rows;
    metadata_out->scrollback_rows = scrollback_rows;
    metadata_out->cursor_visible = cursor_visible;
    metadata_out->active_screen = (int32_t)active_screen;
    *bytes_out = formatted_bytes;
    *len_out = formatted_len;
    return true;
}

void cmux_ghostty_vt_bytes_free(uint8_t *bytes, size_t len) {
    if (bytes == NULL) {
        return;
    }
    ghostty_free(NULL, bytes, len);
}
