#include "CGtkShim.h"

typedef struct {
    GtkWidget *card;
    GtkWidget *room;
    TailscodeStageHit hit;
    TailscodeStageDrag drag;
    void *data;
    int edges;
    gboolean active;
    gboolean pending;
    double start_x, start_y;
    graphene_point_t anchor;
} TailscodeStage;

/// Where a point on `widget` is on the surface it is drawn in. A drag is measured there and not on
/// the card, which moves under the pointer as it is dragged.
static graphene_point_t tailscode_stage_on_surface(GtkWidget *widget, double x, double y) {
    graphene_point_t point = GRAPHENE_POINT_INIT((float)x, (float)y);
    graphene_point_t out = point;
    GtkNative *native = gtk_widget_get_native(widget);
    if (native) gtk_widget_compute_point(widget, GTK_WIDGET(native), &point, &out);
    return out;
}

/// How far the pointer has gone since the press, on the surface.
static void tailscode_stage_travel(GtkGestureDrag *gesture, TailscodeStage *stage, double *dx,
                                   double *dy) {
    double x = 0, y = 0;
    gtk_gesture_drag_get_start_point(gesture, &x, &y);
    GtkWidget *widget = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(gesture));
    graphene_point_t now = tailscode_stage_on_surface(widget, x + *dx, y + *dy);
    *dx = now.x - stage->anchor.x;
    *dy = now.y - stage->anchor.y;
}

/// The edges a point of the room takes hold of, asked of the card from its own corner, so a point
/// just outside the card's border counts as well as one just inside it.
static int tailscode_stage_edges(TailscodeStage *stage, double x, double y) {
    graphene_point_t point = GRAPHENE_POINT_INIT((float)x, (float)y);
    graphene_point_t out;
    if (!gtk_widget_compute_point(stage->room, stage->card, &point, &out)) return 0;
    int width = gtk_widget_get_width(stage->card);
    int height = gtk_widget_get_height(stage->card);
    return stage->hit(out.x, out.y, width, height, stage->data);
}

static const char *tailscode_stage_cursor(int edges) {
    switch (edges) {
    case 1: case 2: return "ew-resize";
    case 4: case 8: return "ns-resize";
    case 5: case 10: return "nwse-resize";
    case 6: case 9: return "nesw-resize";
    default: return NULL;
    }
}

static void tailscode_stage_motion(GtkEventControllerMotion *motion, double x, double y,
                                   TailscodeStage *stage) {
    (void)motion;
    if (stage->active) return;
    gtk_widget_set_cursor_from_name(stage->room,
                                    tailscode_stage_cursor(tailscode_stage_edges(stage, x, y)));
}

static void tailscode_stage_leave(GtkEventControllerMotion *motion, TailscodeStage *stage) {
    (void)motion;
    if (!stage->active) gtk_widget_set_cursor_from_name(stage->room, NULL);
}

/// A press in the band either side of the card's border sizes it. The band is the room's, ahead of
/// everything in it, because the card's rounded corners are not the card's to pick.
static void tailscode_stage_edge_begin(GtkGestureDrag *gesture, double x, double y,
                                       TailscodeStage *stage) {
    int edges = tailscode_stage_edges(stage, x, y);
    if (edges == 0) {
        gtk_gesture_set_state(GTK_GESTURE(gesture), GTK_EVENT_SEQUENCE_DENIED);
        return;
    }
    gtk_gesture_set_state(GTK_GESTURE(gesture), GTK_EVENT_SEQUENCE_CLAIMED);
    stage->anchor = tailscode_stage_on_surface(stage->room, x, y);
    stage->edges = edges;
    stage->active = TRUE;
    stage->drag(0, edges, 0, 0, stage->data);
}

/// A press on the card's own ground may become a move, but only once it has travelled past the
/// desktop's drag threshold: until then it is a click, and the button or line under it keeps it.
static void tailscode_stage_move_begin(GtkGestureDrag *gesture, double x, double y,
                                       TailscodeStage *stage) {
    (void)gesture;
    stage->pending = !stage->active;
    stage->start_x = x;
    stage->start_y = y;
    stage->anchor = tailscode_stage_on_surface(stage->card, x, y);
}

/// The press has become a move. Inside an overlay the card is moved by the app, which owns its
/// place; as an ordinary window the desktop is asked to move it, which is the only way a window
/// can be moved on Wayland.
static void tailscode_stage_move_start(GtkGestureDrag *gesture, TailscodeStage *stage) {
    stage->pending = FALSE;
    gtk_gesture_set_state(GTK_GESTURE(gesture), GTK_EVENT_SEQUENCE_CLAIMED);
    if (stage->room) {
        stage->edges = 16;
        stage->active = TRUE;
        stage->drag(0, 16, 0, 0, stage->data);
        return;
    }
    GtkNative *native = gtk_widget_get_native(stage->card);
    GdkSurface *surface = native ? gtk_native_get_surface(native) : NULL;
    if (!surface || !GDK_IS_TOPLEVEL(surface)) return;
    graphene_point_t at = tailscode_stage_on_surface(stage->card, stage->start_x, stage->start_y);
    double dx = 0, dy = 0;
    gtk_native_get_surface_transform(native, &dx, &dy);
    gdk_toplevel_begin_move(
        GDK_TOPLEVEL(surface), gtk_gesture_get_device(GTK_GESTURE(gesture)),
        (int)gtk_gesture_single_get_current_button(GTK_GESTURE_SINGLE(gesture)), at.x + dx,
        at.y + dy, gtk_event_controller_get_current_event_time(GTK_EVENT_CONTROLLER(gesture)));
    gtk_event_controller_reset(GTK_EVENT_CONTROLLER(gesture));
}

static void tailscode_stage_move_update(GtkGestureDrag *gesture, double dx, double dy,
                                        TailscodeStage *stage) {
    tailscode_stage_travel(gesture, stage, &dx, &dy);
    if (stage->pending) {
        if (!gtk_drag_check_threshold(stage->card, 0, 0, (int)dx, (int)dy)) return;
        tailscode_stage_move_start(gesture, stage);
    }
    if (!stage->active) return;
    stage->drag(1, stage->edges, dx, dy, stage->data);
}

static void tailscode_stage_update(GtkGestureDrag *gesture, double dx, double dy,
                                   TailscodeStage *stage) {
    if (!stage->active) return;
    tailscode_stage_travel(gesture, stage, &dx, &dy);
    stage->drag(1, stage->edges, dx, dy, stage->data);
}

static void tailscode_stage_end(GtkGestureDrag *gesture, double dx, double dy,
                                TailscodeStage *stage) {
    stage->pending = FALSE;
    if (!stage->active) return;
    tailscode_stage_travel(gesture, stage, &dx, &dy);
    stage->active = FALSE;
    stage->drag(2, stage->edges, dx, dy, stage->data);
    stage->edges = 0;
}

static void tailscode_stage_free(gpointer data, GClosure *closure) {
    (void)closure;
    g_free(data);
}

void tailscode_stage_track(GtkWidget *card, GtkWidget *room, TailscodeStageHit hit,
                           TailscodeStageDrag drag, void *data) {
    TailscodeStage *stage = g_new0(TailscodeStage, 1);
    stage->card = card;
    stage->room = room;
    stage->hit = hit;
    stage->drag = drag;
    stage->data = data;

    if (room) {
        GtkEventController *motion = gtk_event_controller_motion_new();
        g_signal_connect(motion, "motion", G_CALLBACK(tailscode_stage_motion), stage);
        g_signal_connect(motion, "leave", G_CALLBACK(tailscode_stage_leave), stage);
        gtk_widget_add_controller(room, motion);

        GtkGesture *edge = gtk_gesture_drag_new();
        gtk_event_controller_set_propagation_phase(GTK_EVENT_CONTROLLER(edge), GTK_PHASE_CAPTURE);
        g_signal_connect(edge, "drag-begin", G_CALLBACK(tailscode_stage_edge_begin), stage);
        g_signal_connect(edge, "drag-update", G_CALLBACK(tailscode_stage_update), stage);
        g_signal_connect(edge, "drag-end", G_CALLBACK(tailscode_stage_end), stage);
        gtk_widget_add_controller(room, GTK_EVENT_CONTROLLER(edge));
    }

    GtkGesture *move = gtk_gesture_drag_new();
    gtk_event_controller_set_propagation_phase(GTK_EVENT_CONTROLLER(move), GTK_PHASE_BUBBLE);
    g_signal_connect(move, "drag-begin", G_CALLBACK(tailscode_stage_move_begin), stage);
    g_signal_connect(move, "drag-update", G_CALLBACK(tailscode_stage_move_update), stage);
    g_signal_connect_data(move, "drag-end", G_CALLBACK(tailscode_stage_end), stage,
                          tailscode_stage_free, 0);
    gtk_widget_add_controller(card, GTK_EVENT_CONTROLLER(move));
}

typedef struct {
    GtkWidget *card;
    void (*handler)(void *);
    void *data;
} TailscodeBackdrop;

static void tailscode_backdrop_pressed(GtkGestureClick *click, int presses, double x, double y,
                                       TailscodeBackdrop *box) {
    (void)presses;
    GtkWidget *room = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(click));
    GtkWidget *picked = gtk_widget_pick(room, x, y, GTK_PICK_DEFAULT);
    if (picked && (picked == box->card || gtk_widget_is_ancestor(picked, box->card))) return;
    box->handler(box->data);
}

void tailscode_stage_backdrop(GtkWidget *room, GtkWidget *card, void (*handler)(void *),
                              void *data) {
    TailscodeBackdrop *box = g_new0(TailscodeBackdrop, 1);
    box->card = card;
    box->handler = handler;
    box->data = data;
    GtkGesture *click = gtk_gesture_click_new();
    gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(click), 0);
    g_signal_connect_data(click, "pressed", G_CALLBACK(tailscode_backdrop_pressed), box,
                          tailscode_stage_free, 0);
    gtk_widget_add_controller(room, GTK_EVENT_CONTROLLER(click));
}

typedef struct {
    void (*handler)(int width, int height, void *);
    void *data;
} TailscodeSized;

static gboolean tailscode_sized_tick(GtkWidget *widget, GdkFrameClock *clock, gpointer data) {
    (void)clock;
    TailscodeSized *box = data;
    int width = gtk_widget_get_width(widget);
    int height = gtk_widget_get_height(widget);
    if (width <= 0 || height <= 0) return G_SOURCE_CONTINUE;
    box->handler(width, height, box->data);
    return G_SOURCE_REMOVE;
}

void tailscode_when_sized(GtkWidget *widget, void (*handler)(int width, int height, void *),
                          void *data) {
    TailscodeSized *box = g_new0(TailscodeSized, 1);
    box->handler = handler;
    box->data = data;
    gtk_widget_add_tick_callback(widget, tailscode_sized_tick, box, g_free);
}

typedef struct {
    void (*handler)(gboolean known, double x, double y, void *);
    void *data;
    gint64 wait;
    gint64 started;
} TailscodePointed;

/// Where the pointer is on `widget`, if the desktop has told its surface. GDK keeps what the last
/// enter and motion said whoever was listening, so a pointer that arrived before anyone asked is
/// still read.
static gboolean tailscode_pointer_on(GtkWidget *widget, double *x, double *y) {
    GtkNative *native = gtk_widget_get_native(widget);
    GdkSurface *surface = native ? gtk_native_get_surface(native) : NULL;
    GdkSeat *seat = gdk_display_get_default_seat(gtk_widget_get_display(widget));
    GdkDevice *pointer = seat ? gdk_seat_get_pointer(seat) : NULL;
    double sx = 0, sy = 0;
    if (!surface || !pointer || !gdk_surface_get_device_position(surface, pointer, &sx, &sy, NULL))
        return FALSE;
    double dx = 0, dy = 0;
    gtk_native_get_surface_transform(native, &dx, &dy);
    graphene_point_t at = GRAPHENE_POINT_INIT((float)(sx - dx), (float)(sy - dy));
    graphene_point_t out;
    if (!gtk_widget_compute_point(GTK_WIDGET(native), widget, &at, &out)) return FALSE;
    *x = out.x;
    *y = out.y;
    return TRUE;
}

static gboolean tailscode_pointed_tick(GtkWidget *widget, GdkFrameClock *clock, gpointer data) {
    TailscodePointed *box = data;
    gint64 now = gdk_frame_clock_get_frame_time(clock);
    if (box->started == 0) box->started = now;
    double x = 0, y = 0;
    gboolean known = tailscode_pointer_on(widget, &x, &y);
    if (!known && now - box->started < box->wait) return G_SOURCE_CONTINUE;
    box->handler(known, x, y, box->data);
    return G_SOURCE_REMOVE;
}

void tailscode_when_pointed(GtkWidget *widget, unsigned wait_ms,
                            void (*handler)(gboolean known, double x, double y, void *),
                            void *data) {
    TailscodePointed *box = g_new0(TailscodePointed, 1);
    box->handler = handler;
    box->data = data;
    box->wait = (gint64)wait_ms * 1000;
    gtk_widget_add_tick_callback(widget, tailscode_pointed_tick, box, g_free);
}

typedef struct {
    double x, y, width, height;
} TailscodeRoomRect;

static void tailscode_room_measure(GtkWidget *widget, GtkOrientation orientation, int for_size,
                                   int *minimum, int *natural, int *minimum_baseline,
                                   int *natural_baseline) {
    (void)widget; (void)orientation; (void)for_size;
    *minimum = 0;
    *natural = 0;
    *minimum_baseline = -1;
    *natural_baseline = -1;
}

/// The card is given exactly the rectangle the stage holds for it — never its natural size, which
/// for a list of ellipsized lines is the width of its longest one — and never less than it needs
/// to draw at all.
static void tailscode_room_allocate(GtkWidget *widget, int width, int height, int baseline) {
    (void)width; (void)height; (void)baseline;
    TailscodeRoomRect *rect = g_object_get_data(G_OBJECT(widget), "tailscode-room-rect");
    for (GtkWidget *child = gtk_widget_get_first_child(widget); child;
         child = gtk_widget_get_next_sibling(child)) {
        if (!gtk_widget_should_layout(child)) continue;
        int min_w = 0, min_h = 0;
        gtk_widget_measure(child, GTK_ORIENTATION_HORIZONTAL, -1, &min_w, NULL, NULL, NULL);
        int w = rect ? MAX((int)rect->width, min_w) : min_w;
        gtk_widget_measure(child, GTK_ORIENTATION_VERTICAL, w, &min_h, NULL, NULL, NULL);
        int h = rect ? MAX((int)rect->height, min_h) : min_h;
        graphene_point_t at = GRAPHENE_POINT_INIT(rect ? (float)rect->x : 0, rect ? (float)rect->y : 0);
        gtk_widget_allocate(child, w, h, -1, gsk_transform_translate(NULL, &at));
    }
}

GtkWidget *tailscode_stage_room(void) {
    GtkWidget *room = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_set_layout_manager(
        room, gtk_custom_layout_new(NULL, tailscode_room_measure, tailscode_room_allocate));
    g_object_set_data_full(G_OBJECT(room), "tailscode-room-rect", g_new0(TailscodeRoomRect, 1),
                           g_free);
    return room;
}

void tailscode_stage_room_place(GtkWidget *room, double x, double y, double width,
                                double height) {
    TailscodeRoomRect *rect = g_object_get_data(G_OBJECT(room), "tailscode-room-rect");
    if (!rect) return;
    rect->x = x;
    rect->y = y;
    rect->width = width;
    rect->height = height;
    gtk_widget_queue_allocate(room);
}
