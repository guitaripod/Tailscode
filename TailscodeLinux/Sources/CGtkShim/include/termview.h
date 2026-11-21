#ifndef TAILSCODE_TERMVIEW_H
#define TAILSCODE_TERMVIEW_H

#include <gtk/gtk.h>
#include <terminal_engine.h>

/// What a terminal view tells its owner. Every call arrives on the GTK thread. Sizes and
/// positions are in device pixels, so a cell's size and a pointer's place are whole numbers in
/// one unit on a display of any density.
typedef struct {
    /// The grid the view can show changed, or its cells did.
    void (*resized)(int cols, int rows, int cell_width, int cell_height, int padding, int width, int height, void *data);
    /// A key that typed no text: an arrow, Return, anything held with Control or Alt. True when
    /// the owner took it.
    gboolean (*key)(guint keyval, guint keycode, guint state, void *data);
    /// Text the input method settled on: a letter, a composed character, a whole word.
    void (*text)(const char *utf8, void *data);
    /// 0 a press, 1 a release, 2 a move. `button` is 0 when none is down.
    void (*pointer)(int kind, int button, double x, double y, guint state, void *data);
    void (*scroll)(double rows, double x, double y, guint state, void *data);
    void (*focus)(gboolean focused, void *data);
    /// The frame clock reached the frame the owner asked to be woken for.
    void (*tick)(void *data);
} TailscodeTermCallbacks;

/// A terminal's picture: a grid of cells drawn as GPU nodes, one cached node per row, so a frame
/// in which three rows changed rebuilds three rows and the compositor repaints only those.
GtkWidget *tailscode_term_view_new(const TailscodeTermCallbacks *callbacks, void *data, void (*destroy)(void *));

/// The face and size the grid is set in. `points` is the size at a scale of one.
void tailscode_term_view_set_font(GtkWidget *view, const char *family, double points);

/// The colour behind the grid before there is a frame to say: 0xRRGGBB. A pane with no shell
/// yet wears the theme like the rest of the window.
void tailscode_term_view_set_canvas(GtkWidget *view, uint32_t rgb);

/// Takes a frame: rebuilds the rows it says changed and asks for a redraw when anything did.
void tailscode_term_view_update(GtkWidget *view, const TSFrame *frame);

/// Asks for one call of `tick` on the next frame the display draws. Asking twice before it comes
/// is asking once, and a view that is not on screen is not woken at all.
void tailscode_term_view_request_tick(GtkWidget *view);

gboolean tailscode_term_view_is_mapped(GtkWidget *view);

/// The size the desktop sets its own text in, which a terminal starts from.
double tailscode_term_default_points(void);

/// How many times any terminal view has rebuilt a row and drawn itself, for a test that proves a
/// quiet terminal costs nothing.
long tailscode_term_view_rows_built(void);
long tailscode_term_view_snapshots(void);

#endif
