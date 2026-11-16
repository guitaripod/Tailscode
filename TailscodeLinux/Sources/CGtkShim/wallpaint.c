#include "include/CGtkShim.h"
#include <math.h>
#include <string.h>

static gint paint_snapshots = 0;

#define TAILSCODE_TYPE_PAINT (tailscode_paint_get_type())
G_DECLARE_FINAL_TYPE(TailscodePaint, tailscode_paint, TAILSCODE, PAINT, GtkWidget)

struct _TailscodePaint {
    GtkWidget parent_instance;
    TailscodeSnapshotDraw draw;
    void *data;
    void (*destroy)(void *);
    int width;
    int height;
};

G_DEFINE_FINAL_TYPE(TailscodePaint, tailscode_paint, GTK_TYPE_WIDGET)

static guint paint_resize_signal = 0;

static void tailscode_paint_size_allocate(GtkWidget *widget, int width, int height, int baseline) {
    (void)baseline;
    TailscodePaint *self = TAILSCODE_PAINT(widget);
    if (width == self->width && height == self->height) return;
    self->width = width;
    self->height = height;
    g_signal_emit(widget, paint_resize_signal, 0, width, height);
}

static void tailscode_paint_snapshot(GtkWidget *widget, GtkSnapshot *snapshot) {
    TailscodePaint *self = TAILSCODE_PAINT(widget);
    int width = gtk_widget_get_width(widget);
    int height = gtk_widget_get_height(widget);
    if (!self->draw || width <= 0 || height <= 0 || tailscode_is_quitting()) return;
    g_atomic_int_inc(&paint_snapshots);
    self->draw(snapshot, width, height, self->data);
}

static void tailscode_paint_finalize(GObject *object) {
    TailscodePaint *self = TAILSCODE_PAINT(object);
    if (self->destroy && self->data) self->destroy(self->data);
    self->data = NULL;
    self->draw = NULL;
    G_OBJECT_CLASS(tailscode_paint_parent_class)->finalize(object);
}

static void tailscode_paint_class_init(TailscodePaintClass *class) {
    G_OBJECT_CLASS(class)->finalize = tailscode_paint_finalize;
    GTK_WIDGET_CLASS(class)->snapshot = tailscode_paint_snapshot;
    GTK_WIDGET_CLASS(class)->size_allocate = tailscode_paint_size_allocate;
    gtk_widget_class_set_css_name(GTK_WIDGET_CLASS(class), "wall-paint");
    paint_resize_signal = g_signal_new(
        "resize", G_TYPE_FROM_CLASS(class), G_SIGNAL_RUN_LAST, 0, NULL, NULL, NULL, G_TYPE_NONE, 2,
        G_TYPE_INT, G_TYPE_INT);
}

static void tailscode_paint_init(TailscodePaint *self) { (void)self; }

GtkWidget *tailscode_paint_new(TailscodeSnapshotDraw draw, void *data, void (*destroy)(void *)) {
    TailscodePaint *self = g_object_new(TAILSCODE_TYPE_PAINT, NULL);
    self->draw = draw;
    self->data = data;
    self->destroy = destroy;
    return GTK_WIDGET(self);
}

void tailscode_paint_set_draw(
    GtkWidget *widget, TailscodeSnapshotDraw draw, void *data, void (*destroy)(void *)) {
    TailscodePaint *self = TAILSCODE_PAINT(widget);
    if (self->destroy && self->data) self->destroy(self->data);
    self->draw = draw;
    self->data = data;
    self->destroy = destroy;
    gtk_widget_queue_draw(widget);
}

long tailscode_paint_snapshots(void) { return g_atomic_int_get(&paint_snapshots); }

double tailscode_widget_device_scale(GtkWidget *widget) {
    GtkNative *native = widget ? gtk_widget_get_native(widget) : NULL;
    GdkSurface *surface = native ? gtk_native_get_surface(native) : NULL;
    if (surface) {
        double scale = gdk_surface_get_scale(surface);
        if (scale > 0) return scale;
    }
    return widget ? MAX(1, gtk_widget_get_scale_factor(widget)) : 1;
}

gboolean tailscode_widget_draws_with_gpu(GtkWidget *widget) {
    GtkNative *native = widget ? gtk_widget_get_native(widget) : NULL;
    GskRenderer *renderer = native ? gtk_native_get_renderer(native) : NULL;
    if (!renderer) return FALSE;
    return strstr(G_OBJECT_TYPE_NAME(renderer), "Cairo") == NULL;
}

struct _TailscodePicture {
    cairo_surface_t *surface;
    GdkTexture *texture;
    double width;
    double height;
    gsize bytes;
};

TailscodePicture *tailscode_picture_new(void) { return g_new0(TailscodePicture, 1); }

static void picture_clear(TailscodePicture *picture) {
    if (!picture) return;
    if (picture->surface) cairo_surface_destroy(picture->surface);
    picture->surface = NULL;
    g_clear_object(&picture->texture);
    picture->bytes = 0;
}

void tailscode_picture_free(TailscodePicture *picture) {
    if (!picture) return;
    picture_clear(picture);
    g_free(picture);
}

gboolean tailscode_picture_has_pixels(TailscodePicture *picture) {
    return picture && (picture->surface || picture->texture);
}

static void picture_release_surface(gpointer data) { cairo_surface_destroy(data); }

void tailscode_picture_paint(
    TailscodePicture *picture, double width, double height, double scale, gboolean gpu,
    TailscodePictureDraw draw, void *data) {
    if (!picture) return;
    picture_clear(picture);
    if (width <= 0 || height <= 0) return;
    if (scale <= 0) scale = 1;
    int pixel_width = MAX(1, (int)ceil(width * scale - 0.01));
    int pixel_height = MAX(1, (int)ceil(height * scale - 0.01));
    cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, pixel_width, pixel_height);
    if (cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS) {
        cairo_surface_destroy(surface);
        return;
    }
    cairo_surface_set_device_scale(surface, pixel_width / width, pixel_height / height);
    cairo_t *cr = cairo_create(surface);
    if (draw) draw(cr, width, height, data);
    cairo_destroy(cr);
    cairo_surface_flush(surface);
    picture->width = width;
    picture->height = height;
    int stride = cairo_image_surface_get_stride(surface);
    picture->bytes = (gsize)stride * (gsize)pixel_height;
    if (gpu) {
        GBytes *bytes = g_bytes_new_with_free_func(
            cairo_image_surface_get_data(surface), picture->bytes, picture_release_surface, surface);
        picture->texture =
            gdk_memory_texture_new(pixel_width, pixel_height, GDK_MEMORY_DEFAULT, bytes, (gsize)stride);
        g_bytes_unref(bytes);
    } else {
        picture->surface = surface;
    }
}

void tailscode_picture_append(
    TailscodePicture *picture, GtkSnapshot *snapshot, double x, double y, double width, double height,
    gboolean smooth) {
    if (!picture || width <= 0 || height <= 0) return;
    graphene_rect_t bounds = GRAPHENE_RECT_INIT((float)x, (float)y, (float)width, (float)height);
    if (picture->texture) {
        gtk_snapshot_append_scaled_texture(
            snapshot, picture->texture, smooth ? GSK_SCALING_FILTER_TRILINEAR : GSK_SCALING_FILTER_LINEAR,
            &bounds);
        return;
    }
    if (!picture->surface || picture->width <= 0 || picture->height <= 0) return;
    cairo_t *cr = gtk_snapshot_append_cairo(snapshot, &bounds);
    cairo_translate(cr, x, y);
    cairo_scale(cr, width / picture->width, height / picture->height);
    cairo_set_source_surface(cr, picture->surface, 0, 0);
    cairo_pattern_set_filter(cairo_get_source(cr), CAIRO_FILTER_GOOD);
    cairo_paint(cr);
    cairo_destroy(cr);
}

static GdkRGBA rgba(double red, double green, double blue, double alpha) {
    GdkRGBA colour = {(float)red, (float)green, (float)blue, (float)CLAMP(alpha, 0, 1)};
    return colour;
}

static GskRoundedRect rounded(double x, double y, double width, double height, double radius) {
    GskRoundedRect shape;
    graphene_rect_t rect = GRAPHENE_RECT_INIT((float)x, (float)y, (float)MAX(0, width), (float)MAX(0, height));
    double limit = MIN(width, height) / 2;
    gsk_rounded_rect_init_from_rect(&shape, &rect, (float)CLAMP(radius, 0, MAX(0, limit)));
    return shape;
}

void tailscode_snap_disc(
    GtkSnapshot *snapshot, double cx, double cy, double radius, double red, double green, double blue,
    double alpha) {
    if (radius <= 0 || alpha <= 0.001) return;
    GskRoundedRect shape = rounded(cx - radius, cy - radius, 2 * radius, 2 * radius, radius);
    GdkRGBA colour = rgba(red, green, blue, alpha);
    gtk_snapshot_push_rounded_clip(snapshot, &shape);
    gtk_snapshot_append_color(snapshot, &colour, &shape.bounds);
    gtk_snapshot_pop(snapshot);
}

static void border(GtkSnapshot *snapshot, GskRoundedRect *outline, double width, GdkRGBA colour) {
    float widths[4] = {(float)width, (float)width, (float)width, (float)width};
    GdkRGBA colours[4] = {colour, colour, colour, colour};
    gtk_snapshot_append_border(snapshot, outline, widths, colours);
}

void tailscode_snap_ring(
    GtkSnapshot *snapshot, double cx, double cy, double radius, double line, double red, double green,
    double blue, double alpha) {
    if (radius <= 0 || line <= 0 || alpha <= 0.001) return;
    double outer = radius + line / 2;
    GskRoundedRect shape = rounded(cx - outer, cy - outer, 2 * outer, 2 * outer, outer);
    border(snapshot, &shape, MIN(line, outer), rgba(red, green, blue, alpha));
}

void tailscode_snap_rounded_fill(
    GtkSnapshot *snapshot, double x, double y, double width, double height, double radius, double red,
    double green, double blue, double alpha) {
    if (width <= 0 || height <= 0 || alpha <= 0.001) return;
    GskRoundedRect shape = rounded(x, y, width, height, radius);
    GdkRGBA colour = rgba(red, green, blue, alpha);
    gtk_snapshot_push_rounded_clip(snapshot, &shape);
    gtk_snapshot_append_color(snapshot, &colour, &shape.bounds);
    gtk_snapshot_pop(snapshot);
}

void tailscode_snap_rounded_stroke(
    GtkSnapshot *snapshot, double x, double y, double width, double height, double radius, double line,
    double red, double green, double blue, double alpha) {
    if (line <= 0 || alpha <= 0.001) return;
    double half = line / 2;
    GskRoundedRect shape = rounded(x - half, y - half, width + line, height + line, radius + half);
    border(snapshot, &shape, line, rgba(red, green, blue, alpha));
}

void tailscode_snap_rounded_band(
    GtkSnapshot *snapshot, double x, double y, double width, double height, double radius, double inner,
    double outer, double red, double green, double blue, double alpha) {
    if (outer <= inner || alpha <= 0.001) return;
    inner = MAX(0, inner);
    GskRoundedRect shape =
        rounded(x - outer, y - outer, width + 2 * outer, height + 2 * outer, radius + outer);
    border(snapshot, &shape, outer - inner, rgba(red, green, blue, alpha));
}

static GskColorStop *color_stops(const double *stops, int count) {
    GskColorStop *out = g_new(GskColorStop, MAX(1, count));
    for (int index = 0; index < count; index++) {
        const double *run = stops + index * 5;
        out[index].offset = (float)CLAMP(run[0], 0, 1);
        out[index].color = rgba(run[1], run[2], run[3], run[4]);
    }
    return out;
}

void tailscode_snap_radial(
    GtkSnapshot *snapshot, double cx, double cy, double inner, double outer, const double *stops,
    int count) {
    if (outer <= 0 || count < 2) return;
    graphene_rect_t bounds =
        GRAPHENE_RECT_INIT((float)(cx - outer), (float)(cy - outer), (float)(2 * outer), (float)(2 * outer));
    graphene_point_t centre = GRAPHENE_POINT_INIT((float)cx, (float)cy);
    GskColorStop *colours = color_stops(stops, count);
    gtk_snapshot_append_radial_gradient(
        snapshot, &bounds, &centre, (float)outer, (float)outer, (float)CLAMP(inner / outer, 0, 1), 1.0f,
        colours, (gsize)count);
    g_free(colours);
}

void tailscode_snap_linear(
    GtkSnapshot *snapshot, double x, double y, double width, double height, double x0, double y0,
    double x1, double y1, const double *stops, int count) {
    if (width <= 0 || height <= 0 || count < 2) return;
    graphene_rect_t bounds = GRAPHENE_RECT_INIT((float)x, (float)y, (float)width, (float)height);
    graphene_point_t start = GRAPHENE_POINT_INIT((float)x0, (float)y0);
    graphene_point_t end = GRAPHENE_POINT_INIT((float)x1, (float)y1);
    GskColorStop *colours = color_stops(stops, count);
    gtk_snapshot_append_linear_gradient(snapshot, &bounds, &start, &end, colours, (gsize)count);
    g_free(colours);
}

void tailscode_snap_segments(
    GtkSnapshot *snapshot, const double *points, int count, double line, double red, double green,
    double blue, double alpha) {
    if (count <= 0 || line <= 0 || alpha <= 0.001) return;
    GdkRGBA colour = rgba(red, green, blue, alpha);
    double half = line / 2;
    for (int index = 0; index < count; index++) {
        const double *run = points + index * 4;
        double dx = run[2] - run[0];
        double dy = run[3] - run[1];
        double length = sqrt(dx * dx + dy * dy);
        gtk_snapshot_save(snapshot);
        graphene_point_t from = GRAPHENE_POINT_INIT((float)run[0], (float)run[1]);
        gtk_snapshot_translate(snapshot, &from);
        if (length > 0.001) gtk_snapshot_rotate(snapshot, (float)(atan2(dy, dx) * 180.0 / G_PI));
        GskRoundedRect shape = rounded(-half, -half, length + line, line, half);
        gtk_snapshot_push_rounded_clip(snapshot, &shape);
        gtk_snapshot_append_color(snapshot, &colour, &shape.bounds);
        gtk_snapshot_pop(snapshot);
        gtk_snapshot_restore(snapshot);
    }
}

void tailscode_snap_motes(
    GtkSnapshot *snapshot, const double *motes, int count, double halo, double halo_share, double red,
    double green, double blue) {
    for (int index = 0; index < count; index++) {
        const double *run = motes + index * 4;
        if (run[3] <= 0.001) continue;
        tailscode_snap_disc(snapshot, run[0], run[1], run[2] * halo, red, green, blue, run[3] * halo_share);
        tailscode_snap_disc(snapshot, run[0], run[1], run[2], red, green, blue, run[3]);
    }
}

void tailscode_snap_texture(
    GtkSnapshot *snapshot, GdkTexture *texture, double x, double y, double width, double height) {
    if (texture == NULL || width <= 0 || height <= 0) return;
    graphene_rect_t bounds = GRAPHENE_RECT_INIT((float)x, (float)y, (float)width, (float)height);
    gtk_snapshot_append_scaled_texture(snapshot, texture, GSK_SCALING_FILTER_TRILINEAR, &bounds);
}

gboolean tailscode_widget_sight_in(GtkWidget *widget, GtkWidget *space, double *out) {
    graphene_rect_t bounds;
    if (widget == NULL || space == NULL || out == NULL) return FALSE;
    if (!gtk_widget_get_mapped(widget) || !gtk_widget_get_mapped(space)) return FALSE;
    if (!gtk_widget_compute_bounds(widget, space, &bounds)) return FALSE;
    out[0] = bounds.origin.x;
    out[1] = bounds.origin.y;
    out[2] = bounds.size.width;
    out[3] = bounds.size.height;
    graphene_rect_t seen = bounds;
    gboolean in_sight = TRUE;
    for (GtkWidget *above = gtk_widget_get_parent(widget); above != NULL && above != space;
         above = gtk_widget_get_parent(above)) {
        graphene_rect_t port;
        if (!GTK_IS_SCROLLED_WINDOW(above)) continue;
        if (!gtk_widget_compute_bounds(above, space, &port)) continue;
        if (!graphene_rect_intersection(&seen, &port, &seen)) {
            in_sight = FALSE;
            break;
        }
    }
    double area = (double)bounds.size.width * (double)bounds.size.height;
    out[4] = in_sight && area > 0
        ? ((double)seen.size.width * (double)seen.size.height) / area
        : 0;
    return TRUE;
}

void tailscode_snap_push_rounded_clip(
    GtkSnapshot *snapshot, double x, double y, double width, double height, double radius) {
    GskRoundedRect shape = rounded(x, y, width, height, radius);
    gtk_snapshot_push_rounded_clip(snapshot, &shape);
}

static void sweep_colour(const double *stops, int count, double offset, double *rgb) {
    offset -= floor(offset);
    double position = offset * (count - 1);
    int index = MIN((int)position, count - 2);
    double mix = position - index;
    for (int channel = 0; channel < 3; channel++) {
        double from = stops[index * 3 + channel];
        rgb[channel] = from + (stops[(index + 1) * 3 + channel] - from) * mix;
    }
}

static double sweep_offset(double cx, double cy, double px, double py, double degrees) {
    double clockwise = atan2(px - cx, cy - py) * 180.0 / G_PI;
    return (clockwise - degrees) / 360.0;
}

static double sweep_angle(double cx, double cy, double px, double py) {
    return atan2(px - cx, cy - py) * 180.0 / G_PI;
}

static void sweep_run(
    GtkSnapshot *snapshot, double cx, double cy, double x0, double y0, double x1, double y1, double across,
    gboolean horizontal, double degrees, double alpha, const double *stops, int count) {
    double turn = fabs(sweep_angle(cx, cy, x1, y1) - sweep_angle(cx, cy, x0, y0));
    if (turn > 180) turn = 360 - turn;
    int pieces = MAX(1, (int)ceil(turn / 10.0));
    for (int piece = 0; piece < pieces; piece++) {
        double a = (double)piece / pieces;
        double b = (double)(piece + 1) / pieces;
        double ax = x0 + (x1 - x0) * a, ay = y0 + (y1 - y0) * a;
        double bx = x0 + (x1 - x0) * b, by = y0 + (y1 - y0) * b;
        double from[3], to[3];
        sweep_colour(stops, count, sweep_offset(cx, cy, ax, ay, degrees), from);
        sweep_colour(stops, count, sweep_offset(cx, cy, bx, by, degrees), to);
        graphene_rect_t bounds = horizontal
            ? GRAPHENE_RECT_INIT((float)MIN(ax, bx), (float)(ay - across / 2), (float)fabs(bx - ax), (float)across)
            : GRAPHENE_RECT_INIT((float)(ax - across / 2), (float)MIN(ay, by), (float)across, (float)fabs(by - ay));
        graphene_point_t start = GRAPHENE_POINT_INIT((float)ax, (float)ay);
        graphene_point_t end = GRAPHENE_POINT_INIT((float)bx, (float)by);
        GskColorStop colours[2] = {
            {0.0f, rgba(from[0], from[1], from[2], alpha)}, {1.0f, rgba(to[0], to[1], to[2], alpha)}};
        gtk_snapshot_append_linear_gradient(snapshot, &bounds, &start, &end, colours, 2);
    }
}

void tailscode_snap_sweep_band(
    GtkSnapshot *snapshot, double x, double y, double width, double height, double radius, double band,
    double degrees, double alpha, const double *stops, int count) {
    if (width <= 0 || height <= 0 || band <= 0 || alpha <= 0.001 || count < 2) return;
    double r = CLAMP(radius, 0, MIN(width, height) / 2);
    double cx = x + width / 2, cy = y + height / 2;
    double half = band / 2;
    sweep_run(snapshot, cx, cy, x + r, y + half, x + width - r, y + half, band, TRUE, degrees, alpha, stops, count);
    sweep_run(snapshot, cx, cy, x + width - half, y + r, x + width - half, y + height - r, band, FALSE, degrees, alpha, stops, count);
    sweep_run(snapshot, cx, cy, x + width - r, y + height - half, x + r, y + height - half, band, TRUE, degrees, alpha, stops, count);
    sweep_run(snapshot, cx, cy, x + half, y + height - r, x + half, y + r, band, FALSE, degrees, alpha, stops, count);
    if (r <= 0) return;
    double corners[4][2] = {{x, y}, {x + width - r, y}, {x + width - r, y + height - r}, {x, y + height - r}};
    double inner = MAX(0, r - band);
    for (int corner = 0; corner < 4; corner++) {
        double ox = corners[corner][0], oy = corners[corner][1];
        double arc_x = corner == 0 || corner == 3 ? x + r : x + width - r;
        double arc_y = corner < 2 ? y + r : y + height - r;
        double lean = (r + inner) / 2 * G_SQRT2 / 2;
        double mid_x = arc_x + (corner == 0 || corner == 3 ? -lean : lean);
        double mid_y = arc_y + (corner < 2 ? -lean : lean);
        double rgb[3];
        sweep_colour(stops, count, sweep_offset(cx, cy, mid_x, mid_y, degrees), rgb);
        GdkRGBA colour = rgba(rgb[0], rgb[1], rgb[2], alpha);
        graphene_rect_t quadrant = GRAPHENE_RECT_INIT((float)ox, (float)oy, (float)r, (float)r);
        gtk_snapshot_push_clip(snapshot, &quadrant);
        GskRoundedRect ring = rounded(arc_x - r, arc_y - r, 2 * r, 2 * r, r);
        if (inner > 0) {
            border(snapshot, &ring, r - inner, colour);
        } else {
            gtk_snapshot_push_rounded_clip(snapshot, &ring);
            gtk_snapshot_append_color(snapshot, &colour, &ring.bounds);
            gtk_snapshot_pop(snapshot);
        }
        gtk_snapshot_pop(snapshot);
    }
}

void tailscode_snap_push_turn(
    GtkSnapshot *snapshot, double cx, double cy, double degrees, double scale, double dx, double dy) {
    gtk_snapshot_save(snapshot);
    graphene_point_t to = GRAPHENE_POINT_INIT((float)(cx + dx), (float)(cy + dy));
    gtk_snapshot_translate(snapshot, &to);
    if (degrees != 0) gtk_snapshot_rotate(snapshot, (float)degrees);
    if (scale != 1) gtk_snapshot_scale(snapshot, (float)scale, (float)scale);
    graphene_point_t back = GRAPHENE_POINT_INIT((float)-cx, (float)-cy);
    gtk_snapshot_translate(snapshot, &back);
}

void tailscode_snap_push_clip(GtkSnapshot *snapshot, double x, double y, double width, double height) {
    graphene_rect_t bounds = GRAPHENE_RECT_INIT((float)x, (float)y, (float)MAX(0, width), (float)MAX(0, height));
    gtk_snapshot_push_clip(snapshot, &bounds);
}
