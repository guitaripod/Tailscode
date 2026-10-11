#include "include/CGtkShim.h"
#include <math.h>

typedef struct {
    GtkWidget *child;
    int x;
    int y;
    int width;
    int height;
} TileSlot;

struct TailscodeTileSink {
    GArray *slots;
};

static gint tile_reparents = 0;

static const char *tile_layer_key = "tailscode-tile-layer";

static int tile_layer_of(GtkWidget *child) {
    return GPOINTER_TO_INT(g_object_get_data(G_OBJECT(child), tile_layer_key));
}

static void tile_unparent_all(GtkWidget *widget) {
    GtkWidget *child;
    while ((child = gtk_widget_get_first_child(widget)) != NULL) gtk_widget_unparent(child);
}

static void tile_measure_child(GtkWidget *child, int width, int *min_width, int *min_height) {
    int minimum_width = 0;
    int minimum_height = 0;
    gtk_widget_measure(child, GTK_ORIENTATION_HORIZONTAL, -1, &minimum_width, NULL, NULL, NULL);
    gtk_widget_measure(
        child, GTK_ORIENTATION_VERTICAL, width > minimum_width ? width : minimum_width,
        &minimum_height, NULL, NULL, NULL);
    *min_width = minimum_width;
    *min_height = minimum_height;
}

static void tile_allocate_child(GtkWidget *child, int x, int y, int width, int height) {
    int minimum_width;
    int minimum_height;
    tile_measure_child(child, width, &minimum_width, &minimum_height);
    if (width < minimum_width) width = minimum_width;
    if (height < minimum_height) height = minimum_height;
    graphene_point_t origin = GRAPHENE_POINT_INIT((float)x, (float)y);
    GskTransform *transform = gsk_transform_translate(NULL, &origin);
    gtk_widget_allocate(child, width, height, -1, transform);
}

#define TAILSCODE_TYPE_TILE_LAYOUT (tailscode_tile_layout_get_type())
G_DECLARE_FINAL_TYPE(TailscodeTileLayout, tailscode_tile_layout, TAILSCODE, TILE_LAYOUT, GtkLayoutManager)

struct _TailscodeTileLayout {
    GtkLayoutManager parent_instance;
};

#define TAILSCODE_TYPE_TILE_CANVAS (tailscode_tile_canvas_get_type())
G_DECLARE_FINAL_TYPE(TailscodeTileCanvas, tailscode_tile_canvas, TAILSCODE, TILE_CANVAS, GtkWidget)

struct _TailscodeTileCanvas {
    GtkWidget parent_instance;
    TailscodeTileSolve solve;
    void *box;
    int minimum_width;
    int minimum_height;
    long allocations;
    long allocate_us;
    gboolean disposed;
};

G_DEFINE_FINAL_TYPE(TailscodeTileLayout, tailscode_tile_layout, GTK_TYPE_LAYOUT_MANAGER)
G_DEFINE_FINAL_TYPE(TailscodeTileCanvas, tailscode_tile_canvas, GTK_TYPE_WIDGET)

static void tailscode_tile_layout_measure(
    GtkLayoutManager *manager, GtkWidget *widget, GtkOrientation orientation, int for_size,
    int *minimum, int *natural, int *minimum_baseline, int *natural_baseline) {
    (void)manager;
    (void)for_size;
    TailscodeTileCanvas *self = TAILSCODE_TILE_CANVAS(widget);
    int size = orientation == GTK_ORIENTATION_HORIZONTAL ? self->minimum_width : self->minimum_height;
    *minimum = size;
    *natural = size;
    *minimum_baseline = -1;
    *natural_baseline = -1;
}

static void tailscode_tile_layout_allocate(
    GtkLayoutManager *manager, GtkWidget *widget, int width, int height, int baseline) {
    (void)manager;
    (void)baseline;
    TailscodeTileCanvas *self = TAILSCODE_TILE_CANVAS(widget);
    gint64 started = g_get_monotonic_time();
    TailscodeTileSink sink;
    sink.slots = g_array_new(FALSE, FALSE, sizeof(TileSlot));
    if (self->solve) self->solve(width, height, &sink, self->box);
    for (GtkWidget *child = gtk_widget_get_first_child(widget); child != NULL;
         child = gtk_widget_get_next_sibling(child)) {
        const TileSlot *placed = NULL;
        for (guint index = 0; index < sink.slots->len; index++) {
            const TileSlot *slot = &g_array_index(sink.slots, TileSlot, index);
            if (slot->child == child) {
                placed = slot;
                break;
            }
        }
        if (!placed) {
            gtk_widget_set_child_visible(child, FALSE);
            continue;
        }
        gtk_widget_set_child_visible(child, TRUE);
        tile_allocate_child(child, placed->x, placed->y, placed->width, placed->height);
    }
    g_array_free(sink.slots, TRUE);
    self->allocations += 1;
    self->allocate_us = (long)(g_get_monotonic_time() - started);
}

static void tailscode_tile_layout_class_init(TailscodeTileLayoutClass *class) {
    GtkLayoutManagerClass *manager = GTK_LAYOUT_MANAGER_CLASS(class);
    manager->measure = tailscode_tile_layout_measure;
    manager->allocate = tailscode_tile_layout_allocate;
}

static void tailscode_tile_layout_init(TailscodeTileLayout *self) { (void)self; }

static void tailscode_tile_canvas_dispose(GObject *object) {
    TailscodeTileCanvas *self = TAILSCODE_TILE_CANVAS(object);
    if (!self->disposed) {
        self->disposed = TRUE;
        tile_unparent_all(GTK_WIDGET(self));
        self->solve = NULL;
        if (self->box) {
            tailscode_box_release_call(self->box);
            self->box = NULL;
        }
    }
    G_OBJECT_CLASS(tailscode_tile_canvas_parent_class)->dispose(object);
}

static void tailscode_tile_canvas_class_init(TailscodeTileCanvasClass *class) {
    G_OBJECT_CLASS(class)->dispose = tailscode_tile_canvas_dispose;
    gtk_widget_class_set_layout_manager_type(GTK_WIDGET_CLASS(class), TAILSCODE_TYPE_TILE_LAYOUT);
    gtk_widget_class_set_css_name(GTK_WIDGET_CLASS(class), "tile-canvas");
}

static void tailscode_tile_canvas_init(TailscodeTileCanvas *self) {
    self->minimum_width = 220;
    self->minimum_height = 120;
    gtk_widget_set_hexpand(GTK_WIDGET(self), TRUE);
    gtk_widget_set_vexpand(GTK_WIDGET(self), TRUE);
}

GtkWidget *tailscode_tile_canvas_new(void) {
    return g_object_new(TAILSCODE_TYPE_TILE_CANVAS, NULL);
}

void tailscode_tile_canvas_set_solver(GtkWidget *canvas, TailscodeTileSolve solve, void *box) {
    TailscodeTileCanvas *self = TAILSCODE_TILE_CANVAS(canvas);
    if (self->box && self->box != box) tailscode_box_release_call(self->box);
    self->solve = solve;
    self->box = box;
    gtk_widget_queue_allocate(canvas);
}

void tailscode_tile_canvas_set_minimum(GtkWidget *canvas, int width, int height) {
    TailscodeTileCanvas *self = TAILSCODE_TILE_CANVAS(canvas);
    self->minimum_width = width;
    self->minimum_height = height;
    gtk_widget_queue_resize(canvas);
}

void tailscode_tile_canvas_add(GtkWidget *canvas, GtkWidget *child, int layer) {
    if (gtk_widget_get_parent(child) != NULL) {
        g_atomic_int_inc(&tile_reparents);
        return;
    }
    g_object_set_data(G_OBJECT(child), tile_layer_key, GINT_TO_POINTER(layer));
    GtkWidget *before = NULL;
    for (GtkWidget *other = gtk_widget_get_first_child(canvas); other != NULL;
         other = gtk_widget_get_next_sibling(other)) {
        if (tile_layer_of(other) > layer) {
            before = other;
            break;
        }
    }
    gtk_widget_insert_before(child, canvas, before);
    gtk_widget_queue_allocate(canvas);
}

void tailscode_tile_canvas_remove(GtkWidget *canvas, GtkWidget *child) {
    if (gtk_widget_get_parent(child) != canvas) return;
    gtk_widget_unparent(child);
    gtk_widget_queue_allocate(canvas);
}

void tailscode_tile_canvas_invalidate(GtkWidget *canvas) {
    gtk_widget_queue_allocate(canvas);
}

void tailscode_tile_sink_place(
    TailscodeTileSink *sink, GtkWidget *child, int x, int y, int width, int height) {
    TileSlot slot = {child, x, y, width < 0 ? 0 : width, height < 0 ? 0 : height};
    g_array_append_val(sink->slots, slot);
}

long tailscode_tile_canvas_reparents(void) { return g_atomic_int_get(&tile_reparents); }

long tailscode_tile_canvas_allocations(GtkWidget *canvas) {
    return TAILSCODE_TILE_CANVAS(canvas)->allocations;
}

long tailscode_tile_canvas_allocate_us(GtkWidget *canvas) {
    return TAILSCODE_TILE_CANVAS(canvas)->allocate_us;
}

int tailscode_tile_canvas_child_count(GtkWidget *canvas) {
    int count = 0;
    for (GtkWidget *child = gtk_widget_get_first_child(canvas); child != NULL;
         child = gtk_widget_get_next_sibling(child))
        count += 1;
    return count;
}

#define TAILSCODE_TYPE_TILE_CLAMP_LAYOUT (tailscode_tile_clamp_layout_get_type())
G_DECLARE_FINAL_TYPE(
    TailscodeTileClampLayout, tailscode_tile_clamp_layout, TAILSCODE, TILE_CLAMP_LAYOUT,
    GtkLayoutManager)

struct _TailscodeTileClampLayout {
    GtkLayoutManager parent_instance;
};

#define TAILSCODE_TYPE_TILE_CLAMP (tailscode_tile_clamp_get_type())
G_DECLARE_FINAL_TYPE(TailscodeTileClamp, tailscode_tile_clamp, TAILSCODE, TILE_CLAMP, GtkWidget)

struct _TailscodeTileClamp {
    GtkWidget parent_instance;
    gboolean disposed;
};

G_DEFINE_FINAL_TYPE(TailscodeTileClampLayout, tailscode_tile_clamp_layout, GTK_TYPE_LAYOUT_MANAGER)
G_DEFINE_FINAL_TYPE(TailscodeTileClamp, tailscode_tile_clamp, GTK_TYPE_WIDGET)

static void tailscode_tile_clamp_layout_measure(
    GtkLayoutManager *manager, GtkWidget *widget, GtkOrientation orientation, int for_size,
    int *minimum, int *natural, int *minimum_baseline, int *natural_baseline) {
    (void)manager;
    (void)widget;
    (void)orientation;
    (void)for_size;
    *minimum = 0;
    *natural = 0;
    *minimum_baseline = -1;
    *natural_baseline = -1;
}

static void tailscode_tile_clamp_layout_allocate(
    GtkLayoutManager *manager, GtkWidget *widget, int width, int height, int baseline) {
    (void)manager;
    (void)baseline;
    for (GtkWidget *child = gtk_widget_get_first_child(widget); child != NULL;
         child = gtk_widget_get_next_sibling(child)) {
        if (!gtk_widget_should_layout(child)) continue;
        tile_allocate_child(child, 0, 0, width, height);
    }
}

static void tailscode_tile_clamp_layout_class_init(TailscodeTileClampLayoutClass *class) {
    GtkLayoutManagerClass *manager = GTK_LAYOUT_MANAGER_CLASS(class);
    manager->measure = tailscode_tile_clamp_layout_measure;
    manager->allocate = tailscode_tile_clamp_layout_allocate;
}

static void tailscode_tile_clamp_layout_init(TailscodeTileClampLayout *self) { (void)self; }

static void tailscode_tile_clamp_dispose(GObject *object) {
    TailscodeTileClamp *self = TAILSCODE_TILE_CLAMP(object);
    if (!self->disposed) {
        self->disposed = TRUE;
        tile_unparent_all(GTK_WIDGET(self));
    }
    G_OBJECT_CLASS(tailscode_tile_clamp_parent_class)->dispose(object);
}

static void tailscode_tile_clamp_class_init(TailscodeTileClampClass *class) {
    G_OBJECT_CLASS(class)->dispose = tailscode_tile_clamp_dispose;
    gtk_widget_class_set_layout_manager_type(
        GTK_WIDGET_CLASS(class), TAILSCODE_TYPE_TILE_CLAMP_LAYOUT);
    gtk_widget_class_set_css_name(GTK_WIDGET_CLASS(class), "tile-clamp");
}

static void tailscode_tile_clamp_init(TailscodeTileClamp *self) {
    gtk_widget_set_overflow(GTK_WIDGET(self), GTK_OVERFLOW_HIDDEN);
}

GtkWidget *tailscode_tile_clamp_new(void) { return g_object_new(TAILSCODE_TYPE_TILE_CLAMP, NULL); }

void tailscode_tile_clamp_add(GtkWidget *clamp, GtkWidget *child) {
    if (gtk_widget_get_parent(child) != NULL) {
        g_atomic_int_inc(&tile_reparents);
        return;
    }
    gtk_widget_set_parent(child, clamp);
}

void tailscode_tile_clamp_remove(GtkWidget *clamp, GtkWidget *child) {
    if (gtk_widget_get_parent(child) != clamp) return;
    gtk_widget_unparent(child);
}

#define TAILSCODE_TYPE_TILE_DIVIDER (tailscode_tile_divider_get_type())
G_DECLARE_FINAL_TYPE(TailscodeTileDivider, tailscode_tile_divider, TAILSCODE, TILE_DIVIDER, GtkWidget)

struct _TailscodeTileDivider {
    GtkWidget parent_instance;
    gboolean across;
    gboolean dragging;
    TailscodeTileDividerHandlers handlers;
    void *data;
};

G_DEFINE_FINAL_TYPE(TailscodeTileDivider, tailscode_tile_divider, GTK_TYPE_WIDGET)

static gboolean tile_pointer_in_parent(
    GtkEventController *controller, GtkWidget *widget, double *x, double *y) {
    GtkWidget *parent = gtk_widget_get_parent(widget);
    GtkNative *native = gtk_widget_get_native(widget);
    GdkEvent *event = gtk_event_controller_get_current_event(controller);
    if (!parent || !native || !event) return FALSE;
    double surface_x = 0;
    double surface_y = 0;
    if (!gdk_event_get_position(event, &surface_x, &surface_y)) return FALSE;
    double shadow_x = 0;
    double shadow_y = 0;
    gtk_native_get_surface_transform(native, &shadow_x, &shadow_y);
    graphene_point_t local = GRAPHENE_POINT_INIT(
        (float)(surface_x - shadow_x), (float)(surface_y - shadow_y));
    graphene_point_t mapped;
    if (!gtk_widget_compute_point(GTK_WIDGET(native), parent, &local, &mapped)) return FALSE;
    *x = mapped.x;
    *y = mapped.y;
    return TRUE;
}

static void tile_divider_began(
    GtkGestureDrag *gesture, double start_x, double start_y, gpointer raw) {
    (void)start_x;
    (void)start_y;
    TailscodeTileDivider *self = raw;
    GtkWidget *widget = GTK_WIDGET(self);
    double x;
    double y;
    if (!tile_pointer_in_parent(GTK_EVENT_CONTROLLER(gesture), widget, &x, &y)) return;
    self->dragging = TRUE;
    gtk_widget_add_css_class(widget, "dragging");
    gtk_widget_queue_draw(widget);
    if (self->handlers.began) self->handlers.began(x, y, self->data);
}

static void tile_divider_updated(
    GtkGestureDrag *gesture, double offset_x, double offset_y, gpointer raw) {
    (void)offset_x;
    (void)offset_y;
    TailscodeTileDivider *self = raw;
    double x;
    double y;
    if (!self->dragging) return;
    if (!tile_pointer_in_parent(GTK_EVENT_CONTROLLER(gesture), GTK_WIDGET(self), &x, &y)) return;
    if (self->handlers.moved) self->handlers.moved(x, y, self->data);
}

static void tile_divider_ended(
    GtkGestureDrag *gesture, double offset_x, double offset_y, gpointer raw) {
    (void)offset_x;
    (void)offset_y;
    TailscodeTileDivider *self = raw;
    GtkWidget *widget = GTK_WIDGET(self);
    if (!self->dragging) return;
    double x = 0;
    double y = 0;
    gboolean known = tile_pointer_in_parent(GTK_EVENT_CONTROLLER(gesture), widget, &x, &y);
    self->dragging = FALSE;
    gtk_widget_remove_css_class(widget, "dragging");
    gtk_widget_queue_draw(widget);
    if (self->handlers.ended) self->handlers.ended(known ? x : NAN, known ? y : NAN, self->data);
}

static void tile_divider_pressed(
    GtkGestureClick *gesture, int presses, double x, double y, gpointer raw) {
    (void)gesture;
    (void)x;
    (void)y;
    TailscodeTileDivider *self = raw;
    gtk_widget_grab_focus(GTK_WIDGET(self));
    if (presses == 2 && self->handlers.equalize) self->handlers.equalize(self->data);
}

static gboolean tile_divider_key(
    GtkEventControllerKey *controller, guint keyval, guint keycode, GdkModifierType state,
    gpointer raw) {
    (void)controller;
    (void)keycode;
    TailscodeTileDivider *self = raw;
    int key;
    switch (keyval) {
    case GDK_KEY_Left:
    case GDK_KEY_Up: key = 0; break;
    case GDK_KEY_Right:
    case GDK_KEY_Down: key = 1; break;
    case GDK_KEY_Home: key = 2; break;
    case GDK_KEY_End: key = 3; break;
    default: return FALSE;
    }
    if (state & (GDK_CONTROL_MASK | GDK_ALT_MASK | GDK_SUPER_MASK)) return FALSE;
    if (!self->handlers.key) return FALSE;
    return self->handlers.key(key, (state & GDK_SHIFT_MASK) ? 1 : 0, self->data);
}

static void tile_divider_snapshot(GtkWidget *widget, GtkSnapshot *snapshot) {
    TailscodeTileDivider *self = TAILSCODE_TILE_DIVIDER(widget);
    int width = gtk_widget_get_width(widget);
    int height = gtk_widget_get_height(widget);
    GdkRGBA color;
    gtk_widget_get_color(widget, &color);
    GtkStateFlags flags = gtk_widget_get_state_flags(widget);
    gboolean hot = self->dragging || (flags & (GTK_STATE_FLAG_PRELIGHT | GTK_STATE_FLAG_FOCUS_VISIBLE));
    int thickness = hot ? 2 : 1;
    graphene_rect_t line;
    if (self->across) {
        int centre = width / 2;
        line = GRAPHENE_RECT_INIT((float)(centre - thickness + 1), 0, (float)thickness, (float)height);
    } else {
        int centre = height / 2;
        line = GRAPHENE_RECT_INIT(0, (float)(centre - thickness + 1), (float)width, (float)thickness);
    }
    gtk_snapshot_append_color(snapshot, &color, &line);
}

static void tile_divider_state_flags_changed(GtkWidget *widget, GtkStateFlags previous) {
    (void)previous;
    gtk_widget_queue_draw(widget);
}

static void tile_divider_measure(
    GtkWidget *widget, GtkOrientation orientation, int for_size, int *minimum, int *natural,
    int *minimum_baseline, int *natural_baseline) {
    (void)for_size;
    TailscodeTileDivider *self = TAILSCODE_TILE_DIVIDER(widget);
    GtkOrientation thick = self->across ? GTK_ORIENTATION_HORIZONTAL : GTK_ORIENTATION_VERTICAL;
    int size = orientation == thick ? 9 : 0;
    *minimum = size;
    *natural = size;
    *minimum_baseline = -1;
    *natural_baseline = -1;
}

static void tailscode_tile_divider_finalize(GObject *object) {
    TailscodeTileDivider *self = TAILSCODE_TILE_DIVIDER(object);
    if (self->data) {
        tailscode_box_release_call(self->data);
        self->data = NULL;
    }
    G_OBJECT_CLASS(tailscode_tile_divider_parent_class)->finalize(object);
}

static void tailscode_tile_divider_class_init(TailscodeTileDividerClass *class) {
    GtkWidgetClass *widget = GTK_WIDGET_CLASS(class);
    widget->snapshot = tile_divider_snapshot;
    widget->measure = tile_divider_measure;
    widget->state_flags_changed = tile_divider_state_flags_changed;
    G_OBJECT_CLASS(class)->finalize = tailscode_tile_divider_finalize;
    gtk_widget_class_set_css_name(widget, "tile-divider");
    gtk_widget_class_set_accessible_role(widget, GTK_ACCESSIBLE_ROLE_SEPARATOR);
}

static void tailscode_tile_divider_init(TailscodeTileDivider *self) {
    GtkWidget *widget = GTK_WIDGET(self);
    gtk_widget_set_focusable(widget, TRUE);
    gtk_widget_set_can_target(widget, TRUE);
}

GtkWidget *tailscode_tile_divider_new(
    gboolean across, TailscodeTileDividerHandlers handlers, void *data) {
    TailscodeTileDivider *self = g_object_new(TAILSCODE_TYPE_TILE_DIVIDER, NULL);
    GtkWidget *widget = GTK_WIDGET(self);
    self->across = across;
    self->handlers = handlers;
    self->data = data;
    gtk_widget_set_cursor_from_name(widget, across ? "col-resize" : "row-resize");
    GtkGesture *drag = gtk_gesture_drag_new();
    gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(drag), GDK_BUTTON_PRIMARY);
    g_signal_connect(drag, "drag-begin", G_CALLBACK(tile_divider_began), self);
    g_signal_connect(drag, "drag-update", G_CALLBACK(tile_divider_updated), self);
    g_signal_connect(drag, "drag-end", G_CALLBACK(tile_divider_ended), self);
    gtk_widget_add_controller(widget, GTK_EVENT_CONTROLLER(drag));
    GtkGesture *click = gtk_gesture_click_new();
    gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(click), GDK_BUTTON_PRIMARY);
    g_signal_connect(click, "pressed", G_CALLBACK(tile_divider_pressed), self);
    gtk_widget_add_controller(widget, GTK_EVENT_CONTROLLER(click));
    GtkEventController *keys = gtk_event_controller_key_new();
    g_signal_connect(keys, "key-pressed", G_CALLBACK(tile_divider_key), self);
    gtk_widget_add_controller(widget, keys);
    return widget;
}

void tailscode_tile_divider_describe(
    GtkWidget *divider, const char *label, double minimum, double maximum, double now,
    const char *text) {
    gtk_accessible_update_property(
        GTK_ACCESSIBLE(divider), GTK_ACCESSIBLE_PROPERTY_LABEL, label,
        GTK_ACCESSIBLE_PROPERTY_VALUE_MIN, minimum, GTK_ACCESSIBLE_PROPERTY_VALUE_MAX, maximum,
        GTK_ACCESSIBLE_PROPERTY_VALUE_NOW, now, GTK_ACCESSIBLE_PROPERTY_VALUE_TEXT, text, -1);
    TailscodeTileDivider *self = TAILSCODE_TILE_DIVIDER(divider);
    gtk_accessible_update_property(
        GTK_ACCESSIBLE(divider), GTK_ACCESSIBLE_PROPERTY_ORIENTATION,
        self->across ? GTK_ORIENTATION_VERTICAL : GTK_ORIENTATION_HORIZONTAL, -1);
}

gboolean tailscode_tile_divider_focus(GtkWidget *divider) {
    return gtk_widget_grab_focus(divider);
}

gboolean tailscode_tile_divider_is(GtkWidget *widget) {
    return widget != NULL && TAILSCODE_IS_TILE_DIVIDER(widget);
}

static const char *tile_property_verdict(
    GtkAccessible *accessible, GtkAccessibleProperty property, double expected) {
    if (!gtk_test_accessible_has_property(accessible, property)) return "missing";
    char *problem = gtk_test_accessible_check_property(accessible, property, expected);
    if (!problem) return "ok";
    g_free(problem);
    return "differs";
}

char *tailscode_tile_divider_reading(
    GtkWidget *divider, const char *label, double minimum, double maximum, double now) {
    GtkAccessible *accessible = GTK_ACCESSIBLE(divider);
    GtkRoot *root = gtk_widget_get_root(divider);
    GtkWidget *focus = root ? gtk_root_get_focus(root) : NULL;
    GEnumClass *roles = g_type_class_ref(GTK_TYPE_ACCESSIBLE_ROLE);
    GEnumValue *name = g_enum_get_value(roles, gtk_accessible_get_accessible_role(accessible));
    const char *labelled = "missing";
    if (gtk_test_accessible_has_property(accessible, GTK_ACCESSIBLE_PROPERTY_LABEL)) {
        char *problem =
            gtk_test_accessible_check_property(accessible, GTK_ACCESSIBLE_PROPERTY_LABEL, label);
        labelled = problem ? "differs" : "ok";
        g_free(problem);
    }
    char *out = g_strdup_printf(
        "role=%s focused=%d label=%s min=%s max=%s now=%s", name ? name->value_nick : "?",
        focus == divider, labelled,
        tile_property_verdict(accessible, GTK_ACCESSIBLE_PROPERTY_VALUE_MIN, minimum),
        tile_property_verdict(accessible, GTK_ACCESSIBLE_PROPERTY_VALUE_MAX, maximum),
        tile_property_verdict(accessible, GTK_ACCESSIBLE_PROPERTY_VALUE_NOW, now));
    g_type_class_unref(roles);
    return out;
}

typedef struct {
    void (*handler)(void *);
    void *data;
} TileDoubleClick;

static void tile_double_clicked(
    GtkGestureClick *gesture, int presses, double x, double y, gpointer raw) {
    (void)gesture;
    (void)x;
    (void)y;
    TileDoubleClick *box = raw;
    if (presses == 2) box->handler(box->data);
}

static void tile_double_click_free(gpointer raw, GClosure *closure) {
    (void)closure;
    TileDoubleClick *box = raw;
    if (box->data) tailscode_box_release_call(box->data);
    g_free(box);
}

void tailscode_tile_on_double_click(GtkWidget *widget, void (*handler)(void *), void *data) {
    TileDoubleClick *box = g_new0(TileDoubleClick, 1);
    box->handler = handler;
    box->data = data;
    GtkGesture *click = gtk_gesture_click_new();
    gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(click), GDK_BUTTON_PRIMARY);
    g_signal_connect_data(click, "pressed", G_CALLBACK(tile_double_clicked), box,
                          tile_double_click_free, 0);
    gtk_widget_add_controller(widget, GTK_EVENT_CONTROLLER(click));
}
