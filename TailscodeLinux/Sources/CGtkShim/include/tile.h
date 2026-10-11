#pragma once
#include <glib.h>
#include <gtk/gtk.h>

/// The tiling canvas: one flat container whose children are every pane's shell, every divider and
/// the overlays above them, placed by a solver the host supplies. A structural verb is a different
/// answer from the solver, never a change of parent: a child is added once and removed once, and a
/// child the solver does not place is hidden with `set_child_visible`, which keeps it realised,
/// keeps its size and scroll position, and takes it out of every pointer and focus walk.
///
/// The solver runs inside the canvas's own allocation, so a rect is never a frame late. It reports
/// each placed child through the sink; a child it does not report is not drawn.
typedef struct TailscodeTileSink TailscodeTileSink;

typedef void (*TailscodeTileSolve)(int width, int height, TailscodeTileSink *sink, void *box);

GtkWidget *tailscode_tile_canvas_new(void);

/// The solver and the host's box for it. The box is released with the canvas.
void tailscode_tile_canvas_set_solver(GtkWidget *canvas, TailscodeTileSolve solve, void *box);

/// The least size the canvas asks of its parent; its natural size is the same, so it expands.
void tailscode_tile_canvas_set_minimum(GtkWidget *canvas, int width, int height);

/// Adds a child on a layer: children of a lower layer stand beneath those of a higher one, in the
/// order added within a layer. Pane shells go first, dividers over them, overlays last, so an
/// overlay can never be hidden by a pane. A child that already has a parent is refused and counted
/// by `tailscode_tile_canvas_reparents`, which the selftest holds at zero.
void tailscode_tile_canvas_add(GtkWidget *canvas, GtkWidget *child, int layer);

/// Takes a child out of the canvas through its own container API.
void tailscode_tile_canvas_remove(GtkWidget *canvas, GtkWidget *child);

/// Asks for one allocation pass: the solver runs again at the next layout.
void tailscode_tile_canvas_invalidate(GtkWidget *canvas);

/// Called by the solver, once per child to place.
void tailscode_tile_sink_place(
    TailscodeTileSink *sink, GtkWidget *child, int x, int y, int width, int height);

/// What the selftest and the recorder read: adds refused for already having a parent, the number
/// of allocation passes and how long the last one took (the solver, every child's measure and
/// allocate, and so every transcript relayout beneath), and the number of children.
long tailscode_tile_canvas_reparents(void);
long tailscode_tile_canvas_allocations(GtkWidget *canvas);
long tailscode_tile_canvas_allocate_us(GtkWidget *canvas);
int tailscode_tile_canvas_child_count(GtkWidget *canvas);

/// A container with no minimum size: its children are placed at its origin at the container's size
/// or their own minimum, whichever is larger, and clipped to the container. A pane's shell is one,
/// so a conversation that needs 280 points can sit in a tile 200 points wide while the face that
/// replaces it settles, rather than asking GTK to allocate under a minimum.
GtkWidget *tailscode_tile_clamp_new(void);
void tailscode_tile_clamp_add(GtkWidget *clamp, GtkWidget *child);
void tailscode_tile_clamp_remove(GtkWidget *clamp, GtkWidget *child);

/// A divider between two panes: nine points of hit area with a centred line drawn in the widget's
/// own colour (CSS `color`), two points while hovered, dragged or focused. It is an accessible
/// separator carrying a value, takes the keyboard, and shows a resize cursor.
///
/// Pointer positions are reported in the canvas's coordinates, taken from the event itself rather
/// than from the gesture's offset, which a divider that moves under the pointer would corrupt.
typedef struct {
    void (*began)(double x, double y, void *data);
    void (*moved)(double x, double y, void *data);
    void (*ended)(double x, double y, void *data);
    void (*equalize)(void *data);
    gboolean (*key)(int key, int large, void *data);
} TailscodeTileDividerHandlers;

/// `across` is true when the line runs vertically (the panes sit side by side).
GtkWidget *tailscode_tile_divider_new(
    gboolean across, TailscodeTileDividerHandlers handlers, void *data);
void tailscode_tile_divider_describe(
    GtkWidget *divider, const char *label, double minimum, double maximum, double now,
    const char *text);
gboolean tailscode_tile_divider_focus(GtkWidget *divider);
gboolean tailscode_tile_divider_is(GtkWidget *widget);
char *tailscode_tile_divider_reading(
    GtkWidget *divider, const char *label, double minimum, double maximum, double now);

/// A double press anywhere on `widget` that its children did not claim, so a button inside a tile
/// keeps its own meaning. The handler's data is released with the widget.
void tailscode_tile_on_double_click(GtkWidget *widget, void (*handler)(void *), void *data);
