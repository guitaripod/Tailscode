#pragma once
#include <glib.h>
#include <gtk/gtk.h>

/// The neural trace's drawing. The head's two picture layers are cairo image surfaces the shim owns
/// and the Swift compositor writes into, and the nodes, wires, glyph and card are painted by Swift
/// through cairo into a canvas whose draw callback it supplies. Neither decides anything: a
/// picture, a size and a colour are always the caller's.

typedef void (*TailscodeCanvasDraw)(cairo_t *cr, int width, int height, void *data);

/// A drawing area that calls `draw` with its own cairo context and size. `destroy` runs once when
/// the widget is finalized, which is the only moment `data` is provably never drawn with again.
GtkWidget *tailscode_canvas_new(TailscodeCanvasDraw draw, void *data, void (*destroy)(void *));

/// A drawing area that paints one ARGB32 image surface the caller fills with `tailscode_layer_blit`.
/// `opaque` replaces what is under it; otherwise the surface is laid over it, premultiplied.
GtkWidget *tailscode_layer_new(gboolean opaque);

/// Gives the layer a surface of `width` by `height` device pixels drawn at `scale` device pixels
/// per logical one, cleared to transparent. A layer already that size is left as it is.
void tailscode_layer_resize(GtkWidget *layer, int width, int height, int scale);

/// Frees the surface and leaves the layer blank, for a pane that is parked.
void tailscode_layer_release(GtkWidget *layer);

/// Copies the rows `y..<y+h`, columns `x..<x+w`, of a tightly packed BGRA picture `width` pixels
/// wide into the layer's surface and asks for a redraw. A picture of another size is ignored.
void tailscode_layer_blit(
    GtkWidget *layer, const guint8 *bytes, int width, int height, int x, int y, int w, int h);

/// Paints the surface scaled by `scale` about the point (`cx`, `cy`) given as fractions of the
/// layer, which is the interior and the nodes following a dive. A scale of one is pixel-exact.
void tailscode_layer_zoom(GtkWidget *layer, double cx, double cy, double scale);

/// What the layer's surface holds, in bytes, for the harness.
gsize tailscode_layer_footprint(GtkWidget *layer);

/// Presses, with how many were made in a row and which button, wherever they land inside `widget`.
/// Watched in the capture phase and never claimed, so the press keeps its ordinary meaning.
void tailscode_on_click_at(
    GtkWidget *widget, void (*handler)(double x, double y, int presses, int button, void *data),
    void *data);

/// Text through Pango, for painting onto a Swift-owned cairo context. `font` is a Pango font
/// description ("Monospace Bold 9"), `width` the wrap width in pixels or a number below one for
/// none. `align` is 0 left, 1 centre, 2 right; `max_lines` of zero is unlimited and a limit
/// ellipsizes the last line it keeps.
void tailscode_text_measure(
    const char *text, const char *font, double width, int max_lines, double *out_width,
    double *out_height);
double tailscode_text_draw(
    cairo_t *cr, const char *text, const char *font, double x, double y, double width, int align,
    int max_lines, double red, double green, double blue, double alpha);

/// The same with Pango markup, for a word set in two weights.
double tailscode_markup_draw(
    cairo_t *cr, const char *markup, const char *font, double x, double y, double width, int align,
    int max_lines, double red, double green, double blue, double alpha);

/// Whether the pointer is over `widget` or the keyboard is on it, announced once when either
/// begins and once when both have ended. Never claimed, so the widget keeps its own behaviour.
void tailscode_on_hover_focus(
    GtkWidget *widget, void (*enter)(void *), void (*leave)(void *), void *data);

/// A container that keeps its one child at a fixed proportion, as wide as the space allows up to
/// `max_width` and centred, and asks for exactly the height that proportion needs. It requests
/// almost no width of its own, so a narrow pane is never widened by it.
GtkWidget *tailscode_aspect_new(double ratio, int max_width);
void tailscode_aspect_set_child(GtkWidget *aspect, GtkWidget *child);

/// Hands the allocator's free pages back to the system, for the moment after the head's layers
/// are decoded and resampled and their transient copies are gone.
void tailscode_malloc_trim(void);
