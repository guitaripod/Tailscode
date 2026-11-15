#include "include/frames.h"
#include <time.h>

#define METER_CAPACITY 65536

typedef struct {
    GdkFrameClock *clock;
    GdkSurface *surface;
    guint render_signal;
    gulong render_hook;
    gboolean rendered;
    gulong before_id;
    gulong after_id;
    gulong layout_id;
    gulong laid_id;
    gint64 layout_began_us;
    double layout_ms;
    gint64 began_us;
    gint64 cycle_began_us;
    gint64 last_paint_us;
    double cpu_start_ms;
    int count;
    double gaps[METER_CAPACITY];
    double cycles[METER_CAPACITY];
    double layouts[METER_CAPACITY];
} FrameMeter;

static FrameMeter *meter = NULL;

static double thread_cpu_ms(void) {
    struct timespec spec;
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &spec);
    return (double)spec.tv_sec * 1000.0 + (double)spec.tv_nsec / 1e6;
}

static void meter_before(GdkFrameClock *clock, gpointer data) {
    (void)clock;
    FrameMeter *self = data;
    self->cycle_began_us = g_get_monotonic_time();
}

static void meter_layout(GdkFrameClock *clock, gpointer data) {
    (void)clock;
    FrameMeter *self = data;
    self->layout_began_us = g_get_monotonic_time();
}

static void meter_laid(GdkFrameClock *clock, gpointer data) {
    (void)clock;
    FrameMeter *self = data;
    if (self->layout_began_us) self->layout_ms += (double)(g_get_monotonic_time() - self->layout_began_us) / 1000.0;
    self->layout_began_us = 0;
}

static gboolean meter_render(
    GSignalInvocationHint *hint, guint count, const GValue *values, gpointer data) {
    (void)hint;
    FrameMeter *self = data;
    if (count > 0 && g_value_get_object(&values[0]) == (gpointer)self->surface) self->rendered = TRUE;
    return TRUE;
}

static void meter_after(GdkFrameClock *clock, gpointer data) {
    (void)clock;
    FrameMeter *self = data;
    gint64 now = g_get_monotonic_time();
    if (!self->rendered) {
        self->cycle_began_us = 0;
        self->layout_ms = 0;
        return;
    }
    self->rendered = FALSE;
    if (self->last_paint_us != 0 && self->count < METER_CAPACITY) {
        self->gaps[self->count] = (double)(now - self->last_paint_us) / 1000.0;
        self->cycles[self->count] =
            self->cycle_began_us ? (double)(now - self->cycle_began_us) / 1000.0 : 0;
        self->layouts[self->count] = self->layout_ms;
        self->count += 1;
    }
    self->last_paint_us = now;
    self->cycle_began_us = 0;
    self->layout_ms = 0;
}

static void meter_detach(void) {
    if (!meter) return;
    if (meter->clock) {
        g_signal_handler_disconnect(meter->clock, meter->before_id);
        g_signal_handler_disconnect(meter->clock, meter->after_id);
        g_signal_handler_disconnect(meter->clock, meter->layout_id);
        g_signal_handler_disconnect(meter->clock, meter->laid_id);
        g_object_unref(meter->clock);
    }
    if (meter->surface) {
        g_signal_remove_emission_hook(meter->render_signal, meter->render_hook);
        g_object_unref(meter->surface);
    }
    g_free(meter);
    meter = NULL;
}

gboolean tailscode_frame_meter_start(GtkWidget *widget) {
    meter_detach();
    GdkFrameClock *clock = widget ? gtk_widget_get_frame_clock(widget) : NULL;
    GtkNative *native = widget ? gtk_widget_get_native(widget) : NULL;
    GdkSurface *surface = native ? gtk_native_get_surface(native) : NULL;
    if (!clock || !surface) return FALSE;
    meter = g_new0(FrameMeter, 1);
    meter->clock = g_object_ref(clock);
    meter->surface = g_object_ref(surface);
    meter->render_signal = g_signal_lookup("render", GDK_TYPE_SURFACE);
    meter->render_hook = g_signal_add_emission_hook(meter->render_signal, 0, meter_render, meter, NULL);
    meter->began_us = g_get_monotonic_time();
    meter->cpu_start_ms = thread_cpu_ms();
    meter->before_id = g_signal_connect(clock, "before-paint", G_CALLBACK(meter_before), meter);
    meter->after_id = g_signal_connect_after(clock, "after-paint", G_CALLBACK(meter_after), meter);
    meter->layout_id = g_signal_connect_after(clock, "update", G_CALLBACK(meter_layout), meter);
    meter->laid_id = g_signal_connect_after(clock, "layout", G_CALLBACK(meter_laid), meter);
    return TRUE;
}

int tailscode_frame_meter_stop(
    double *gaps, double *cycles, double *layouts, int capacity, double *cpu_ms, double *seconds,
    double *refresh_ms) {
    if (!meter) return 0;
    int count = meter->count < capacity ? meter->count : capacity;
    for (int index = 0; index < count; index++) {
        gaps[index] = meter->gaps[index];
        cycles[index] = meter->cycles[index];
        layouts[index] = meter->layouts[index];
    }
    *cpu_ms = thread_cpu_ms() - meter->cpu_start_ms;
    *seconds = (double)(g_get_monotonic_time() - meter->began_us) / 1e6;
    gint64 interval = 0;
    gint64 presentation = 0;
    gdk_frame_clock_get_refresh_info(
        meter->clock, gdk_frame_clock_get_frame_time(meter->clock), &interval, &presentation);
    *refresh_ms = (double)interval / 1000.0;
    meter_detach();
    return count;
}

double tailscode_frame_refresh_ms(GtkWidget *widget) {
    GdkFrameClock *clock = widget ? gtk_widget_get_frame_clock(widget) : NULL;
    if (!clock) return 0;
    gint64 interval = 0;
    gint64 presentation = 0;
    gdk_frame_clock_get_refresh_info(
        clock, gdk_frame_clock_get_frame_time(clock), &interval, &presentation);
    return (double)interval / 1000.0;
}
