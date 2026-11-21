#include "terminal_engine.h"

#include <stdlib.h>
#include <string.h>

#if defined(TS_HAS_GHOSTTY) && defined(__APPLE__)
#include <TargetConditionals.h>
#if TARGET_OS_SIMULATOR && defined(__x86_64__)
#undef TS_HAS_GHOSTTY
#endif
#endif

#ifdef TS_HAS_GHOSTTY

#include <ghostty/vt.h>
#include <pthread.h>
#include <time.h>

#define TS_EXTRA_LIMIT 15
#define TS_HOLD_LIMIT_NS 250000000ull
#define TS_REPEAT_CLICK_NS 500000000ull

typedef struct {
  uint8_t* bytes;
  size_t length;
  size_t capacity;
} TSBuffer;

typedef struct {
  uint32_t* codepoints;
  size_t length;
  size_t capacity;
} TSExtras;

struct TSTerminal {
  pthread_mutex_t lock;
  GhosttyTerminal terminal;
  GhosttyRenderState state;
  GhosttyRenderStateRowIterator rows_iterator;
  GhosttyRenderStateRowCells row_cells;
  GhosttyKeyEncoder key_encoder;
  GhosttyKeyEvent key_event;
  GhosttyMouseEncoder mouse_encoder;
  GhosttyMouseEvent mouse_event;
  GhosttySelectionGesture gesture;
  GhosttySelectionGestureEvent gesture_press;
  GhosttySelectionGestureEvent gesture_drag;
  GhosttySelectionGestureEvent gesture_release;
  TSBuffer replies;
  uint16_t cols;
  uint16_t rows;
  TSCell* cells;
  uint8_t* row_dirty;
  TSExtras* extras;
  const uint32_t** extras_view;
  uint16_t grid_cols;
  uint16_t grid_rows;
  uint32_t cell_width;
  uint32_t cell_height;
  uint32_t padding_left;
  uint32_t padding_top;
  uint32_t width;
  uint32_t height;
  uint32_t selection_foreground;
  uint32_t selection_background;
  bool dark;
  bool held;
  uint64_t held_since;
  uint32_t bells;
  uint32_t title_generation;
  bool repaint;
};

static uint64_t ts_now(void) {
  struct timespec now;
  clock_gettime(CLOCK_MONOTONIC, &now);
  return (uint64_t)now.tv_sec * 1000000000ull + (uint64_t)now.tv_nsec;
}

static uint32_t ts_rgb(GhosttyColorRgb color) {
  return ((uint32_t)color.r << 16) | ((uint32_t)color.g << 8) | (uint32_t)color.b;
}

static GhosttyColorRgb ts_color(uint32_t rgb) {
  GhosttyColorRgb color = {.r = (uint8_t)(rgb >> 16), .g = (uint8_t)(rgb >> 8), .b = (uint8_t)rgb};
  return color;
}

static uint32_t ts_blend(uint32_t over, uint32_t under) {
  uint32_t r = (((over >> 16) & 0xff) + ((under >> 16) & 0xff)) / 2;
  uint32_t g = (((over >> 8) & 0xff) + ((under >> 8) & 0xff)) / 2;
  uint32_t b = ((over & 0xff) + (under & 0xff)) / 2;
  return (r << 16) | (g << 8) | b;
}

static void ts_buffer_append(TSBuffer* buffer, const uint8_t* bytes, size_t length) {
  if (length == 0) return;
  if (buffer->length + length > buffer->capacity) {
    size_t capacity = buffer->capacity ? buffer->capacity * 2 : 256;
    while (capacity < buffer->length + length) capacity *= 2;
    uint8_t* grown = realloc(buffer->bytes, capacity);
    if (!grown) return;
    buffer->bytes = grown;
    buffer->capacity = capacity;
  }
  memcpy(buffer->bytes + buffer->length, bytes, length);
  buffer->length += length;
}

static void ts_on_write(GhosttyTerminal terminal, void* userdata, const uint8_t* data, size_t length) {
  (void)terminal;
  TSTerminal* self = userdata;
  ts_buffer_append(&self->replies, data, length);
}

static void ts_on_bell(GhosttyTerminal terminal, void* userdata) {
  (void)terminal;
  ((TSTerminal*)userdata)->bells += 1;
}

static void ts_on_title(GhosttyTerminal terminal, void* userdata) {
  (void)terminal;
  ((TSTerminal*)userdata)->title_generation += 1;
}

static void ts_on_hold(GhosttyTerminal terminal, void* userdata, bool held) {
  (void)terminal;
  TSTerminal* self = userdata;
  self->held = held;
  self->held_since = held ? ts_now() : 0;
}

static bool ts_on_size(GhosttyTerminal terminal, void* userdata, GhosttySizeReportSize* out) {
  (void)terminal;
  TSTerminal* self = userdata;
  out->rows = self->rows;
  out->columns = self->cols;
  out->cell_width = self->cell_width ? self->cell_width : 8;
  out->cell_height = self->cell_height ? self->cell_height : 16;
  return true;
}

static bool ts_on_scheme(GhosttyTerminal terminal, void* userdata, GhosttyColorScheme* out) {
  (void)terminal;
  *out = ((TSTerminal*)userdata)->dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT;
  return true;
}

bool ts_engine_available(void) { return true; }

TSTerminal* ts_terminal_new(uint16_t cols, uint16_t rows, uint32_t scrollback_lines) {
  TSTerminal* self = calloc(1, sizeof(TSTerminal));
  if (!self) return NULL;
  pthread_mutex_init(&self->lock, NULL);
  self->cols = cols ? cols : 80;
  self->rows = rows ? rows : 24;
  self->dark = true;
  self->selection_foreground = 0x000000;
  self->selection_background = 0xb4d5fe;
  bool made =
      ghostty_terminal_new(NULL, &self->terminal, self->cols, self->rows) == GHOSTTY_SUCCESS &&
      ghostty_render_state_new(NULL, &self->state) == GHOSTTY_SUCCESS &&
      ghostty_render_state_row_iterator_new(NULL, &self->rows_iterator) == GHOSTTY_SUCCESS &&
      ghostty_render_state_row_cells_new(NULL, &self->row_cells) == GHOSTTY_SUCCESS &&
      ghostty_key_encoder_new(NULL, &self->key_encoder) == GHOSTTY_SUCCESS &&
      ghostty_key_event_new(NULL, &self->key_event) == GHOSTTY_SUCCESS &&
      ghostty_mouse_encoder_new(NULL, &self->mouse_encoder) == GHOSTTY_SUCCESS &&
      ghostty_mouse_event_new(NULL, &self->mouse_event) == GHOSTTY_SUCCESS &&
      ghostty_selection_gesture_new(NULL, &self->gesture) == GHOSTTY_SUCCESS &&
      ghostty_selection_gesture_event_new(NULL, &self->gesture_press, GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_PRESS) == GHOSTTY_SUCCESS &&
      ghostty_selection_gesture_event_new(NULL, &self->gesture_drag, GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_DRAG) == GHOSTTY_SUCCESS &&
      ghostty_selection_gesture_event_new(NULL, &self->gesture_release, GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_RELEASE) == GHOSTTY_SUCCESS;
  if (!made) {
    ts_terminal_free(self);
    return NULL;
  }
  ghostty_terminal_set(self->terminal, GHOSTTY_TERMINAL_OPT_USERDATA, self);
  ghostty_terminal_set(self->terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY, (const void*)ts_on_write);
  ghostty_terminal_set(self->terminal, GHOSTTY_TERMINAL_OPT_BELL, (const void*)ts_on_bell);
  ghostty_terminal_set(self->terminal, GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, (const void*)ts_on_title);
  ghostty_terminal_set(self->terminal, GHOSTTY_TERMINAL_OPT_PWD_CHANGED, (const void*)ts_on_title);
  ghostty_terminal_set(self->terminal, GHOSTTY_TERMINAL_OPT_RENDER_HOLD, (const void*)ts_on_hold);
  ghostty_terminal_set(self->terminal, GHOSTTY_TERMINAL_OPT_SIZE, (const void*)ts_on_size);
  ghostty_terminal_set(self->terminal, GHOSTTY_TERMINAL_OPT_COLOR_SCHEME, (const void*)ts_on_scheme);
  size_t lines = scrollback_lines;
  ghostty_terminal_set(self->terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &lines);
  self->repaint = true;
  return self;
}

static void ts_grid_free(TSTerminal* self) {
  if (self->extras) {
    for (uint16_t row = 0; row < self->grid_rows; row++) free(self->extras[row].codepoints);
  }
  free(self->extras);
  free(self->extras_view);
  free(self->cells);
  free(self->row_dirty);
  self->extras = NULL;
  self->extras_view = NULL;
  self->cells = NULL;
  self->row_dirty = NULL;
  self->grid_cols = 0;
  self->grid_rows = 0;
}

void ts_terminal_free(TSTerminal* self) {
  if (!self) return;
  if (self->gesture) ghostty_selection_gesture_free(self->gesture, self->terminal);
  if (self->gesture_press) ghostty_selection_gesture_event_free(self->gesture_press);
  if (self->gesture_drag) ghostty_selection_gesture_event_free(self->gesture_drag);
  if (self->gesture_release) ghostty_selection_gesture_event_free(self->gesture_release);
  if (self->mouse_event) ghostty_mouse_event_free(self->mouse_event);
  if (self->mouse_encoder) ghostty_mouse_encoder_free(self->mouse_encoder);
  if (self->key_event) ghostty_key_event_free(self->key_event);
  if (self->key_encoder) ghostty_key_encoder_free(self->key_encoder);
  if (self->row_cells) ghostty_render_state_row_cells_free(self->row_cells);
  if (self->rows_iterator) ghostty_render_state_row_iterator_free(self->rows_iterator);
  if (self->state) ghostty_render_state_free(self->state);
  if (self->terminal) ghostty_terminal_free(self->terminal);
  ts_grid_free(self);
  free(self->replies.bytes);
  pthread_mutex_destroy(&self->lock);
  free(self);
}

void ts_terminal_write(TSTerminal* self, const uint8_t* bytes, size_t length) {
  if (!self || length == 0) return;
  pthread_mutex_lock(&self->lock);
  ghostty_terminal_vt_write(self->terminal, bytes, length);
  pthread_mutex_unlock(&self->lock);
}

uint8_t* ts_terminal_take_replies(TSTerminal* self, size_t* length) {
  *length = 0;
  if (!self) return NULL;
  pthread_mutex_lock(&self->lock);
  uint8_t* bytes = NULL;
  if (self->replies.length > 0) {
    bytes = self->replies.bytes;
    *length = self->replies.length;
    self->replies.bytes = NULL;
    self->replies.length = 0;
    self->replies.capacity = 0;
  }
  pthread_mutex_unlock(&self->lock);
  return bytes;
}

void ts_bytes_free(uint8_t* bytes) { free(bytes); }

void ts_terminal_resize(TSTerminal* self, uint16_t cols, uint16_t rows, uint32_t cell_width, uint32_t cell_height) {
  if (!self || cols == 0 || rows == 0) return;
  pthread_mutex_lock(&self->lock);
  self->cols = cols;
  self->rows = rows;
  self->cell_width = cell_width;
  self->cell_height = cell_height;
  ghostty_terminal_resize(self->terminal, cols, rows, cell_width, cell_height);
  self->repaint = true;
  pthread_mutex_unlock(&self->lock);
}

void ts_terminal_reset(TSTerminal* self) {
  if (!self) return;
  pthread_mutex_lock(&self->lock);
  ghostty_selection_gesture_reset(self->gesture, self->terminal);
  ghostty_terminal_reset(self->terminal);
  self->replies.length = 0;
  self->repaint = true;
  pthread_mutex_unlock(&self->lock);
}

void ts_terminal_set_theme(TSTerminal* self, uint32_t foreground, uint32_t background, uint32_t cursor, const uint32_t* ansi, uint32_t selection_foreground, uint32_t selection_background, bool dark) {
  if (!self) return;
  pthread_mutex_lock(&self->lock);
  GhosttyColorRgb palette[256];
  ghostty_color_palette_default(palette);
  if (ansi) {
    for (int index = 0; index < 16; index++) palette[index] = ts_color(ansi[index]);
  }
  GhosttyColorRgb fg = ts_color(foreground);
  GhosttyColorRgb bg = ts_color(background);
  GhosttyColorRgb caret = ts_color(cursor);
  ghostty_terminal_set(self->terminal, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, palette);
  ghostty_terminal_set(self->terminal, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &fg);
  ghostty_terminal_set(self->terminal, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &bg);
  ghostty_terminal_set(self->terminal, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &caret);
  self->selection_foreground = selection_foreground;
  self->selection_background = selection_background;
  self->dark = dark;
  self->repaint = true;
  pthread_mutex_unlock(&self->lock);
}

static bool ts_mode(TSTerminal* self, GhosttyMode mode) {
  GhosttyTerminalModeConfig config = {.mode = mode, .value = false};
  if (ghostty_terminal_get(self->terminal, GHOSTTY_TERMINAL_DATA_MODE, &config) != GHOSTTY_SUCCESS) return false;
  return config.value;
}

static bool ts_grid_fit(TSTerminal* self, uint16_t cols, uint16_t rows) {
  if (self->grid_cols == cols && self->grid_rows == rows && self->cells) return true;
  ts_grid_free(self);
  self->cells = calloc((size_t)cols * rows, sizeof(TSCell));
  self->row_dirty = calloc(rows, 1);
  self->extras = calloc(rows, sizeof(TSExtras));
  self->extras_view = calloc(rows, sizeof(uint32_t*));
  if (!self->cells || !self->row_dirty || !self->extras || !self->extras_view) {
    ts_grid_free(self);
    return false;
  }
  self->grid_cols = cols;
  self->grid_rows = rows;
  return true;
}

static uint16_t ts_extras_append(TSExtras* extras, const uint32_t* codepoints, size_t count) {
  if (extras->length + count > extras->capacity) {
    size_t capacity = extras->capacity ? extras->capacity * 2 : 16;
    while (capacity < extras->length + count) capacity *= 2;
    uint32_t* grown = realloc(extras->codepoints, capacity * sizeof(uint32_t));
    if (!grown) return 0;
    extras->codepoints = grown;
    extras->capacity = capacity;
  }
  uint16_t offset = (uint16_t)extras->length;
  memcpy(extras->codepoints + extras->length, codepoints, count * sizeof(uint32_t));
  extras->length += count;
  return offset;
}

static void ts_read_row(TSTerminal* self, uint16_t y, const GhosttyRenderStateColors* colors, uint32_t default_fg, uint32_t default_bg) {
  TSCell* row = self->cells + (size_t)y * self->grid_cols;
  TSExtras* extras = &self->extras[y];
  extras->length = 0;
  memset(row, 0, sizeof(TSCell) * self->grid_cols);
  if (ghostty_render_state_row_get(self->rows_iterator, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &self->row_cells) != GHOSTTY_SUCCESS) return;
  GhosttyRenderStateRowSelection selection = GHOSTTY_INIT_SIZED(GhosttyRenderStateRowSelection);
  bool selected_row = ghostty_render_state_row_get(self->rows_iterator, GHOSTTY_RENDER_STATE_ROW_DATA_SELECTION, &selection) == GHOSTTY_SUCCESS;
  uint16_t x = 0;
  while (x < self->grid_cols && ghostty_render_state_row_cells_next(self->row_cells)) {
    TSCell* cell = &row[x];
    cell->fg = default_fg;
    cell->bg = default_bg;
    cell->width = 1;
    GhosttyCell raw = 0;
    GhosttyCellWide wide = GHOSTTY_CELL_WIDE_NARROW;
    if (ghostty_render_state_row_cells_get(self->row_cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw) == GHOSTTY_SUCCESS) {
      ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide);
    }
    if (wide == GHOSTTY_CELL_WIDE_WIDE) cell->width = 2;
    if (wide == GHOSTTY_CELL_WIDE_SPACER_TAIL) cell->width = 0;
    uint32_t codepoints[TS_EXTRA_LIMIT + 1];
    GhosttyCodepointBuffer graphemes = {.ptr = codepoints, .cap = TS_EXTRA_LIMIT + 1};
    ghostty_render_state_row_cells_get(self->row_cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, &graphemes);
    size_t count = graphemes.len < graphemes.cap ? graphemes.len : graphemes.cap;
    if (count > 0) {
      cell->codepoint = codepoints[0];
      if (count > 1) {
        cell->extra = (uint8_t)(count - 1);
        cell->extra_offset = ts_extras_append(extras, codepoints + 1, count - 1);
      }
    }
    GhosttyStyle style;
    ghostty_style_default(&style);
    bool styled = false;
    ghostty_render_state_row_cells_get(self->row_cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_HAS_STYLING, &styled);
    if (styled) ghostty_render_state_row_cells_get(self->row_cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style);
    GhosttyColorRgb resolved;
    if (ghostty_render_state_row_cells_get(self->row_cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &resolved) == GHOSTTY_SUCCESS) cell->fg = ts_rgb(resolved);
    if (ghostty_render_state_row_cells_get(self->row_cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &resolved) == GHOSTTY_SUCCESS) cell->bg = ts_rgb(resolved);
    cell->decoration = cell->fg;
    if (style.underline_color.tag == GHOSTTY_STYLE_COLOR_RGB) cell->decoration = ts_rgb(style.underline_color.value.rgb);
    if (style.underline_color.tag == GHOSTTY_STYLE_COLOR_PALETTE) cell->decoration = ts_rgb(colors->palette[style.underline_color.value.palette]);
    if (style.flags & GHOSTTY_STYLE_FLAG_INVERSE) {
      uint32_t swap = cell->fg;
      cell->fg = cell->bg;
      cell->bg = swap;
    }
    if (style.flags & GHOSTTY_STYLE_FLAG_FAINT) cell->fg = ts_blend(cell->fg, cell->bg);
    if (style.flags & GHOSTTY_STYLE_FLAG_INVISIBLE) cell->fg = cell->bg;
    uint16_t flags = 0;
    if (style.flags & GHOSTTY_STYLE_FLAG_BOLD) flags |= TS_CELL_BOLD;
    if (style.flags & GHOSTTY_STYLE_FLAG_ITALIC) flags |= TS_CELL_ITALIC;
    if (style.flags & GHOSTTY_STYLE_FLAG_STRIKETHROUGH) flags |= TS_CELL_STRIKETHROUGH;
    if (style.flags & GHOSTTY_STYLE_FLAG_OVERLINE) flags |= TS_CELL_OVERLINE;
    flags |= (uint16_t)(GHOSTTY_STYLE_UNDERLINE(style) << TS_CELL_UNDERLINE_SHIFT) & TS_CELL_UNDERLINE_MASK;
    if (selected_row && x >= selection.start_x && x <= selection.end_x) {
      cell->fg = self->selection_foreground;
      cell->bg = self->selection_background;
      flags |= TS_CELL_SELECTED;
    }
    if (cell->bg != default_bg) flags |= TS_CELL_FILLED;
    cell->flags = flags;
    x++;
  }
  self->extras_view[y] = extras->codepoints;
}

void ts_terminal_frame(TSTerminal* self, TSFrame* frame, bool force) {
  memset(frame, 0, sizeof(TSFrame));
  if (!self) return;
  pthread_mutex_lock(&self->lock);
  bool holding = self->held && ts_now() - self->held_since < TS_HOLD_LIMIT_NS;
  if (!holding) ghostty_render_state_update(self->state, self->terminal);
  GhosttyTerminalScrollbar scrollbar = {0};
  ghostty_terminal_get(self->terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &scrollbar);
  GhosttyTerminalScreen screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY;
  ghostty_terminal_get(self->terminal, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen);
  bool tracking = false;
  ghostty_terminal_get(self->terminal, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &tracking);
  bool reversed = ts_mode(self, GHOSTTY_MODE_REVERSE_COLORS);
  if (self->repaint) force = true;
  self->repaint = false;
  frame->bells = self->bells;
  frame->title_generation = self->title_generation;
  pthread_mutex_unlock(&self->lock);

  uint16_t cols = 0;
  uint16_t rows = 0;
  ghostty_render_state_get(self->state, GHOSTTY_RENDER_STATE_DATA_COLS, &cols);
  ghostty_render_state_get(self->state, GHOSTTY_RENDER_STATE_DATA_ROWS, &rows);
  if (cols == 0 || rows == 0) return;
  if (cols != self->grid_cols || rows != self->grid_rows) force = true;
  if (!ts_grid_fit(self, cols, rows)) return;

  GhosttyRenderStateColors colors = GHOSTTY_INIT_SIZED(GhosttyRenderStateColors);
  ghostty_render_state_get(self->state, GHOSTTY_RENDER_STATE_DATA_COLORS, &colors);
  uint32_t default_fg = ts_rgb(reversed ? colors.background : colors.foreground);
  uint32_t default_bg = ts_rgb(reversed ? colors.foreground : colors.background);

  GhosttyRenderStateDirty dirty = GHOSTTY_RENDER_STATE_DIRTY_FALSE;
  ghostty_render_state_get(self->state, GHOSTTY_RENDER_STATE_DATA_DIRTY, &dirty);
  if (force) dirty = GHOSTTY_RENDER_STATE_DIRTY_FULL;
  memset(self->row_dirty, 0, rows);
  if (dirty != GHOSTTY_RENDER_STATE_DIRTY_FALSE &&
      ghostty_render_state_get(self->state, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &self->rows_iterator) == GHOSTTY_SUCCESS) {
    uint16_t y = 0;
    while (y < rows && ghostty_render_state_row_iterator_next(self->rows_iterator)) {
      bool changed = dirty == GHOSTTY_RENDER_STATE_DIRTY_FULL;
      if (!changed) ghostty_render_state_row_get(self->rows_iterator, GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY, &changed);
      if (changed) {
        ts_read_row(self, y, &colors, default_fg, default_bg);
        self->row_dirty[y] = 1;
      }
      y++;
    }
    ghostty_render_state_clean(self->state);
  }

  GhosttyRenderStateCursor cursor = GHOSTTY_INIT_SIZED(GhosttyRenderStateCursor);
  ghostty_render_state_get(self->state, GHOSTTY_RENDER_STATE_DATA_CURSOR, &cursor);
  frame->cols = cols;
  frame->rows = rows;
  frame->dirty = dirty == GHOSTTY_RENDER_STATE_DIRTY_FULL ? TS_DIRTY_ALL : dirty == GHOSTTY_RENDER_STATE_DIRTY_PARTIAL ? TS_DIRTY_ROWS : TS_DIRTY_NONE;
  frame->cells = self->cells;
  frame->row_dirty = self->row_dirty;
  frame->row_extras = self->extras_view;
  frame->background = default_bg;
  frame->foreground = default_fg;
  frame->cursor_color = colors.cursor_has_value ? ts_rgb(colors.cursor) : default_fg;
  frame->cursor_visible = cursor.visible && cursor.viewport_has_value;
  frame->cursor_blinking = cursor.blinking;
  frame->cursor_style = (uint8_t)cursor.visual_style;
  frame->cursor_x = cursor.viewport_x;
  frame->cursor_y = cursor.viewport_y;
  frame->scroll_total = scrollbar.total;
  frame->scroll_offset = scrollbar.offset;
  frame->scroll_length = scrollbar.len;
  frame->alternate_screen = screen == GHOSTTY_TERMINAL_SCREEN_ALTERNATE;
  frame->mouse_tracking = tracking;
}

static size_t ts_copy_string(TSTerminal* self, GhosttyTerminalData data, char* buffer, size_t capacity) {
  if (!self) return 0;
  pthread_mutex_lock(&self->lock);
  GhosttyString text = {0};
  size_t length = 0;
  if (ghostty_terminal_get(self->terminal, data, &text) == GHOSTTY_SUCCESS && text.ptr) {
    length = text.len;
    if (buffer && capacity > 0) memcpy(buffer, text.ptr, length < capacity ? length : capacity);
  }
  pthread_mutex_unlock(&self->lock);
  return length;
}

size_t ts_terminal_title(TSTerminal* self, char* buffer, size_t capacity) {
  return ts_copy_string(self, GHOSTTY_TERMINAL_DATA_TITLE, buffer, capacity);
}

size_t ts_terminal_reported_directory(TSTerminal* self, char* buffer, size_t capacity) {
  return ts_copy_string(self, GHOSTTY_TERMINAL_DATA_PWD, buffer, capacity);
}

static GhosttyMods ts_mods(uint16_t mods) {
  GhosttyMods result = 0;
  if (mods & TS_MOD_SHIFT) result |= GHOSTTY_MODS_SHIFT;
  if (mods & TS_MOD_CTRL) result |= GHOSTTY_MODS_CTRL;
  if (mods & TS_MOD_ALT) result |= GHOSTTY_MODS_ALT;
  if (mods & TS_MOD_SUPER) result |= GHOSTTY_MODS_SUPER;
  return result;
}

static size_t ts_encode_key(TSTerminal* self, uint32_t key, uint16_t mods, uint8_t action, const char* text, size_t text_length, uint32_t unshifted, uint8_t* out, size_t capacity) {
  ghostty_key_encoder_set_from_terminal(self->key_encoder, self->terminal);
  ghostty_key_event_set_action(self->key_event, (GhosttyKeyAction)action);
  ghostty_key_event_set_key(self->key_event, (GhosttyKey)key);
  ghostty_key_event_set_mods(self->key_event, ts_mods(mods));
  GhosttyMods consumed = 0;
  if (text_length > 0 && (mods & TS_MOD_SHIFT)) consumed |= GHOSTTY_MODS_SHIFT;
  ghostty_key_event_set_consumed_mods(self->key_event, consumed);
  ghostty_key_event_set_composing(self->key_event, false);
  GhosttyString utf8 = {.ptr = (const uint8_t*)text, .len = text ? text_length : 0};
  ghostty_key_event_set_utf8(self->key_event, utf8);
  ghostty_key_event_set_unshifted_codepoint(self->key_event, unshifted);
  size_t written = 0;
  if (ghostty_key_encoder_encode(self->key_encoder, self->key_event, out, capacity, &written) != GHOSTTY_SUCCESS) return 0;
  return written;
}

size_t ts_terminal_key(TSTerminal* self, uint32_t key, uint16_t mods, uint8_t action, const char* text, size_t text_length, uint32_t unshifted, uint8_t* out, size_t capacity) {
  if (!self) return 0;
  pthread_mutex_lock(&self->lock);
  size_t written = ts_encode_key(self, key, mods, action, text, text_length, unshifted, out, capacity);
  pthread_mutex_unlock(&self->lock);
  return written;
}

uint8_t* ts_terminal_paste(TSTerminal* self, const char* text, size_t length, size_t* out_length) {
  *out_length = 0;
  if (!self || length == 0) return NULL;
  pthread_mutex_lock(&self->lock);
  bool bracketed = ts_mode(self, GHOSTTY_MODE_BRACKETED_PASTE);
  pthread_mutex_unlock(&self->lock);
  char* scratch = malloc(length);
  if (!scratch) return NULL;
  memcpy(scratch, text, length);
  size_t capacity = length + 16;
  uint8_t* out = malloc(capacity);
  size_t written = 0;
  GhosttyResult result = out ? ghostty_paste_encode(scratch, length, bracketed, out, capacity, &written) : GHOSTTY_OUT_OF_MEMORY;
  if (result == GHOSTTY_OUT_OF_SPACE) {
    free(out);
    capacity = written;
    out = malloc(capacity);
    memcpy(scratch, text, length);
    result = out ? ghostty_paste_encode(scratch, length, bracketed, out, capacity, &written) : GHOSTTY_OUT_OF_MEMORY;
  }
  free(scratch);
  if (result != GHOSTTY_SUCCESS) {
    free(out);
    return NULL;
  }
  *out_length = written;
  return out;
}

bool ts_terminal_paste_is_risky(TSTerminal* self, const char* text, size_t length) {
  if (!self || length == 0) return false;
  pthread_mutex_lock(&self->lock);
  bool bracketed = ts_mode(self, GHOSTTY_MODE_BRACKETED_PASTE);
  pthread_mutex_unlock(&self->lock);
  if (bracketed) return false;
  return !ghostty_paste_is_safe(text, length);
}

size_t ts_terminal_focus(TSTerminal* self, bool gained, uint8_t* out, size_t capacity) {
  if (!self) return 0;
  pthread_mutex_lock(&self->lock);
  bool wanted = ts_mode(self, GHOSTTY_MODE_FOCUS_EVENT);
  pthread_mutex_unlock(&self->lock);
  if (!wanted) return 0;
  size_t written = 0;
  if (ghostty_focus_encode(gained ? GHOSTTY_FOCUS_GAINED : GHOSTTY_FOCUS_LOST, out, capacity, &written) != GHOSTTY_SUCCESS) return 0;
  return written;
}

void ts_terminal_set_geometry(TSTerminal* self, uint32_t cell_width, uint32_t cell_height, uint32_t padding_left, uint32_t padding_top, uint32_t width, uint32_t height) {
  if (!self) return;
  pthread_mutex_lock(&self->lock);
  self->cell_width = cell_width;
  self->cell_height = cell_height;
  self->padding_left = padding_left;
  self->padding_top = padding_top;
  self->width = width;
  self->height = height;
  pthread_mutex_unlock(&self->lock);
}

static size_t ts_encode_mouse(TSTerminal* self, GhosttyMouseAction action, GhosttyMouseButton button, bool has_button, uint16_t mods, float x, float y, bool any_pressed, uint8_t* out, size_t capacity) {
  ghostty_mouse_encoder_set_from_terminal(self->mouse_encoder, self->terminal);
  GhosttyMouseEncoderSize size = GHOSTTY_INIT_SIZED(GhosttyMouseEncoderSize);
  size.screen_width = self->width;
  size.screen_height = self->height;
  size.cell_width = self->cell_width ? self->cell_width : 1;
  size.cell_height = self->cell_height ? self->cell_height : 1;
  size.padding_left = self->padding_left;
  size.padding_top = self->padding_top;
  ghostty_mouse_encoder_set(self->mouse_encoder, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &size);
  ghostty_mouse_encoder_set(self->mouse_encoder, GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, &any_pressed);
  ghostty_mouse_event_set_action(self->mouse_event, action);
  if (has_button) {
    ghostty_mouse_event_set_button(self->mouse_event, button);
  } else {
    ghostty_mouse_event_clear_button(self->mouse_event);
  }
  ghostty_mouse_event_set_mods(self->mouse_event, ts_mods(mods));
  GhosttyMousePosition position = {.x = x, .y = y};
  ghostty_mouse_event_set_position(self->mouse_event, position);
  size_t written = 0;
  if (ghostty_mouse_encoder_encode(self->mouse_encoder, self->mouse_event, out, capacity, &written) != GHOSTTY_SUCCESS) return 0;
  return written;
}

static bool ts_program_has_mouse(TSTerminal* self, uint16_t mods) {
  if (mods & TS_MOD_SHIFT) return false;
  bool tracking = false;
  ghostty_terminal_get(self->terminal, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &tracking);
  return tracking;
}

size_t ts_terminal_mouse(TSTerminal* self, uint8_t action, uint8_t button, uint16_t mods, float x, float y, bool any_pressed, uint8_t* out, size_t capacity) {
  if (!self) return 0;
  pthread_mutex_lock(&self->lock);
  size_t written = 0;
  if (ts_program_has_mouse(self, mods)) {
    GhosttyMouseButton which = button == 1 ? GHOSTTY_MOUSE_BUTTON_LEFT : button == 2 ? GHOSTTY_MOUSE_BUTTON_RIGHT : GHOSTTY_MOUSE_BUTTON_MIDDLE;
    written = ts_encode_mouse(self, (GhosttyMouseAction)action, which, button != 0, mods, x, y, any_pressed, out, capacity);
  }
  pthread_mutex_unlock(&self->lock);
  return written;
}

static void ts_scroll(TSTerminal* self, GhosttyTerminalScrollViewportTag tag, intptr_t delta, size_t row) {
  GhosttyTerminalScrollViewport behavior = {.tag = tag};
  if (tag == GHOSTTY_TERMINAL_SCROLL_VIEWPORT_DELTA) behavior.value.delta = delta;
  if (tag == GHOSTTY_TERMINAL_SCROLL_VIEWPORT_ROW) behavior.value.row = row;
  ghostty_terminal_scroll_viewport(self->terminal, behavior);
}

size_t ts_terminal_wheel(TSTerminal* self, int32_t rows, uint16_t mods, float x, float y, uint8_t* out, size_t capacity) {
  if (!self || rows == 0) return 0;
  pthread_mutex_lock(&self->lock);
  size_t written = 0;
  int32_t steps = rows < 0 ? -rows : rows;
  if (steps > 20) steps = 20;
  GhosttyTerminalScreen screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY;
  ghostty_terminal_get(self->terminal, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen);
  if (ts_program_has_mouse(self, mods)) {
    GhosttyMouseButton button = rows < 0 ? GHOSTTY_MOUSE_BUTTON_FOUR : GHOSTTY_MOUSE_BUTTON_FIVE;
    for (int32_t step = 0; step < steps && written < capacity; step++) {
      written += ts_encode_mouse(self, GHOSTTY_MOUSE_ACTION_PRESS, button, true, mods, x, y, false, out + written, capacity - written);
    }
  } else if (screen == GHOSTTY_TERMINAL_SCREEN_ALTERNATE) {
    GhosttyKey key = rows < 0 ? GHOSTTY_KEY_ARROW_UP : GHOSTTY_KEY_ARROW_DOWN;
    for (int32_t step = 0; step < steps && written < capacity; step++) {
      written += ts_encode_key(self, key, 0, TS_KEY_PRESS, NULL, 0, 0, out + written, capacity - written);
    }
  } else {
    ts_scroll(self, GHOSTTY_TERMINAL_SCROLL_VIEWPORT_DELTA, rows, 0);
  }
  pthread_mutex_unlock(&self->lock);
  return written;
}

void ts_terminal_scroll_to_bottom(TSTerminal* self) {
  if (!self) return;
  pthread_mutex_lock(&self->lock);
  ts_scroll(self, GHOSTTY_TERMINAL_SCROLL_VIEWPORT_BOTTOM, 0, 0);
  pthread_mutex_unlock(&self->lock);
}

void ts_terminal_scroll_to_row(TSTerminal* self, uint64_t row) {
  if (!self) return;
  pthread_mutex_lock(&self->lock);
  ts_scroll(self, GHOSTTY_TERMINAL_SCROLL_VIEWPORT_ROW, 0, (size_t)row);
  pthread_mutex_unlock(&self->lock);
}

void ts_terminal_scroll_pages(TSTerminal* self, int32_t pages) {
  if (!self || pages == 0) return;
  pthread_mutex_lock(&self->lock);
  intptr_t page = self->rows > 1 ? self->rows - 1 : 1;
  ts_scroll(self, GHOSTTY_TERMINAL_SCROLL_VIEWPORT_DELTA, page * pages, 0);
  pthread_mutex_unlock(&self->lock);
}

static bool ts_ref_at(TSTerminal* self, float x, float y, GhosttyGridRef* ref) {
  uint32_t cell_width = self->cell_width ? self->cell_width : 1;
  uint32_t cell_height = self->cell_height ? self->cell_height : 1;
  float left = x - (float)self->padding_left;
  float top = y - (float)self->padding_top;
  int64_t col = left <= 0 ? 0 : (int64_t)(left / (float)cell_width);
  int64_t row = top <= 0 ? 0 : (int64_t)(top / (float)cell_height);
  if (col >= self->cols) col = self->cols - 1;
  if (row >= self->rows) row = self->rows - 1;
  GhosttyPoint point = {.tag = GHOSTTY_POINT_TAG_VIEWPORT};
  point.value.coordinate.x = (uint16_t)col;
  point.value.coordinate.y = (uint32_t)row;
  return ghostty_terminal_grid_ref(self->terminal, point, ref) == GHOSTTY_SUCCESS;
}

void ts_terminal_select(TSTerminal* self, uint8_t type, float x, float y, uint64_t time_ns) {
  if (!self) return;
  pthread_mutex_lock(&self->lock);
  GhosttySelectionGestureEvent event = type == TS_SELECT_PRESS ? self->gesture_press : type == TS_SELECT_DRAG ? self->gesture_drag : self->gesture_release;
  GhosttyGridRef ref = {0};
  if (ts_ref_at(self, x, y, &ref)) {
    ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &ref);
    if (type != TS_SELECT_RELEASE) {
      GhosttySurfacePosition position = {.x = x, .y = y};
      ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION, &position);
    }
    if (type == TS_SELECT_PRESS) {
      uint64_t interval = TS_REPEAT_CLICK_NS;
      double distance = self->cell_width ? (double)self->cell_width : 8.0;
      ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_TIME_NS, &time_ns);
      ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_INTERVAL_NS, &interval);
      ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_DISTANCE, &distance);
    }
    if (type == TS_SELECT_DRAG) {
      GhosttySelectionGestureGeometry geometry = {
          .columns = self->cols,
          .cell_width = self->cell_width ? self->cell_width : 1,
          .padding_left = self->padding_left,
          .screen_height = self->height,
      };
      ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_GEOMETRY, &geometry);
    }
    GhosttySelection selection = {0};
    GhosttyResult result = ghostty_selection_gesture_event(self->gesture, self->terminal, event, type == TS_SELECT_RELEASE ? NULL : &selection);
    if (type != TS_SELECT_RELEASE) {
      if (result == GHOSTTY_SUCCESS) {
        ghostty_terminal_set(self->terminal, GHOSTTY_TERMINAL_OPT_SELECTION, &selection);
      } else if (type == TS_SELECT_PRESS) {
        ghostty_terminal_set(self->terminal, GHOSTTY_TERMINAL_OPT_SELECTION, NULL);
      }
      self->repaint = true;
    }
  }
  pthread_mutex_unlock(&self->lock);
}

void ts_terminal_select_all(TSTerminal* self) {
  if (!self) return;
  pthread_mutex_lock(&self->lock);
  GhosttySelection selection = {0};
  if (ghostty_terminal_select_all(self->terminal, &selection) == GHOSTTY_SUCCESS) {
    ghostty_terminal_set(self->terminal, GHOSTTY_TERMINAL_OPT_SELECTION, &selection);
    self->repaint = true;
  }
  pthread_mutex_unlock(&self->lock);
}

void ts_terminal_clear_selection(TSTerminal* self) {
  if (!self) return;
  pthread_mutex_lock(&self->lock);
  ghostty_terminal_set(self->terminal, GHOSTTY_TERMINAL_OPT_SELECTION, NULL);
  self->repaint = true;
  pthread_mutex_unlock(&self->lock);
}

bool ts_terminal_has_selection(TSTerminal* self) {
  if (!self) return false;
  pthread_mutex_lock(&self->lock);
  GhosttySelection selection = {0};
  bool has = ghostty_terminal_get(self->terminal, GHOSTTY_TERMINAL_DATA_SELECTION, &selection) == GHOSTTY_SUCCESS;
  pthread_mutex_unlock(&self->lock);
  return has;
}

static uint8_t* ts_format(TSTerminal* self, const GhosttySelection* selection, size_t* length) {
  GhosttyFormatter formatter = NULL;
  if (ghostty_formatter_terminal_new(NULL, &formatter, self->terminal) != GHOSTTY_SUCCESS) return NULL;
  GhosttyFormatterFormat emit = GHOSTTY_FORMATTER_FORMAT_PLAIN;
  bool yes = true;
  ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_EMIT, &emit);
  ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_TRIM, &yes);
  ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_UNWRAP, &yes);
  if (selection) ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_SELECTION, selection);
  uint8_t* formatted = NULL;
  size_t formatted_length = 0;
  uint8_t* copy = NULL;
  if (ghostty_formatter_format_alloc(formatter, NULL, &formatted, &formatted_length) == GHOSTTY_SUCCESS) {
    copy = malloc(formatted_length ? formatted_length : 1);
    if (copy) {
      memcpy(copy, formatted, formatted_length);
      *length = formatted_length;
    }
    ghostty_free(NULL, formatted, formatted_length);
  }
  ghostty_formatter_free(formatter);
  return copy;
}

uint8_t* ts_terminal_selection_text(TSTerminal* self, size_t* length) {
  *length = 0;
  if (!self) return NULL;
  pthread_mutex_lock(&self->lock);
  GhosttySelection selection = {0};
  uint8_t* text = NULL;
  if (ghostty_terminal_get(self->terminal, GHOSTTY_TERMINAL_DATA_SELECTION, &selection) == GHOSTTY_SUCCESS) {
    text = ts_format(self, &selection, length);
  }
  pthread_mutex_unlock(&self->lock);
  return text;
}

uint8_t* ts_terminal_text(TSTerminal* self, size_t* length) {
  *length = 0;
  if (!self) return NULL;
  pthread_mutex_lock(&self->lock);
  uint8_t* text = ts_format(self, NULL, length);
  pthread_mutex_unlock(&self->lock);
  return text;
}

#else

bool ts_engine_available(void) { return false; }
TSTerminal* ts_terminal_new(uint16_t cols, uint16_t rows, uint32_t scrollback_lines) {
  (void)cols;
  (void)rows;
  (void)scrollback_lines;
  return NULL;
}
void ts_terminal_free(TSTerminal* terminal) { (void)terminal; }
void ts_terminal_write(TSTerminal* terminal, const uint8_t* bytes, size_t length) {
  (void)terminal;
  (void)bytes;
  (void)length;
}
uint8_t* ts_terminal_take_replies(TSTerminal* terminal, size_t* length) {
  (void)terminal;
  *length = 0;
  return NULL;
}
void ts_bytes_free(uint8_t* bytes) { free(bytes); }
void ts_terminal_resize(TSTerminal* terminal, uint16_t cols, uint16_t rows, uint32_t cell_width, uint32_t cell_height) {
  (void)terminal;
  (void)cols;
  (void)rows;
  (void)cell_width;
  (void)cell_height;
}
void ts_terminal_reset(TSTerminal* terminal) { (void)terminal; }
void ts_terminal_set_theme(TSTerminal* terminal, uint32_t foreground, uint32_t background, uint32_t cursor, const uint32_t* ansi, uint32_t selection_foreground, uint32_t selection_background, bool dark) {
  (void)terminal;
  (void)foreground;
  (void)background;
  (void)cursor;
  (void)ansi;
  (void)selection_foreground;
  (void)selection_background;
  (void)dark;
}
void ts_terminal_frame(TSTerminal* terminal, TSFrame* frame, bool force) {
  (void)terminal;
  (void)force;
  memset(frame, 0, sizeof(TSFrame));
}
size_t ts_terminal_title(TSTerminal* terminal, char* buffer, size_t capacity) {
  (void)terminal;
  (void)buffer;
  (void)capacity;
  return 0;
}
size_t ts_terminal_reported_directory(TSTerminal* terminal, char* buffer, size_t capacity) {
  (void)terminal;
  (void)buffer;
  (void)capacity;
  return 0;
}
size_t ts_terminal_key(TSTerminal* terminal, uint32_t key, uint16_t mods, uint8_t action, const char* text, size_t text_length, uint32_t unshifted, uint8_t* out, size_t capacity) {
  (void)terminal;
  (void)key;
  (void)mods;
  (void)action;
  (void)text;
  (void)text_length;
  (void)unshifted;
  (void)out;
  (void)capacity;
  return 0;
}
uint8_t* ts_terminal_paste(TSTerminal* terminal, const char* text, size_t length, size_t* out_length) {
  (void)terminal;
  (void)text;
  (void)length;
  *out_length = 0;
  return NULL;
}
bool ts_terminal_paste_is_risky(TSTerminal* terminal, const char* text, size_t length) {
  (void)terminal;
  (void)text;
  (void)length;
  return false;
}
size_t ts_terminal_focus(TSTerminal* terminal, bool gained, uint8_t* out, size_t capacity) {
  (void)terminal;
  (void)gained;
  (void)out;
  (void)capacity;
  return 0;
}
void ts_terminal_set_geometry(TSTerminal* terminal, uint32_t cell_width, uint32_t cell_height, uint32_t padding_left, uint32_t padding_top, uint32_t width, uint32_t height) {
  (void)terminal;
  (void)cell_width;
  (void)cell_height;
  (void)padding_left;
  (void)padding_top;
  (void)width;
  (void)height;
}
size_t ts_terminal_mouse(TSTerminal* terminal, uint8_t action, uint8_t button, uint16_t mods, float x, float y, bool any_pressed, uint8_t* out, size_t capacity) {
  (void)terminal;
  (void)action;
  (void)button;
  (void)mods;
  (void)x;
  (void)y;
  (void)any_pressed;
  (void)out;
  (void)capacity;
  return 0;
}
size_t ts_terminal_wheel(TSTerminal* terminal, int32_t rows, uint16_t mods, float x, float y, uint8_t* out, size_t capacity) {
  (void)terminal;
  (void)rows;
  (void)mods;
  (void)x;
  (void)y;
  (void)out;
  (void)capacity;
  return 0;
}
void ts_terminal_scroll_to_bottom(TSTerminal* terminal) { (void)terminal; }
void ts_terminal_scroll_to_row(TSTerminal* terminal, uint64_t row) {
  (void)terminal;
  (void)row;
}
void ts_terminal_scroll_pages(TSTerminal* terminal, int32_t pages) {
  (void)terminal;
  (void)pages;
}
void ts_terminal_select(TSTerminal* terminal, uint8_t type, float x, float y, uint64_t time_ns) {
  (void)terminal;
  (void)type;
  (void)x;
  (void)y;
  (void)time_ns;
}
void ts_terminal_select_all(TSTerminal* terminal) { (void)terminal; }
void ts_terminal_clear_selection(TSTerminal* terminal) { (void)terminal; }
bool ts_terminal_has_selection(TSTerminal* terminal) {
  (void)terminal;
  return false;
}
uint8_t* ts_terminal_selection_text(TSTerminal* terminal, size_t* length) {
  (void)terminal;
  *length = 0;
  return NULL;
}
uint8_t* ts_terminal_text(TSTerminal* terminal, size_t* length) {
  (void)terminal;
  *length = 0;
  return NULL;
}

#endif
