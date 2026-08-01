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
