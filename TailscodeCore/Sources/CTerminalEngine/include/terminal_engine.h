#ifndef TAILSCODE_TERMINAL_ENGINE_H
#define TAILSCODE_TERMINAL_ENGINE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// A terminal emulator: the screen a shell's bytes add up to, and the bytes a keyboard and a mouse
/// turn into. The emulation is libghostty-vt's; this is the narrow, thread-safe door every client
/// uses to it, so no client holds an engine type and none makes a rule the others do not share.
///
/// Every function may be called from any thread. Bytes are usually written on one thread while
/// another draws: a frame is a copy taken under the engine's lock and read after it is released.
typedef struct TSTerminal TSTerminal;

enum {
  TS_CELL_BOLD = 1 << 0,
  TS_CELL_ITALIC = 1 << 1,
  TS_CELL_STRIKETHROUGH = 1 << 2,
  TS_CELL_OVERLINE = 1 << 3,
  TS_CELL_SELECTED = 1 << 4,
  /// The cell's background is not the screen's: there is a rectangle to fill.
  TS_CELL_FILLED = 1 << 5,
  TS_CELL_UNDERLINE_SHIFT = 8,
  TS_CELL_UNDERLINE_MASK = 7 << 8,
};

enum {
  TS_UNDERLINE_NONE = 0,
  TS_UNDERLINE_SINGLE = 1,
  TS_UNDERLINE_DOUBLE = 2,
  TS_UNDERLINE_CURLY = 3,
  TS_UNDERLINE_DOTTED = 4,
  TS_UNDERLINE_DASHED = 5,
};

/// One cell, ready to draw: its colours are final (palette, defaults, reverse video, faint,
/// concealed and selection are already in them).
typedef struct {
  /// The first codepoint, 0 for an empty cell.
  uint32_t codepoint;
  /// 0xRRGGBB.
  uint32_t fg;
  uint32_t bg;
  uint32_t decoration;
  uint16_t flags;
  /// 1, 2 for a wide character, 0 for the second half of one.
  uint8_t width;
  /// How many more codepoints the cell holds (accents, joiners), found in the row's extras.
  uint8_t extra;
  /// Where this cell's extra codepoints start in the row's extras.
  uint16_t extra_offset;
  uint16_t reserved;
} TSCell;

enum {
  TS_DIRTY_NONE = 0,
  TS_DIRTY_ROWS = 1,
  TS_DIRTY_ALL = 2,
};

enum {
  TS_CURSOR_BAR = 0,
  TS_CURSOR_BLOCK = 1,
  TS_CURSOR_UNDERLINE = 2,
  TS_CURSOR_HOLLOW = 3,
};

/// What a renderer needs for one frame. The pointers belong to the terminal and are valid until
/// the next ts_terminal_frame or ts_terminal_free on the same terminal.
typedef struct {
  uint16_t cols;
  uint16_t rows;
  uint8_t dirty;
  /// rows * cols cells, row after row.
  const TSCell* cells;
  /// One byte per row, 1 where the row changed since the frame before.
  const uint8_t* row_dirty;
  /// Per row, the extra codepoints of its cells.
  const uint32_t* const* row_extras;
  uint32_t background;
  uint32_t foreground;
  uint32_t cursor_color;
  bool cursor_visible;
  bool cursor_blinking;
  uint8_t cursor_style;
  uint16_t cursor_x;
  uint16_t cursor_y;
  /// Every row there is, scrollback included, the row the screen starts at, and how many show.
  uint64_t scroll_total;
  uint64_t scroll_offset;
  uint64_t scroll_length;
  bool alternate_screen;
  bool mouse_tracking;
  /// Counted up on every bell, so a renderer can tell a new one from the last.
  uint32_t bells;
  /// Counted up whenever the title or the folder the shell reported changes.
  uint32_t title_generation;
} TSFrame;

/// False where the build has no engine linked; every other call is then a no-op.
bool ts_engine_available(void);

TSTerminal* ts_terminal_new(uint16_t cols, uint16_t rows, uint32_t scrollback_lines);
void ts_terminal_free(TSTerminal* terminal);

/// The shell's output. Anything the terminal must answer (a status report, a size query) is kept
/// for ts_terminal_take_replies.
void ts_terminal_write(TSTerminal* terminal, const uint8_t* bytes, size_t length);

/// The bytes the terminal owes the shell since the last call. The caller frees them with
/// ts_bytes_free. Returns NULL when there are none.
uint8_t* ts_terminal_take_replies(TSTerminal* terminal, size_t* length);
void ts_bytes_free(uint8_t* bytes);

void ts_terminal_resize(TSTerminal* terminal, uint16_t cols, uint16_t rows, uint32_t cell_width, uint32_t cell_height);

/// Forgets everything: screen, scrollback, modes. For a stream that starts over.
void ts_terminal_reset(TSTerminal* terminal);

/// Colours as 0xRRGGBB. `ansi` is the sixteen named colours.
void ts_terminal_set_theme(TSTerminal* terminal, uint32_t foreground, uint32_t background, uint32_t cursor, const uint32_t* ansi, uint32_t selection_foreground, uint32_t selection_background, bool dark);

/// Takes a frame. `force` reports every row as changed, for a renderer that lost its picture.
void ts_terminal_frame(TSTerminal* terminal, TSFrame* frame, bool force);

/// The title a program set, or the folder a shell reported, as UTF-8. Returns the length, which
/// may be larger than `capacity`; nothing is written past `capacity`.
size_t ts_terminal_title(TSTerminal* terminal, char* buffer, size_t capacity);
size_t ts_terminal_reported_directory(TSTerminal* terminal, char* buffer, size_t capacity);

enum {
  TS_MOD_SHIFT = 1 << 0,
  TS_MOD_CTRL = 1 << 1,
  TS_MOD_ALT = 1 << 2,
  TS_MOD_SUPER = 1 << 3,
};

enum {
  TS_KEY_RELEASE = 0,
  TS_KEY_PRESS = 1,
  TS_KEY_REPEAT = 2,
};

/// A key, as the shell should hear it. `key` is a physical key (the W3C code numbering
/// libghostty uses, see TerminalKey in Swift), `text` is what the key typed with its modifiers,
/// when it typed anything, and `unshifted` is the character on the key cap. Returns the number of
/// bytes written to `out`.
size_t ts_terminal_key(TSTerminal* terminal, uint32_t key, uint16_t mods, uint8_t action, const char* text, size_t text_length, uint32_t unshifted, uint8_t* out, size_t capacity);

/// Text that did not come from a key: a paste, a dictation, a drop. Bracketed when the program
/// asked for that, and never able to smuggle the end of a paste. The caller frees the result with
/// ts_bytes_free.
uint8_t* ts_terminal_paste(TSTerminal* terminal, const char* text, size_t length, size_t* out_length);

/// Whether pasting `text` could run a command by itself (it holds a line break) in a program that
/// has not asked for bracketed paste.
bool ts_terminal_paste_is_risky(TSTerminal* terminal, const char* text, size_t length);

/// Tells the program the window gained or lost focus, when it asked to be told.
size_t ts_terminal_focus(TSTerminal* terminal, bool gained, uint8_t* out, size_t capacity);

/// Where things are, in pixels, so a pointer position can be turned into a cell.
void ts_terminal_set_geometry(TSTerminal* terminal, uint32_t cell_width, uint32_t cell_height, uint32_t padding_left, uint32_t padding_top, uint32_t width, uint32_t height);

enum {
  TS_MOUSE_PRESS = 0,
  TS_MOUSE_RELEASE = 1,
  TS_MOUSE_MOTION = 2,
};

/// A pointer event for a program that asked for the mouse. Returns 0, writing nothing, when no
/// program is listening: the pointer is then the person's, for selecting. `button` is 0 for none,
/// 1 left, 2 right, 3 middle.
size_t ts_terminal_mouse(TSTerminal* terminal, uint8_t action, uint8_t button, uint16_t mods, float x, float y, bool any_pressed, uint8_t* out, size_t capacity);

/// A wheel turn of `rows` rows, negative up. Scrolls the scrollback, or, where a full-screen
/// program has the screen, tells the program instead: the bytes for it are written to `out`.
size_t ts_terminal_wheel(TSTerminal* terminal, int32_t rows, uint16_t mods, float x, float y, uint8_t* out, size_t capacity);

void ts_terminal_scroll_to_bottom(TSTerminal* terminal);
void ts_terminal_scroll_to_row(TSTerminal* terminal, uint64_t row);
void ts_terminal_scroll_pages(TSTerminal* terminal, int32_t pages);

enum {
  TS_SELECT_PRESS = 0,
  TS_SELECT_RELEASE = 1,
  TS_SELECT_DRAG = 2,
};

/// A press, drag or release of the selecting pointer. A second and a third press close together
/// select the word and the line. `time_ns` is any steady clock.
void ts_terminal_select(TSTerminal* terminal, uint8_t type, float x, float y, uint64_t time_ns);
void ts_terminal_select_all(TSTerminal* terminal);
void ts_terminal_clear_selection(TSTerminal* terminal);
bool ts_terminal_has_selection(TSTerminal* terminal);

/// The selected text as UTF-8, wrapped lines joined, or NULL with nothing selected. The caller
/// frees it with ts_bytes_free.
uint8_t* ts_terminal_selection_text(TSTerminal* terminal, size_t* length);

/// The whole of what the terminal holds, scrollback first, as plain UTF-8. The caller frees it
/// with ts_bytes_free.
uint8_t* ts_terminal_text(TSTerminal* terminal, size_t* length);

/// One filled rectangle of a character that is drawn, not typeset: `alpha` is below 1 only for
/// the shade characters.
typedef struct {
  float x;
  float y;
  float width;
  float height;
  float alpha;
} TSBoxRect;

#define TS_BOX_RECTS_MAX 24

/// The rectangles that draw a box-drawing or block character in a cell of the given size, so
/// lines meet from cell to cell whatever the font's own glyphs do. `scale` is device pixels per
/// unit: every edge lands on a device pixel. Returns 0 for a character that is not drawn this
/// way, which is then typeset like any other.
size_t ts_box_drawing(uint32_t codepoint, float width, float height, float scale, TSBoxRect* out);

#ifdef __cplusplus
}
#endif

#endif
