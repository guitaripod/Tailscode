#ifndef TAILSCODE_WALLPAINT_H
#define TAILSCODE_WALLPAINT_H

#include <gtk/gtk.h>

/// Drawing that costs the GPU and not the main thread. A paint widget hands its snapshot to the
/// caller, who builds it from pictures painted once and from shapes the renderer draws itself
/// (discs, rings, rounded bands, gradients, a conic sweep through a mask), placed with opacity and
/// a transform. Under a GPU renderer a picture is a texture node, uploaded once and cached by the
/// renderer; under the cairo renderer it is a cairo node replaying one surface, which is a copy.
/// Nothing here rasterises per frame unless the caller paints a picture again.

typedef void (*TailscodeSnapshotDraw)(GtkSnapshot *snapshot, double width, double height, void *data);

/// A widget whose snapshot is `draw`, called with its own size. `destroy` runs once when the
/// widget is finalized, the only moment `data` is provably never drawn with again. Like a drawing
/// area it says `resize` with its new width and height whenever its size changes.
GtkWidget *tailscode_paint_new(TailscodeSnapshotDraw draw, void *data, void (*destroy)(void *));

/// Gives a paint widget made without one its drawing, for an owner that needs the widget before it
/// can hand the widget itself to the closure. `destroy` runs once when the widget is finalized.
void tailscode_paint_set_draw(
    GtkWidget *widget, TailscodeSnapshotDraw draw, void *data, void (*destroy)(void *));

/// How many snapshots every paint widget has taken, for a bench.
long tailscode_paint_snapshots(void);

/// Device pixels per logical pixel where the widget is shown: the surface's own scale, which is
/// fractional under a fractionally scaled desktop, or the widget's integer factor before it has one.
double tailscode_widget_device_scale(GtkWidget *widget);

/// Whether the widget's window draws with a GPU renderer (Vulkan or GL) rather than cairo.
gboolean tailscode_widget_draws_with_gpu(GtkWidget *widget);

typedef struct _TailscodePicture TailscodePicture;
typedef void (*TailscodePictureDraw)(cairo_t *cr, double width, double height, void *data);

TailscodePicture *tailscode_picture_new(void);
void tailscode_picture_free(TailscodePicture *picture);

/// Paints the picture again: `width` by `height` logical pixels at `scale` device pixels each, on
/// a cleared surface handed to `draw`. With `gpu` the pixels become a texture at once and the
/// surface is let go; otherwise the surface is kept for the cairo renderer to replay.
void tailscode_picture_paint(
    TailscodePicture *picture, double width, double height, double scale, gboolean gpu,
    TailscodePictureDraw draw, void *data);

gboolean tailscode_picture_has_pixels(TailscodePicture *picture);

/// Draws the picture stretched over the rectangle. `smooth` filters it with mipmaps, for a small
/// picture drawn much smaller than it was painted.
void tailscode_picture_append(
    TailscodePicture *picture, GtkSnapshot *snapshot, double x, double y, double width, double height,
    gboolean smooth);

/// A filled circle.
void tailscode_snap_disc(
    GtkSnapshot *snapshot, double cx, double cy, double radius, double red, double green, double blue,
    double alpha);

/// A circle's outline `line` wide, centred on the radius.
void tailscode_snap_ring(
    GtkSnapshot *snapshot, double cx, double cy, double radius, double line, double red, double green,
    double blue, double alpha);

/// A filled rounded rectangle.
void tailscode_snap_rounded_fill(
    GtkSnapshot *snapshot, double x, double y, double width, double height, double radius, double red,
    double green, double blue, double alpha);

/// A rounded rectangle's outline `line` wide, centred on its edge.
void tailscode_snap_rounded_stroke(
    GtkSnapshot *snapshot, double x, double y, double width, double height, double radius, double line,
    double red, double green, double blue, double alpha);

/// The band from `inner` to `outer` outside a rounded rectangle, following its corners.
void tailscode_snap_rounded_band(
    GtkSnapshot *snapshot, double x, double y, double width, double height, double radius, double inner,
    double outer, double red, double green, double blue, double alpha);

/// A radial gradient about (`cx`, `cy`) from `inner` to `outer`, drawn over the square that holds
/// the outer circle. `stops` is `count` runs of offset, red, green, blue, alpha.
void tailscode_snap_radial(
    GtkSnapshot *snapshot, double cx, double cy, double inner, double outer, const double *stops,
    int count);

/// A linear gradient from (`x0`, `y0`) to (`x1`, `y1`) over the rectangle. `stops` as above.
void tailscode_snap_linear(
    GtkSnapshot *snapshot, double x, double y, double width, double height, double x0, double y0,
    double x1, double y1, const double *stops, int count);

/// Short strokes with round ends, `count` runs of x0, y0, x1, y1, all `line` wide in one colour,
/// each a turned rounded bar the renderer draws itself rather than a path it would rasterise.
void tailscode_snap_segments(
    GtkSnapshot *snapshot, const double *points, int count, double line, double red, double green,
    double blue, double alpha);

/// A field of soft points: for each of `count` runs of x, y, radius, alpha, a halo `halo` times the
/// radius at `halo_share` of the alpha under a disc at the full alpha, all in one colour.
void tailscode_snap_motes(
    GtkSnapshot *snapshot, const double *motes, int count, double halo, double halo_share, double red,
    double green, double blue);

/// Draws a texture stretched over the rectangle, filtered both ways, so a picture drawn at any
/// size between a thumbnail's and a window's is smooth on every frame of the way.
void tailscode_snap_texture(
    GtkSnapshot *snapshot, GdkTexture *texture, double x, double y, double width, double height);

/// Where `widget` stands in `space`, an ancestor or a sibling under the same root, as x, y, width
/// and height in `out`, followed by the share of its area (0…1) that shows through every scroller
/// it is inside: a tile scrolled out of its transcript is laid out and mapped and not in sight.
/// False when either is not laid out.
gboolean tailscode_widget_sight_in(GtkWidget *widget, GtkWidget *space, double *out);

/// Clips what follows to a rounded rectangle; `gtk_snapshot_pop` ends it.
void tailscode_snap_push_rounded_clip(
    GtkSnapshot *snapshot, double x, double y, double width, double height, double radius);

/// A band `band` wide just inside a rounded rectangle's edge, coloured by a conic sweep of the
/// evenly spaced RGB `stops` about the rectangle's centre, turned `degrees` clockwise from the top,
/// at `alpha`. It is cut into straight runs a tenth of a turn long, each a gradient between the
/// sweep's colours at its ends, and four corners in the colour at their middle, so the GPU draws it
/// without the offscreen picture a mask would cost on every frame.
void tailscode_snap_sweep_band(
    GtkSnapshot *snapshot, double x, double y, double width, double height, double radius, double band,
    double degrees, double alpha, const double *stops, int count);

/// Saves the snapshot and turns what follows `degrees` clockwise and scales it by `scale`, both
/// about (`cx`, `cy`), then moves it by (`dx`, `dy`). `gtk_snapshot_restore` undoes it.
void tailscode_snap_push_turn(
    GtkSnapshot *snapshot, double cx, double cy, double degrees, double scale, double dx, double dy);

/// Clips what follows to the rectangle; `gtk_snapshot_pop` ends it.
void tailscode_snap_push_clip(GtkSnapshot *snapshot, double x, double y, double width, double height);

#endif
