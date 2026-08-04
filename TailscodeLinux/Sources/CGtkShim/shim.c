#include "include/CGtkShim.h"

void tailscode_connect(gpointer instance, const char *signal, GCallback handler, gpointer data) {
    g_signal_connect_data(instance, signal, handler, data, NULL, 0);
}

typedef struct {
    void (*handler)(void *);
    void *data;
} TailscodeIdle;

static gboolean tailscode_idle_trampoline(gpointer raw) {
    TailscodeIdle *box = raw;
    box->handler(box->data);
    g_free(box);
    return G_SOURCE_REMOVE;
}

void tailscode_on_main(void (*handler)(void *), void *data) {
    TailscodeIdle *box = g_new0(TailscodeIdle, 1);
    box->handler = handler;
    box->data = data;
    g_idle_add(tailscode_idle_trampoline, box);
}

void tailscode_after(guint ms, void (*handler)(void *), void *data) {
    TailscodeIdle *box = g_new0(TailscodeIdle, 1);
    box->handler = handler;
    box->data = data;
    g_timeout_add(ms, tailscode_idle_trampoline, box);
}

typedef struct {
    void (*setup)(GtkListItem *, void *);
    void (*bind)(GtkListItem *, void *);
    void *data;
} TailscodeFactory;

static void tailscode_factory_setup(
    GtkSignalListItemFactory *factory, GtkListItem *item, gpointer raw) {
    (void)factory;
    TailscodeFactory *box = raw;
    box->setup(item, box->data);
}

static void tailscode_factory_bind(
    GtkSignalListItemFactory *factory, GtkListItem *item, gpointer raw) {
    (void)factory;
    TailscodeFactory *box = raw;
    box->bind(item, box->data);
}

GtkListItemFactory *tailscode_make_factory(
    void (*setup)(GtkListItem *, void *),
    void (*bind)(GtkListItem *, void *),
    void *data) {
    TailscodeFactory *box = g_new0(TailscodeFactory, 1);
    box->setup = setup;
    box->bind = bind;
    box->data = data;
    GtkListItemFactory *factory = gtk_signal_list_item_factory_new();
    g_signal_connect_data(
        factory, "setup", G_CALLBACK(tailscode_factory_setup), box, NULL, 0);
    g_signal_connect_data(
        factory, "bind", G_CALLBACK(tailscode_factory_bind), box, NULL, 0);
    return factory;
}

typedef struct {
    gboolean (*handler)(guint, guint, void *);
    void *data;
} TailscodeKey;

static gboolean tailscode_key_trampoline(
    GtkEventControllerKey *controller, guint keyval, guint keycode, GdkModifierType state,
    gpointer raw) {
    (void)controller;
    (void)keycode;
    TailscodeKey *box = raw;
    return box->handler(keyval, (guint)state, box->data);
}

void tailscode_connect_key(
    GtkWidget *widget, gboolean (*handler)(guint keyval, guint state, void *), void *data) {
    TailscodeKey *box = g_new0(TailscodeKey, 1);
    box->handler = handler;
    box->data = data;
    GtkEventController *controller = gtk_event_controller_key_new();
    gtk_event_controller_set_propagation_phase(controller, GTK_PHASE_CAPTURE);
    g_signal_connect_data(
        controller, "key-pressed", G_CALLBACK(tailscode_key_trampoline), box, NULL, 0);
    gtk_widget_add_controller(widget, controller);
}

gboolean tailscode_focus_is_editable(GtkWidget *root) {
    GtkRoot *window = gtk_widget_get_root(root);
    if (!window) return FALSE;
    GtkWidget *focus = gtk_root_get_focus(window);
    if (!focus) return FALSE;
    return GTK_IS_TEXT_VIEW(focus) || GTK_IS_ENTRY(focus) || GTK_IS_EDITABLE(focus)
        || g_type_is_a(G_TYPE_FROM_INSTANCE(focus), g_type_from_name("VteTerminal"));
}

GdkTexture *tailscode_texture_from_bytes(const void *data, gsize len) {
    GBytes *bytes = g_bytes_new(data, len);
    GdkTexture *texture = gdk_texture_new_from_bytes(bytes, NULL);
    g_bytes_unref(bytes);
    return texture;
}

GtkWidget *tailscode_picture_for_texture(GdkTexture *texture) {
    GtkWidget *picture = gtk_picture_new_for_paintable(GDK_PAINTABLE(texture));
    gtk_picture_set_content_fit(GTK_PICTURE(picture), GTK_CONTENT_FIT_SCALE_DOWN);
    gtk_picture_set_can_shrink(GTK_PICTURE(picture), TRUE);
    return picture;
}

int tailscode_texture_width(GdkTexture *texture) {
    return gdk_texture_get_width(texture);
}

int tailscode_texture_height(GdkTexture *texture) {
    return gdk_texture_get_height(texture);
}

typedef struct {
    void (*handler)(const char *const *paths, int count, void *data);
    void *data;
} TailscodeFileOpen;

static void tailscode_file_open_done(GObject *source, GAsyncResult *result, gpointer raw) {
    TailscodeFileOpen *box = raw;
    GListModel *files =
        gtk_file_dialog_open_multiple_finish(GTK_FILE_DIALOG(source), result, NULL);
    if (!files) {
        box->handler(NULL, 0, box->data);
        g_free(box);
        return;
    }
    guint total = g_list_model_get_n_items(files);
    char **paths = g_new0(char *, total ? total : 1);
    int count = 0;
    for (guint i = 0; i < total; i++) {
        GFile *file = g_list_model_get_item(files, i);
        char *path = g_file_get_path(file);
        if (path) paths[count++] = path;
        g_object_unref(file);
    }
    g_object_unref(files);
    box->handler((const char *const *)paths, count, box->data);
    for (int i = 0; i < count; i++) g_free(paths[i]);
    g_free(paths);
    g_free(box);
}

void tailscode_file_open(
    GtkWindow *parent, void (*handler)(const char *const *paths, int count, void *data),
    void *data) {
    TailscodeFileOpen *box = g_new0(TailscodeFileOpen, 1);
    box->handler = handler;
    box->data = data;
    GtkFileDialog *dialog = gtk_file_dialog_new();
    gtk_file_dialog_open_multiple(dialog, parent, NULL, tailscode_file_open_done, box);
    g_object_unref(dialog);
}

typedef struct {
    void (*handler)(const char *path, void *data);
    void *data;
} TailscodeFolderPick;

static void tailscode_folder_pick_done(GObject *source, GAsyncResult *result, gpointer raw) {
    TailscodeFolderPick *box = raw;
    GFile *folder = gtk_file_dialog_select_folder_finish(GTK_FILE_DIALOG(source), result, NULL);
    if (!folder) {
        box->handler(NULL, box->data);
        g_free(box);
        return;
    }
    char *path = g_file_get_path(folder);
    box->handler(path, box->data);
    g_free(path);
    g_object_unref(folder);
    g_free(box);
}

void tailscode_select_folder(
    GtkWindow *parent, const char *initial,
    void (*handler)(const char *path, void *data), void *data) {
    TailscodeFolderPick *box = g_new0(TailscodeFolderPick, 1);
    box->handler = handler;
    box->data = data;
    GtkFileDialog *dialog = gtk_file_dialog_new();
    if (initial && *initial) {
        GFile *folder = g_file_new_for_path(initial);
        gtk_file_dialog_set_initial_folder(dialog, folder);
        g_object_unref(folder);
    }
    gtk_file_dialog_select_folder(dialog, parent, NULL, tailscode_folder_pick_done, box);
    g_object_unref(dialog);
}

typedef struct {
    void (*handler)(const void *bytes, gsize len, void *data);
    void *data;
} TailscodeClipboardRead;

static void tailscode_clipboard_read_done(GObject *source, GAsyncResult *result, gpointer raw) {
    TailscodeClipboardRead *box = raw;
    GdkTexture *texture =
        gdk_clipboard_read_texture_finish(GDK_CLIPBOARD(source), result, NULL);
    if (!texture) {
        box->handler(NULL, 0, box->data);
        g_free(box);
        return;
    }
    GBytes *png = gdk_texture_save_to_png_bytes(texture);
    gsize len = 0;
    const void *bytes = g_bytes_get_data(png, &len);
    box->handler(bytes, len, box->data);
    g_bytes_unref(png);
    g_object_unref(texture);
    g_free(box);
}

void tailscode_clipboard_read_image(
    void (*handler)(const void *bytes, gsize len, void *data), void *data) {
    GdkDisplay *display = gdk_display_get_default();
    GdkClipboard *clipboard = display ? gdk_display_get_clipboard(display) : NULL;
    if (!clipboard) {
        handler(NULL, 0, data);
        return;
    }
    TailscodeClipboardRead *box = g_new0(TailscodeClipboardRead, 1);
    box->handler = handler;
    box->data = data;
    gdk_clipboard_read_texture_async(clipboard, NULL, tailscode_clipboard_read_done, box);
}

double tailscode_widget_offset_y(GtkWidget *widget, GtkWidget *ancestor) {
    graphene_rect_t bounds;
    if (!gtk_widget_compute_bounds(widget, ancestor, &bounds)) return -1;
    return bounds.origin.y;
}

GtkWidget *tailscode_focused_widget(GtkWidget *root) {
    GtkRoot *window = gtk_widget_get_root(root);
    if (!window) return NULL;
    return gtk_root_get_focus(window);
}

gboolean tailscode_widget_bounds_in(
    GtkWidget *widget, GtkWidget *ancestor, double *x, double *y, double *width, double *height) {
    graphene_rect_t bounds;
    if (!gtk_widget_compute_bounds(widget, ancestor, &bounds)) return FALSE;
    if (x) *x = bounds.origin.x;
    if (y) *y = bounds.origin.y;
    if (width) *width = bounds.size.width;
    if (height) *height = bounds.size.height;
    return TRUE;
}

static gpointer tailscode_chat_ref_copy(gpointer boxed) { return g_strdup(boxed); }
static void tailscode_chat_ref_free(gpointer boxed) { g_free(boxed); }

GType tailscode_chat_ref_get_type(void) {
    static gsize once = 0;
    if (g_once_init_enter(&once)) {
        GType registered = g_boxed_type_register_static(
            "TailscodeChatRef", tailscode_chat_ref_copy, tailscode_chat_ref_free);
        g_once_init_leave(&once, registered);
    }
    return (GType)once;
}

void tailscode_make_chat_drag_source(GtkWidget *widget, const char *payload) {
    GtkDragSource *source = gtk_drag_source_new();
    gtk_drag_source_set_actions(source, GDK_ACTION_COPY);
    gtk_drag_source_set_content(
        source, gdk_content_provider_new_typed(tailscode_chat_ref_get_type(), payload));
    GdkPaintable *ghost = gtk_widget_paintable_new(widget);
    gtk_drag_source_set_icon(source, ghost, 0, 0);
    g_object_unref(ghost);
    gtk_widget_add_controller(widget, GTK_EVENT_CONTROLLER(source));
}

typedef struct {
    void (*motion)(const char *payload, double x, double y, void *data);
    void (*leave)(void *data);
    gboolean (*drop)(const char *payload, double x, double y, void *data);
    void *data;
} TailscodeChatDrop;

static const char *tailscode_chat_ref_value(const GValue *value) {
    if (!value || !G_VALUE_HOLDS(value, tailscode_chat_ref_get_type())) return NULL;
    return g_value_get_boxed(value);
}

static GdkDragAction tailscode_chat_motion(
    GtkDropTarget *target, double x, double y, gpointer raw) {
    TailscodeChatDrop *box = raw;
    const char *payload = tailscode_chat_ref_value(gtk_drop_target_get_value(target));
    box->motion(payload, x, y, box->data);
    return GDK_ACTION_COPY;
}

static void tailscode_chat_leave(GtkDropTarget *target, gpointer raw) {
    (void)target;
    TailscodeChatDrop *box = raw;
    box->leave(box->data);
}

static gboolean tailscode_chat_dropped(
    GtkDropTarget *target, const GValue *value, double x, double y, gpointer raw) {
    (void)target;
    TailscodeChatDrop *box = raw;
    const char *payload = tailscode_chat_ref_value(value);
    if (!payload) return FALSE;
    return box->drop(payload, x, y, box->data);
}

void tailscode_accept_chat_drops(
    GtkWidget *widget,
    void (*motion)(const char *payload, double x, double y, void *data),
    void (*leave)(void *data),
    gboolean (*drop)(const char *payload, double x, double y, void *data),
    void *data) {
    TailscodeChatDrop *box = g_new0(TailscodeChatDrop, 1);
    box->motion = motion;
    box->leave = leave;
    box->drop = drop;
    box->data = data;
    GtkDropTarget *target = gtk_drop_target_new(tailscode_chat_ref_get_type(), GDK_ACTION_COPY);
    gtk_drop_target_set_preload(target, TRUE);
    g_signal_connect_data(target, "motion", G_CALLBACK(tailscode_chat_motion), box, NULL, 0);
    g_signal_connect_data(target, "enter", G_CALLBACK(tailscode_chat_motion), box, NULL, 0);
    g_signal_connect_data(target, "leave", G_CALLBACK(tailscode_chat_leave), box, NULL, 0);
    g_signal_connect_data(target, "drop", G_CALLBACK(tailscode_chat_dropped), box, NULL, 0);
    gtk_widget_add_controller(widget, GTK_EVENT_CONTROLLER(target));
}

typedef struct {
    void (*handler)(const char *const *paths, int count, void *data);
    void *data;
} TailscodeDrop;

static gboolean tailscode_drop_received(
    GtkDropTarget *target, const GValue *value, double x, double y, gpointer raw) {
    (void)target;
    (void)x;
    (void)y;
    TailscodeDrop *box = raw;
    if (!G_VALUE_HOLDS(value, GDK_TYPE_FILE_LIST)) return FALSE;
    GSList *files = g_value_get_boxed(value);
    guint total = g_slist_length(files);
    char **paths = g_new0(char *, total ? total : 1);
    int count = 0;
    for (GSList *item = files; item; item = item->next) {
        char *path = g_file_get_path(item->data);
        if (path) paths[count++] = path;
    }
    box->handler((const char *const *)paths, count, box->data);
    for (int i = 0; i < count; i++) g_free(paths[i]);
    g_free(paths);
    return count > 0;
}

void tailscode_accept_file_drops(
    GtkWidget *widget, void (*handler)(const char *const *paths, int count, void *data),
    void *data) {
    TailscodeDrop *box = g_new0(TailscodeDrop, 1);
    box->handler = handler;
    box->data = data;
    GtkDropTarget *target = gtk_drop_target_new(GDK_TYPE_FILE_LIST, GDK_ACTION_COPY);
    g_signal_connect_data(target, "drop", G_CALLBACK(tailscode_drop_received), box, NULL, 0);
    gtk_widget_add_controller(widget, GTK_EVENT_CONTROLLER(target));
}

typedef struct {
    void (*handler)(void *);
    void *data;
} TailscodeNotify;

static void tailscode_notify_trampoline(GObject *object, GParamSpec *pspec, gpointer raw) {
    (void)object;
    (void)pspec;
    TailscodeNotify *box = raw;
    box->handler(box->data);
}

void tailscode_connect_notify(
    gpointer instance, const char *property, void (*handler)(void *), void *data) {
    TailscodeNotify *box = g_new0(TailscodeNotify, 1);
    box->handler = handler;
    box->data = data;
    char *signal = g_strdup_printf("notify::%s", property);
    g_signal_connect_data(instance, signal, G_CALLBACK(tailscode_notify_trampoline), box, NULL, 0);
    g_free(signal);
}

void tailscode_set_text_scale(double scale) {
    GtkSettings *settings = gtk_settings_get_default();
    if (!settings) return;
    g_object_set(settings, "gtk-xft-dpi", (gint)(96.0 * 1024.0 * scale), NULL);
}

typedef struct {
    void (*handler)(void *);
    void *data;
} TailscodeClick;

static void tailscode_click_released(
    GtkGestureClick *gesture, gint n_press, gdouble x, gdouble y, gpointer raw) {
    (void)gesture; (void)n_press; (void)x; (void)y;
    TailscodeClick *box = raw;
    box->handler(box->data);
}

void tailscode_on_release(GtkWidget *widget, void (*handler)(void *), void *data) {
    TailscodeClick *box = g_new0(TailscodeClick, 1);
    box->handler = handler;
    box->data = data;
    GtkGesture *click = gtk_gesture_click_new();
    g_signal_connect_data(click, "released", G_CALLBACK(tailscode_click_released), box,
                          (GClosureNotify)(void (*)(void))g_free, 0);
    gtk_widget_add_controller(widget, GTK_EVENT_CONTROLLER(click));
}

typedef struct {
    void (*handler)(double x, double y, void *);
    void *data;
} TailscodePoint;

static void tailscode_press_captured(
    GtkGestureClick *gesture, gint n_press, gdouble x, gdouble y, gpointer raw) {
    (void)gesture; (void)n_press;
    TailscodePoint *box = raw;
    box->handler(x, y, box->data);
}

void tailscode_on_press_capture(
    GtkWidget *widget, void (*handler)(double x, double y, void *), void *data) {
    TailscodePoint *box = g_new0(TailscodePoint, 1);
    box->handler = handler;
    box->data = data;
    GtkGesture *click = gtk_gesture_click_new();
    gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(click), 0);
    gtk_event_controller_set_propagation_phase(GTK_EVENT_CONTROLLER(click), GTK_PHASE_CAPTURE);
    g_signal_connect_data(click, "pressed", G_CALLBACK(tailscode_press_captured), box,
                          (GClosureNotify)(void (*)(void))g_free, 0);
    gtk_widget_add_controller(widget, GTK_EVENT_CONTROLLER(click));
}

typedef struct {
    void (*handler)(void *);
    void *data;
    guint32 last_press;
    double last_point;
} TailscodePanedClick;

/// The gap between a paned's two children — where the handle is drawn — along the axis it splits.
static gboolean tailscode_paned_gap(
    GtkPaned *paned, gboolean *horizontal, double *low, double *high, double *across) {
    GtkWidget *start = gtk_paned_get_start_child(paned);
    GtkWidget *end = gtk_paned_get_end_child(paned);
    if (!start || !end) return FALSE;
    graphene_rect_t first, second;
    if (!gtk_widget_compute_bounds(start, GTK_WIDGET(paned), &first)) return FALSE;
    if (!gtk_widget_compute_bounds(end, GTK_WIDGET(paned), &second)) return FALSE;
    *horizontal =
        gtk_orientable_get_orientation(GTK_ORIENTABLE(paned)) == GTK_ORIENTATION_HORIZONTAL;
    *low = *horizontal ? first.origin.x + first.size.width : first.origin.y + first.size.height;
    *high = *horizontal ? second.origin.x : second.origin.y;
    *across = *horizontal ? gtk_widget_get_height(GTK_WIDGET(paned)) / 2.0
                          : gtk_widget_get_width(GTK_WIDGET(paned)) / 2.0;
    return TRUE;
}

gboolean tailscode_paned_handle_center(GtkWidget *widget, double *x, double *y) {
    if (!widget || !GTK_IS_PANED(widget)) return FALSE;
    gboolean horizontal = FALSE;
    double low = 0, high = 0, across = 0;
    if (!tailscode_paned_gap(GTK_PANED(widget), &horizontal, &low, &high, &across)) return FALSE;
    double middle = (low + high) / 2.0;
    *x = horizontal ? middle : across;
    *y = horizontal ? across : middle;
    return TRUE;
}

static gboolean tailscode_point_in_paned_handle(GtkPaned *paned, double x, double y) {
    gboolean horizontal = FALSE;
    double low = 0, high = 0, across = 0;
    if (!tailscode_paned_gap(paned, &horizontal, &low, &high, &across)) return FALSE;
    double point = horizontal ? x : y;
    return point >= low - 4.0 && point <= high + 4.0;
}

/// Counts the presses itself rather than trusting `n_press`: the child under a thin handle claims
/// the sequence on the first press, which cancels this gesture and resets GTK's own count, so a
/// second press on the same spot inside the desktop's double-click time is the signal.
static void tailscode_paned_double_click_pressed(
    GtkGestureClick *gesture, gint n_press, gdouble x, gdouble y, gpointer raw) {
    (void)n_press;
    GtkWidget *widget = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(gesture));
    if (!widget || !GTK_IS_PANED(widget)) return;
    if (!tailscode_point_in_paned_handle(GTK_PANED(widget), x, y)) return;
    gboolean horizontal =
        gtk_orientable_get_orientation(GTK_ORIENTABLE(widget)) == GTK_ORIENTATION_HORIZONTAL;
    double point = horizontal ? x : y;
    guint32 now = gtk_event_controller_get_current_event_time(GTK_EVENT_CONTROLLER(gesture));
    int interval = 400;
    GtkSettings *settings = gtk_widget_get_settings(widget);
    if (settings) g_object_get(settings, "gtk-double-click-time", &interval, NULL);
    TailscodePanedClick *box = raw;
    gboolean again = box->last_press != 0 && now > box->last_press
        && now - box->last_press <= (guint32)interval && ABS(point - box->last_point) <= 8.0;
    box->last_press = now;
    box->last_point = point;
    if (!again) return;
    box->last_press = 0;
    gtk_gesture_set_state(GTK_GESTURE(gesture), GTK_EVENT_SEQUENCE_CLAIMED);
    box->handler(box->data);
}

void tailscode_on_paned_handle_double_click(
    GtkWidget *paned, void (*handler)(void *), void *data) {
    TailscodePanedClick *box = g_new0(TailscodePanedClick, 1);
    box->handler = handler;
    box->data = data;
    GtkGesture *click = gtk_gesture_click_new();
    gtk_event_controller_set_propagation_phase(GTK_EVENT_CONTROLLER(click), GTK_PHASE_CAPTURE);
    g_signal_connect_data(click, "pressed", G_CALLBACK(tailscode_paned_double_click_pressed), box,
                          (GClosureNotify)(void (*)(void))g_free, 0);
    gtk_widget_add_controller(paned, GTK_EVENT_CONTROLLER(click));
}

typedef struct {
    void (*handler)(double x, double y, void *);
    void *data;
} TailscodePress;

static void tailscode_right_click_pressed(
    GtkGestureClick *gesture, gint n_press, gdouble x, gdouble y, gpointer raw) {
    (void)n_press; (void)x; (void)y; (void)raw;
    gtk_gesture_set_state(GTK_GESTURE(gesture), GTK_EVENT_SEQUENCE_CLAIMED);
}

static void tailscode_right_click_released(
    GtkGestureClick *gesture, gint n_press, gdouble x, gdouble y, gpointer raw) {
    (void)gesture; (void)n_press;
    TailscodePress *box = raw;
    box->handler(x, y, box->data);
}

void tailscode_on_right_click(
    GtkWidget *widget, void (*handler)(double x, double y, void *), void *data) {
    TailscodePress *box = g_new0(TailscodePress, 1);
    box->handler = handler;
    box->data = data;
    GtkGesture *click = gtk_gesture_click_new();
    gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(click), GDK_BUTTON_SECONDARY);
    g_signal_connect_data(click, "pressed", G_CALLBACK(tailscode_right_click_pressed), NULL,
                          NULL, 0);
    g_signal_connect_data(click, "released", G_CALLBACK(tailscode_right_click_released), box,
                          (GClosureNotify)(void (*)(void))g_free, 0);
    gtk_widget_add_controller(widget, GTK_EVENT_CONTROLLER(click));
}

char *tailscode_label_selection(GtkWidget *widget) {
    if (!widget || !GTK_IS_LABEL(widget)) return NULL;
    int start = 0, end = 0;
    if (!gtk_label_get_selection_bounds(GTK_LABEL(widget), &start, &end)) return NULL;
    const char *text = gtk_label_get_text(GTK_LABEL(widget));
    if (!text) return NULL;
    return g_utf8_substring(text, start, end);
}

gboolean tailscode_label_has_selection(GtkWidget *widget) {
    if (!widget || !GTK_IS_LABEL(widget)) return FALSE;
    int start = 0, end = 0;
    return gtk_label_get_selection_bounds(GTK_LABEL(widget), &start, &end);
}

gboolean tailscode_animations_enabled(void) {
    GtkSettings *settings = gtk_settings_get_default();
    if (!settings) return TRUE;
    gboolean enabled = TRUE;
    g_object_get(settings, "gtk-enable-animations", &enabled, NULL);
    return enabled;
}

typedef struct {
    void (*handler)(void *);
    void *data;
} TailscodeTick;

static gboolean tailscode_tick_trampoline(
    GtkWidget *widget, GdkFrameClock *clock, gpointer raw) {
    (void)widget;
    (void)clock;
    TailscodeTick *box = raw;
    box->handler(box->data);
    return G_SOURCE_CONTINUE;
}

static void tailscode_tick_free(gpointer raw) { g_free(raw); }

guint tailscode_add_tick(GtkWidget *widget, void (*handler)(void *), void *data) {
    if (!widget) return 0;
    TailscodeTick *box = g_new0(TailscodeTick, 1);
    box->handler = handler;
    box->data = data;
    return gtk_widget_add_tick_callback(
        widget, tailscode_tick_trampoline, box, tailscode_tick_free);
}

void tailscode_remove_tick(GtkWidget *widget, guint id) {
    if (!widget || id == 0) return;
    gtk_widget_remove_tick_callback(widget, id);
}

/// Prose wraps at the pane's width, and a label that stops wrapping runs off the edge of the
/// window. Setting a label's text is not supposed to disturb that, but the reveal sets it a
/// hundred times a second and one silent reset is a paragraph nobody can read — so the properties
/// the transcript depends on are restated rather than assumed.
static void tailscode_label_keep_wrapping(GtkLabel *label) {
    gtk_label_set_wrap(label, TRUE);
    gtk_label_set_wrap_mode(label, PANGO_WRAP_WORD_CHAR);
    gtk_label_set_ellipsize(label, PANGO_ELLIPSIZE_NONE);
    gtk_label_set_xalign(label, 0);
    gtk_label_set_max_width_chars(label, -1);
}

/// One live row at a time, so one parse is all the cache ever has to hold. Re-rendering markdown
/// and re-parsing markup on every frame was the cost that made a smooth reveal stutter; this makes
/// a frame a substring and an attribute list.
static char *tailscode_reveal_markup = NULL;
static char *tailscode_reveal_text = NULL;
static PangoAttrList *tailscode_reveal_attrs = NULL;

static gboolean tailscode_reveal_parse(const char *markup) {
    if (tailscode_reveal_markup && strcmp(tailscode_reveal_markup, markup) == 0) return TRUE;
    PangoAttrList *attrs = NULL;
    char *text = NULL;
    if (!pango_parse_markup(markup, -1, 0, &attrs, &text, NULL, NULL)) return FALSE;
    g_free(tailscode_reveal_markup);
    g_free(tailscode_reveal_text);
    if (tailscode_reveal_attrs) pango_attr_list_unref(tailscode_reveal_attrs);
    tailscode_reveal_markup = g_strdup(markup);
    tailscode_reveal_text = text;
    tailscode_reveal_attrs = attrs;
    return TRUE;
}

const char *tailscode_markup_text(const char *markup) {
    if (!markup || !tailscode_reveal_parse(markup)) return NULL;
    return tailscode_reveal_text;
}

int tailscode_label_reveal(
    GtkWidget *label, const char *markup, int visible, int wave,
    const unsigned int *rgb, const unsigned short *alpha) {
    if (!label || !GTK_IS_LABEL(label) || !markup) return -1;
    if (visible < 0) {
        gtk_label_set_attributes(GTK_LABEL(label), NULL);
        gtk_label_set_markup(GTK_LABEL(label), markup);
        tailscode_label_keep_wrapping(GTK_LABEL(label));
        return -1;
    }
    if (!tailscode_reveal_parse(markup)) return -1;

    /* The whole arrived paragraph is laid out; only its colours change per frame. Setting a
       label's text inside the frame clock's update phase measures it against the previous frame's
       allocation, so a reveal that re-set the text every frame wrapped at a stale width and ran
       off the pane. Text once, attributes many. */
    const char *shown = gtk_label_get_text(GTK_LABEL(label));
    if (!shown || strcmp(shown, tailscode_reveal_text) != 0) {
        gtk_label_set_text(GTK_LABEL(label), tailscode_reveal_text);
        tailscode_label_keep_wrapping(GTK_LABEL(label));
    }

    int total = (int)g_utf8_strlen(tailscode_reveal_text, -1);
    int seen = CLAMP(visible, 0, total);
    const char *edge = g_utf8_offset_to_pointer(tailscode_reveal_text, seen);

    PangoAttrList *list = pango_attr_list_copy(tailscode_reveal_attrs);
    if (seen < total) {
        PangoAttribute *hidden = pango_attr_foreground_alpha_new(1);
        hidden->start_index = (guint)(edge - tailscode_reveal_text);
        hidden->end_index = G_MAXUINT;
        pango_attr_list_insert(list, hidden);
    }
    if (wave > 0 && rgb && alpha) {
        const char *cursor = edge;
        for (int index = 0; index < wave; index++) {
            const char *previous = g_utf8_find_prev_char(tailscode_reveal_text, cursor);
            if (!previous) break;
            guint start = (guint)(previous - tailscode_reveal_text);
            guint end = (guint)(cursor - tailscode_reveal_text);
            unsigned int colour = rgb[index];
            PangoAttribute *foreground = pango_attr_foreground_new(
                (guint16)(((colour >> 16) & 0xff) * 257),
                (guint16)(((colour >> 8) & 0xff) * 257),
                (guint16)((colour & 0xff) * 257));
            foreground->start_index = start;
            foreground->end_index = end;
            pango_attr_list_insert(list, foreground);
            unsigned short opacity = alpha[index] < 1 ? 1 : alpha[index];
            if (opacity < 65535) {
                PangoAttribute *fade = pango_attr_foreground_alpha_new((guint16)opacity);
                fade->start_index = start;
                fade->end_index = end;
                pango_attr_list_insert(list, fade);
            }
            cursor = previous;
        }
    }
    gtk_label_set_attributes(GTK_LABEL(label), list);
    pango_attr_list_unref(list);
    return total;
}

#ifdef TAILSCODE_HAS_MPV
#include <epoxy/egl.h>
#include <epoxy/gl.h>
#include <locale.h>
#include <epoxy/glx.h>
#include <mpv/client.h>
#include <mpv/render_gl.h>

struct TailscodeMpv {
    mpv_handle *mpv;
    mpv_render_context *render;
    GtkWidget *area;
    void (*event)(void *user, const char *kind, const char *text);
    void *user;
    gboolean disposed;
    gboolean playing;
    guint pending_render;
    guint pending_events;
};

gboolean tailscode_mpv_available(void) { return TRUE; }

static const char *tailscode_mpv_error = "";

const char *tailscode_mpv_last_error(void) { return tailscode_mpv_error; }

/// libepoxy keeps its own resolver private, so the address comes from whichever backend GTK
/// actually opened — EGL under Wayland, GLX under X11.
static void *tailscode_mpv_proc(void *ctx, const char *name) {
    (void)ctx;
    void *address = NULL;
    if (epoxy_has_egl()) address = (void *)eglGetProcAddress(name);
    if (!address) address = (void *)glXGetProcAddressARB((const GLubyte *)name);
    return address;
}

static gboolean tailscode_mpv_queue_render(gpointer raw) {
    TailscodeMpv *player = raw;
    player->pending_render = 0;
    if (!player->disposed && player->area) {
        gtk_gl_area_queue_render(GTK_GL_AREA(player->area));
    }
    return G_SOURCE_REMOVE;
}

/// mpv asks for a frame from its own thread. One idle at a time is enough — a second request
/// before the first has drawn is the same request — and it leaves nothing queued against a player
/// that is being torn down.
static void tailscode_mpv_update(void *raw) {
    TailscodeMpv *player = raw;
    if (player->disposed || player->pending_render) return;
    player->pending_render =
        g_idle_add_full(G_PRIORITY_HIGH, tailscode_mpv_queue_render, player, NULL);
}

static void tailscode_mpv_report(TailscodeMpv *player, const char *kind, const char *text) {
    if (player->event && !player->disposed) {
        player->event(player->user, kind, text ? text : "");
    }
}

static gboolean tailscode_mpv_drain(gpointer raw) {
    TailscodeMpv *player = raw;
    player->pending_events = 0;
    if (player->disposed || !player->mpv) return G_SOURCE_REMOVE;
    while (1) {
        mpv_event *event = mpv_wait_event(player->mpv, 0);
        if (!event || event->event_id == MPV_EVENT_NONE) break;
        switch (event->event_id) {
        case MPV_EVENT_FILE_LOADED:
            tailscode_mpv_report(player, "loaded", NULL);
            break;
        case MPV_EVENT_END_FILE: {
            mpv_event_end_file *end = event->data;
            if (end && end->reason == MPV_END_FILE_REASON_ERROR) {
                tailscode_mpv_report(player, "error", mpv_error_string(end->error));
            } else {
                tailscode_mpv_report(player, "end", NULL);
            }
            break;
        }
        case MPV_EVENT_PROPERTY_CHANGE: {
            mpv_event_property *property = event->data;
            if (!property || !property->data) break;
            if (property->format == MPV_FORMAT_STRING) {
                tailscode_mpv_report(player, "title", *(char **)property->data);
            } else if (property->format == MPV_FORMAT_FLAG) {
                int flag = *(int *)property->data;
                tailscode_mpv_report(player, property->name, flag ? "1" : "0");
            }
            break;
        }
        default:
            break;
        }
    }
    return G_SOURCE_REMOVE;
}

static void tailscode_mpv_wakeup(void *raw) {
    TailscodeMpv *player = raw;
    if (player->disposed || player->pending_events) return;
    player->pending_events = g_idle_add(tailscode_mpv_drain, player);
}

/// The tiling rebuilds its widget tree whenever a pane opens or closes, and GTK unrealizes every
/// pane's contents to do it — the GL context this pane was drawing into is gone by the time it
/// comes back. So the render context is rebuilt against the new one and the video chain is
/// re-selected: without that kick mpv keeps decoding into an output that no longer exists, and the
/// pane stays black for the rest of the stream.
static void tailscode_mpv_realize(GtkGLArea *area, gpointer raw) {
    TailscodeMpv *player = raw;
    gtk_gl_area_make_current(area);
    if (gtk_gl_area_get_error(area) != NULL) {
        tailscode_mpv_report(player, "error", "no OpenGL in this pane");
        return;
    }
    if (player->render) {
        mpv_render_context_set_update_callback(player->render, NULL, NULL);
        mpv_render_context_free(player->render);
        player->render = NULL;
    }
    mpv_opengl_init_params gl = {.get_proc_address = tailscode_mpv_proc};
    int advanced = 0;
    mpv_render_param params[] = {
        {MPV_RENDER_PARAM_API_TYPE, (void *)MPV_RENDER_API_TYPE_OPENGL},
        {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &gl},
        {MPV_RENDER_PARAM_ADVANCED_CONTROL, &advanced},
        {0, NULL}};
    if (mpv_render_context_create(&player->render, player->mpv, params) < 0) {
        player->render = NULL;
        tailscode_mpv_report(player, "error", "mpv could not use this pane's OpenGL");
        return;
    }
    mpv_render_context_set_update_callback(player->render, tailscode_mpv_update, player);
    if (player->playing) {
        mpv_set_property_string(player->mpv, "vid", "no");
        mpv_set_property_string(player->mpv, "vid", "auto");
    }
}

static gboolean tailscode_mpv_render(GtkGLArea *area, GdkGLContext *context, gpointer raw) {
    (void)context;
    TailscodeMpv *player = raw;
    if (!player->render) return FALSE;
    int scale = gtk_widget_get_scale_factor(GTK_WIDGET(area));
    int width = gtk_widget_get_width(GTK_WIDGET(area)) * scale;
    int height = gtk_widget_get_height(GTK_WIDGET(area)) * scale;
    if (width <= 0 || height <= 0) return TRUE;
    GLint fbo = 0;
    glGetIntegerv(GL_FRAMEBUFFER_BINDING, &fbo);
    mpv_opengl_fbo target = {.fbo = (int)fbo, .w = width, .h = height};
    int flip = 1;
    mpv_render_param params[] = {
        {MPV_RENDER_PARAM_OPENGL_FBO, &target},
        {MPV_RENDER_PARAM_FLIP_Y, &flip},
        {0, NULL}};
    mpv_render_context_render(player->render, params);
    return TRUE;
}

TailscodeMpv *tailscode_mpv_new(
    void (*event)(void *user, const char *kind, const char *text), void *user) {
    TailscodeMpv *player = g_new0(TailscodeMpv, 1);
    player->event = event;
    player->user = user;
    /// libmpv refuses to start under a locale whose decimal separator is not a dot, and GTK sets
    /// the process locale from the environment before this runs.
    setlocale(LC_NUMERIC, "C");
    player->mpv = mpv_create();
    if (!player->mpv) {
        tailscode_mpv_error = "mpv could not be created";
        g_free(player);
        return NULL;
    }
    mpv_set_option_string(player->mpv, "terminal", "no");
    mpv_set_option_string(player->mpv, "msg-level", "all=no");
    mpv_set_option_string(player->mpv, "vo", "libmpv");
    mpv_set_option_string(player->mpv, "hwdec", "auto-safe");
    mpv_set_option_string(player->mpv, "ytdl", "yes");
    mpv_set_option_string(
        player->mpv, "ytdl-format",
        "bestvideo[height<=?1080]+bestaudio/best[height<=?1080]/best");
    mpv_set_option_string(player->mpv, "idle", "yes");
    mpv_set_option_string(player->mpv, "keep-open", "no");
    mpv_set_option_string(player->mpv, "cache", "yes");
    mpv_set_option_string(player->mpv, "input-default-bindings", "no");
    mpv_set_option_string(player->mpv, "input-vo-keyboard", "no");
    mpv_set_option_string(player->mpv, "osc", "no");
    int started = mpv_initialize(player->mpv);
    if (started < 0) {
        tailscode_mpv_error = mpv_error_string(started);
        mpv_destroy(player->mpv);
        g_free(player);
        return NULL;
    }
    mpv_observe_property(player->mpv, 0, "media-title", MPV_FORMAT_STRING);
    mpv_observe_property(player->mpv, 0, "pause", MPV_FORMAT_FLAG);
    mpv_observe_property(player->mpv, 0, "mute", MPV_FORMAT_FLAG);
    mpv_set_wakeup_callback(player->mpv, tailscode_mpv_wakeup, player);

    player->area = gtk_gl_area_new();
    gtk_gl_area_set_has_depth_buffer(GTK_GL_AREA(player->area), FALSE);
    gtk_gl_area_set_has_stencil_buffer(GTK_GL_AREA(player->area), FALSE);
    gtk_widget_set_hexpand(player->area, TRUE);
    gtk_widget_set_vexpand(player->area, TRUE);
    g_signal_connect(player->area, "realize", G_CALLBACK(tailscode_mpv_realize), player);
    g_signal_connect(player->area, "render", G_CALLBACK(tailscode_mpv_render), player);
    return player;
}

GtkWidget *tailscode_mpv_area(TailscodeMpv *player) { return player ? player->area : NULL; }

void tailscode_mpv_play(TailscodeMpv *player, const char *url) {
    if (!player || !player->mpv) return;
    const char *command[] = {"loadfile", url, "replace", NULL};
    mpv_command_async(player->mpv, 0, (const char **)command);
    player->playing = TRUE;
}

void tailscode_mpv_command(TailscodeMpv *player, const char *const *args) {
    if (!player || !player->mpv || !args) return;
    mpv_command_async(player->mpv, 0, (const char **)args);
}

gboolean tailscode_mpv_flag(TailscodeMpv *player, const char *name) {
    if (!player || !player->mpv) return FALSE;
    int value = 0;
    if (mpv_get_property(player->mpv, name, MPV_FORMAT_FLAG, &value) < 0) return FALSE;
    return value ? TRUE : FALSE;
}

/// Teardown in the only order that is safe: stop mpv calling back, take the widget out of the
/// tree so GTK can never render into a dead player, free the GL objects while their context is
/// still current, and only then let mpv go.
void tailscode_mpv_free(TailscodeMpv *player) {
    if (!player) return;
    player->disposed = TRUE;
    player->event = NULL;
    if (player->render) mpv_render_context_set_update_callback(player->render, NULL, NULL);
    if (player->mpv) mpv_set_wakeup_callback(player->mpv, NULL, NULL);
    if (player->pending_render) {
        g_source_remove(player->pending_render);
        player->pending_render = 0;
    }
    if (player->pending_events) {
        g_source_remove(player->pending_events);
        player->pending_events = 0;
    }
    GtkWidget *area = player->area;
    player->area = NULL;
    if (area) {
        g_signal_handlers_disconnect_by_data(area, player);
        if (player->render && gtk_widget_get_realized(area)) {
            gtk_gl_area_make_current(GTK_GL_AREA(area));
        }
    }
    if (player->render) {
        mpv_render_context_free(player->render);
        player->render = NULL;
    }
    if (area && gtk_widget_get_parent(area)) gtk_widget_unparent(area);
    if (player->mpv) {
        mpv_destroy(player->mpv);
        player->mpv = NULL;
    }
    g_free(player);
}

#else

gboolean tailscode_mpv_available(void) { return FALSE; }

const char *tailscode_mpv_last_error(void) { return "this build has no libmpv"; }

TailscodeMpv *tailscode_mpv_new(
    void (*event)(void *user, const char *kind, const char *text), void *user) {
    (void)event;
    (void)user;
    return NULL;
}

GtkWidget *tailscode_mpv_area(TailscodeMpv *player) {
    (void)player;
    return NULL;
}

void tailscode_mpv_play(TailscodeMpv *player, const char *url) {
    (void)player;
    (void)url;
}

void tailscode_mpv_command(TailscodeMpv *player, const char *const *args) {
    (void)player;
    (void)args;
}

gboolean tailscode_mpv_flag(TailscodeMpv *player, const char *name) {
    (void)player;
    (void)name;
    return FALSE;
}

void tailscode_mpv_free(TailscodeMpv *player) { (void)player; }

#endif

#ifdef TAILSCODE_HAS_WEBKIT
#include <webkit/webkit.h>

struct TailscodeWeb {
    WebKitWebView *view;
    void (*event)(void *user, const char *kind, const char *text);
    void *user;
    gboolean disposed;
};

gboolean tailscode_web_available(void) { return TRUE; }

static void tailscode_web_report(TailscodeWeb *web, const char *kind, const char *text) {
    if (web->event && !web->disposed) web->event(web->user, kind, text ? text : "");
}

static void tailscode_web_history(TailscodeWeb *web) {
    char state[8];
    g_snprintf(
        state, sizeof state, "%d%d", webkit_web_view_can_go_back(web->view) ? 1 : 0,
        webkit_web_view_can_go_forward(web->view) ? 1 : 0);
    tailscode_web_report(web, "history", state);
}

static void tailscode_web_notify_title(GObject *object, GParamSpec *spec, gpointer raw) {
    (void)object;
    (void)spec;
    TailscodeWeb *web = raw;
    tailscode_web_report(web, "title", webkit_web_view_get_title(web->view));
}

static void tailscode_web_notify_uri(GObject *object, GParamSpec *spec, gpointer raw) {
    (void)object;
    (void)spec;
    TailscodeWeb *web = raw;
    tailscode_web_report(web, "uri", webkit_web_view_get_uri(web->view));
    tailscode_web_history(web);
}

static void tailscode_web_notify_progress(GObject *object, GParamSpec *spec, gpointer raw) {
    (void)object;
    (void)spec;
    TailscodeWeb *web = raw;
    char fraction[16];
    g_ascii_formatd(
        fraction, sizeof fraction, "%.3f", webkit_web_view_get_estimated_load_progress(web->view));
    tailscode_web_report(web, "progress", fraction);
}

static gboolean tailscode_web_failed(
    WebKitWebView *view, WebKitLoadEvent event, gchar *uri, GError *error, gpointer raw) {
    (void)view;
    (void)event;
    (void)uri;
    TailscodeWeb *web = raw;
    if (error && error->code == WEBKIT_NETWORK_ERROR_CANCELLED) return FALSE;
    tailscode_web_report(web, "error", error ? error->message : "that page would not open");
    return FALSE;
}

static void tailscode_web_load_changed(
    WebKitWebView *view, WebKitLoadEvent event, gpointer raw) {
    (void)view;
    TailscodeWeb *web = raw;
    if (event == WEBKIT_LOAD_FINISHED) {
        tailscode_web_report(web, "progress", "1");
        tailscode_web_report(web, "title", webkit_web_view_get_title(web->view));
        tailscode_web_history(web);
    }
}

TailscodeWeb *tailscode_web_new(
    void (*event)(void *user, const char *kind, const char *text), void *user) {
    TailscodeWeb *web = g_new0(TailscodeWeb, 1);
    web->event = event;
    web->user = user;
    web->view = WEBKIT_WEB_VIEW(webkit_web_view_new());
    if (!web->view) {
        g_free(web);
        return NULL;
    }
    WebKitSettings *settings = webkit_web_view_get_settings(web->view);
    webkit_settings_set_enable_developer_extras(settings, TRUE);
    webkit_settings_set_enable_smooth_scrolling(settings, TRUE);
    webkit_settings_set_enable_webgl(settings, TRUE);
    webkit_settings_set_media_playback_requires_user_gesture(settings, FALSE);
    webkit_settings_set_javascript_can_open_windows_automatically(settings, FALSE);
    webkit_settings_set_hardware_acceleration_policy(
        settings, WEBKIT_HARDWARE_ACCELERATION_POLICY_ALWAYS);

    gtk_widget_set_hexpand(GTK_WIDGET(web->view), TRUE);
    gtk_widget_set_vexpand(GTK_WIDGET(web->view), TRUE);
    g_signal_connect(web->view, "notify::title", G_CALLBACK(tailscode_web_notify_title), web);
    g_signal_connect(web->view, "notify::uri", G_CALLBACK(tailscode_web_notify_uri), web);
    g_signal_connect(
        web->view, "notify::estimated-load-progress",
        G_CALLBACK(tailscode_web_notify_progress), web);
    g_signal_connect(web->view, "load-failed", G_CALLBACK(tailscode_web_failed), web);
    g_signal_connect(web->view, "load-changed", G_CALLBACK(tailscode_web_load_changed), web);
    return web;
}

GtkWidget *tailscode_web_widget(TailscodeWeb *web) {
    return web ? GTK_WIDGET(web->view) : NULL;
}

void tailscode_web_load(TailscodeWeb *web, const char *uri) {
    if (!web || !uri) return;
    webkit_web_view_load_uri(web->view, uri);
}

void tailscode_web_verb(TailscodeWeb *web, const char *verb) {
    if (!web || !verb) return;
    if (g_strcmp0(verb, "back") == 0 && webkit_web_view_can_go_back(web->view)) {
        webkit_web_view_go_back(web->view);
    } else if (g_strcmp0(verb, "forward") == 0 && webkit_web_view_can_go_forward(web->view)) {
        webkit_web_view_go_forward(web->view);
    } else if (g_strcmp0(verb, "reload") == 0) {
        webkit_web_view_reload(web->view);
    } else if (g_strcmp0(verb, "stop") == 0) {
        webkit_web_view_stop_loading(web->view);
    }
}

void tailscode_web_zoom(TailscodeWeb *web, double level) {
    if (!web) return;
    webkit_web_view_set_zoom_level(web->view, level);
}

void tailscode_web_free(TailscodeWeb *web) {
    if (!web) return;
    web->disposed = TRUE;
    web->event = NULL;
    if (web->view) {
        GtkWidget *widget = GTK_WIDGET(web->view);
        g_signal_handlers_disconnect_by_data(web->view, web);
        webkit_web_view_stop_loading(web->view);
        web->view = NULL;
        if (gtk_widget_get_parent(widget)) gtk_widget_unparent(widget);
    }
    g_free(web);
}

#else

gboolean tailscode_web_available(void) { return FALSE; }

TailscodeWeb *tailscode_web_new(
    void (*event)(void *user, const char *kind, const char *text), void *user) {
    (void)event;
    (void)user;
    return NULL;
}

GtkWidget *tailscode_web_widget(TailscodeWeb *web) {
    (void)web;
    return NULL;
}

void tailscode_web_load(TailscodeWeb *web, const char *uri) {
    (void)web;
    (void)uri;
}

void tailscode_web_verb(TailscodeWeb *web, const char *verb) {
    (void)web;
    (void)verb;
}

void tailscode_web_zoom(TailscodeWeb *web, double level) {
    (void)web;
    (void)level;
}

void tailscode_web_free(TailscodeWeb *web) { (void)web; }

#endif
