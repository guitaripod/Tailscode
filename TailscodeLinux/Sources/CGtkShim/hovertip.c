#include "CGtkShim.h"
#include <math.h>

/// How long the pointer must rest on a widget before its help appears, how long when help was on
/// screen a moment ago (sweeping along a toolbar reads one help after another without a pause),
/// and how long the fade takes either way. Short on purpose: help that makes you wait is help you
/// stop asking for.
enum {
    TIP_FIRST_MS = 220,
    TIP_BROWSE_MS = 40,
    TIP_BROWSE_WINDOW_MS = 800,
    TIP_FADE_MS = 130,
    TIP_LIFT_MS = 24,
    TIP_MOVE_SLOP = 8,
    TIP_BIG_WIDTH = 240,
    TIP_BIG_HEIGHT = 56,
};

typedef struct {
    GtkWidget *popover;
    GtkWidget *label;
    GtkWidget *owner;
    GtkWidget *candidate;
    GtkWidget *suppressed;
    guint show_timer;
    guint hide_timer;
    guint lift_timer;
    gint64 last_seen_us;
    gboolean lit;
    double armed_x, armed_y;
    double pointer_x, pointer_y;
} TailscodeTip;

static TailscodeTip tip;

int tailscode_tip_first_delay_ms(void) { return TIP_FIRST_MS; }
int tailscode_tip_browse_delay_ms(void) { return TIP_BROWSE_MS; }
int tailscode_tip_fade_ms(void) { return TIP_FADE_MS; }

static void tip_clear(guint *id) {
    if (*id) g_source_remove(*id);
    *id = 0;
}

/// Whether the desktop wants motion at all. With animations off the help is placed and removed
/// without waiting out a fade that would not be drawn.
static gboolean tip_animates(void) {
    gboolean on = TRUE;
    GtkSettings *settings = gtk_settings_get_default();
    if (settings) g_object_get(settings, "gtk-enable-animations", &on, NULL);
    return on;
}


/// Whether `widget` is something a person presses or flips: a button, a menu button, a switch or a
/// check. The toggle inside a menu button is the menu button's own part, not a control.
static gboolean tip_is_control(GtkWidget *widget) {
    GtkWidget *parent = gtk_widget_get_parent(widget);
    if (GTK_IS_BUTTON(widget) && parent && GTK_IS_MENU_BUTTON(parent)) return FALSE;
    return GTK_IS_BUTTON(widget) || GTK_IS_MENU_BUTTON(widget) || GTK_IS_SWITCH(widget) ||
           GTK_IS_CHECK_BUTTON(widget);
}

static void tip_count_letters(GtkWidget *widget, int *letters) {
    if (GTK_IS_LABEL(widget)) {
        const char *text = gtk_label_get_text(GTK_LABEL(widget));
        for (const char *at = text; at && *at; at = g_utf8_next_char(at))
            if (g_unichar_isalpha(g_utf8_get_char(at))) (*letters)++;
    }
    for (GtkWidget *child = gtk_widget_get_first_child(widget); child;
         child = gtk_widget_get_next_sibling(child)) {
        if (GTK_IS_POPOVER(child)) continue;
        tip_count_letters(child, letters);
    }
}

/// The preferences row a switch or an option sits in, which carries the title that names it.
static GtkWidget *tip_row_of(GtkWidget *widget) {
    for (GtkWidget *up = gtk_widget_get_parent(widget); up; up = gtk_widget_get_parent(up)) {
        const char *name = G_OBJECT_TYPE_NAME(up);
        if (g_str_has_prefix(name, "Adw") && strstr(name, "Row")) return up;
    }
    return NULL;
}

gboolean tailscode_tip_names_itself(GtkWidget *widget) {
    int letters = 0;
    tip_count_letters(widget, &letters);
    if (letters >= 3) return TRUE;
    if (GTK_IS_SWITCH(widget) || GTK_IS_CHECK_BUTTON(widget) || GTK_IS_TOGGLE_BUTTON(widget)) {
        GtkWidget *row = tip_row_of(widget);
        if (!row) row = gtk_widget_get_parent(widget);
        if (row) tip_count_letters(row, &letters);
    }
    return letters >= 3;
}

/// What `widget` says under the pointer: the words it was given, and failing those the name it
/// already carries for a screen reader — but only when it is a control wearing no sentence of its
/// own, because a button that reads "Cancel" gains nothing from a help that says "Cancel".
char *tailscode_tip_words(GtkWidget *widget) {
    const char *text = gtk_widget_get_tooltip_text(widget);
    if (text && *text) return g_strdup(text);
    if (!tip_is_control(widget) || tailscode_tip_names_itself(widget)) return NULL;
    const char *said = g_object_get_data(G_OBJECT(widget), "tailscode-accessible-label");
    return said && *said ? g_strdup(said) : NULL;
}

/// The one popover every help is drawn in, built on the first call and reparented to whichever
/// widget is being helped. It takes no pointer and no focus, so help never gets between the
/// pointer and what it is pointing at.
static GtkWidget *tip_popover(void) {
    if (tip.popover) return tip.popover;
    GtkWidget *label = gtk_label_new(NULL);
    gtk_label_set_wrap(GTK_LABEL(label), TRUE);
    gtk_label_set_wrap_mode(GTK_LABEL(label), PANGO_WRAP_WORD_CHAR);
    gtk_label_set_max_width_chars(GTK_LABEL(label), 44);
    gtk_label_set_xalign(GTK_LABEL(label), 0);
    gtk_label_set_selectable(GTK_LABEL(label), FALSE);
    gtk_widget_add_css_class(label, "hover-tip-text");
    gtk_widget_set_can_target(label, FALSE);
    GtkWidget *popover = gtk_popover_new();
    g_object_ref_sink(popover);
    gtk_popover_set_has_arrow(GTK_POPOVER(popover), FALSE);
    gtk_popover_set_autohide(GTK_POPOVER(popover), FALSE);
    gtk_popover_set_position(GTK_POPOVER(popover), GTK_POS_BOTTOM);
    gtk_popover_set_child(GTK_POPOVER(popover), label);
    gtk_widget_set_can_target(popover, FALSE);
    gtk_widget_set_can_focus(popover, FALSE);
    gtk_widget_set_focusable(popover, FALSE);
    gtk_widget_add_css_class(popover, "hover-tip");
    tip.popover = popover;
    tip.label = label;
    return popover;
}

/// Takes the help away at once and lets go of the widget it was parented to.
static void tip_drop(void) {
    tip_clear(&tip.show_timer);
    tip_clear(&tip.hide_timer);
    tip_clear(&tip.lift_timer);
    if (tip.popover && tip.owner) {
        gtk_widget_remove_css_class(tip.popover, "lit");
        if (gtk_widget_get_parent(tip.popover) == tip.owner) {
            gtk_popover_popdown(GTK_POPOVER(tip.popover));
            gtk_widget_unparent(tip.popover);
        }
    }
    tip.owner = NULL;
    tip.lit = FALSE;
}

static gboolean tip_hide_fired(gpointer data) {
    (void)data;
    tip.hide_timer = 0;
    if (tailscode_is_quitting()) return G_SOURCE_REMOVE;
    tip_drop();
    return G_SOURCE_REMOVE;
}

/// Starts the fade out; the popover goes once it is invisible. Showing again before then turns
/// the fade round.
static void tip_soft_hide(void) {
    tip_clear(&tip.show_timer);
    tip_clear(&tip.lift_timer);
    if (!tip.owner) return;
    if (tip.lit) tip.last_seen_us = g_get_monotonic_time();
    tip.lit = FALSE;
    gtk_widget_remove_css_class(tip.popover, "lit");
    if (!tip_animates()) {
        tip_drop();
        return;
    }
    if (!tip.hide_timer) tip.hide_timer = g_timeout_add(TIP_FADE_MS + 30, tip_hide_fired, NULL);
}

static gboolean tip_lift_fired(gpointer data) {
    (void)data;
    tip.lift_timer = 0;
    if (tailscode_is_quitting() || !tip.owner || !tip.popover) return G_SOURCE_REMOVE;
    gtk_widget_add_css_class(tip.popover, "lit");
    tip.lit = TRUE;
    return G_SOURCE_REMOVE;
}

static void tip_on_inactive(GObject *window, GParamSpec *spec, gpointer data) {
    (void)spec;
    (void)data;
    if (tailscode_is_quitting() || gtk_window_is_active(GTK_WINDOW(window))) return;
    tip.candidate = NULL;
    tip_drop();
}

/// Help is put away when the window it sits in is no longer the one being used, which is the
/// moment a pointer resting on a button stops meaning anything.
static void tip_watch_window(GtkWidget *widget) {
    GtkRoot *root = gtk_widget_get_root(widget);
    if (!root || !GTK_IS_WINDOW(root)) return;
    if (g_object_get_data(G_OBJECT(root), "tailscode-tip-window")) return;
    g_object_set_data(G_OBJECT(root), "tailscode-tip-window", GINT_TO_POINTER(1));
    g_signal_connect(root, "notify::is-active", G_CALLBACK(tip_on_inactive), NULL);
}

/// Where the help sits: under a small widget, centred on it; under the pointer for a big one — a
/// row, a card, a strip of chart — where the widget's own edge is nowhere near where the eye is.
static void tip_place(GtkWidget *widget) {
    int width = gtk_widget_get_width(widget);
    int height = gtk_widget_get_height(widget);
    GdkRectangle rect;
    if (width > TIP_BIG_WIDTH || height > TIP_BIG_HEIGHT) {
        rect = (GdkRectangle){(int)tip.pointer_x, (int)tip.pointer_y, 1, 1};
        gtk_popover_set_offset(GTK_POPOVER(tip.popover), 0, 14);
    } else {
        rect = (GdkRectangle){0, 0, width, height};
        gtk_popover_set_offset(GTK_POPOVER(tip.popover), 0, 6);
    }
    gtk_popover_set_pointing_to(GTK_POPOVER(tip.popover), &rect);
}

static void tip_present(GtkWidget *widget, const char *text) {
    GtkWidget *popover = tip_popover();
    tip_clear(&tip.hide_timer);
    gboolean same = tip.owner == widget && gtk_widget_get_parent(popover) == widget;
    gboolean showing = same && gtk_widget_get_mapped(popover);
    if (!same) {
        tip_drop();
        gtk_widget_set_parent(popover, widget);
        tip.owner = widget;
    }
    gtk_label_set_text(GTK_LABEL(tip.label), text);
    tip_place(widget);
    tip_watch_window(widget);
    if (showing) {
        gtk_popover_present(GTK_POPOVER(popover));
        if (!tip.lit) {
            gtk_widget_add_css_class(popover, "lit");
            tip.lit = TRUE;
        }
        return;
    }
    gtk_popover_popup(GTK_POPOVER(popover));
    if (!tip_animates()) {
        gtk_widget_add_css_class(popover, "lit");
        tip.lit = TRUE;
        return;
    }
    tip_clear(&tip.lift_timer);
    tip.lift_timer = g_timeout_add(TIP_LIFT_MS, tip_lift_fired, NULL);
}

static gboolean tip_show_fired(gpointer data) {
    (void)data;
    tip.show_timer = 0;
    if (tailscode_is_quitting()) return G_SOURCE_REMOVE;
    GtkWidget *widget = tip.candidate;
    if (!widget || widget == tip.suppressed || !gtk_widget_get_mapped(widget)) return G_SOURCE_REMOVE;
    char *text = tailscode_tip_words(widget);
    if (text && *text) tip_present(widget, text);
    g_free(text);
    return G_SOURCE_REMOVE;
}

static gboolean tip_recent(void) {
    if (tip.owner) return TRUE;
    return g_get_monotonic_time() - tip.last_seen_us < (gint64)TIP_BROWSE_WINDOW_MS * 1000;
}

static void tip_arm(GtkWidget *widget, double x, double y) {
    tip_clear(&tip.show_timer);
    tip.armed_x = x;
    tip.armed_y = y;
    guint delay = tip_recent() ? TIP_BROWSE_MS : TIP_FIRST_MS;
    tip.show_timer = g_timeout_add(delay, tip_show_fired, NULL);
    (void)widget;
}

/// The words on screen follow the widget's own: a chart that words the span under the pointer
/// changes its text as the pointer moves, and the help should change with it.
static void tip_refresh(GtkWidget *widget) {
    char *text = tailscode_tip_words(widget);
    if (!text || !*text) {
        tip_soft_hide();
    } else if (g_strcmp0(text, gtk_label_get_text(GTK_LABEL(tip.label))) != 0) {
        gtk_label_set_text(GTK_LABEL(tip.label), text);
        gtk_popover_present(GTK_POPOVER(tip.popover));
    }
    g_free(text);
}

/// The widget whose help the pointer is on: the nearest one at or above `picked` that has words
/// to say. Asked of what is under the pointer rather than of each widget, so a control that cannot
/// be pressed right now still explains itself — GTK delivers no motion to an insensitive widget.
static GtkWidget *tip_target(GtkWidget *picked) {
    for (GtkWidget *widget = picked; widget; widget = gtk_widget_get_parent(widget)) {
        if (!g_object_get_data(G_OBJECT(widget), "tailscode-tip")) continue;
        char *words = tailscode_tip_words(widget);
        gboolean has = words && *words;
        g_free(words);
        if (has) return widget;
    }
    return NULL;
}

static void tip_on_motion(GtkEventControllerMotion *controller, double x, double y, gpointer data) {
    (void)data;
    if (tailscode_is_quitting()) return;
    GtkEventController *base = GTK_EVENT_CONTROLLER(controller);
    GtkWidget *native = gtk_event_controller_get_widget(base);
    GdkModifierType state = gtk_event_controller_get_current_event_state(base);
    if (state & (GDK_BUTTON1_MASK | GDK_BUTTON2_MASK | GDK_BUTTON3_MASK)) {
        tip.candidate = NULL;
        tip_soft_hide();
        return;
    }
    GtkWidget *widget = tip_target(gtk_widget_pick(native, x, y, GTK_PICK_INSENSITIVE));
    if (!widget) {
        tip.candidate = NULL;
        tip.suppressed = NULL;
        tip_clear(&tip.show_timer);
        tip_soft_hide();
        return;
    }
    double wx = x, wy = y;
    gtk_widget_translate_coordinates(native, widget, x, y, &wx, &wy);
    tip.pointer_x = wx;
    tip.pointer_y = wy;
    if (tip.candidate != widget) {
        tip.candidate = widget;
        if (tip.suppressed != widget) tip.suppressed = NULL;
        if (tip.owner && tip.owner != widget) tip_soft_hide();
        if (widget == tip.suppressed) return;
        tip_arm(widget, wx, wy);
        return;
    }
    if (widget == tip.suppressed) return;
    if (tip.owner == widget) {
        tip_refresh(widget);
        return;
    }
    if (tip.show_timer && hypot(wx - tip.armed_x, wy - tip.armed_y) > TIP_MOVE_SLOP)
        tip_arm(widget, wx, wy);
}

static void tip_on_leave(GtkEventControllerMotion *controller, gpointer data) {
    (void)controller;
    (void)data;
    if (tailscode_is_quitting()) return;
    tip.candidate = NULL;
    tip.suppressed = NULL;
    tip_clear(&tip.show_timer);
    tip_soft_hide();
}

static void tip_on_press(GtkGestureClick *gesture, int presses, double x, double y, gpointer data) {
    (void)presses;
    (void)data;
    if (tailscode_is_quitting()) return;
    GtkWidget *native = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(gesture));
    GtkWidget *widget = tip_target(gtk_widget_pick(native, x, y, GTK_PICK_INSENSITIVE));
    tip.suppressed = tip.candidate ? tip.candidate : widget;
    tip_clear(&tip.show_timer);
    tip_soft_hide();
}

static void tip_on_gone(GtkWidget *widget, gpointer data) {
    (void)data;
    if (tip.owner == widget) tip_drop();
    if (tip.candidate == widget) {
        tip.candidate = NULL;
        tip_clear(&tip.show_timer);
    }
    if (tip.suppressed == widget) tip.suppressed = NULL;
}

/// One pair of controllers per surface — window or popover — watches the pointer for every helped
/// widget on it, instead of a pair on each widget.
static void tip_hook_native(GtkWidget *widget) {
    GtkNative *native = gtk_widget_get_native(widget);
    if (!native) return;
    GtkWidget *surface = GTK_WIDGET(native);
    if (g_object_get_data(G_OBJECT(surface), "tailscode-tip-native")) return;
    g_object_set_data(G_OBJECT(surface), "tailscode-tip-native", GINT_TO_POINTER(1));
    GtkEventController *motion = gtk_event_controller_motion_new();
    gtk_event_controller_set_propagation_phase(motion, GTK_PHASE_CAPTURE);
    g_signal_connect(motion, "enter", G_CALLBACK(tip_on_motion), NULL);
    g_signal_connect(motion, "motion", G_CALLBACK(tip_on_motion), NULL);
    g_signal_connect(motion, "leave", G_CALLBACK(tip_on_leave), NULL);
    gtk_widget_add_controller(surface, motion);
    GtkGesture *click = gtk_gesture_click_new();
    gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(click), 0);
    gtk_event_controller_set_propagation_phase(GTK_EVENT_CONTROLLER(click), GTK_PHASE_CAPTURE);
    g_signal_connect(click, "pressed", G_CALLBACK(tip_on_press), NULL);
    gtk_widget_add_controller(surface, GTK_EVENT_CONTROLLER(click));
}

static void tip_on_mapped(GtkWidget *widget, gpointer data) {
    (void)data;
    tip_hook_native(widget);
}

/// Marks `widget` as one that has help and sees that the surface it is on is being watched, now
/// or the moment it is mapped into one.
void tailscode_tip_install(GtkWidget *widget) {
    if (g_object_get_data(G_OBJECT(widget), "tailscode-tip")) return;
    g_object_set_data(G_OBJECT(widget), "tailscode-tip", GINT_TO_POINTER(1));
    g_signal_connect(widget, "destroy", G_CALLBACK(tip_on_gone), NULL);
    g_signal_connect(widget, "unmap", G_CALLBACK(tip_on_gone), NULL);
    g_signal_connect(widget, "map", G_CALLBACK(tip_on_mapped), NULL);
    tip_hook_native(widget);
}

/// A control that is given a name for a screen reader is given help from it too, when it is the
/// kind of control that has no words of its own: the name is already the right sentence.
void tailscode_tip_follow_name(GtkWidget *widget) {
    if (tip_is_control(widget)) tailscode_tip_install(widget);
}

void tailscode_tip_set(GtkWidget *widget, const char *text) {
    gboolean has = text && *text;
    gtk_widget_set_tooltip_text(widget, has ? text : NULL);
    gtk_widget_set_has_tooltip(widget, FALSE);
    if (!has) {
        if (tip.owner == widget) tip_soft_hide();
        return;
    }
    if (tip.owner == widget && tip.popover) tip_refresh(widget);
    tailscode_tip_install(widget);
}

gboolean tailscode_tip_visible(void) {
    return tip.owner != NULL && tip.popover && gtk_widget_get_mapped(tip.popover);
}

GtkWidget *tailscode_tip_owner(void) { return tip.owner; }

void tailscode_tip_dismiss(void) {
    tip.candidate = NULL;
    tip_drop();
}

static char *tip_window_words[4];

static gboolean tip_in_window_controls(GtkWidget *widget) {
    GtkWidget *parent = gtk_widget_get_parent(widget);
    return parent && g_strcmp0(G_OBJECT_TYPE_NAME(parent), "GtkWindowControls") == 0;
}

/// Gives one of the window's own buttons its help: the desktop draws minimise, maximise and close
/// for it, and they say nothing until they are told what to.
static void tip_dress_control(GtkWidget *widget) {
    const char *words = NULL;
    if (gtk_widget_has_css_class(widget, "minimize")) words = tip_window_words[0];
    else if (gtk_widget_has_css_class(widget, "maximize")) {
        GtkRoot *root = gtk_widget_get_root(widget);
        gboolean maximized = root && GTK_IS_WINDOW(root) && gtk_window_is_maximized(GTK_WINDOW(root));
        words = maximized ? tip_window_words[2] : tip_window_words[1];
    } else if (gtk_widget_has_css_class(widget, "close")) words = tip_window_words[3];
    if (words) tailscode_tip_set(widget, words);
}

static void tip_redress(GtkWidget *widget) {
    if (GTK_IS_BUTTON(widget) && tip_in_window_controls(widget)) tip_dress_control(widget);
    for (GtkWidget *child = gtk_widget_get_first_child(widget); child;
         child = gtk_widget_get_next_sibling(child))
        if (!GTK_IS_POPOVER(child)) tip_redress(child);
}

static void tip_on_maximized(GObject *window, GParamSpec *spec, gpointer data) {
    (void)spec;
    (void)data;
    if (!tailscode_is_quitting()) tip_redress(GTK_WIDGET(window));
}

/// Every widget that maps anywhere is seen once: the window's own buttons are dressed the moment
/// they appear, in whatever window they appear, with no window having to be registered.
static gboolean tip_on_any_map(GSignalInvocationHint *hint, guint count, const GValue *values,
                               gpointer data) {
    (void)hint;
    (void)data;
    if (count < 1 || tailscode_is_quitting()) return TRUE;
    GtkWidget *widget = g_value_get_object(&values[0]);
    if (!GTK_IS_BUTTON(widget) || !tip_in_window_controls(widget)) return TRUE;
    tip_dress_control(widget);
    GtkRoot *root = gtk_widget_get_root(widget);
    if (root && GTK_IS_WINDOW(root) && !g_object_get_data(G_OBJECT(root), "tailscode-tip-max")) {
        g_object_set_data(G_OBJECT(root), "tailscode-tip-max", GINT_TO_POINTER(1));
        g_signal_connect(root, "notify::maximized", G_CALLBACK(tip_on_maximized), NULL);
    }
    return TRUE;
}

void tailscode_tip_watch_windows(const char *minimize, const char *maximize, const char *restore,
                                 const char *close) {
    const char *words[4] = {minimize, maximize, restore, close};
    for (int index = 0; index < 4; index++) {
        g_free(tip_window_words[index]);
        tip_window_words[index] = g_strdup(words[index]);
    }
    static gboolean hooked = FALSE;
    if (hooked) return;
    g_type_class_ref(GTK_TYPE_WIDGET);
    guint signal = g_signal_lookup("map", GTK_TYPE_WIDGET);
    if (!signal) return;
    hooked = TRUE;
    g_signal_add_emission_hook(signal, 0, tip_on_any_map, NULL, NULL);
}
