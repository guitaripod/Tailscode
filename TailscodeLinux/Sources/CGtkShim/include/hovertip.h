#ifndef TAILSCODE_HOVERTIP_H
#define TAILSCODE_HOVERTIP_H

#include <gtk/gtk.h>

/// Gives `widget` the app's hover help: `text` appears under the pointer after it has rested a
/// beat — straight away when another help was on screen a moment ago — and fades in and out
/// rather than switching. The widget keeps `text` as its tooltip text for anything that reads it
/// back, but GTK's own tooltip is switched off for it, because its timing and its look are not
/// settable. A nil or empty `text` takes the help away.
void tailscode_tip_set(GtkWidget *widget, const char *text);

/// Seats the pointer watching on `widget` without giving it words, for a control whose help is
/// its accessible name (`tailscode_tip_follow_name`, called by `tailscode_set_accessible_label`).
void tailscode_tip_install(GtkWidget *widget);
void tailscode_tip_follow_name(GtkWidget *widget);

/// The words a control shows on hover (nil when it shows none), to be freed by the caller, and
/// whether the control already reads as a sentence by itself.
char *tailscode_tip_words(GtkWidget *widget);
gboolean tailscode_tip_names_itself(GtkWidget *widget);

/// Whether help is on screen or on its way, and the widget it belongs to: for the selftest.
gboolean tailscode_tip_visible(void);
GtkWidget *tailscode_tip_owner(void);

/// Gives every window the application ever opens help on the buttons the desktop draws for it
/// (minimise, maximise or restore, close), in the words given. Call once, before the first
/// window.
void tailscode_tip_watch_windows(const char *minimize, const char *maximize, const char *restore,
                                 const char *close);

/// Puts the help away at once, without the fade. Called when a window closes or a surface that
/// help was parented to goes away.
void tailscode_tip_dismiss(void);

/// The timings, in milliseconds, so the selftest asserts the contract and not a copy of it.
int tailscode_tip_first_delay_ms(void);
int tailscode_tip_browse_delay_ms(void);
int tailscode_tip_fade_ms(void);

#endif
