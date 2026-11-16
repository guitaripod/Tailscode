#pragma once
#include <glib.h>

/// Whether the person is at this desktop: how long since the last keyboard or pointer input
/// anywhere on it, whether the screen is locked, and when the machine goes to sleep. Read from
/// the compositor's ext-idle-notify on Wayland, GNOME's idle monitor or the freedesktop screen
/// saver otherwise; a session that offers none of them answers unknown.

/// Starts listening to the compositor for input idle. Main thread; 1 when it will report.
int tailscode_desk_idle_begin(void);

/// Seconds since the last input, from any thread; negative when this session cannot say.
double tailscode_desk_idle_seconds(void);

/// 1 when the screen is locked, 0 when not, -1 when this session cannot say. Any thread.
int tailscode_desk_locked(void);

/// What the watch reports: the lock changed (value 1 locked), or the machine is going to sleep
/// (value 1) or came back (value 0).
typedef enum {
    TAILSCODE_DESK_LOCK = 0,
    TAILSCODE_DESK_SLEEP = 1,
} TailscodeDeskEvent;

typedef void (*TailscodeDeskCallback)(int event, int value, void *data);

/// Calls back on the main loop when the lock changes or the machine sleeps or wakes. Main thread.
void tailscode_desk_watch(TailscodeDeskCallback callback, void *data);
