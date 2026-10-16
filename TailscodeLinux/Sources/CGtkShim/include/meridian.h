#pragma once
#include <glib.h>
#include <gtk/gtk.h>

/// The world clock's drawing. Every widget here is a plain drawing area that keeps a copy of what it
/// was told and paints it; none of them decides anything, so a time, a position or a colour is
/// always the caller's. Colours are RGB in 0-1.

/// The inks every Meridian widget paints with, eleven colours in this order: canvas, text, dim,
/// accent, warn, info, special, night, day, raised, rule. A widget keeps its own copy.
#define TAILSCODE_MERIDIAN_INKS 11
void tailscode_meridian_set_inks(GtkWidget *widget, const double *rgb);

typedef enum {
    TAILSCODE_GLYPH_SKY_NIGHT = 0,
    TAILSCODE_GLYPH_SKY_TWILIGHT = 1,
    TAILSCODE_GLYPH_SKY_DAY = 2,
    TAILSCODE_GLYPH_SUN = 3,
    TAILSCODE_GLYPH_MOON = 4,
    TAILSCODE_GLYPH_GLOBE = 5,
    TAILSCODE_GLYPH_CLOCK = 6,
    TAILSCODE_GLYPH_INFO = 7,
} TailscodeGlyphKind;

/// A square glyph of the given size. The sky kinds draw a horizon with a half-circle arc over it and
/// the body at `progress` along the arc (0 the left horizon, 1 the right), in `body` over `ink`; the
/// icon kinds draw one stroked or filled icon in `body`.
GtkWidget *tailscode_glyph_new(int size);
void tailscode_glyph_set(
    GtkWidget *glyph, int kind, double progress, const double *body, const double *ink);

/// What a press on a strip's mark or a drag on the scrubber tells its owner. For a strip `kind` is 0
/// and `value` the mark's index; for the scrubber `kind` is 0 on press, 1 on drag and 2 on release
/// and `value` the position as a fraction of the track.
typedef void (*TailscodeMeridianHandler)(void *data, int kind, double value);

/// A day laid along a line: a gradient from night to day through the stops, rounded, with an
/// optional hour grid, a sun at noon, a dot where the moment is, and marks. `widget_height` is the
/// widget's own, `strip_height` the painted band centred in it.
GtkWidget *tailscode_strip_new(int widget_height, int strip_height, double radius);

/// The gradient as `count` pairs of (position, light).
void tailscode_strip_set_stops(GtkWidget *strip, const double *pairs, int count);

/// The hairline inside the edge (alpha 0 for none) and the hour grid (`grid_count` equal divisions,
/// 0 for none) with its alpha.
void tailscode_strip_set_finish(GtkWidget *strip, double hairline, int grid_count, double grid_alpha);

/// The sun at noon, a fraction of the width, or a negative number for none.
void tailscode_strip_set_noon(GtkWidget *strip, double position);

/// The moment's dot: a fraction of the width (negative for none), its radius, and its colour.
void tailscode_strip_set_dot(GtkWidget *strip, double position, double radius, const double *rgb);

/// The marks on the strip: `kinds` 0 a reset (a tick the strip's height and a label in a pill), 1 an
/// alarm (a diamond and its time). `positions` are fractions of the width.
void tailscode_strip_set_marks(
    GtkWidget *strip, int count, const int *kinds, const double *positions, const char *const *labels);
void tailscode_strip_set_handler(GtkWidget *strip, TailscodeMeridianHandler handler, void *data);

/// Where a mark is as drawn now, `x, y, width, height` in widget pixels, for the harness.
int tailscode_strip_mark_rect(GtkWidget *strip, int index, double *out);

/// The lines that cross every lane: a band where everyone is awake (negative start for none) with
/// its label at the top, the line that is now, and the line being read.
GtkWidget *tailscode_lines_new(void);
void tailscode_lines_set(
    GtkWidget *lines, double golden_start, double golden_end, const char *golden_label,
    double now_position, double line_position);

/// The hour labels above the lanes: positions as fractions of the width. The first is set flush
/// left and the last flush right; the rest are centred on their position.
GtkWidget *tailscode_ticks_new(void);
void tailscode_ticks_set(GtkWidget *ticks, int count, const double *positions, const char *const *labels);

/// The track under the lanes and the thumb on it, at a fraction of the track.
GtkWidget *tailscode_scrubber_new(TailscodeMeridianHandler handler, void *data);
void tailscode_scrubber_set(GtkWidget *scrubber, double position);
double tailscode_scrubber_position(GtkWidget *scrubber);

/// Points the scrubber at a different owner, or at none (NULL).
void tailscode_scrubber_set_handler(GtkWidget *scrubber, TailscodeMeridianHandler handler, void *data);
