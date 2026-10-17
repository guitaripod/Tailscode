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
    double scale;
    double cx;
    double cy;
    double zoom;
    double ox;
    double oy;
} TailscodeLayer;

static void layer_draw(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer raw) {
    TailscodeLayer *layer = raw;
    if (!layer->surface || width <= 0 || height <= 0) return;
    if (layer->zoom != 1.0) {
        cairo_translate(cr, layer->cx * width, layer->cy * height);
        cairo_scale(cr, layer->zoom, layer->zoom);
        cairo_translate(cr, -layer->cx * width, -layer->cy * height);
    }
    cairo_set_operator(cr, layer->opaque ? CAIRO_OPERATOR_SOURCE : CAIRO_OPERATOR_OVER);
    cairo_set_source_surface(cr, layer->surface, -layer->ox, -layer->oy);
    gboolean exact = layer->zoom == 1.0 && layer->scale >= (double)gtk_widget_get_scale_factor(GTK_WIDGET(area));
    cairo_pattern_set_filter(cairo_get_source(cr), exact ? CAIRO_FILTER_NEAREST : CAIRO_FILTER_GOOD);
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
    layer->scale = 1.0;
    g_object_set_data_full(G_OBJECT(area), "tailscode-layer", layer, layer_free);
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(area), layer_draw, layer, NULL);
    return area;
}

static TailscodeLayer *layer_of(GtkWidget *widget) {
    return widget ? g_object_get_data(G_OBJECT(widget), "tailscode-layer") : NULL;
}

void tailscode_layer_resize(GtkWidget *widget, int width, int height, int scale) {
    tailscode_layer_resize_scaled(widget, width, height, scale < 1 ? 1.0 : (double)scale);
}

void tailscode_layer_resize_scaled(GtkWidget *widget, int width, int height, double scale) {
    TailscodeLayer *layer = layer_of(widget);
    if (!layer || width <= 0 || height <= 0) return;
    if (scale < 0.1) scale = 0.1;
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

void tailscode_layer_set_offset(GtkWidget *widget, double ox, double oy) {
    TailscodeLayer *layer = layer_of(widget);
    if (!layer) return;
    if (layer->ox == ox && layer->oy == oy) return;
    layer->ox = ox;
    layer->oy = oy;
    gtk_widget_queue_draw(widget);
}

cairo_surface_t *tailscode_layer_surface(GtkWidget *widget) {
    TailscodeLayer *layer = layer_of(widget);
    return layer ? layer->surface : NULL;
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

static GHashTable *layout_cache = NULL;

static PangoLayout *text_layout_build(
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

static long layout_hits = 0;
static long layout_misses = 0;

/// A layout for the text, made once per (text, font, width, alignment, lines) and kept: the nodes
/// are repainted thirty times a second with the same few words, and a fresh Pango layout per word
/// per frame is most of what painting them costs. The cache is dropped whole when it fills.
static PangoLayout *text_layout(
    cairo_t *cr, const char *font, double width, int align, int max_lines, gboolean markup,
    const char *text) {
    if (!layout_cache)
        layout_cache = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, g_object_unref);
    if (g_hash_table_size(layout_cache) > 384) g_hash_table_remove_all(layout_cache);
    char *key = g_strdup_printf(
        "%s|%d|%d|%d|%.1f|%s", font ? font : "", align, max_lines, markup ? 1 : 0, width,
        text ? text : "");
    PangoLayout *cached = g_hash_table_lookup(layout_cache, key);
    if (cached) {
        layout_hits++;
        g_free(key);
        pango_cairo_update_layout(cr, cached);
        return g_object_ref(cached);
    }
    layout_misses++;
    PangoLayout *layout = text_layout_build(cr, font, width, align, max_lines, markup, text);
    g_hash_table_insert(layout_cache, key, g_object_ref(layout));
    return layout;
}

void tailscode_text_cache_stats(long *hits, long *misses, int *entries) {
    if (hits) *hits = layout_hits;
    if (misses) *misses = layout_misses;
    if (entries) *entries = layout_cache ? (int)g_hash_table_size(layout_cache) : 0;
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
    PangoLayout *layout = text_layout_build(cr, font, width, align, max_lines, FALSE, text);
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


typedef struct {
    GtkWidget *child;
    int x;
    int y;
    int width;
    int height;
} BrainSlot;

struct TailscodeBrainRowSink {
    GArray *slots;
};

#define TAILSCODE_TYPE_BRAIN_ROW (tailscode_brain_row_get_type())
G_DECLARE_FINAL_TYPE(TailscodeBrainRow, tailscode_brain_row, TAILSCODE, BRAIN_ROW, GtkWidget)

struct _TailscodeBrainRow {
    GtkWidget parent_instance;
    TailscodeBrainRowSolve solve;
    TailscodeBrainRowHeight height;
    void *data;
    void (*destroy)(void *);
    gboolean disposed;
};

G_DEFINE_FINAL_TYPE(TailscodeBrainRow, tailscode_brain_row, GTK_TYPE_WIDGET)

static void brain_row_measure(
    GtkWidget *widget, GtkOrientation orientation, int for_size, int *minimum, int *natural,
    int *minimum_baseline, int *natural_baseline) {
    TailscodeBrainRow *self = TAILSCODE_BRAIN_ROW(widget);
    if (orientation == GTK_ORIENTATION_HORIZONTAL) {
        *minimum = 1;
        *natural = 1;
    } else {
        int width = for_size > 0 ? for_size : 600;
        int height = self->height ? self->height(width, self->data) : 1;
        if (height < 1) height = 1;
        *minimum = height;
        *natural = height;
    }
    *minimum_baseline = -1;
    *natural_baseline = -1;
}

static GtkSizeRequestMode brain_row_request_mode(GtkWidget *widget) {
    (void)widget;
    return GTK_SIZE_REQUEST_HEIGHT_FOR_WIDTH;
}

static void brain_row_allocate(GtkWidget *widget, int width, int height, int baseline) {
    (void)baseline;
    TailscodeBrainRow *self = TAILSCODE_BRAIN_ROW(widget);
    TailscodeBrainRowSink sink;
    sink.slots = g_array_new(FALSE, FALSE, sizeof(BrainSlot));
    if (self->solve && !self->disposed) self->solve(width, height, &sink, self->data);
    for (GtkWidget *child = gtk_widget_get_first_child(widget); child != NULL;
         child = gtk_widget_get_next_sibling(child)) {
        const BrainSlot *placed = NULL;
        for (guint index = 0; index < sink.slots->len; index++) {
            const BrainSlot *slot = &g_array_index(sink.slots, BrainSlot, index);
            if (slot->child == child) {
                placed = slot;
                break;
            }
        }
        if (!placed || placed->width < 1 || placed->height < 1) {
            gtk_widget_set_child_visible(child, FALSE);
            continue;
        }
        gtk_widget_set_child_visible(child, TRUE);
        int minimum_width = 0;
        int minimum_height = 0;
        gtk_widget_measure(child, GTK_ORIENTATION_HORIZONTAL, -1, &minimum_width, NULL, NULL, NULL);
        int w = placed->width < minimum_width ? minimum_width : placed->width;
        gtk_widget_measure(child, GTK_ORIENTATION_VERTICAL, w, &minimum_height, NULL, NULL, NULL);
        int h = placed->height < minimum_height ? minimum_height : placed->height;
        graphene_point_t origin = GRAPHENE_POINT_INIT((float)placed->x, (float)placed->y);
        GskTransform *transform = gsk_transform_translate(NULL, &origin);
        gtk_widget_allocate(child, w, h, -1, transform);
    }
    g_array_free(sink.slots, TRUE);
}

static void brain_row_dispose(GObject *object) {
    TailscodeBrainRow *self = TAILSCODE_BRAIN_ROW(object);
    if (!self->disposed) {
        self->disposed = TRUE;
        GtkWidget *child;
        while ((child = gtk_widget_get_first_child(GTK_WIDGET(self))) != NULL)
            gtk_widget_unparent(child);
        self->solve = NULL;
        self->height = NULL;
        if (self->destroy && self->data) self->destroy(self->data);
        self->data = NULL;
    }
    G_OBJECT_CLASS(tailscode_brain_row_parent_class)->dispose(object);
}

static void tailscode_brain_row_class_init(TailscodeBrainRowClass *class) {
    GtkWidgetClass *widget_class = GTK_WIDGET_CLASS(class);
    widget_class->measure = brain_row_measure;
    widget_class->get_request_mode = brain_row_request_mode;
    widget_class->size_allocate = brain_row_allocate;
    G_OBJECT_CLASS(class)->dispose = brain_row_dispose;
    gtk_widget_class_set_css_name(widget_class, "brain-frame");
}

static void tailscode_brain_row_init(TailscodeBrainRow *self) {
    gtk_widget_set_hexpand(GTK_WIDGET(self), TRUE);
    gtk_widget_set_overflow(GTK_WIDGET(self), GTK_OVERFLOW_HIDDEN);
}

GtkWidget *tailscode_brain_row_new(
    TailscodeBrainRowSolve solve, TailscodeBrainRowHeight height, void *data,
    void (*destroy)(void *)) {
    TailscodeBrainRow *self = g_object_new(TAILSCODE_TYPE_BRAIN_ROW, NULL);
    self->solve = solve;
    self->height = height;
    self->data = data;
    self->destroy = destroy;
    return GTK_WIDGET(self);
}

void tailscode_brain_row_add(GtkWidget *row, GtkWidget *child) {
    if (gtk_widget_get_parent(child) != NULL) return;
    gtk_widget_set_parent(child, row);
    gtk_widget_queue_allocate(row);
}

void tailscode_brain_row_remove(GtkWidget *row, GtkWidget *child) {
    if (gtk_widget_get_parent(child) != row) return;
    gtk_widget_unparent(child);
    gtk_widget_queue_allocate(row);
}

void tailscode_brain_row_invalidate(GtkWidget *row) { gtk_widget_queue_allocate(row); }

void tailscode_brain_row_remeasure(GtkWidget *row) { gtk_widget_queue_resize(row); }

void tailscode_brain_row_place(
    TailscodeBrainRowSink *sink, GtkWidget *child, int x, int y, int width, int height) {
    BrainSlot slot = {child, x, y, width, height};
    g_array_append_val(sink->slots, slot);
}

void tailscode_brain_row_raise(GtkWidget *row, GtkWidget *child) {
    if (gtk_widget_get_parent(child) != row) return;
    gtk_widget_insert_before(child, row, NULL);
}

typedef struct {
    void (*enter)(void *);
    void (*leave)(void *);
    void *data;
} TailscodeFocusWatch;

static void focus_watch_free(gpointer raw, GClosure *closure) {
    (void)closure;
    TailscodeFocusWatch *watch = raw;
    if (watch->data) tailscode_box_release_call(watch->data);
    g_free(watch);
}

static void focus_watch_entered(GtkEventControllerFocus *c, gpointer raw) {
    (void)c;
    TailscodeFocusWatch *watch = raw;
    watch->enter(watch->data);
}

static void focus_watch_left(GtkEventControllerFocus *c, gpointer raw) {
    (void)c;
    TailscodeFocusWatch *watch = raw;
    watch->leave(watch->data);
}

void tailscode_on_focus_change(
    GtkWidget *widget, void (*enter)(void *), void (*leave)(void *), void *data) {
    TailscodeFocusWatch *watch = g_new0(TailscodeFocusWatch, 1);
    watch->enter = enter;
    watch->leave = leave;
    watch->data = data;
    GtkEventController *focus = gtk_event_controller_focus_new();
    g_signal_connect_data(focus, "enter", G_CALLBACK(focus_watch_entered), watch, NULL, 0);
    g_signal_connect_data(
        focus, "leave", G_CALLBACK(focus_watch_left), watch, (GClosureNotify)focus_watch_free, 0);
    gtk_widget_add_controller(widget, focus);
}

char *tailscode_widget_font(GtkWidget *widget) {
    PangoContext *context = gtk_widget_get_pango_context(widget);
    const PangoFontDescription *description = pango_context_get_font_description(context);
    return description ? pango_font_description_to_string(description) : g_strdup("Sans 10");
}

double tailscode_label_line_height(GtkWidget *label) {
    PangoLayout *layout = gtk_label_get_layout(GTK_LABEL(label));
    if (!layout) return 0;
    int width = 0;
    int height = 0;
    pango_layout_get_pixel_size(layout, &width, &height);
    return height;
}
