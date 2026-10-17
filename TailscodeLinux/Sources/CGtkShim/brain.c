#include "brain.h"
#include "CGtkShim.h"
#include <malloc.h>
#include <math.h>
#include <string.h>
#include <pango/pangocairo.h>

typedef struct {
    TailscodeCanvasDraw draw;
    void *data;
    void (*destroy)(void *);
} TailscodeCanvas;

static void canvas_draw(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer raw) {
    (void)area;
    TailscodeCanvas *canvas = raw;
    if (width <= 0 || height <= 0 || !canvas->draw) return;
    canvas->draw(cr, width, height, canvas->data);
}

static void canvas_free(gpointer raw) {
    TailscodeCanvas *canvas = raw;
    if (canvas->destroy) canvas->destroy(canvas->data);
    g_free(canvas);
}

GtkWidget *tailscode_canvas_new(TailscodeCanvasDraw draw, void *data, void (*destroy)(void *)) {
    GtkWidget *area = gtk_drawing_area_new();
    TailscodeCanvas *canvas = g_new0(TailscodeCanvas, 1);
    canvas->draw = draw;
    canvas->data = data;
    canvas->destroy = destroy;
    g_object_set_data_full(G_OBJECT(area), "tailscode-canvas", canvas, canvas_free);
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(area), canvas_draw, canvas, NULL);
    return area;
}

typedef struct {
    cairo_surface_t *surface;
    gboolean opaque;
    int width;
    int height;
    int scale;
    double cx;
    double cy;
    double zoom;
} TailscodeLayer;

static void layer_draw(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer raw) {
    (void)area;
    TailscodeLayer *layer = raw;
    if (!layer->surface || width <= 0 || height <= 0) return;
    if (layer->zoom != 1.0) {
        cairo_translate(cr, layer->cx * width, layer->cy * height);
        cairo_scale(cr, layer->zoom, layer->zoom);
        cairo_translate(cr, -layer->cx * width, -layer->cy * height);
    }
    cairo_set_operator(cr, layer->opaque ? CAIRO_OPERATOR_SOURCE : CAIRO_OPERATOR_OVER);
    cairo_set_source_surface(cr, layer->surface, 0, 0);
    cairo_pattern_set_filter(
        cairo_get_source(cr), layer->zoom == 1.0 ? CAIRO_FILTER_NEAREST : CAIRO_FILTER_BILINEAR);
    cairo_pattern_set_extend(cairo_get_source(cr), CAIRO_EXTEND_PAD);
    cairo_paint(cr);
}

static void layer_free(gpointer raw) {
    TailscodeLayer *layer = raw;
    if (layer->surface) cairo_surface_destroy(layer->surface);
    g_free(layer);
}

GtkWidget *tailscode_layer_new(gboolean opaque) {
    GtkWidget *area = gtk_drawing_area_new();
    TailscodeLayer *layer = g_new0(TailscodeLayer, 1);
    layer->opaque = opaque;
    layer->zoom = 1.0;
    layer->cx = 0.5;
    layer->cy = 0.5;
    layer->scale = 1;
    g_object_set_data_full(G_OBJECT(area), "tailscode-layer", layer, layer_free);
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(area), layer_draw, layer, NULL);
    return area;
}

static TailscodeLayer *layer_of(GtkWidget *widget) {
    return widget ? g_object_get_data(G_OBJECT(widget), "tailscode-layer") : NULL;
}

void tailscode_layer_resize(GtkWidget *widget, int width, int height, int scale) {
    TailscodeLayer *layer = layer_of(widget);
    if (!layer || width <= 0 || height <= 0) return;
    if (scale < 1) scale = 1;
    if (layer->surface && layer->width == width && layer->height == height &&
        layer->scale == scale)
        return;
    if (layer->surface) cairo_surface_destroy(layer->surface);
    layer->surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, width, height);
    cairo_surface_set_device_scale(layer->surface, scale, scale);
    layer->width = width;
    layer->height = height;
    layer->scale = scale;
    gtk_widget_queue_draw(widget);
}

void tailscode_layer_release(GtkWidget *widget) {
    TailscodeLayer *layer = layer_of(widget);
    if (!layer || !layer->surface) return;
    cairo_surface_destroy(layer->surface);
    layer->surface = NULL;
    layer->width = 0;
    layer->height = 0;
    gtk_widget_queue_draw(widget);
}

void tailscode_layer_blit(
    GtkWidget *widget, const guint8 *bytes, int width, int height, int x, int y, int w, int h) {
    TailscodeLayer *layer = layer_of(widget);
    if (!layer || !layer->surface || !bytes) return;
    if (width != layer->width || height != layer->height) return;
    int x0 = MAX(0, x);
    int y0 = MAX(0, y);
    int x1 = MIN(width, x + w);
    int y1 = MIN(height, y + h);
    if (x1 <= x0 || y1 <= y0) return;
    cairo_surface_flush(layer->surface);
    guint8 *dest = cairo_image_surface_get_data(layer->surface);
    int stride = cairo_image_surface_get_stride(layer->surface);
    gsize row = (gsize)(x1 - x0) * 4;
    for (int line = y0; line < y1; line++) {
        memcpy(dest + (gsize)line * stride + (gsize)x0 * 4, bytes + ((gsize)line * width + x0) * 4, row);
    }
    cairo_surface_mark_dirty_rectangle(layer->surface, x0, y0, x1 - x0, y1 - y0);
    gtk_widget_queue_draw(widget);
}

void tailscode_layer_zoom(GtkWidget *widget, double cx, double cy, double scale) {
    TailscodeLayer *layer = layer_of(widget);
    if (!layer) return;
    if (scale < 0.05) scale = 0.05;
    if (layer->cx == cx && layer->cy == cy && layer->zoom == scale) return;
    layer->cx = cx;
    layer->cy = cy;
    layer->zoom = scale;
    gtk_widget_queue_draw(widget);
}

gsize tailscode_layer_footprint(GtkWidget *widget) {
    TailscodeLayer *layer = layer_of(widget);
    if (!layer || !layer->surface) return 0;
    return (gsize)cairo_image_surface_get_stride(layer->surface) * layer->height;
}

typedef struct {
    void (*handler)(double x, double y, int presses, int button, void *data);
    void *data;
} TailscodeClickAt;

static void click_free(gpointer raw, GClosure *closure) {
    (void)closure;
    TailscodeClickAt *box = raw;
    if (box->data) tailscode_box_release_call(box->data);
    g_free(box);
}

static void click_pressed(
    GtkGestureClick *gesture, gint presses, gdouble x, gdouble y, gpointer raw) {
    TailscodeClickAt *box = raw;
    int button = gtk_gesture_single_get_current_button(GTK_GESTURE_SINGLE(gesture));
    box->handler(x, y, presses, button, box->data);
}

void tailscode_on_click_at(
    GtkWidget *widget, void (*handler)(double x, double y, int presses, int button, void *data),
    void *data) {
    TailscodeClickAt *box = g_new0(TailscodeClickAt, 1);
    box->handler = handler;
    box->data = data;
    GtkGesture *click = gtk_gesture_click_new();
    gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(click), 0);
    gtk_event_controller_set_propagation_phase(GTK_EVENT_CONTROLLER(click), GTK_PHASE_CAPTURE);
    g_signal_connect_data(
        click, "pressed", G_CALLBACK(click_pressed), box, (GClosureNotify)click_free, 0);
    gtk_widget_add_controller(widget, GTK_EVENT_CONTROLLER(click));
}

static PangoLayout *text_layout(
    cairo_t *cr, const char *font, double width, int align, int max_lines, gboolean markup,
    const char *text) {
    PangoLayout *layout = pango_cairo_create_layout(cr);
    PangoFontDescription *description = pango_font_description_from_string(font ? font : "Sans 10");
    pango_layout_set_font_description(layout, description);
    pango_font_description_free(description);
    if (width >= 1) {
        pango_layout_set_width(layout, (int)(width * PANGO_SCALE));
        pango_layout_set_wrap(layout, PANGO_WRAP_WORD_CHAR);
    }
    if (max_lines > 0) {
        pango_layout_set_ellipsize(layout, PANGO_ELLIPSIZE_END);
        if (width >= 1) pango_layout_set_height(layout, -max_lines);
        else pango_layout_set_width(layout, -1);
    }
    pango_layout_set_alignment(
        layout, align == 1 ? PANGO_ALIGN_CENTER : (align == 2 ? PANGO_ALIGN_RIGHT : PANGO_ALIGN_LEFT));
    if (markup) pango_layout_set_markup(layout, text ? text : "", -1);
    else pango_layout_set_text(layout, text ? text : "", -1);
    return layout;
}

void tailscode_text_measure(
    const char *text, const char *font, double width, int max_lines, double *out_width,
    double *out_height) {
    cairo_surface_t *scratch = cairo_image_surface_create(CAIRO_FORMAT_A8, 1, 1);
    cairo_t *cr = cairo_create(scratch);
    PangoLayout *layout = text_layout(cr, font, width, 0, max_lines, FALSE, text);
    int w = 0;
    int h = 0;
    pango_layout_get_pixel_size(layout, &w, &h);
    if (out_width) *out_width = w;
    if (out_height) *out_height = h;
    g_object_unref(layout);
    cairo_destroy(cr);
    cairo_surface_destroy(scratch);
}

static double draw_layout(
    cairo_t *cr, PangoLayout *layout, double x, double y, double red, double green, double blue,
    double alpha) {
    int w = 0;
    int h = 0;
    pango_layout_get_pixel_size(layout, &w, &h);
    cairo_save(cr);
    cairo_set_source_rgba(cr, red, green, blue, alpha);
    cairo_move_to(cr, x, y);
    pango_cairo_show_layout(cr, layout);
    cairo_restore(cr);
    g_object_unref(layout);
    return h;
}

double tailscode_text_draw(
    cairo_t *cr, const char *text, const char *font, double x, double y, double width, int align,
    int max_lines, double red, double green, double blue, double alpha) {
    PangoLayout *layout = text_layout(cr, font, width, align, max_lines, FALSE, text);
    return draw_layout(cr, layout, x, y, red, green, blue, alpha);
}

double tailscode_markup_draw(
    cairo_t *cr, const char *markup, const char *font, double x, double y, double width, int align,
    int max_lines, double red, double green, double blue, double alpha) {
    PangoLayout *layout = text_layout(cr, font, width, align, max_lines, TRUE, markup);
    return draw_layout(cr, layout, x, y, red, green, blue, alpha);
}

double tailscode_poster_text(
    cairo_t *cr, const char *text, const char *font, double x, double y, double width, int align,
    int max_lines, double line_factor, double tracking, double red, double green, double blue,
    double alpha) {
    PangoLayout *layout = text_layout(cr, font, width, align, max_lines, FALSE, text);
    if (line_factor > 0) pango_layout_set_line_spacing(layout, (float)line_factor);
    if (tracking != 0) {
        PangoAttrList *attributes = pango_attr_list_new();
        pango_attr_list_insert(
            attributes, pango_attr_letter_spacing_new((int)(tracking * PANGO_SCALE)));
        pango_layout_set_attributes(layout, attributes);
        pango_attr_list_unref(attributes);
    }
    return draw_layout(cr, layout, x, y, red, green, blue, alpha);
}

static cairo_status_t poster_png_write(void *closure, const unsigned char *data, unsigned int length) {
    g_byte_array_append((GByteArray *)closure, data, length);
    return CAIRO_STATUS_SUCCESS;
}

unsigned char *tailscode_surface_png(cairo_surface_t *surface, gsize *out_len) {
    if (out_len) *out_len = 0;
    if (!surface) return NULL;
    GByteArray *array = g_byte_array_new();
    cairo_status_t status = cairo_surface_write_to_png_stream(surface, poster_png_write, array);
    if (status != CAIRO_STATUS_SUCCESS || array->len == 0) {
        g_byte_array_free(array, TRUE);
        return NULL;
    }
    if (out_len) *out_len = array->len;
    return g_byte_array_free(array, FALSE);
}

typedef struct {
    void (*enter)(void *);
    void (*leave)(void *);
    void *data;
    int hovering;
    int focused;
} TailscodeHoverFocus;

static void hover_free(gpointer raw, GClosure *closure) {
    (void)closure;
    TailscodeHoverFocus *watch = raw;
    if (watch->data) tailscode_box_release_call(watch->data);
    g_free(watch);
}

static void hover_focus_update(TailscodeHoverFocus *watch, int hovering, int focused) {
    int before = watch->hovering || watch->focused;
    watch->hovering = hovering;
    watch->focused = focused;
    int after = watch->hovering || watch->focused;
    if (after && !before) watch->enter(watch->data);
    if (!after && before) watch->leave(watch->data);
}

static void hover_entered(GtkEventControllerMotion *c, gdouble x, gdouble y, gpointer raw) {
    (void)c; (void)x; (void)y;
    TailscodeHoverFocus *watch = raw;
    hover_focus_update(watch, 1, watch->focused);
}

static void hover_left(GtkEventControllerMotion *c, gpointer raw) {
    (void)c;
    TailscodeHoverFocus *watch = raw;
    hover_focus_update(watch, 0, watch->focused);
}

static void focus_entered(GtkEventControllerFocus *c, gpointer raw) {
    (void)c;
    TailscodeHoverFocus *watch = raw;
    hover_focus_update(watch, watch->hovering, 1);
}

static void focus_left(GtkEventControllerFocus *c, gpointer raw) {
    (void)c;
    TailscodeHoverFocus *watch = raw;
    hover_focus_update(watch, watch->hovering, 0);
}

void tailscode_on_hover_focus(
    GtkWidget *widget, void (*enter)(void *), void (*leave)(void *), void *data) {
    TailscodeHoverFocus *watch = g_new0(TailscodeHoverFocus, 1);
    watch->enter = enter;
    watch->leave = leave;
    watch->data = data;
    GtkEventController *motion = gtk_event_controller_motion_new();
    g_signal_connect_data(motion, "enter", G_CALLBACK(hover_entered), watch, NULL, 0);
    g_signal_connect_data(motion, "leave", G_CALLBACK(hover_left), watch, NULL, 0);
    gtk_widget_add_controller(widget, motion);
    GtkEventController *focus = gtk_event_controller_focus_new();
    g_signal_connect_data(focus, "enter", G_CALLBACK(focus_entered), watch, NULL, 0);
    g_signal_connect_data(focus, "leave", G_CALLBACK(focus_left), watch, (GClosureNotify)hover_free, 0);
    gtk_widget_add_controller(widget, focus);
}

#define TAILSCODE_TYPE_ASPECT (tailscode_aspect_get_type())
G_DECLARE_FINAL_TYPE(TailscodeAspect, tailscode_aspect, TAILSCODE, ASPECT, GtkWidget)

struct _TailscodeAspect {
    GtkWidget parent_instance;
    GtkWidget *child;
    double ratio;
    int max_width;
};

G_DEFINE_TYPE(TailscodeAspect, tailscode_aspect, GTK_TYPE_WIDGET)

static void aspect_size(TailscodeAspect *self, int available, int *width, int *height) {
    int w = available < 0 ? self->max_width : MIN(available, self->max_width);
    w = MAX(w, 1);
    *width = w;
    *height = MAX(1, (int)(w / self->ratio + 0.5));
}

static void aspect_measure(
    GtkWidget *widget, GtkOrientation orientation, int for_size, int *minimum, int *natural,
    int *minimum_baseline, int *natural_baseline) {
    TailscodeAspect *self = TAILSCODE_ASPECT(widget);
    int w, h;
    if (orientation == GTK_ORIENTATION_HORIZONTAL) {
        aspect_size(self, -1, &w, &h);
        *minimum = 1;
        *natural = w;
    } else {
        aspect_size(self, for_size, &w, &h);
        *minimum = h;
        *natural = h;
    }
    *minimum_baseline = -1;
    *natural_baseline = -1;
}

static void aspect_allocate(GtkWidget *widget, int width, int height, int baseline) {
    (void)baseline;
    TailscodeAspect *self = TAILSCODE_ASPECT(widget);
    if (!self->child || !gtk_widget_should_layout(self->child)) return;
    int w, h;
    aspect_size(self, width, &w, &h);
    GtkAllocation allocation = {(width - w) / 2, 0, w, MIN(h, MAX(height, 1))};
    gtk_widget_size_allocate(self->child, &allocation, -1);
}

static void aspect_dispose(GObject *object) {
    TailscodeAspect *self = TAILSCODE_ASPECT(object);
    if (self->child) {
        gtk_widget_unparent(self->child);
        self->child = NULL;
    }
    G_OBJECT_CLASS(tailscode_aspect_parent_class)->dispose(object);
}

static void tailscode_aspect_class_init(TailscodeAspectClass *klass) {
    GtkWidgetClass *widget_class = GTK_WIDGET_CLASS(klass);
    widget_class->measure = aspect_measure;
    widget_class->size_allocate = aspect_allocate;
    G_OBJECT_CLASS(klass)->dispose = aspect_dispose;
}

static void tailscode_aspect_init(TailscodeAspect *self) {
    self->ratio = 1.5;
    self->max_width = 760;
    gtk_widget_set_hexpand(GTK_WIDGET(self), TRUE);
}

GtkWidget *tailscode_aspect_new(double ratio, int max_width) {
    TailscodeAspect *self = g_object_new(TAILSCODE_TYPE_ASPECT, NULL);
    self->ratio = ratio > 0.01 ? ratio : 1.5;
    self->max_width = MAX(1, max_width);
    return GTK_WIDGET(self);
}

void tailscode_aspect_set_child(GtkWidget *aspect, GtkWidget *child) {
    TailscodeAspect *self = TAILSCODE_ASPECT(aspect);
    if (self->child) gtk_widget_unparent(self->child);
    self->child = child;
    if (child) gtk_widget_set_parent(child, aspect);
}

void tailscode_malloc_trim(void) { malloc_trim(0); }
