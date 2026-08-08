#pragma once
#include <adwaita.h>
#include <gtk/gtk.h>
#include <glib.h>

/// Signal connection and idle scheduling that Swift cannot reach on its own: `g_signal_connect`
/// is a macro, and `g_idle_add` takes a varargs-free but GSourceFunc-shaped callback whose
/// lifetime rules are easier to get right in C than through an imported function pointer.
void tailscode_connect(gpointer instance, const char *signal, GCallback handler, gpointer data);

/// How the shim lets go of a Swift closure a signal was holding. Registered once at startup; the
/// closure is released when GObject finishes with the connection, which is the only moment at
/// which the handler is provably never called again.
void tailscode_set_box_release(void (*release)(void *));

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

/// Decodes image bytes into a texture at most `max_dim` pixels on its long side, so a transcript
/// bubble — a thumbnail at 220×140 — does not pin a full-resolution screenshot in VRAM. The
/// original pixel size is reported back for the caption and the gallery's 1:1 zoom, whose
/// texture the gallery decodes separately, one page at a time. NULL when the bytes are not a
/// decodable image; the caller owns the returned reference.
GdkTexture *tailscode_texture_scaled(
    const void *data, gsize len, int max_dim, int *out_orig_w, int *out_orig_h);

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

/// Names a control for assistive technology. A button whose only child is a glyph has nothing an
/// AT can read, and `gtk_accessible_update_property` is variadic, so it cannot be called from
/// Swift directly.
void tailscode_set_accessible_label(GtkWidget *widget, const char *label);

/// The widget that currently holds focus inside `root`, or NULL — how a key handler tells the
/// prompt box apart from the search field without guessing from the event.
GtkWidget *tailscode_focused_widget(GtkWidget *root);

/// The widget's rectangle inside `ancestor` — the whole frame, where `tailscode_widget_offset_y`
/// answers only the top edge. False when the two are not connected.
gboolean tailscode_widget_bounds_in(
    GtkWidget *widget, GtkWidget *ancestor, double *x, double *y, double *width, double *height);

/// The private type a dragged chat travels as. A boxed string rather than `G_TYPE_STRING`: every
/// editable text view in the app accepts dropped text, so a public type would let a chat dragged
/// slightly wide of a pane land in a prompt box as pasted words.
GType tailscode_chat_ref_get_type(void);

/// Makes `widget` draggable, carrying `payload` under that private type and dragging a likeness
/// of the widget itself so the pointer holds the row it picked up.
void tailscode_make_chat_drag_source(GtkWidget *widget, const char *payload);

/// Accepts a dragged chat over `widget`: `motion` on every move inside it (with the payload, which
/// the target preloads so the highlight can name the chat before it lands), `leave` when the
/// pointer goes, and `drop` to take it. The payload lives inside a `GValue` Swift cannot unbox.
void tailscode_accept_chat_drops(
    GtkWidget *widget,
    void (*motion)(const char *payload, double x, double y, void *data),
    void (*leave)(void *data),
    gboolean (*drop)(const char *payload, double x, double y, void *data),
    void *data);

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

/// Any pointer button going down anywhere inside `widget`, with where it landed in `widget`'s own
/// coordinates. The gesture watches in the capture phase, which runs from the toplevel down before
/// any child sees the event, and never claims the sequence, so the text view still selects, the
/// button still fires and the scroller still drags. Watch the window rather than a subtree: a menu
/// button pops its popover on the press and the sequence never reaches an intermediate widget's
/// capture gesture at all. Watching every button rather than only the primary one means a right
/// click activates what it is about to open a menu on.
void tailscode_on_press_capture(
    GtkWidget *widget, void (*handler)(double x, double y, void *), void *data);

/// A double click on `paned`'s own handle — the gap between its two children, not anywhere in
/// them. The gesture watches in the capture phase so it sees the press before the paned's resize
/// drag does, and claims the sequence only for the second press on the handle, which leaves an
/// ordinary drag and every click inside a child untouched.
void tailscode_on_paned_handle_double_click(
    GtkWidget *paned, void (*handler)(void *), void *data);

/// The middle of that same handle in the paned's own coordinates — what the driver aims a real
/// pointer at, so the test and the gesture agree on where the divider is.
gboolean tailscode_paned_handle_center(GtkWidget *paned, double *x, double *y);

/// A right click on `widget`, with where it landed in the widget's own coordinates. The gesture
/// claims the sequence on press so the widget underneath does not also treat it as a click, but
/// the handler fires on release: a popover popped up mid-press grabs the pointer, and the release
/// would land on whichever menu item the popover placed under it — a visible flash of a button
/// nobody chose.
void tailscode_on_right_click(
    GtkWidget *widget, void (*handler)(double x, double y, void *), void *data);
char *tailscode_label_selection(GtkWidget *widget);
gboolean tailscode_label_has_selection(GtkWidget *widget);
/// Whether a widget is a label — the band tints the label inside a segment, whatever wrapped it.
gboolean tailscode_is_label(GtkWidget *widget);

/// The stream cascade, painted into a label from markup that is parsed once.
///
/// The whole arrived paragraph is laid out and everything past `visible` is drawn at zero alpha
/// rather than cut off — which is what makes the reveal read as writing rather than as a widget
/// resizing: the text is measured when it arrives and never again, so no glyph moves after it
/// lands and no line re-wraps under the reader. The last `wave` visible glyphs carry the
/// per-character colour and alpha the shared cascade computed. Returns the markup's total rendered
/// length, or -1 if it could not be parsed. A negative `visible` clears the wave and hands the
/// label the whole markup back.
int tailscode_label_reveal(
    GtkWidget *label, const char *markup, int visible, int wave,
    const unsigned int *rgb, const unsigned short *alpha);

/// The markup's rendered text — what a reader actually sees, with every marker already eaten.
/// The caller paces over this, so it has to be the same string the label will show. Owned by the
/// one-entry parse cache and valid until the next call with different markup.
const char *tailscode_markup_text(const char *markup);

/// A callback on the widget's own frame clock. A chained timeout drifts against the compositor and
/// lands two frames in one and none in the next, which is the stutter a cascade exists to remove;
/// the frame clock is what the screen is actually doing.
guint tailscode_add_tick(GtkWidget *widget, void (*handler)(void *), void *data);
void tailscode_remove_tick(GtkWidget *widget, guint id);

/// Whether the desktop wants motion at all. A person who has turned animations off has said what
/// they want from a cascade, and the answer is the text.
gboolean tailscode_animations_enabled(void);

/// The tailnet radar: a drawing area that shows a scan as a dial rather than a spinner. Every
/// number it draws comes from Core's `TailnetRadar` — the sweep's angle, the ping ring, and each
/// found machine's place and brightness — so the three clients search at one speed and put the
/// same machine in the same place. The area never takes input.
GtkWidget *tailscode_radar_new(void);

/// The four inks, as RGB triples in 0-1: the grid, then a machine that is ready, one that wants a
/// password, and one still being asked.
void tailscode_radar_ink(GtkWidget *area, const double *rgb, int colour_count);

/// One frame: the sweep's angle and light, the ping ring's radius and light, the fixed rings as
/// fractions of the dial, and the sparks as angle/radius/light/scale/tone quintuples.
void tailscode_radar_set(
    GtkWidget *area, double sweep, double sweep_light, double ping, double ping_light,
    const double *rings, int ring_count, const double *sparks, int spark_count);

/// The ultracode aura, drawn rather than themed: a drawing area to lay over the prompt box, whose
/// perimeter carries the rainbow round and round under a soft glow. A CSS gradient cannot travel
/// around a box — its angle sweeps across the whole rectangle, so the colour crosses the corners
/// instead of running along the edge — and reloading a provider every frame restyles the entire
/// display to repaint one border. The area never takes input.
GtkWidget *tailscode_aura_new(void);

/// One frame: where the rainbow's head sits (`phase`, wrapping at 1), how brightly the glow burns
/// (`glow`, 0–1), and the stops themselves as flat RGB triples in 0–1.
void tailscode_aura_set(
    GtkWidget *area, double phase, double glow, const double *rgb, int stop_count);

/// The presence orb's canvas: a GL area whose every frame is one metaball field rasterised by a
/// fragment shader. The shader draws exactly what Core's `PresenceField` handed over and adds
/// nothing — no motion, no colour choice, no state lives on this side. The area is transparent:
/// the creature is composited over whatever the sidebar draws, so it wears no box of its own.
/// A machine whose GL cannot compile the program reports not-ready and the area stays clear.
GtkWidget *tailscode_orb_new(void);
gboolean tailscode_orb_ready(GtkWidget *area);

/// One frame: blobs as x/y/radius/weight quads in the orb's unit space, the body ink as RGB in
/// 0–1, the breath (`intensity`), the glow budget (`energy`), and the ultracode rim (`rainbow`
/// 0–1 over the shared stops, head at `rainbow_phase`).
void tailscode_orb_set(
    GtkWidget *area, const float *blobs, int blob_count, const float *color, float energy,
    float intensity, float rainbow, float rainbow_phase, float rainbow_glow, const float *stops,
    int stop_count);

/// The video slot's player. libmpv draws into a GL area the pane owns, so a stream is a widget in
/// the split tree rather than a window floating over it — Wayland gives a client no way to place
/// an external window inside another, and a pane that cannot be tiled is not a pane. Compiled out
/// where libmpv is absent, which is what `tailscode_mpv_available` reports.
typedef struct TailscodeMpv TailscodeMpv;

gboolean tailscode_mpv_available(void);

/// Creates the player and its GL area. `event` is called on the main thread with a kind
/// ("loaded", "title", "end", "error", "pause", "mute") and the payload that goes with it.
TailscodeMpv *tailscode_mpv_new(
    void (*event)(void *user, const char *kind, const char *text), void *user);

/// Why the last `tailscode_mpv_new` came back NULL, in mpv's own words.
const char *tailscode_mpv_last_error(void);

GtkWidget *tailscode_mpv_area(TailscodeMpv *player);
void tailscode_mpv_play(TailscodeMpv *player, const char *url);

/// A NULL-terminated mpv command, exactly as `VideoCommand.mpvCommand` states it.
void tailscode_mpv_command(TailscodeMpv *player, const char *const *args);

gboolean tailscode_mpv_flag(TailscodeMpv *player, const char *name);
void tailscode_mpv_free(TailscodeMpv *player);

/// The browser slot's engine. WebKitGTK is a GtkWidget, so a page is a widget the tiling owns
/// exactly like the transcript beside it — no window to place, no process to reparent, and the
/// same compositor path the rest of the app draws through. Compiled out where it is absent, which
/// is what `tailscode_web_available` reports.
typedef struct TailscodeWeb TailscodeWeb;

gboolean tailscode_web_available(void);

/// Creates the web view. `event` is called on the main thread with a kind ("title", "uri",
/// "progress", "history", "error") and the payload that goes with it.
TailscodeWeb *tailscode_web_new(
    void (*event)(void *user, const char *kind, const char *text), void *user);

GtkWidget *tailscode_web_widget(TailscodeWeb *web);
void tailscode_web_load(TailscodeWeb *web, const char *uri);

/// One of "back", "forward", "reload", "stop".
void tailscode_web_verb(TailscodeWeb *web, const char *verb);
void tailscode_web_zoom(TailscodeWeb *web, double level);
void tailscode_web_free(TailscodeWeb *web);
