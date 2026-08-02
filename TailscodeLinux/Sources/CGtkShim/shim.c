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
