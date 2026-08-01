#pragma once
#include <adwaita.h>
#include <gtk/gtk.h>
#include <glib.h>

/// Signal connection and idle scheduling that Swift cannot reach on its own: `g_signal_connect`
/// is a macro, and `g_idle_add` takes a varargs-free but GSourceFunc-shaped callback whose
/// lifetime rules are easier to get right in C than through an imported function pointer.
void tailscode_connect(gpointer instance, const char *signal, GCallback handler, gpointer data);

/// Runs `handler(data)` once on the GLib main context, then frees nothing — the Swift side owns
/// `data` and releases it inside the handler.
void tailscode_on_main(void (*handler)(void *), void *data);

/// A `GtkListItemFactory` whose bind step calls back into Swift with the list item and the row's
/// position, which is all the transcript and the sidebar need.
GtkListItemFactory *tailscode_make_factory(
    void (*setup)(GtkListItem *, void *),
    void (*bind)(GtkListItem *, void *),
    void *data);

/// A key-press controller on `widget` forwarding to Swift. Returning true stops propagation, which
/// is how a normal-mode binding keeps a letter from reaching a text view.
void tailscode_connect_key(
    GtkWidget *widget, gboolean (*handler)(guint keyval, guint state, void *), void *data);

/// Whether the widget that currently has focus inside `root` is one that takes text.
gboolean tailscode_focus_is_editable(GtkWidget *root);
