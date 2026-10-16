#include "include/previewlens.h"
#include "include/CGtkShim.h"
#include <gdk/gdkcairo.h>
#include <pango/pangocairo.h>
#include <math.h>
#include <string.h>

typedef struct {
    cairo_surface_t *full;
    int width;
    int height;
    cairo_surface_t *fitted;
    int fitted_width;
    int fitted_height;
    double fitted_scale;
} CompareShot;

typedef struct {
    CompareShot before;
    CompareShot after;
    gboolean side_by_side;
    double handle;
    double *regions;
    int region_count;
    double ink[3];
    double drag_origin;
} Compare;

typedef struct {
    double x;
    double y;
    double width;
    double height;
} CompareRect;

static const char *compare_key = "tailscode-compare";
static gint compare_live = 0;
static const double compare_gap = 12.0;

static Compare *compare_of(GtkWidget *area) {
    return area ? g_object_get_data(G_OBJECT(area), compare_key) : NULL;
}

static void compare_shot_release(CompareShot *shot) {
    if (shot->fitted) cairo_surface_destroy(shot->fitted);
    if (shot->full) {
        cairo_surface_destroy(shot->full);
        g_atomic_int_add(&compare_live, -1);
    }
    memset(shot, 0, sizeof(*shot));
}

static gboolean compare_shot_decode(CompareShot *shot, const void *bytes, gsize length) {
    GdkTexture *texture = tailscode_texture_from_bytes(bytes, length);
    if (!texture) return FALSE;
    int width = gdk_texture_get_width(texture);
    int height = gdk_texture_get_height(texture);
    cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, width, height);
    if (cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS) {
        cairo_surface_destroy(surface);
        g_object_unref(texture);
        return FALSE;
    }
    cairo_surface_flush(surface);
    gdk_texture_download(
        texture, cairo_image_surface_get_data(surface),
        (gsize)cairo_image_surface_get_stride(surface));
    cairo_surface_mark_dirty(surface);
    g_object_unref(texture);
    memset(shot, 0, sizeof(*shot));
    shot->full = surface;
    shot->width = width;
    shot->height = height;
    g_atomic_int_add(&compare_live, 1);
    return TRUE;
}

static CompareRect compare_fit(int picture_width, int picture_height, CompareRect cell) {
    if (picture_width <= 0 || picture_height <= 0 || cell.width <= 0 || cell.height <= 0) return cell;
    double scale = MIN(cell.width / picture_width, cell.height / picture_height);
    CompareRect fitted = {0, 0, picture_width * scale, picture_height * scale};
    fitted.x = cell.x + (cell.width - fitted.width) / 2.0;
    fitted.y = cell.y + (cell.height - fitted.height) / 2.0;
    return fitted;
}

static void compare_cells(Compare *self, int width, int height, CompareRect *before, CompareRect *after) {
    CompareRect whole = {0, 0, width, height};
    if (!self->side_by_side) {
        CompareRect shared = compare_fit(self->after.width, self->after.height, whole);
        *before = shared;
        *after = shared;
        return;
    }
    double cell_width = MAX(0.0, (width - compare_gap) / 2.0);
    CompareRect left = {0, 0, cell_width, height};
    CompareRect right = {cell_width + compare_gap, 0, cell_width, height};
    *before = compare_fit(self->before.width, self->before.height, left);
    *after = compare_fit(self->after.width, self->after.height, right);
}

static void compare_rect_of_region(const double *fractions, CompareRect picture, CompareRect *out) {
    out->x = picture.x + fractions[0] * picture.width;
    out->y = picture.y + fractions[1] * picture.height;
    out->width = fractions[2] * picture.width;
    out->height = fractions[3] * picture.height;
}

static int compare_plan_for(Compare *self, int width, int height, double *out, int capacity) {
    int needed = 12 + self->region_count * 4;
    if (!out || capacity < needed) return -1;
    CompareRect before, after;
    compare_cells(self, width, height, &before, &after);
    out[0] = self->side_by_side ? 1 : 0;
    if (self->side_by_side) {
        out[1] = -1;
        out[2] = -1;
    } else {
        double handle = CLAMP(self->handle, 0.0, 1.0);
        out[1] = after.x + handle * after.width;
        out[2] = out[1];
    }
    out[3] = self->side_by_side ? 0 : self->region_count;
    out[4] = before.x;
    out[5] = before.y;
    out[6] = before.width;
    out[7] = before.height;
    out[8] = after.x;
    out[9] = after.y;
    out[10] = after.width;
    out[11] = after.height;
    int written = 12;
    if (!self->side_by_side) {
        for (int index = 0; index < self->region_count; index++) {
            CompareRect region;
            compare_rect_of_region(self->regions + index * 4, after, &region);
            out[written++] = region.x;
            out[written++] = region.y;
            out[written++] = region.width;
            out[written++] = region.height;
        }
    }
    return written;
}

int tailscode_compare_plan(GtkWidget *area, int width, int height, double *out, int capacity) {
    Compare *self = compare_of(area);
    return self ? compare_plan_for(self, width, height, out, capacity) : -1;
}

static void compare_fitted(CompareShot *shot, CompareRect rect, double scale) {
    if (!shot->full) return;
    int width = MAX(1, (int)ceil(rect.width * scale));
    int height = MAX(1, (int)ceil(rect.height * scale));
    if (shot->fitted && shot->fitted_width == width && shot->fitted_height == height
        && shot->fitted_scale == scale)
        return;
    if (shot->fitted) cairo_surface_destroy(shot->fitted);
    shot->fitted = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, width, height);
    shot->fitted_width = width;
    shot->fitted_height = height;
    shot->fitted_scale = scale;
    cairo_t *cr = cairo_create(shot->fitted);
    cairo_scale(cr, (double)width / shot->width, (double)height / shot->height);
    cairo_set_source_surface(cr, shot->full, 0, 0);
    cairo_pattern_set_filter(cairo_get_source(cr), CAIRO_FILTER_BEST);
    cairo_pattern_set_extend(cairo_get_source(cr), CAIRO_EXTEND_PAD);
    cairo_paint(cr);
    cairo_destroy(cr);
    cairo_surface_set_device_scale(shot->fitted, (double)width / rect.width, (double)height / rect.height);
}

static void compare_blit(cairo_t *cr, CompareShot *shot, CompareRect rect, double scale) {
    if (!shot->full || rect.width <= 0 || rect.height <= 0) return;
    compare_fitted(shot, rect, scale);
    cairo_set_source_surface(cr, shot->fitted, rect.x, rect.y);
    cairo_paint(cr);
}

static void compare_handle_draw(cairo_t *cr, double x, CompareRect picture) {
    cairo_set_line_width(cr, 4);
    cairo_set_source_rgba(cr, 0, 0, 0, 0.28);
    cairo_move_to(cr, x, picture.y);
    cairo_line_to(cr, x, picture.y + picture.height);
    cairo_stroke(cr);
    cairo_set_line_width(cr, 2);
    cairo_set_source_rgba(cr, 1, 1, 1, 0.96);
    cairo_move_to(cr, x, picture.y);
    cairo_line_to(cr, x, picture.y + picture.height);
    cairo_stroke(cr);
    double centre = picture.y + picture.height / 2.0;
    cairo_arc(cr, x, centre, 14, 0, 2 * G_PI);
    cairo_set_source_rgba(cr, 0, 0, 0, 0.30);
    cairo_fill_preserve(cr);
    cairo_set_source_rgba(cr, 1, 1, 1, 0.97);
    cairo_set_line_width(cr, 2);
    cairo_stroke_preserve(cr);
    cairo_set_source_rgba(cr, 0.12, 0.12, 0.14, 0.92);
    cairo_fill(cr);
    cairo_set_source_rgba(cr, 1, 1, 1, 0.97);
    cairo_set_line_width(cr, 2);
    cairo_move_to(cr, x - 4, centre - 5);
    cairo_line_to(cr, x - 9, centre);
    cairo_line_to(cr, x - 4, centre + 5);
    cairo_stroke(cr);
    cairo_move_to(cr, x + 4, centre - 5);
    cairo_line_to(cr, x + 9, centre);
    cairo_line_to(cr, x + 4, centre + 5);
    cairo_stroke(cr);
}

static void compare_badge_draw(cairo_t *cr, const double *ink, int number, double x, double y) {
    char text[16];
    g_snprintf(text, sizeof(text), "%d", number);
    PangoLayout *layout = pango_cairo_create_layout(cr);
    PangoFontDescription *font = pango_font_description_from_string("Sans Bold 9");
    pango_layout_set_font_description(layout, font);
    pango_font_description_free(font);
    pango_layout_set_text(layout, text, -1);
    int text_width = 0, text_height = 0;
    pango_layout_get_pixel_size(layout, &text_width, &text_height);
    double width = MAX(18.0, text_width + 10.0);
    double height = MAX(18.0, text_height + 2.0);
    double radius = height / 2.0;
    cairo_new_sub_path(cr);
    cairo_arc(cr, x + radius, y + radius, radius, G_PI / 2, G_PI * 3 / 2);
    cairo_arc(cr, x + width - radius, y + radius, radius, -G_PI / 2, G_PI / 2);
    cairo_close_path(cr);
    cairo_set_source_rgb(cr, ink[0], ink[1], ink[2]);
    cairo_fill(cr);
    double luminance = 0.2126 * ink[0] + 0.7152 * ink[1] + 0.0722 * ink[2];
    if (luminance > 0.55) cairo_set_source_rgb(cr, 0.05, 0.05, 0.07);
    else cairo_set_source_rgb(cr, 1, 1, 1);
    cairo_move_to(cr, x + (width - text_width) / 2.0, y + (height - text_height) / 2.0);
    pango_cairo_show_layout(cr, layout);
    g_object_unref(layout);
}

static void compare_outlines_draw(cairo_t *cr, Compare *self, double *plan, int count) {
    static const double dashes[2] = {6.0, 4.0};
    for (int index = 0; index < count; index++) {
        double *rect = plan + 12 + index * 4;
        double x = rect[0] + 1, y = rect[1] + 1;
        double w = MAX(0.0, rect[2] - 2), h = MAX(0.0, rect[3] - 2);
        cairo_set_dash(cr, NULL, 0, 0);
        cairo_set_line_width(cr, 4);
        cairo_set_source_rgba(cr, 0, 0, 0, 0.35);
        cairo_rectangle(cr, x, y, w, h);
        cairo_stroke(cr);
        cairo_set_dash(cr, dashes, 2, 0);
        cairo_set_line_width(cr, 2);
        cairo_set_source_rgb(cr, self->ink[0], self->ink[1], self->ink[2]);
        cairo_rectangle(cr, x, y, w, h);
        cairo_stroke(cr);
    }
    cairo_set_dash(cr, NULL, 0, 0);
    for (int index = 0; index < count; index++) {
        double *rect = plan + 12 + index * 4;
        compare_badge_draw(cr, self->ink, index + 1, rect[0] + 3, rect[1] + 3);
    }
}

static void compare_draw(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer raw) {
    Compare *self = raw;
    if (!self->after.full) return;
    double scale = gtk_widget_get_scale_factor(GTK_WIDGET(area));
    int capacity = 12 + self->region_count * 4;
    double *plan = g_new0(double, capacity);
    int written = compare_plan_for(self, width, height, plan, capacity);
    if (written < 12) {
        g_free(plan);
        return;
    }
    CompareRect before = {plan[4], plan[5], plan[6], plan[7]};
    CompareRect after = {plan[8], plan[9], plan[10], plan[11]};
    if (!self->side_by_side) {
        compare_blit(cr, &self->after, after, scale);
        if (self->before.full) {
            cairo_save(cr);
            cairo_rectangle(cr, before.x, before.y, plan[1] - before.x, before.height);
            cairo_clip(cr);
            compare_blit(cr, &self->before, before, scale);
            cairo_restore(cr);
        }
        compare_outlines_draw(cr, self, plan, (int)plan[3]);
        compare_handle_draw(cr, plan[1], after);
    } else {
        compare_blit(cr, &self->before, before, scale);
        compare_blit(cr, &self->after, after, scale);
    }
    g_free(plan);
}

static void compare_set_handle_x(GtkWidget *area, Compare *self, double x, int width, int height) {
    double plan[12];
    int saved_regions = self->region_count;
    self->region_count = 0;
    int written = compare_plan_for(self, width, height, plan, 12);
    self->region_count = saved_regions;
    if (written < 12 || plan[10] <= 0) return;
    self->handle = CLAMP((x - plan[8]) / plan[10], 0.0, 1.0);
    gtk_widget_queue_draw(area);
}

void tailscode_compare_drag(GtkWidget *area, double x, int width, int height) {
    Compare *self = compare_of(area);
    if (!self || self->side_by_side) return;
    compare_set_handle_x(area, self, x, width, height);
}

static void compare_drag_begin(GtkGestureDrag *gesture, double x, double y, gpointer raw) {
    (void)y;
    GtkWidget *area = GTK_WIDGET(raw);
    Compare *self = compare_of(area);
    if (!self) return;
    self->drag_origin = x;
    gtk_widget_grab_focus(area);
    tailscode_compare_drag(area, x, gtk_widget_get_width(area), gtk_widget_get_height(area));
    (void)gesture;
}

static void compare_drag_update(GtkGestureDrag *gesture, double dx, double dy, gpointer raw) {
    (void)dy;
    (void)gesture;
    GtkWidget *area = GTK_WIDGET(raw);
    Compare *self = compare_of(area);
    if (!self) return;
    tailscode_compare_drag(
        area, self->drag_origin + dx, gtk_widget_get_width(area), gtk_widget_get_height(area));
}

static gboolean compare_key_pressed(
    GtkEventControllerKey *controller, guint keyval, guint keycode, GdkModifierType state,
    gpointer raw) {
    (void)controller;
    (void)keycode;
    (void)state;
    GtkWidget *area = GTK_WIDGET(raw);
    Compare *self = compare_of(area);
    if (!self || self->side_by_side) return FALSE;
    if (keyval == GDK_KEY_Left) tailscode_compare_set_handle(area, self->handle - 0.02);
    else if (keyval == GDK_KEY_Right) tailscode_compare_set_handle(area, self->handle + 0.02);
    else return FALSE;
    return TRUE;
}

static void compare_free(gpointer raw) {
    Compare *self = raw;
    compare_shot_release(&self->before);
    compare_shot_release(&self->after);
    g_free(self->regions);
    g_free(self);
}

GtkWidget *tailscode_compare_new(void) {
    GtkWidget *area = gtk_drawing_area_new();
    Compare *self = g_new0(Compare, 1);
    self->handle = 0.5;
    self->ink[0] = 0.9;
    self->ink[1] = 0.7;
    self->ink[2] = 0.2;
    g_object_set_data_full(G_OBJECT(area), compare_key, self, compare_free);
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(area), compare_draw, self, NULL);
    gtk_widget_set_hexpand(area, TRUE);
    gtk_widget_set_vexpand(area, TRUE);
    gtk_widget_set_focusable(area, TRUE);
    gtk_widget_set_cursor_from_name(area, "ew-resize");
    GtkGesture *drag = gtk_gesture_drag_new();
    g_signal_connect(drag, "drag-begin", G_CALLBACK(compare_drag_begin), area);
    g_signal_connect(drag, "drag-update", G_CALLBACK(compare_drag_update), area);
    gtk_widget_add_controller(area, GTK_EVENT_CONTROLLER(drag));
    GtkEventController *keys = gtk_event_controller_key_new();
    g_signal_connect(keys, "key-pressed", G_CALLBACK(compare_key_pressed), area);
    gtk_widget_add_controller(area, keys);
    return area;
}

gboolean tailscode_compare_set_pictures(
    GtkWidget *area, const void *before, gsize before_len, const void *after, gsize after_len) {
    Compare *self = compare_of(area);
    if (!self) return FALSE;
    CompareShot earlier, later;
    memset(&earlier, 0, sizeof(earlier));
    memset(&later, 0, sizeof(later));
    if (!compare_shot_decode(&earlier, before, before_len)) return FALSE;
    if (!compare_shot_decode(&later, after, after_len)) {
        compare_shot_release(&earlier);
        return FALSE;
    }
    compare_shot_release(&self->before);
    compare_shot_release(&self->after);
    self->before = earlier;
    self->after = later;
    gtk_widget_queue_draw(area);
    return TRUE;
}

void tailscode_compare_clear(GtkWidget *area) {
    Compare *self = compare_of(area);
    if (!self) return;
    compare_shot_release(&self->before);
    compare_shot_release(&self->after);
    g_free(self->regions);
    self->regions = NULL;
    self->region_count = 0;
    gtk_widget_queue_draw(area);
}

void tailscode_compare_size(GtkWidget *area, int *width, int *height) {
    Compare *self = compare_of(area);
    if (width) *width = self ? self->after.width : 0;
    if (height) *height = self ? self->after.height : 0;
}

void tailscode_compare_set_mode(GtkWidget *area, gboolean side_by_side) {
    Compare *self = compare_of(area);
    if (!self) return;
    self->side_by_side = side_by_side;
    gtk_widget_set_cursor_from_name(area, side_by_side ? NULL : "ew-resize");
    gtk_widget_queue_draw(area);
}

void tailscode_compare_set_regions(
    GtkWidget *area, const double *fractions, int count, const double *rgb) {
    Compare *self = compare_of(area);
    if (!self) return;
    g_free(self->regions);
    self->regions = NULL;
    self->region_count = 0;
    if (fractions && count > 0) {
        self->regions = g_memdup2(fractions, sizeof(double) * 4 * (gsize)count);
        self->region_count = count;
    }
    if (rgb) {
        self->ink[0] = rgb[0];
        self->ink[1] = rgb[1];
        self->ink[2] = rgb[2];
    }
    gtk_widget_queue_draw(area);
}

void tailscode_compare_set_handle(GtkWidget *area, double fraction) {
    Compare *self = compare_of(area);
    if (!self) return;
    self->handle = CLAMP(fraction, 0.0, 1.0);
    gtk_widget_queue_draw(area);
}

double tailscode_compare_handle(GtkWidget *area) {
    Compare *self = compare_of(area);
    return self ? self->handle : 0.5;
}

int tailscode_compare_live_pictures(void) {
    return g_atomic_int_get(&compare_live);
}

typedef struct {
    GtkWidget *scale;
    double *fractions;
    int count;
    double ink[3];
} ScrubTicks;

static const char *scrub_ticks_key = "tailscode-scrub-ticks";

static int scrub_ticks_positions(ScrubTicks *self, double *out, int capacity) {
    if (!self->scale || !GTK_IS_RANGE(self->scale)) return 0;
    GdkRectangle trough;
    gtk_range_get_range_rect(GTK_RANGE(self->scale), &trough);
    int slider_start = 0, slider_end = 0;
    gtk_range_get_slider_range(GTK_RANGE(self->scale), &slider_start, &slider_end);
    double slider = MAX(0, slider_end - slider_start);
    double travel = MAX(1.0, trough.width - slider);
    int written = 0;
    for (int index = 0; index < self->count && written < capacity; index++)
        out[written++] = trough.x + slider / 2.0 + CLAMP(self->fractions[index], 0.0, 1.0) * travel;
    return written;
}

int tailscode_scrub_ticks_plan(GtkWidget *area, double *out, int capacity) {
    ScrubTicks *self = area ? g_object_get_data(G_OBJECT(area), scrub_ticks_key) : NULL;
    return self ? scrub_ticks_positions(self, out, capacity) : -1;
}

static void scrub_ticks_draw(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer raw) {
    (void)area;
    (void)width;
    ScrubTicks *self = raw;
    if (self->count <= 0) return;
    double *places = g_new0(double, self->count);
    int count = scrub_ticks_positions(self, places, self->count);
    cairo_set_source_rgb(cr, self->ink[0], self->ink[1], self->ink[2]);
    cairo_set_line_width(cr, 2);
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND);
    for (int index = 0; index < count; index++) {
        cairo_move_to(cr, places[index], height - 9);
        cairo_line_to(cr, places[index], height - 2);
        cairo_stroke(cr);
    }
    g_free(places);
}

static void scrub_ticks_free(gpointer raw) {
    ScrubTicks *self = raw;
    if (self->scale) g_object_remove_weak_pointer(G_OBJECT(self->scale), (gpointer *)&self->scale);
    g_free(self->fractions);
    g_free(self);
}

GtkWidget *tailscode_scrub_ticks_new(GtkWidget *scale) {
    GtkWidget *area = gtk_drawing_area_new();
    ScrubTicks *self = g_new0(ScrubTicks, 1);
    self->scale = scale;
    if (scale) g_object_add_weak_pointer(G_OBJECT(scale), (gpointer *)&self->scale);
    self->ink[0] = 0.9;
    self->ink[1] = 0.6;
    self->ink[2] = 0.1;
    g_object_set_data_full(G_OBJECT(area), scrub_ticks_key, self, scrub_ticks_free);
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(area), scrub_ticks_draw, self, NULL);
    gtk_widget_set_can_target(area, FALSE);
    gtk_widget_set_can_focus(area, FALSE);
    return area;
}

void tailscode_scrub_ticks_set(GtkWidget *area, const double *fractions, int count, const double *rgb) {
    ScrubTicks *self = area ? g_object_get_data(G_OBJECT(area), scrub_ticks_key) : NULL;
    if (!self) return;
    g_free(self->fractions);
    self->fractions = NULL;
    self->count = 0;
    if (fractions && count > 0) {
        self->fractions = g_memdup2(fractions, sizeof(double) * (gsize)count);
        self->count = count;
    }
    if (rgb) {
        self->ink[0] = rgb[0];
        self->ink[1] = rgb[1];
        self->ink[2] = rgb[2];
    }
    gtk_widget_queue_draw(area);
}

typedef struct {
    TailscodeOutlineHandler handler;
    void *data;
    double *rects[3];
    int counts[3];
    double ink[3][3];
    gboolean active;
} Outline;

static const char *outline_key = "tailscode-outline";

static Outline *outline_of(GtkWidget *area) {
    return area ? g_object_get_data(G_OBJECT(area), outline_key) : NULL;
}

static void outline_draw_group(cairo_t *cr, Outline *self, int group, int width, int height) {
    if (self->counts[group] <= 0) return;
    double line = group == 0 ? 1.5 : 2.5;
    for (int index = 0; index < self->counts[group]; index++) {
        const double *rect = self->rects[group] + 4 * index;
        double x = rect[0] * width;
        double y = rect[1] * height;
        double w = MAX(rect[2] * width, 2.0);
        double h = MAX(rect[3] * height, 2.0);
        gboolean whole = rect[2] * rect[3] > 0.6;
        cairo_rectangle(cr, x + line / 2, y + line / 2, MAX(w - line, 1.0), MAX(h - line, 1.0));
        cairo_set_source_rgba(
            cr, self->ink[group][0], self->ink[group][1], self->ink[group][2],
            whole ? 0.0 : (group == 1 ? 0.16 : 0.09));
        cairo_fill_preserve(cr);
        cairo_set_source_rgb(cr, self->ink[group][0], self->ink[group][1], self->ink[group][2]);
        cairo_set_line_width(cr, line);
        cairo_stroke(cr);
    }
}

static void outline_draw(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer raw) {
    (void)area;
    Outline *self = raw;
    outline_draw_group(cr, self, 0, width, height);
    outline_draw_group(cr, self, 1, width, height);
    outline_draw_group(cr, self, 2, width, height);
}

static void outline_tell(GtkWidget *area, int kind, double x, double y) {
    Outline *self = outline_of(area);
    if (!self || !self->handler) return;
    int width = gtk_widget_get_width(area);
    int height = gtk_widget_get_height(area);
    if (width <= 0 || height <= 0) return;
    self->handler(self->data, kind, CLAMP(x / width, 0.0, 1.0), CLAMP(y / height, 0.0, 1.0));
}

static void outline_motion(GtkEventControllerMotion *controller, double x, double y, gpointer raw) {
    (void)controller;
    outline_tell(GTK_WIDGET(raw), 0, x, y);
}

static void outline_leave(GtkEventControllerMotion *controller, gpointer raw) {
    (void)controller;
    outline_tell(GTK_WIDGET(raw), 1, 0, 0);
}

static void outline_pressed(GtkGestureClick *gesture, int presses, double x, double y, gpointer raw) {
    (void)gesture;
    (void)presses;
    outline_tell(GTK_WIDGET(raw), 2, x, y);
}

static void outline_free(gpointer raw) {
    Outline *self = raw;
    for (int group = 0; group < 3; group++) g_free(self->rects[group]);
    g_free(self);
}

GtkWidget *tailscode_outline_new(TailscodeOutlineHandler handler, void *data) {
    GtkWidget *area = gtk_drawing_area_new();
    Outline *self = g_new0(Outline, 1);
    self->handler = handler;
    self->data = data;
    for (int group = 0; group < 3; group++) {
        self->ink[group][0] = 0.2;
        self->ink[group][1] = 0.6;
        self->ink[group][2] = 1.0;
    }
    g_object_set_data_full(G_OBJECT(area), outline_key, self, outline_free);
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(area), outline_draw, self, NULL);
    gtk_widget_set_hexpand(area, TRUE);
    gtk_widget_set_vexpand(area, TRUE);
    gtk_widget_set_can_target(area, FALSE);
    gtk_widget_set_can_focus(area, FALSE);
    GtkEventController *motion = gtk_event_controller_motion_new();
    g_signal_connect(motion, "motion", G_CALLBACK(outline_motion), area);
    g_signal_connect(motion, "leave", G_CALLBACK(outline_leave), area);
    gtk_widget_add_controller(area, motion);
    GtkGesture *click = gtk_gesture_click_new();
    g_signal_connect(click, "pressed", G_CALLBACK(outline_pressed), area);
    gtk_widget_add_controller(area, GTK_EVENT_CONTROLLER(click));
    return area;
}

void tailscode_outline_bind(GtkWidget *area, void *data) {
    Outline *self = outline_of(area);
    if (self) self->data = data;
}

void tailscode_outline_detach(GtkWidget *area) {
    Outline *self = outline_of(area);
    if (!self) return;
    self->handler = NULL;
    self->data = NULL;
}

void tailscode_outline_set_active(GtkWidget *area, gboolean active) {
    Outline *self = outline_of(area);
    if (!self) return;
    self->active = active;
    gtk_widget_set_can_target(area, active);
    gtk_widget_set_cursor_from_name(area, active ? "crosshair" : NULL);
    gtk_widget_queue_draw(area);
}

void tailscode_outline_set(GtkWidget *area, int group, const double *rects, int count, const double *rgb) {
    Outline *self = outline_of(area);
    if (!self || group < 0 || group > 2) return;
    g_free(self->rects[group]);
    self->rects[group] = NULL;
    self->counts[group] = 0;
    if (rects && count > 0) {
        self->rects[group] = g_memdup2(rects, sizeof(double) * 4 * (gsize)count);
        self->counts[group] = count;
    }
    if (rgb) {
        self->ink[group][0] = rgb[0];
        self->ink[group][1] = rgb[1];
        self->ink[group][2] = rgb[2];
    }
    gtk_widget_queue_draw(area);
}

int tailscode_outline_plan(GtkWidget *area, int width, int height, double *out, int capacity) {
    Outline *self = outline_of(area);
    if (!self) return -1;
    int total = self->counts[0] + self->counts[1] + self->counts[2];
    if (capacity < 3 + 4 * total) return -1;
    out[0] = self->counts[0];
    out[1] = self->counts[1];
    out[2] = self->counts[2];
    int written = 3;
    for (int group = 0; group < 3; group++) {
        for (int index = 0; index < self->counts[group]; index++) {
            const double *rect = self->rects[group] + 4 * index;
            out[written++] = rect[0] * width;
            out[written++] = rect[1] * height;
            out[written++] = rect[2] * width;
            out[written++] = rect[3] * height;
        }
    }
    return written;
}

void tailscode_outline_point(GtkWidget *area, int kind, double fx, double fy) {
    Outline *self = outline_of(area);
    if (!self || !self->handler) return;
    self->handler(self->data, kind, CLAMP(fx, 0.0, 1.0), CLAMP(fy, 0.0, 1.0));
}

typedef struct {
    TailscodeWidthHandler handler;
    void *data;
    int width;
} WidthSensor;

static const char *width_sensor_key = "tailscode-width-sensor";

static void width_sensor_resize(GtkDrawingArea *area, int width, int height, gpointer raw) {
    (void)area;
    WidthSensor *self = raw;
    if (width == self->width) return;
    self->width = width;
    if (self->handler) self->handler(self->data, width, height);
}

GtkWidget *tailscode_width_sensor_new(TailscodeWidthHandler handler, void *data) {
    GtkWidget *area = gtk_drawing_area_new();
    WidthSensor *self = g_new0(WidthSensor, 1);
    self->handler = handler;
    self->data = data;
    g_object_set_data_full(G_OBJECT(area), width_sensor_key, self, g_free);
    g_signal_connect(area, "resize", G_CALLBACK(width_sensor_resize), self);
    gtk_widget_set_hexpand(area, TRUE);
    gtk_widget_set_size_request(area, -1, 0);
    gtk_widget_set_can_target(area, FALSE);
    gtk_widget_set_can_focus(area, FALSE);
    return area;
}

void tailscode_width_sensor_bind(GtkWidget *area, void *data) {
    WidthSensor *self = area ? g_object_get_data(G_OBJECT(area), width_sensor_key) : NULL;
    if (self) self->data = data;
}

void tailscode_width_sensor_detach(GtkWidget *area) {
    WidthSensor *self = area ? g_object_get_data(G_OBJECT(area), width_sensor_key) : NULL;
    if (!self) return;
    self->handler = NULL;
    self->data = NULL;
}

typedef struct {
    TailscodeTouchHandler handler;
    void *data;
    double *rings;
    int ring_count;
    double *trail;
    int trail_count;
    double ink[3];
    double pointer_x;
    double pointer_y;
    double start_x;
    double start_y;
    gboolean active;
    gboolean pressed;
} Touch;

static const char *touch_key = "tailscode-touch";

static Touch *touch_of(GtkWidget *area) {
    return area ? g_object_get_data(G_OBJECT(area), touch_key) : NULL;
}

static void touch_tell(GtkWidget *area, int kind, double x, double y, double a, double b) {
    Touch *self = touch_of(area);
    if (!self || !self->handler) return;
    self->handler(self->data, kind, x, y, a, b, gtk_widget_get_width(area), gtk_widget_get_height(area));
}

static void touch_draw_trail(cairo_t *cr, Touch *self, int width, int height) {
    if (self->trail_count <= 0) return;
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND);
    cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND);
    cairo_set_line_width(cr, 3.0);
    for (int index = 1; index < self->trail_count; index++) {
        const double *from = self->trail + 3 * (index - 1);
        const double *to = self->trail + 3 * index;
        cairo_set_source_rgba(cr, 0, 0, 0, (from[2] + to[2]) / 2 * 0.3);
        cairo_set_line_width(cr, 5.5);
        cairo_move_to(cr, from[0] * width, from[1] * height);
        cairo_line_to(cr, to[0] * width, to[1] * height);
        cairo_stroke(cr);
        cairo_set_line_width(cr, 3.0);
        cairo_set_source_rgba(cr, self->ink[0], self->ink[1], self->ink[2], (from[2] + to[2]) / 2);
        cairo_move_to(cr, from[0] * width, from[1] * height);
        cairo_line_to(cr, to[0] * width, to[1] * height);
        cairo_stroke(cr);
    }
    const double *head = self->trail + 3 * (self->trail_count - 1);
    cairo_set_source_rgba(cr, self->ink[0], self->ink[1], self->ink[2], head[2]);
    cairo_arc(cr, head[0] * width, head[1] * height, 4.5, 0, 2 * G_PI);
    cairo_fill(cr);
}

static void touch_draw_ring(cairo_t *cr, Touch *self, const double *ring, int width, int height) {
    double x = ring[0] * width;
    double y = ring[1] * height;
    double radius = MAX(ring[2] * width, 4.0);
    double alpha = CLAMP(ring[3], 0.0, 1.0);
    cairo_arc(cr, x, y, radius, 0, 2 * G_PI);
    cairo_set_source_rgba(cr, 0, 0, 0, alpha * 0.3);
    cairo_set_line_width(cr, 5.0);
    cairo_stroke_preserve(cr);
    cairo_set_source_rgba(cr, self->ink[0], self->ink[1], self->ink[2], alpha * 0.16);
    cairo_fill_preserve(cr);
    cairo_set_source_rgba(cr, self->ink[0], self->ink[1], self->ink[2], ring[4] > 0.5 ? alpha * 0.55 : alpha);
    cairo_set_line_width(cr, 2.5);
    cairo_stroke(cr);
    if (ring[4] > 0.5) {
        double start = (ring[5] - 90.0) * G_PI / 180.0;
        cairo_arc(cr, x, y, radius, start, start + 100.0 * G_PI / 180.0);
        cairo_set_source_rgba(cr, self->ink[0], self->ink[1], self->ink[2], MIN(1.0, alpha * 1.7));
        cairo_set_line_width(cr, 3.5);
        cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND);
        cairo_stroke(cr);
    }
}

static void touch_draw(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer raw) {
    (void)area;
    Touch *self = raw;
    touch_draw_trail(cr, self, width, height);
    for (int index = 0; index < self->ring_count; index++) {
        touch_draw_ring(cr, self, self->rings + 6 * index, width, height);
    }
}

static void touch_begin(GtkGestureDrag *gesture, double x, double y, gpointer raw) {
    (void)gesture;
    Touch *self = touch_of(GTK_WIDGET(raw));
    if (!self) return;
    self->pressed = TRUE;
    self->start_x = x;
    self->start_y = y;
    self->pointer_x = x;
    self->pointer_y = y;
    touch_tell(GTK_WIDGET(raw), 0, x, y, 0, 0);
}

static void touch_update(GtkGestureDrag *gesture, double dx, double dy, gpointer raw) {
    (void)gesture;
    Touch *self = touch_of(GTK_WIDGET(raw));
    if (!self || !self->pressed) return;
    self->pointer_x = self->start_x + dx;
    self->pointer_y = self->start_y + dy;
    touch_tell(GTK_WIDGET(raw), 1, self->pointer_x, self->pointer_y, 0, 0);
}

static void touch_end(GtkGestureDrag *gesture, double dx, double dy, gpointer raw) {
    (void)gesture;
    Touch *self = touch_of(GTK_WIDGET(raw));
    if (!self || !self->pressed) return;
    self->pressed = FALSE;
    self->pointer_x = self->start_x + dx;
    self->pointer_y = self->start_y + dy;
    touch_tell(GTK_WIDGET(raw), 2, self->pointer_x, self->pointer_y, 0, 0);
}

static void touch_cancel(GtkGesture *gesture, GdkEventSequence *sequence, gpointer raw) {
    (void)gesture;
    (void)sequence;
    Touch *self = touch_of(GTK_WIDGET(raw));
    if (!self || !self->pressed) return;
    self->pressed = FALSE;
    touch_tell(GTK_WIDGET(raw), 3, self->pointer_x, self->pointer_y, 0, 0);
}

static void touch_motion(GtkEventControllerMotion *controller, double x, double y, gpointer raw) {
    (void)controller;
    Touch *self = touch_of(GTK_WIDGET(raw));
    if (!self || self->pressed) return;
    self->pointer_x = x;
    self->pointer_y = y;
}

static gboolean touch_scroll(GtkEventControllerScroll *controller, double dx, double dy, gpointer raw) {
    Touch *self = touch_of(GTK_WIDGET(raw));
    if (!self) return FALSE;
    gboolean wheel = gtk_event_controller_scroll_get_unit(controller) == GDK_SCROLL_UNIT_WHEEL;
    touch_tell(GTK_WIDGET(raw), wheel ? 4 : 5, self->pointer_x, self->pointer_y, dx, dy);
    return TRUE;
}

static void touch_free(gpointer raw) {
    Touch *self = raw;
    g_free(self->rings);
    g_free(self->trail);
    g_free(self);
}

GtkWidget *tailscode_touch_new(TailscodeTouchHandler handler, void *data) {
    GtkWidget *area = gtk_drawing_area_new();
    Touch *self = g_new0(Touch, 1);
    self->handler = handler;
    self->data = data;
    self->ink[0] = 0.2;
    self->ink[1] = 0.6;
    self->ink[2] = 1.0;
    g_object_set_data_full(G_OBJECT(area), touch_key, self, touch_free);
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(area), touch_draw, self, NULL);
    gtk_widget_set_hexpand(area, TRUE);
    gtk_widget_set_vexpand(area, TRUE);
    gtk_widget_set_can_target(area, FALSE);
    gtk_widget_set_can_focus(area, FALSE);
    GtkGesture *drag = gtk_gesture_drag_new();
    gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(drag), GDK_BUTTON_PRIMARY);
    g_signal_connect(drag, "drag-begin", G_CALLBACK(touch_begin), area);
    g_signal_connect(drag, "drag-update", G_CALLBACK(touch_update), area);
    g_signal_connect(drag, "drag-end", G_CALLBACK(touch_end), area);
    g_signal_connect(drag, "cancel", G_CALLBACK(touch_cancel), area);
    gtk_widget_add_controller(area, GTK_EVENT_CONTROLLER(drag));
    GtkEventController *motion = gtk_event_controller_motion_new();
    g_signal_connect(motion, "motion", G_CALLBACK(touch_motion), area);
    gtk_widget_add_controller(area, motion);
    GtkEventController *scroll = gtk_event_controller_scroll_new(GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES);
    g_signal_connect(scroll, "scroll", G_CALLBACK(touch_scroll), area);
    gtk_widget_add_controller(area, scroll);
    return area;
}

void tailscode_touch_bind(GtkWidget *area, void *data) {
    Touch *self = touch_of(area);
    if (self) self->data = data;
}

void tailscode_touch_detach(GtkWidget *area) {
    Touch *self = touch_of(area);
    if (!self) return;
    self->handler = NULL;
    self->data = NULL;
}

void tailscode_touch_set_active(GtkWidget *area, gboolean active) {
    Touch *self = touch_of(area);
    if (!self) return;
    self->active = active;
    if (!active) self->pressed = FALSE;
    gtk_widget_set_can_target(area, active);
    gtk_widget_set_cursor_from_name(area, active ? "pointer" : NULL);
    gtk_widget_queue_draw(area);
}

gboolean tailscode_touch_active(GtkWidget *area) {
    Touch *self = touch_of(area);
    return self ? self->active : FALSE;
}

void tailscode_touch_set_marks(
    GtkWidget *area, const double *rings, int ring_count, const double *trail, int trail_count,
    const double *rgb) {
    Touch *self = touch_of(area);
    if (!self) return;
    g_free(self->rings);
    g_free(self->trail);
    self->rings = NULL;
    self->trail = NULL;
    self->ring_count = 0;
    self->trail_count = 0;
    if (rings && ring_count > 0) {
        self->rings = g_memdup2(rings, sizeof(double) * 6 * (gsize)ring_count);
        self->ring_count = ring_count;
    }
    if (trail && trail_count > 0) {
        self->trail = g_memdup2(trail, sizeof(double) * 3 * (gsize)trail_count);
        self->trail_count = trail_count;
    }
    if (rgb) {
        self->ink[0] = rgb[0];
        self->ink[1] = rgb[1];
        self->ink[2] = rgb[2];
    }
    gtk_widget_queue_draw(area);
}

int tailscode_touch_plan(GtkWidget *area, int width, int height, double *out, int capacity) {
    Touch *self = touch_of(area);
    if (!self) return -1;
    int needed = 2 + 5 * self->ring_count + 3 * self->trail_count;
    if (capacity < needed) return -1;
    out[0] = self->ring_count;
    out[1] = self->trail_count;
    int written = 2;
    for (int index = 0; index < self->ring_count; index++) {
        const double *ring = self->rings + 6 * index;
        out[written++] = ring[0] * width;
        out[written++] = ring[1] * height;
        out[written++] = ring[2] * width;
        out[written++] = ring[3];
        out[written++] = ring[4];
    }
    for (int index = 0; index < self->trail_count; index++) {
        const double *point = self->trail + 3 * index;
        out[written++] = point[0] * width;
        out[written++] = point[1] * height;
        out[written++] = point[2];
    }
    return written;
}

void tailscode_touch_point(
    GtkWidget *area, int kind, double fx, double fy, double a, double b, double width, double height) {
    Touch *self = touch_of(area);
    if (!self || !self->handler) return;
    double x = CLAMP(fx, 0.0, 1.0) * width;
    double y = CLAMP(fy, 0.0, 1.0) * height;
    self->pointer_x = x;
    self->pointer_y = y;
    self->handler(self->data, kind, x, y, a, b, width, height);
}
