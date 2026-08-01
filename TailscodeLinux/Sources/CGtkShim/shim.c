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
