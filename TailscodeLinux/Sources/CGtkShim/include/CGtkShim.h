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

/// Decodes image bytes into a texture the app can keep and reuse across renders. NULL when the
/// bytes are not a decodable image. The caller owns the returned reference.
GdkTexture *tailscode_texture_from_bytes(const void *data, gsize len);

/// A picture widget over a texture, sized to fit its own allocation. `GDK_PAINTABLE` is a macro,
/// which is why the cast lives here.
GtkWidget *tailscode_picture_for_texture(GdkTexture *texture);

/// The texture's pixel size, for captioning a picture with what it actually is.
int tailscode_texture_width(GdkTexture *texture);
int tailscode_texture_height(GdkTexture *texture);

/// Opens the file chooser and calls back with the chosen absolute paths — an empty call when the
/// person cancelled. `GtkFileDialog` is GAsyncResult-shaped, which Swift cannot complete without
/// the `GTK_FILE_DIALOG` macro cast; the whole exchange lives here and the callback runs on the
/// GLib main context.
void tailscode_file_open(
    GtkWindow *parent, void (*handler)(const char *const *paths, int count, void *data),
    void *data);

/// Opens the desktop's own folder chooser — the portal decides what "native" means — and calls
/// back with the chosen absolute path, or NULL when the person cancelled. Same GAsyncResult
/// shape as `tailscode_file_open`, same rule: the callback runs on the GLib main context.
void tailscode_select_folder(
    GtkWindow *parent, const char *initial,
    void (*handler)(const char *path, void *data), void *data);

/// Reads the clipboard as an image and calls back with PNG bytes, or with NULL when the clipboard
/// holds no picture. Same GAsyncResult shape, same rule: the callback runs on the main context and
/// the bytes are only valid inside it.
void tailscode_clipboard_read_image(
    void (*handler)(const void *bytes, gsize len, void *data), void *data);

/// The widget's vertical offset inside `ancestor`, or -1 when the two are not connected — what a
/// scroll-to-row needs from graphene without importing it.
double tailscode_widget_offset_y(GtkWidget *widget, GtkWidget *ancestor);

/// Scales every font in the app by setting `gtk-xft-dpi` (which is 1024ths of a DPI, hence the
/// shim: the property write is a varargs `g_object_set`).
void tailscode_set_text_scale(double scale);

/// The widget that currently holds focus inside `root`, or NULL — how a key handler tells the
/// prompt box apart from the search field without guessing from the event.
GtkWidget *tailscode_focused_widget(GtkWidget *root);

/// Accepts files dropped on `widget` and calls back with their paths. The drop payload is a
/// `GdkFileList` inside a `GValue`, neither of which Swift can unbox, so the whole exchange is C.
void tailscode_accept_file_drops(
    GtkWidget *widget, void (*handler)(const char *const *paths, int count, void *data),
    void *data);

/// Watches a GObject property. `notify::` signals carry a GParamSpec the two-argument trampoline
/// cannot marshal, so property watching gets its own three-argument trampoline here.
void tailscode_connect_notify(
    gpointer instance, const char *property, void (*handler)(void *), void *data);

/// Runs `handler(data)` once on the GLib main context after `ms` milliseconds — the timed cousin
/// of `tailscode_on_main`, with the same ownership rule.
void tailscode_after(guint ms, void (*handler)(void *), void *data);
void tailscode_on_release(GtkWidget *widget, void (*handler)(void *), void *data);

/// A right click on `widget`, with where it landed in the widget's own coordinates. The gesture
/// claims the sequence on press so the widget underneath does not also treat it as a click, but
/// the handler fires on release: a popover popped up mid-press grabs the pointer, and the release
/// would land on whichever menu item the popover placed under it — a visible flash of a button
/// nobody chose.
void tailscode_on_right_click(
    GtkWidget *widget, void (*handler)(double x, double y, void *), void *data);
char *tailscode_label_selection(GtkWidget *widget);
gboolean tailscode_label_has_selection(GtkWidget *widget);
