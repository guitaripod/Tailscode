#include "meridian.h"
#include <math.h>
#include <string.h>
#include <pango/pangocairo.h>

#define INKS TAILSCODE_MERIDIAN_INKS
enum { INK_CANVAS, INK_TEXT, INK_DIM, INK_ACCENT, INK_WARN, INK_INFO, INK_SPECIAL, INK_NIGHT, INK_DAY, INK_RAISED, INK_RULE };

static const char *ink_key = "tailscode-meridian-ink";

static void ink_attach(GtkWidget *widget, double *ink) {
    for (int index = 0; index < INKS; index++) {
        ink[index * 3] = 0.5;
        ink[index * 3 + 1] = 0.5;
        ink[index * 3 + 2] = 0.5;
    }
    g_object_set_data(G_OBJECT(widget), ink_key, ink);
}

void tailscode_meridian_set_inks(GtkWidget *widget, const double *rgb) {
    double *ink = g_object_get_data(G_OBJECT(widget), ink_key);
    if (!ink || !rgb) return;
    memcpy(ink, rgb, sizeof(double) * INKS * 3);
    gtk_widget_queue_draw(widget);
}

static void paint(cairo_t *cr, const double *ink, int slot, double alpha) {
    cairo_set_source_rgba(cr, ink[slot * 3], ink[slot * 3 + 1], ink[slot * 3 + 2], alpha);
}

static void rounded(cairo_t *cr, double x, double y, double w, double h, double r) {
    r = MIN(r, MIN(w, h) / 2);
    cairo_new_sub_path(cr);
    cairo_arc(cr, x + w - r, y + r, r, -G_PI / 2, 0);
    cairo_arc(cr, x + w - r, y + h - r, r, 0, G_PI / 2);
    cairo_arc(cr, x + r, y + h - r, r, G_PI / 2, G_PI);
    cairo_arc(cr, x + r, y + r, r, G_PI, G_PI * 3 / 2);
    cairo_close_path(cr);
}

static void glow(cairo_t *cr, double x, double y, double radius, const double *ink, int slot, double alpha) {
    cairo_pattern_t *pattern = cairo_pattern_create_radial(x, y, 0, x, y, radius);
    cairo_pattern_add_color_stop_rgba(pattern, 0, ink[slot * 3], ink[slot * 3 + 1], ink[slot * 3 + 2], alpha);
    cairo_pattern_add_color_stop_rgba(pattern, 1, ink[slot * 3], ink[slot * 3 + 1], ink[slot * 3 + 2], 0);
    cairo_set_source(cr, pattern);
    cairo_arc(cr, x, y, radius, 0, 2 * G_PI);
    cairo_fill(cr);
    cairo_pattern_destroy(pattern);
}

static PangoLayout *text_layout(GtkWidget *widget, const char *text, int *width, int *height) {
    PangoLayout *layout = gtk_widget_create_pango_layout(widget, text);
    pango_layout_get_pixel_size(layout, width, height);
    return layout;
}

typedef struct {
    double ink[INKS * 3];
    int kind;
    double progress;
    double body[3];
    double line[3];
} Glyph;

static void crescent(cairo_t *cr, double x, double y, double r, double cut) {
    cairo_save(cr);
    cairo_rectangle(cr, x - 4 * r, y - 4 * r, 8 * r, 8 * r);
    cairo_arc(cr, x + r * cut, y - r * cut * 0.7, r * 0.88, 0, 2 * G_PI);
    cairo_set_fill_rule(cr, CAIRO_FILL_RULE_EVEN_ODD);
    cairo_clip(cr);
    cairo_arc(cr, x, y, r, 0, 2 * G_PI);
    cairo_fill(cr);
    cairo_restore(cr);
}

static void sun_disc(cairo_t *cr, double x, double y, double r, double rays) {
    cairo_arc(cr, x, y, r, 0, 2 * G_PI);
    cairo_fill(cr);
    if (rays <= 0) return;
    for (int index = 0; index < 8; index++) {
        double angle = index * G_PI / 4;
        cairo_move_to(cr, x + cos(angle) * (r + rays * 0.45), y + sin(angle) * (r + rays * 0.45));
        cairo_line_to(cr, x + cos(angle) * (r + rays), y + sin(angle) * (r + rays));
    }
    cairo_stroke(cr);
}

static void glyph_sky(cairo_t *cr, Glyph *self) {
    const double cx = 8, cy = 11.5, r = 5.5;
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND);
    cairo_set_line_width(cr, 1.2);
    cairo_set_source_rgba(cr, self->line[0], self->line[1], self->line[2], 0.5);
    cairo_arc(cr, cx, cy, r, G_PI, 2 * G_PI);
    cairo_stroke(cr);
    cairo_set_line_width(cr, 1.4);
    cairo_set_source_rgba(cr, self->line[0], self->line[1], self->line[2], 0.85);
    cairo_move_to(cr, 1.2, cy);
    cairo_line_to(cr, 14.8, cy);
    cairo_stroke(cr);
    double theta = G_PI * (1.0 - CLAMP(self->progress, 0.0, 1.0));
    double x = cx + r * cos(theta);
    double y = self->kind == TAILSCODE_GLYPH_SKY_TWILIGHT ? cy : cy - r * sin(theta);
    cairo_set_source_rgb(cr, self->body[0], self->body[1], self->body[2]);
    if (self->kind == TAILSCODE_GLYPH_SKY_DAY) {
        cairo_pattern_t *pattern = cairo_pattern_create_radial(x, y, 0, x, y, 5);
        cairo_pattern_add_color_stop_rgba(pattern, 0, self->body[0], self->body[1], self->body[2], 0.4);
        cairo_pattern_add_color_stop_rgba(pattern, 1, self->body[0], self->body[1], self->body[2], 0);
        cairo_set_source(cr, pattern);
        cairo_arc(cr, x, y, 5, 0, 2 * G_PI);
        cairo_fill(cr);
        cairo_pattern_destroy(pattern);
        cairo_set_source_rgb(cr, self->body[0], self->body[1], self->body[2]);
        cairo_set_line_width(cr, 1.0);
        sun_disc(cr, x, y, 2.0, 1.9);
    } else if (self->kind == TAILSCODE_GLYPH_SKY_TWILIGHT) {
        cairo_save(cr);
        cairo_rectangle(cr, 0, 0, 16, cy - 0.7);
        cairo_clip(cr);
        cairo_arc(cr, x, y, 2.6, 0, 2 * G_PI);
        cairo_fill(cr);
        cairo_restore(cr);
    } else {
        crescent(cr, x, y, 2.9, 0.55);
    }
}

static void glyph_icon(cairo_t *cr, Glyph *self) {
    cairo_set_source_rgb(cr, self->body[0], self->body[1], self->body[2]);
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND);
    cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND);
    cairo_set_line_width(cr, 2);
    switch (self->kind) {
    case TAILSCODE_GLYPH_SUN:
        cairo_arc(cr, 12, 12, 4, 0, 2 * G_PI);
        cairo_stroke(cr);
        for (int index = 0; index < 8; index++) {
            double angle = index * G_PI / 4;
            cairo_move_to(cr, 12 + cos(angle) * 7.6, 12 + sin(angle) * 7.6);
            cairo_line_to(cr, 12 + cos(angle) * 10, 12 + sin(angle) * 10);
        }
        cairo_stroke(cr);
        break;
    case TAILSCODE_GLYPH_MOON:
        crescent(cr, 11.5, 12.5, 8.5, 0.62);
        break;
    case TAILSCODE_GLYPH_GLOBE:
        cairo_arc(cr, 12, 12, 9.5, 0, 2 * G_PI);
        cairo_stroke(cr);
        cairo_move_to(cr, 12, 2.5);
        cairo_line_to(cr, 12, 21.5);
        cairo_stroke(cr);
        cairo_save(cr);
        cairo_translate(cr, 12, 12);
        cairo_scale(cr, 4.5 / 9.5, 1);
        cairo_arc(cr, 0, 0, 9.5, 0, 2 * G_PI);
        cairo_restore(cr);
        cairo_stroke(cr);
        break;
    case TAILSCODE_GLYPH_CLOCK:
        cairo_arc(cr, 12, 12, 9, 0, 2 * G_PI);
        cairo_stroke(cr);
        cairo_move_to(cr, 12, 7);
        cairo_line_to(cr, 12, 12);
        cairo_line_to(cr, 15, 14);
        cairo_stroke(cr);
        break;
    case TAILSCODE_GLYPH_INFO:
        cairo_arc(cr, 12, 12, 9, 0, 2 * G_PI);
        cairo_stroke(cr);
        cairo_move_to(cr, 12, 11);
        cairo_line_to(cr, 12, 16);
        cairo_stroke(cr);
        cairo_arc(cr, 12, 8, 1.1, 0, 2 * G_PI);
        cairo_fill(cr);
        break;
    }
}

static void glyph_draw(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer raw) {
    (void)area;
    Glyph *self = raw;
    double extent = MIN(width, height);
    cairo_save(cr);
    cairo_translate(cr, (width - extent) / 2, (height - extent) / 2);
    gboolean sky = self->kind <= TAILSCODE_GLYPH_SKY_DAY;
    cairo_scale(cr, extent / (sky ? 16.0 : 24.0), extent / (sky ? 16.0 : 24.0));
    if (sky) glyph_sky(cr, self);
    else glyph_icon(cr, self);
    cairo_restore(cr);
}

GtkWidget *tailscode_glyph_new(int size) {
    GtkWidget *area = gtk_drawing_area_new();
    Glyph *self = g_new0(Glyph, 1);
    ink_attach(area, self->ink);
    g_object_set_data_full(G_OBJECT(area), "tailscode-glyph", self, g_free);
    gtk_drawing_area_set_content_width(GTK_DRAWING_AREA(area), size);
    gtk_drawing_area_set_content_height(GTK_DRAWING_AREA(area), size);
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(area), glyph_draw, self, NULL);
    gtk_widget_set_halign(area, GTK_ALIGN_CENTER);
    gtk_widget_set_valign(area, GTK_ALIGN_CENTER);
    return area;
}

void tailscode_glyph_set(GtkWidget *area, int kind, double progress, const double *body, const double *line) {
    Glyph *self = g_object_get_data(G_OBJECT(area), "tailscode-glyph");
    if (!self) return;
    self->kind = kind;
    self->progress = progress;
    if (body) memcpy(self->body, body, sizeof(double) * 3);
    if (line) memcpy(self->line, line, sizeof(double) * 3);
    gtk_widget_queue_draw(area);
}

typedef struct {
    double ink[INKS * 3];
    int widget_height, strip_height;
    double radius;
    double *stops;
    int stop_count;
    double hairline, grid_alpha, noon, dot, dot_radius, dot_rgb[3];
    int grid_count;
    int mark_count;
    int *kinds;
    double *positions;
    char **labels;
    double (*rects)[4];
    TailscodeMeridianHandler handler;
    void *data;
} Strip;

static void strip_clear_marks(Strip *self) {
    for (int index = 0; index < self->mark_count; index++) g_free(self->labels[index]);
    g_free(self->kinds);
    g_free(self->positions);
    g_free(self->labels);
    g_free(self->rects);
    self->kinds = NULL;
    self->positions = NULL;
    self->labels = NULL;
    self->rects = NULL;
    self->mark_count = 0;
}

static void strip_gradient(cairo_t *cr, Strip *self, double width) {
    if (self->stop_count <= 0) {
        paint(cr, self->ink, INK_NIGHT, 1);
        return;
    }
    cairo_pattern_t *pattern = cairo_pattern_create_linear(0, 0, width, 0);
    for (int index = 0; index < self->stop_count; index++) {
        double position = self->stops[index * 2];
        double light = CLAMP(self->stops[index * 2 + 1], 0.0, 1.0);
        const double *night = self->ink + INK_NIGHT * 3;
        const double *day = self->ink + INK_DAY * 3;
        cairo_pattern_add_color_stop_rgb(
            pattern, CLAMP(position, 0.0, 1.0), night[0] + (day[0] - night[0]) * light,
            night[1] + (day[1] - night[1]) * light, night[2] + (day[2] - night[2]) * light);
    }
    cairo_set_source(cr, pattern);
    cairo_pattern_destroy(pattern);
}

static void strip_marks(GtkWidget *widget, cairo_t *cr, Strip *self, double width, double top, double height) {
    for (int index = 0; index < self->mark_count; index++) {
        double x = CLAMP(self->positions[index], 0.0, 1.0) * width;
        int text_width = 0, text_height = 0;
        PangoLayout *layout = text_layout(widget, self->labels[index], &text_width, &text_height);
        double *rect = self->rects[index];
        if (self->kinds[index] == 0) {
            paint(cr, self->ink, INK_INFO, 1);
            cairo_rectangle(cr, x - 1, top, 2, height);
            cairo_fill(cr);
            double pill_height = MIN(22.0, height - 4);
            double pill_width = text_width + 18;
            double pill_x = x + 8;
            if (pill_x + pill_width > width - 4) pill_x = x - 8 - pill_width;
            double pill_y = top + (height - pill_height) / 2;
            paint(cr, self->ink, INK_CANVAS, 0.9);
            rounded(cr, pill_x, pill_y, pill_width, pill_height, pill_height / 2);
            cairo_fill(cr);
            paint(cr, self->ink, INK_INFO, 1);
            cairo_move_to(cr, pill_x + 9, pill_y + (pill_height - text_height) / 2.0);
            pango_cairo_show_layout(cr, layout);
            rect[0] = MIN(x - 6, pill_x);
            rect[1] = top;
            rect[2] = MAX(x + 6, pill_x + pill_width) - rect[0];
            rect[3] = height;
        } else {
            double centre = top + height / 2;
            double label_x = x + 10;
            if (label_x + text_width > width - 4) label_x = x - 10 - text_width;
            paint(cr, self->ink, INK_CANVAS, 0.9);
            rounded(cr, label_x - 5, centre - 9, text_width + 10, 18, 9);
            cairo_fill(cr);
            paint(cr, self->ink, INK_SPECIAL, 1);
            cairo_move_to(cr, label_x, centre - text_height / 2.0);
            pango_cairo_show_layout(cr, layout);
            cairo_move_to(cr, x, centre - 6);
            cairo_line_to(cr, x + 6, centre);
            cairo_line_to(cr, x, centre + 6);
            cairo_line_to(cr, x - 6, centre);
            cairo_close_path(cr);
            cairo_fill(cr);
            rect[0] = MIN(x - 8, label_x);
            rect[1] = top;
            rect[2] = MAX(x + 8, label_x + text_width) - rect[0];
            rect[3] = height;
        }
        g_object_unref(layout);
    }
}

static void strip_draw(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer raw) {
    Strip *self = raw;
    double top = (height - self->strip_height) / 2.0;
    double strip = self->strip_height;
    cairo_save(cr);
    rounded(cr, 0, top, width, strip, self->radius);
    cairo_clip(cr);
    cairo_save(cr);
    cairo_translate(cr, 0, top);
    strip_gradient(cr, self, width);
    cairo_rectangle(cr, 0, 0, width, strip);
    cairo_fill(cr);
    cairo_restore(cr);
    if (self->grid_count > 1 && self->grid_alpha > 0) {
        paint(cr, self->ink, INK_TEXT, self->grid_alpha);
        for (int index = 1; index < self->grid_count; index++) {
            double x = floor(width * index / (double)self->grid_count);
            cairo_rectangle(cr, x, top, 1, strip);
        }
        cairo_fill(cr);
    }
    if (self->noon >= 0 && self->noon <= 1) {
        double x = self->noon * width;
        glow(cr, x, top + strip / 2, 18, self->ink, INK_WARN, 0.5);
        paint(cr, self->ink, INK_WARN, 1);
        cairo_arc(cr, x, top + strip / 2, 7, 0, 2 * G_PI);
        cairo_fill(cr);
    }
    strip_marks(GTK_WIDGET(area), cr, self, width, top, strip);
    cairo_restore(cr);
    if (self->hairline > 0) {
        paint(cr, self->ink, INK_TEXT, self->hairline);
        cairo_set_line_width(cr, 1);
        rounded(cr, 0.5, top + 0.5, width - 1, strip - 1, self->radius - 0.5);
        cairo_stroke(cr);
    }
    if (self->dot >= 0 && self->dot_radius > 0) {
        double x = CLAMP(self->dot * width, self->dot_radius, width - self->dot_radius);
        double y = height / 2.0;
        cairo_pattern_t *pattern = cairo_pattern_create_radial(x, y, 0, x, y, self->dot_radius + 8);
        cairo_pattern_add_color_stop_rgba(pattern, 0, self->dot_rgb[0], self->dot_rgb[1], self->dot_rgb[2], 0.55);
        cairo_pattern_add_color_stop_rgba(pattern, 1, self->dot_rgb[0], self->dot_rgb[1], self->dot_rgb[2], 0);
        cairo_set_source(cr, pattern);
        cairo_arc(cr, x, y, self->dot_radius + 8, 0, 2 * G_PI);
        cairo_fill(cr);
        cairo_pattern_destroy(pattern);
        cairo_set_source_rgb(cr, self->dot_rgb[0], self->dot_rgb[1], self->dot_rgb[2]);
        cairo_arc(cr, x, y, self->dot_radius, 0, 2 * G_PI);
        cairo_fill(cr);
    }
}

static void strip_pressed(GtkGestureClick *gesture, int presses, double x, double y, gpointer raw) {
    (void)presses;
    (void)gesture;
    Strip *self = raw;
    if (!self->handler) return;
    for (int index = 0; index < self->mark_count; index++) {
        double *rect = self->rects[index];
        if (x >= rect[0] && x <= rect[0] + rect[2] && y >= rect[1] && y <= rect[1] + rect[3]) {
            self->handler(self->data, 0, index);
            return;
        }
    }
}

static void strip_free(gpointer raw) {
    Strip *self = raw;
    strip_clear_marks(self);
    g_free(self->stops);
    g_free(self);
}

GtkWidget *tailscode_strip_new(int widget_height, int strip_height, double radius) {
    GtkWidget *area = gtk_drawing_area_new();
    Strip *self = g_new0(Strip, 1);
    ink_attach(area, self->ink);
    self->widget_height = widget_height;
    self->strip_height = strip_height;
    self->radius = radius;
    self->noon = -1;
    self->dot = -1;
    g_object_set_data_full(G_OBJECT(area), "tailscode-strip", self, strip_free);
    gtk_drawing_area_set_content_height(GTK_DRAWING_AREA(area), widget_height);
    gtk_drawing_area_set_content_width(GTK_DRAWING_AREA(area), 40);
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(area), strip_draw, self, NULL);
    gtk_widget_set_hexpand(area, TRUE);
    GtkGesture *click = gtk_gesture_click_new();
    g_signal_connect(click, "pressed", G_CALLBACK(strip_pressed), self);
    gtk_widget_add_controller(area, GTK_EVENT_CONTROLLER(click));
    return area;
}

static Strip *strip_of(GtkWidget *area) { return g_object_get_data(G_OBJECT(area), "tailscode-strip"); }

void tailscode_strip_set_stops(GtkWidget *area, const double *pairs, int count) {
    Strip *self = strip_of(area);
    if (!self) return;
    g_free(self->stops);
    self->stops = count > 0 ? g_memdup2(pairs, sizeof(double) * 2 * count) : NULL;
    self->stop_count = count;
    gtk_widget_queue_draw(area);
}

void tailscode_strip_set_finish(GtkWidget *area, double hairline, int grid_count, double grid_alpha) {
    Strip *self = strip_of(area);
    if (!self) return;
    self->hairline = hairline;
    self->grid_count = grid_count;
    self->grid_alpha = grid_alpha;
    gtk_widget_queue_draw(area);
}

void tailscode_strip_set_noon(GtkWidget *area, double position) {
    Strip *self = strip_of(area);
    if (!self) return;
    self->noon = position;
    gtk_widget_queue_draw(area);
}

void tailscode_strip_set_dot(GtkWidget *area, double position, double radius, const double *rgb) {
    Strip *self = strip_of(area);
    if (!self) return;
    self->dot = position;
    self->dot_radius = radius;
    if (rgb) memcpy(self->dot_rgb, rgb, sizeof(double) * 3);
    gtk_widget_queue_draw(area);
}

void tailscode_strip_set_marks(
    GtkWidget *area, int count, const int *kinds, const double *positions, const char *const *labels) {
    Strip *self = strip_of(area);
    if (!self) return;
    strip_clear_marks(self);
    if (count > 0) {
        self->kinds = g_memdup2(kinds, sizeof(int) * count);
        self->positions = g_memdup2(positions, sizeof(double) * count);
        self->labels = g_new0(char *, count);
        self->rects = (double (*)[4])g_malloc0_n(count, sizeof(double) * 4);
        for (int index = 0; index < count; index++) self->labels[index] = g_strdup(labels[index]);
    }
    self->mark_count = count;
    gtk_widget_set_cursor_from_name(area, count > 0 ? "pointer" : NULL);
    gtk_widget_queue_draw(area);
}

void tailscode_strip_set_handler(GtkWidget *area, TailscodeMeridianHandler handler, void *data) {
    Strip *self = strip_of(area);
    if (!self) return;
    self->handler = handler;
    self->data = data;
}

int tailscode_strip_mark_rect(GtkWidget *area, int index, double *out) {
    Strip *self = strip_of(area);
    if (!self || index < 0 || index >= self->mark_count) return 0;
    memcpy(out, self->rects[index], sizeof(double) * 4);
    return 1;
}

typedef struct {
    double ink[INKS * 3];
    double golden_start, golden_end, now, line;
    char *label;
} Lines;

static void lines_draw(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer raw) {
    Lines *self = raw;
    if (self->golden_start >= 0 && self->golden_end > self->golden_start) {
        double x = self->golden_start * width;
        double w = (self->golden_end - self->golden_start) * width;
        paint(cr, self->ink, INK_ACCENT, 0.12);
        cairo_rectangle(cr, x, 0, w, height);
        cairo_fill(cr);
        if (self->label && self->label[0]) {
            int text_width = 0, text_height = 0;
            PangoLayout *layout = text_layout(GTK_WIDGET(area), self->label, &text_width, &text_height);
            paint(cr, self->ink, INK_ACCENT, 0.95);
            cairo_move_to(cr, x + MAX(6.0, (w - text_width) / 2), 1);
            pango_cairo_show_layout(cr, layout);
            g_object_unref(layout);
        }
    }
    if (self->now >= 0 && self->now <= 1) {
        paint(cr, self->ink, INK_TEXT, 0.35);
        cairo_rectangle(cr, round(self->now * width) - 1, 0, 2, height);
        cairo_fill(cr);
    }
    if (self->line >= 0 && self->line <= 1) {
        double x = round(self->line * width);
        paint(cr, self->ink, INK_ACCENT, 0.12);
        cairo_rectangle(cr, x - 7, 0, 14, height);
        cairo_fill(cr);
        paint(cr, self->ink, INK_ACCENT, 0.22);
        cairo_rectangle(cr, x - 4, 0, 8, height);
        cairo_fill(cr);
        paint(cr, self->ink, INK_ACCENT, 1);
        cairo_rectangle(cr, x - 1, 0, 2, height);
        cairo_fill(cr);
    }
}

static void lines_free(gpointer raw) {
    Lines *self = raw;
    g_free(self->label);
    g_free(self);
}

GtkWidget *tailscode_lines_new(void) {
    GtkWidget *area = gtk_drawing_area_new();
    Lines *self = g_new0(Lines, 1);
    ink_attach(area, self->ink);
    self->golden_start = -1;
    self->now = -1;
    self->line = -1;
    g_object_set_data_full(G_OBJECT(area), "tailscode-lines", self, lines_free);
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(area), lines_draw, self, NULL);
    gtk_widget_set_can_target(area, FALSE);
    gtk_widget_set_hexpand(area, TRUE);
    gtk_widget_set_vexpand(area, TRUE);
    return area;
}

void tailscode_lines_set(
    GtkWidget *area, double golden_start, double golden_end, const char *golden_label, double now_position,
    double line_position) {
    Lines *self = g_object_get_data(G_OBJECT(area), "tailscode-lines");
    if (!self) return;
    self->golden_start = golden_start;
    self->golden_end = golden_end;
    g_free(self->label);
    self->label = g_strdup(golden_label);
    self->now = now_position;
    self->line = line_position;
    gtk_widget_queue_draw(area);
}

typedef struct {
    double ink[INKS * 3];
    int count;
    double *positions;
    char **labels;
} Ticks;

static void ticks_clear(Ticks *self) {
    for (int index = 0; index < self->count; index++) g_free(self->labels[index]);
    g_free(self->positions);
    g_free(self->labels);
    self->positions = NULL;
    self->labels = NULL;
    self->count = 0;
}

static void ticks_draw(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer raw) {
    Ticks *self = raw;
    paint(cr, self->ink, INK_DIM, 1);
    for (int index = 0; index < self->count; index++) {
        int text_width = 0, text_height = 0;
        PangoLayout *layout = text_layout(GTK_WIDGET(area), self->labels[index], &text_width, &text_height);
        double x = self->positions[index] * width - text_width / 2.0;
        if (index == 0) x = 0;
        else if (index == self->count - 1) x = width - text_width;
        cairo_move_to(cr, x, (height - text_height) / 2.0);
        pango_cairo_show_layout(cr, layout);
        g_object_unref(layout);
    }
}

static void ticks_free(gpointer raw) {
    Ticks *self = raw;
    ticks_clear(self);
    g_free(self);
}

GtkWidget *tailscode_ticks_new(void) {
    GtkWidget *area = gtk_drawing_area_new();
    Ticks *self = g_new0(Ticks, 1);
    ink_attach(area, self->ink);
    g_object_set_data_full(G_OBJECT(area), "tailscode-ticks", self, ticks_free);
    gtk_drawing_area_set_content_height(GTK_DRAWING_AREA(area), 16);
    gtk_drawing_area_set_content_width(GTK_DRAWING_AREA(area), 40);
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(area), ticks_draw, self, NULL);
    gtk_widget_set_hexpand(area, TRUE);
    gtk_widget_set_can_target(area, FALSE);
    return area;
}

void tailscode_ticks_set(GtkWidget *area, int count, const double *positions, const char *const *labels) {
    Ticks *self = g_object_get_data(G_OBJECT(area), "tailscode-ticks");
    if (!self) return;
    ticks_clear(self);
    if (count > 0) {
        self->positions = g_memdup2(positions, sizeof(double) * count);
        self->labels = g_new0(char *, count);
        for (int index = 0; index < count; index++) self->labels[index] = g_strdup(labels[index]);
    }
    self->count = count;
    gtk_widget_queue_draw(area);
}

typedef struct {
    double ink[INKS * 3];
    double position;
    TailscodeMeridianHandler handler;
    void *data;
    double origin;
} Scrubber;

#define THUMB_WIDTH 18.0
#define THUMB_HEIGHT 24.0

static void scrubber_draw(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer raw) {
    (void)area;
    Scrubber *self = raw;
    paint(cr, self->ink, INK_RAISED, 1);
    rounded(cr, 0, 0, width, height, height / 2.0);
    cairo_fill(cr);
    paint(cr, self->ink, INK_RULE, 1);
    cairo_set_line_width(cr, 1);
    rounded(cr, 0.5, 0.5, width - 1, height - 1, height / 2.0 - 0.5);
    cairo_stroke(cr);
    double x = THUMB_WIDTH / 2 + CLAMP(self->position, 0.0, 1.0) * (width - THUMB_WIDTH);
    double y = height / 2.0;
    glow(cr, x, y, 18, self->ink, INK_ACCENT, 0.6);
    paint(cr, self->ink, INK_RAISED, 1);
    rounded(cr, x - THUMB_WIDTH / 2 - 0.5, y - THUMB_HEIGHT / 2 - 0.5, THUMB_WIDTH + 1, THUMB_HEIGHT + 1, THUMB_WIDTH / 2 + 0.5);
    cairo_fill(cr);
    paint(cr, self->ink, INK_ACCENT, 1);
    rounded(cr, x - THUMB_WIDTH / 2 + 3, y - THUMB_HEIGHT / 2 + 3, THUMB_WIDTH - 6, THUMB_HEIGHT - 6, (THUMB_WIDTH - 6) / 2);
    cairo_fill(cr);
}

static double scrubber_fraction(GtkWidget *area, double x) {
    double width = gtk_widget_get_width(area);
    if (width <= THUMB_WIDTH) return 0;
    return CLAMP((x - THUMB_WIDTH / 2) / (width - THUMB_WIDTH), 0.0, 1.0);
}

static void scrubber_begin(GtkGestureDrag *gesture, double x, double y, gpointer raw) {
    (void)y;
    Scrubber *self = raw;
    GtkWidget *area = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(gesture));
    self->origin = x;
    gtk_widget_grab_focus(area);
    if (self->handler) self->handler(self->data, 0, scrubber_fraction(area, x));
}

static void scrubber_update(GtkGestureDrag *gesture, double dx, double dy, gpointer raw) {
    (void)dy;
    Scrubber *self = raw;
    GtkWidget *area = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(gesture));
    if (self->handler) self->handler(self->data, 1, scrubber_fraction(area, self->origin + dx));
}

static void scrubber_end(GtkGestureDrag *gesture, double dx, double dy, gpointer raw) {
    (void)dy;
    Scrubber *self = raw;
    GtkWidget *area = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(gesture));
    if (self->handler) self->handler(self->data, 2, scrubber_fraction(area, self->origin + dx));
}

GtkWidget *tailscode_scrubber_new(TailscodeMeridianHandler handler, void *data) {
    GtkWidget *area = gtk_drawing_area_new();
    Scrubber *self = g_new0(Scrubber, 1);
    ink_attach(area, self->ink);
    self->handler = handler;
    self->data = data;
    g_object_set_data_full(G_OBJECT(area), "tailscode-scrubber", self, g_free);
    gtk_drawing_area_set_content_height(GTK_DRAWING_AREA(area), 30);
    gtk_drawing_area_set_content_width(GTK_DRAWING_AREA(area), 120);
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(area), scrubber_draw, self, NULL);
    gtk_widget_set_hexpand(area, TRUE);
    gtk_widget_set_focusable(area, TRUE);
    gtk_widget_set_cursor_from_name(area, "ew-resize");
    GtkGesture *drag = gtk_gesture_drag_new();
    g_signal_connect(drag, "drag-begin", G_CALLBACK(scrubber_begin), self);
    g_signal_connect(drag, "drag-update", G_CALLBACK(scrubber_update), self);
    g_signal_connect(drag, "drag-end", G_CALLBACK(scrubber_end), self);
    gtk_widget_add_controller(area, GTK_EVENT_CONTROLLER(drag));
    return area;
}

void tailscode_scrubber_set(GtkWidget *area, double position) {
    Scrubber *self = g_object_get_data(G_OBJECT(area), "tailscode-scrubber");
    if (!self) return;
    self->position = position;
    gtk_widget_queue_draw(area);
}

double tailscode_scrubber_position(GtkWidget *area) {
    Scrubber *self = g_object_get_data(G_OBJECT(area), "tailscode-scrubber");
    return self ? self->position : 0;
}

void tailscode_scrubber_set_handler(GtkWidget *area, TailscodeMeridianHandler handler, void *data) {
    Scrubber *self = g_object_get_data(G_OBJECT(area), "tailscode-scrubber");
    if (!self) return;
    self->handler = handler;
    self->data = data;
}
