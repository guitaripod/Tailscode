#ifndef TAILSCODE_FRAMES_H
#define TAILSCODE_FRAMES_H

#include <gtk/gtk.h>

/// Frame pacing for one window, for a bench: every frame its clock cycles through and its surface
/// actually renders is stamped from `before-paint` to `after-paint` (a cycle that drew nothing is
/// not a frame), and the main thread's CPU time is read when the meter starts and
/// when it is read, so a bench can say how often the window was drawn, how evenly, and what each
/// frame cost the thread that draws it. One meter for the process; starting it again restarts it.
gboolean tailscode_frame_meter_start(GtkWidget *widget);

/// Copies up to `capacity` gaps between consecutive painted frames, the time each frame's paint
/// cycle took and the part of it spent laying the window out, all in milliseconds, and answers how
/// many there were. `cpu_ms` is the main
/// thread's CPU time since the start, `seconds` the wall time, `refresh_ms` the clock's refresh
/// interval (0 when it gave none). Stops the meter.
int tailscode_frame_meter_stop(
    double *gaps, double *cycles, double *layouts, int capacity, double *cpu_ms, double *seconds,
    double *refresh_ms);

/// The refresh interval the widget's frame clock reports for its monitor, in milliseconds, or 0
/// before the widget is realized or when the backend says nothing.
double tailscode_frame_refresh_ms(GtkWidget *widget);

#endif
