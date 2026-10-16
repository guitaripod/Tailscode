#pragma once
#include <glib.h>
#include <gtk/gtk.h>

/// The preview pane's Compare stage: two pictures of the same screen drawn in one area, either laid
/// over each other with a draggable handle (the left of it shows the earlier picture, the right of
/// it the later) or side by side, with the places that changed outlined and numbered on top.
///
/// The area keeps one decoded picture per shot and a copy of each at the size it is drawn, rebuilt
/// only when the allocation changes, so a drag repaints from pixels it already has. Where every
/// rectangle falls is one function (`tailscode_compare_plan`) that the draw and the harness both
/// read, so a claim about where an outline lands is a claim about where it is drawn.
GtkWidget *tailscode_compare_new(void);

/// Decodes the two JPEGs and keeps them, releasing whatever was held. FALSE, with nothing changed,
/// when either does not decode.
gboolean tailscode_compare_set_pictures(
    GtkWidget *area, const void *before, gsize before_len, const void *after, gsize after_len);

/// Releases both pictures and the regions.
void tailscode_compare_clear(GtkWidget *area);

/// The pixel size of the later picture, or 0 x 0 when none is held.
void tailscode_compare_size(GtkWidget *area, int *width, int *height);

/// Slider (FALSE) or side by side (TRUE).
void tailscode_compare_set_mode(GtkWidget *area, gboolean side_by_side);

/// The changed places as `x, y, width, height` fractions of the picture, and the outline's ink as
/// RGB in 0-1. A NULL ink keeps the last.
void tailscode_compare_set_regions(
    GtkWidget *area, const double *fractions, int count, const double *rgb);

/// Where the handle stands, as a fraction of the picture's width.
void tailscode_compare_set_handle(GtkWidget *area, double fraction);
double tailscode_compare_handle(GtkWidget *area);

/// Moves the handle to an x position inside an area of the given size, as a press or drag does.
void tailscode_compare_drag(GtkWidget *area, double x, int width, int height);

/// What a frame at this size would draw, as numbers: `[mode, clipX, handleX, regionCount, then the
/// earlier picture's x, y, width, height, the later picture's x, y, width, height, then one
/// x, y, width, height per region]`, all in widget pixels. In slider mode both pictures share one
/// rectangle and `clipX` is where the earlier one stops; side by side `clipX` and `handleX` are -1
/// and no outline is drawn. Returns how many numbers it wrote, or -1 if `capacity` is too small.
int tailscode_compare_plan(GtkWidget *area, int width, int height, double *out, int capacity);

/// How many pictures every compare area in the process is holding. Two per area at most; none once
/// it is cleared or gone.
int tailscode_compare_live_pictures(void);

/// Ticks laid over a scale's trough where something happened: a transparent layer that never takes
/// input, whose marks are fractions of the scale's range. A scale's own marks make its slider snap
/// to them, which would leave a scrubber that cannot be put anywhere else, so these are drawn
/// rather than added. The layer asks the scale where its trough and slider are each time it
/// draws, so a tick stays on its value at any width.
GtkWidget *tailscode_scrub_ticks_new(GtkWidget *scale);

/// The ticks as fractions of the range (0-1) and their ink as RGB in 0-1.
void tailscode_scrub_ticks_set(GtkWidget *area, const double *fractions, int count, const double *rgb);

/// Where each tick stands, in the scale's own pixels, as it would be drawn now.
int tailscode_scrub_ticks_plan(GtkWidget *area, double *out, int capacity);

/// What an outline layer tells its owner: a pointer moving (kind 0), leaving (1) or pressing (2),
/// at a fraction of the layer's own width and height, so the owner never needs to know how large
/// the picture underneath is drawn.
typedef void (*TailscodeOutlineHandler)(void *data, int kind, double fx, double fy);

/// A transparent layer over the preview picture that outlines views. It draws three groups, each
/// a list of rectangles given as fractions of the layer: 0 is the view under the pointer, 1 is
/// the one pinned, 2 is the views a finding is about. It takes the pointer only while active, so a
/// layer that is not in use never stands between the picture and a press.
GtkWidget *tailscode_outline_new(TailscodeOutlineHandler handler, void *data);

/// Gives the handler the owner it speaks to, once the owner exists to be pointed at.
void tailscode_outline_bind(GtkWidget *area, void *data);

/// Forgets the handler: the owner is going away and the layer may outlive it for a frame.
void tailscode_outline_detach(GtkWidget *area);

void tailscode_outline_set_active(GtkWidget *area, gboolean active);

/// Replaces one group's rectangles (`x, y, width, height` fractions) and its ink (RGB, 0-1). A NULL
/// ink keeps the last.
void tailscode_outline_set(GtkWidget *area, int group, const double *rects, int count, const double *rgb);

/// What a frame at this size would draw: `[hoverCount, pinnedCount, markCount]`, then every
/// rectangle in widget pixels in that order. Returns how many numbers it wrote, or -1 if
/// `capacity` is too small.
int tailscode_outline_plan(GtkWidget *area, int width, int height, double *out, int capacity);

/// Delivers an event as if the pointer had done it, at a fraction of the layer.
void tailscode_outline_point(GtkWidget *area, int kind, double fx, double fy);

/// What a width sensor tells its owner: the size it was just given.
typedef void (*TailscodeWidthHandler)(void *data, int width, int height);

/// A layer with no height that reports the width it is given each time that changes, which is how
/// a container learns it has become narrow without running a clock.
GtkWidget *tailscode_width_sensor_new(TailscodeWidthHandler handler, void *data);
void tailscode_width_sensor_detach(GtkWidget *area);
void tailscode_width_sensor_bind(GtkWidget *area, void *data);

/// What a touch layer tells its owner, in the layer's own pixels: a press (kind 0), the pointer
/// moving with it held (1), the release (2), a gesture the toolkit took back (3), the wheel (4,
/// `a` and `b` are the horizontal and vertical notches) or a smooth scroll (5, the same in pixels).
/// `x` and `y` are where the pointer stands, `width` and `height` the layer's size.
typedef void (*TailscodeTouchHandler)(
    void *data, int kind, double x, double y, double a, double b, double width, double height);

/// A transparent layer over the preview picture that operates it. It reports presses, drags and
/// scrolls and draws what the owner hands it (rings and a trail, as fractions of the layer), and it
/// takes the pointer only while active, so a layer that is not in use never stands between the
/// picture and anything else.
GtkWidget *tailscode_touch_new(TailscodeTouchHandler handler, void *data);
void tailscode_touch_bind(GtkWidget *area, void *data);
void tailscode_touch_detach(GtkWidget *area);

/// Takes the pointer (with a hand cursor) or gives it back.
void tailscode_touch_set_active(GtkWidget *area, gboolean active);

/// Replaces what is drawn. Rings are `x, y, radius, alpha, busy, angle` (fractions of the layer,
/// the radius a fraction of its width, the angle in degrees); the trail is `x, y, alpha`. A NULL
/// ink keeps the last (RGB, 0-1).
void tailscode_touch_set_marks(
    GtkWidget *area, const double *rings, int ring_count, const double *trail, int trail_count,
    const double *rgb);

/// What a frame at this size would draw, in pixels: `[ringCount, trailCount]`, then `x, y, radius,
/// alpha, busy` per ring and `x, y, alpha` per trail point. Returns how many numbers it wrote, or
/// -1 if `capacity` is too small.
int tailscode_touch_plan(GtkWidget *area, int width, int height, double *out, int capacity);

/// Delivers an event as if the pointer had done it, at a fraction of a layer of the given size.
void tailscode_touch_point(
    GtkWidget *area, int kind, double fx, double fy, double a, double b, double width, double height);

/// Whether the layer takes the pointer, and the cursor it shows.
gboolean tailscode_touch_active(GtkWidget *area);
