#include "desk.h"
#include <gio/gio.h>
#include <stdatomic.h>
#include <string.h>

#ifdef TAILSCODE_HAS_WAYLAND
#include <gdk/gdk.h>
#include <gdk/wayland/gdkwayland.h>
#include <wayland-client.h>
#include "ext-idle-notify-v1-client-protocol.h"
#endif

#define DESK_IDLE_GRAIN_MS 5000
#define DESK_DBUS_TIMEOUT_MS 400
#define DESK_REPROBE_US ((gint64)300 * G_USEC_PER_SEC)

static _Atomic gint64 desk_idle_since = 0;
static _Atomic int desk_wayland_ready = 0;
static _Atomic int desk_idle_route = 0;
static _Atomic int desk_lock_route = 0;
static _Atomic gint64 desk_idle_failed_at = 0;
static _Atomic gint64 desk_lock_failed_at = 0;

static int desk_route(_Atomic int *route, _Atomic gint64 *failed_at) {
    int current = atomic_load(route);
    if (current != -1) return current;
    if (g_get_monotonic_time() - atomic_load(failed_at) < DESK_REPROBE_US) return -1;
    atomic_store(route, 0);
    return 0;
}

#ifdef TAILSCODE_HAS_WAYLAND
static struct wl_seat *desk_seat = NULL;
static struct ext_idle_notifier_v1 *desk_notifier = NULL;
static uint32_t desk_notifier_version = 0;
static struct ext_idle_notification_v1 *desk_notification = NULL;

static void desk_idled(void *data, struct ext_idle_notification_v1 *notification) {
    (void)data;
    (void)notification;
    atomic_store(&desk_idle_since, g_get_monotonic_time() - (gint64)DESK_IDLE_GRAIN_MS * 1000);
}

static void desk_resumed(void *data, struct ext_idle_notification_v1 *notification) {
    (void)data;
    (void)notification;
    atomic_store(&desk_idle_since, 0);
}

static const struct ext_idle_notification_v1_listener desk_notification_listener = {
    .idled = desk_idled,
    .resumed = desk_resumed,
};

static void desk_global(
    void *data, struct wl_registry *registry, uint32_t name, const char *interface, uint32_t version) {
    (void)data;
    if (strcmp(interface, ext_idle_notifier_v1_interface.name) == 0 && !desk_notifier) {
        desk_notifier_version = version < 2 ? version : 2;
        desk_notifier = wl_registry_bind(registry, name, &ext_idle_notifier_v1_interface, desk_notifier_version);
    } else if (strcmp(interface, wl_seat_interface.name) == 0 && !desk_seat) {
        desk_seat = wl_registry_bind(registry, name, &wl_seat_interface, 1);
    }
}

static void desk_global_remove(void *data, struct wl_registry *registry, uint32_t name) {
    (void)data;
    (void)registry;
    (void)name;
}

static const struct wl_registry_listener desk_registry_listener = {
    .global = desk_global,
    .global_remove = desk_global_remove,
};
#endif

int tailscode_desk_idle_begin(void) {
#ifdef TAILSCODE_HAS_WAYLAND
    if (atomic_load(&desk_wayland_ready)) return 1;
    GdkDisplay *display = gdk_display_get_default();
    if (!display || !GDK_IS_WAYLAND_DISPLAY(display)) return 0;
    struct wl_display *wayland = gdk_wayland_display_get_wl_display(display);
    if (!wayland) return 0;
    struct wl_event_queue *queue = wl_display_create_queue(wayland);
    struct wl_display *wrapped = wl_proxy_create_wrapper(wayland);
    wl_proxy_set_queue((struct wl_proxy *)wrapped, queue);
    struct wl_registry *registry = wl_display_get_registry(wrapped);
    wl_registry_add_listener(registry, &desk_registry_listener, NULL);
    wl_display_roundtrip_queue(wayland, queue);
    wl_registry_destroy(registry);
    wl_proxy_wrapper_destroy(wrapped);
    if (!desk_notifier || !desk_seat) {
        if (desk_notifier) ext_idle_notifier_v1_destroy(desk_notifier);
        if (desk_seat) wl_seat_destroy(desk_seat);
        desk_notifier = NULL;
        desk_seat = NULL;
        wl_event_queue_destroy(queue);
        return 0;
    }
    wl_proxy_set_queue((struct wl_proxy *)desk_notifier, NULL);
    wl_proxy_set_queue((struct wl_proxy *)desk_seat, NULL);
    desk_notification = desk_notifier_version >= 2
        ? ext_idle_notifier_v1_get_input_idle_notification(desk_notifier, DESK_IDLE_GRAIN_MS, desk_seat)
        : ext_idle_notifier_v1_get_idle_notification(desk_notifier, DESK_IDLE_GRAIN_MS, desk_seat);
    ext_idle_notification_v1_add_listener(desk_notification, &desk_notification_listener, NULL);
    wl_display_flush(wayland);
    wl_event_queue_destroy(queue);
    atomic_store(&desk_wayland_ready, 1);
    return 1;
#else
    return 0;
#endif
}

static GDBusConnection *desk_bus(GBusType type) {
    GError *error = NULL;
    GDBusConnection *bus = g_bus_get_sync(type, NULL, &error);
    g_clear_error(&error);
    return bus;
}

static GVariant *desk_call(
    const char *destination, const char *path, const char *interface, const char *method,
    const char *reply_type) {
    GDBusConnection *bus = desk_bus(G_BUS_TYPE_SESSION);
    if (!bus) return NULL;
    GError *error = NULL;
    GVariant *reply = g_dbus_connection_call_sync(
        bus, destination, path, interface, method, NULL, G_VARIANT_TYPE(reply_type),
        G_DBUS_CALL_FLAGS_NO_AUTO_START, DESK_DBUS_TIMEOUT_MS, NULL, &error);
    g_clear_error(&error);
    g_object_unref(bus);
    return reply;
}

static double desk_mutter_idle(void) {
    GVariant *reply = desk_call(
        "org.gnome.Mutter.IdleMonitor", "/org/gnome/Mutter/IdleMonitor/Core",
        "org.gnome.Mutter.IdleMonitor", "GetIdletime", "(t)");
    if (!reply) return -1;
    guint64 milliseconds = 0;
    g_variant_get(reply, "(t)", &milliseconds);
    g_variant_unref(reply);
    return milliseconds / 1000.0;
}

static double desk_screensaver_idle(void) {
    GVariant *reply = desk_call(
        "org.freedesktop.ScreenSaver", "/org/freedesktop/ScreenSaver",
        "org.freedesktop.ScreenSaver", "GetSessionIdleTime", "(u)");
    if (!reply) return -1;
    guint32 seconds = 0;
    g_variant_get(reply, "(u)", &seconds);
    g_variant_unref(reply);
    return seconds;
}

double tailscode_desk_idle_seconds(void) {
    if (atomic_load(&desk_wayland_ready)) {
        gint64 since = atomic_load(&desk_idle_since);
        if (since == 0) return 0;
        return (g_get_monotonic_time() - since) / 1e6;
    }
    int route = desk_route(&desk_idle_route, &desk_idle_failed_at);
    if (route == -1) return -1;
    if (route == 0 || route == 1) {
        double idle = desk_mutter_idle();
        if (idle >= 0) {
            atomic_store(&desk_idle_route, 1);
            return idle;
        }
    }
    if (route == 0 || route == 2) {
        double idle = desk_screensaver_idle();
        if (idle >= 0) {
            atomic_store(&desk_idle_route, 2);
            return idle;
        }
    }
    if (route == 0) {
        atomic_store(&desk_idle_failed_at, g_get_monotonic_time());
        atomic_store(&desk_idle_route, -1);
    }
    return -1;
}

static int desk_active(const char *destination, const char *path, const char *interface) {
    GVariant *reply = desk_call(destination, path, interface, "GetActive", "(b)");
    if (!reply) return -1;
    gboolean active = FALSE;
    g_variant_get(reply, "(b)", &active);
    g_variant_unref(reply);
    return active ? 1 : 0;
}

int tailscode_desk_locked(void) {
    int route = desk_route(&desk_lock_route, &desk_lock_failed_at);
    if (route == -1) return -1;
    if (route == 0 || route == 1) {
        int active = desk_active(
            "org.freedesktop.ScreenSaver", "/org/freedesktop/ScreenSaver", "org.freedesktop.ScreenSaver");
        if (active >= 0) {
            atomic_store(&desk_lock_route, 1);
            return active;
        }
    }
    if (route == 0 || route == 2) {
        int active = desk_active("org.gnome.ScreenSaver", "/org/gnome/ScreenSaver", "org.gnome.ScreenSaver");
        if (active >= 0) {
            atomic_store(&desk_lock_route, 2);
            return active;
        }
    }
    if (route == 0) {
        atomic_store(&desk_lock_failed_at, g_get_monotonic_time());
        atomic_store(&desk_lock_route, -1);
    }
    return -1;
}

typedef struct {
    TailscodeDeskCallback callback;
    void *data;
} DeskWatch;

static DeskWatch desk_watch = {NULL, NULL};

static void desk_lock_signal(
    GDBusConnection *connection, const char *sender, const char *path, const char *interface,
    const char *signal, GVariant *parameters, gpointer data) {
    (void)connection;
    (void)sender;
    (void)path;
    (void)interface;
    (void)signal;
    (void)data;
    if (!desk_watch.callback || !g_variant_is_of_type(parameters, G_VARIANT_TYPE("(b)"))) return;
    gboolean active = FALSE;
    g_variant_get(parameters, "(b)", &active);
    desk_watch.callback(TAILSCODE_DESK_LOCK, active ? 1 : 0, desk_watch.data);
}

static void desk_sleep_signal(
    GDBusConnection *connection, const char *sender, const char *path, const char *interface,
    const char *signal, GVariant *parameters, gpointer data) {
    (void)connection;
    (void)sender;
    (void)path;
    (void)interface;
    (void)signal;
    (void)data;
    if (!desk_watch.callback || !g_variant_is_of_type(parameters, G_VARIANT_TYPE("(b)"))) return;
    gboolean going = FALSE;
    g_variant_get(parameters, "(b)", &going);
    desk_watch.callback(TAILSCODE_DESK_SLEEP, going ? 1 : 0, desk_watch.data);
}

void tailscode_desk_watch(TailscodeDeskCallback callback, void *data) {
    gboolean first = desk_watch.callback == NULL;
    desk_watch.callback = callback;
    desk_watch.data = data;
    if (!first) return;
    GDBusConnection *session = desk_bus(G_BUS_TYPE_SESSION);
    if (session) {
        g_dbus_connection_signal_subscribe(
            session, NULL, "org.freedesktop.ScreenSaver", "ActiveChanged", NULL, NULL,
            G_DBUS_SIGNAL_FLAGS_NONE, desk_lock_signal, NULL, NULL);
        g_dbus_connection_signal_subscribe(
            session, NULL, "org.gnome.ScreenSaver", "ActiveChanged", NULL, NULL,
            G_DBUS_SIGNAL_FLAGS_NONE, desk_lock_signal, NULL, NULL);
    }
    GDBusConnection *system = desk_bus(G_BUS_TYPE_SYSTEM);
    if (system) {
        g_dbus_connection_signal_subscribe(
            system, "org.freedesktop.login1", "org.freedesktop.login1.Manager", "PrepareForSleep",
            "/org/freedesktop/login1", NULL, G_DBUS_SIGNAL_FLAGS_NONE, desk_sleep_signal, NULL, NULL);
    }
}
