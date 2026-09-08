// GTK4 and gtk4-layer-shell behind one header a module map can name, plus the
// handful of things that exist only as C macros and therefore cannot be reached
// from Swift at all.
//
// Two headers rather than one because the layer-shell protocol is what makes
// the picker possible and GTK does not ship it:
//
//   gtk/gtk.h              the toolkit — windows, widgets, the main loop
//   gtk4-layer-shell.h     zwlr_layer_shell_v1, which is the only Wayland
//                          mechanism that gives a surface keyboard input over
//                          the frontmost app. There is no plain-`xdg_toplevel`
//                          equivalent; `xdg-shell`'s `activated` state is a
//                          decoration hint the compositor sends *to* the
//                          client, and `xdg-activation-v1` only hands out
//                          tokens to raise other surfaces.
//
// gtk4-layer-shell-0.pc lists `Requires.private: gtk4, wayland-client`, which
// pkg-config expands for `--cflags` but not for `--libs`, so this one target
// carries the headers for both and SkrepkaLinuxUI links gtk-4 and the GLib
// stack explicitly — the same split Sources/CX11 already has for Xfixes and
// Xlib. See Package.swift.
//
// The macros below matter more than they look. GTK's type system *is* macros:
// every GTK_WINDOW(), GTK_BOX(), GTK_LIST_BOX() is a checked downcast expanded
// by the preprocessor, and Swift imports no macro that expands to a statement.
// Every binding for GTK in any language reproduces this layer somehow; writing
// it as static inline functions is what a code generator would emit, minus the
// generator.

#include <gtk/gtk.h>
#include <gtk4-layer-shell.h>

// MARK: - Casts

static inline GtkWindow *skrepka_as_window(GtkWidget *widget) {
	return GTK_WINDOW(widget);
}

static inline GtkBox *skrepka_as_box(GtkWidget *widget) { return GTK_BOX(widget); }

static inline GtkListBox *skrepka_as_list_box(GtkWidget *widget) {
	return GTK_LIST_BOX(widget);
}

static inline GtkEditable *skrepka_as_editable(GtkWidget *widget) {
	return GTK_EDITABLE(widget);
}

static inline GtkLabel *skrepka_as_label(GtkWidget *widget) { return GTK_LABEL(widget); }

static inline GtkScrolledWindow *skrepka_as_scrolled_window(GtkWidget *widget) {
	return GTK_SCROLLED_WINDOW(widget);
}

static inline GtkWidget *skrepka_row_as_widget(GtkListBoxRow *row) {
	return GTK_WIDGET(row);
}

static inline GtkWidget *skrepka_window_as_widget(GtkWindow *window) {
	return GTK_WIDGET(window);
}

// MARK: - Main loop

static inline gboolean skrepka_quit_main_loop_callback(gpointer data) {
	g_main_loop_quit((GMainLoop *)data);
	return G_SOURCE_REMOVE;
}

/// Queue a main-loop quit on the loop's own context.
///
/// Queuing rather than calling `g_main_loop_quit` directly matters when a
/// caller stops the loop after it is published but before `g_main_loop_run`:
/// the idle callback runs after `g_main_loop_run` marks the loop running, so
/// the stop cannot be lost.
static inline void skrepka_schedule_main_loop_quit(GMainLoop *loop) {
	GSource *source = g_idle_source_new();
	g_source_set_callback(source, skrepka_quit_main_loop_callback, loop, NULL);
	g_source_attach(source, g_main_loop_get_context(loop));
	g_source_unref(source);
}

// MARK: - Geometry

/// The height, in pixels, of the shortest monitor GDK knows about — or 0 when
/// it knows about none, which is what a display that has not been opened yet
/// reports.
///
/// A C function rather than Swift because the monitor list is a `GListModel`,
/// and walking one from Swift means `g_list_model_get_item` plus a manual
/// unref per element to answer a question that is one loop in C.
///
/// Layer-shell hands placement to the compositor, so the surface's output is
/// not known until it maps. The conservative minimum keeps the palette from
/// being clipped when that output is shorter than another monitor. Each item
/// returned by `g_list_model_get_item` has a full-transfer reference and is
/// unreffed before the next item is read.
static inline int skrepka_smallest_monitor_height(void) {
	GdkDisplay *display = gdk_display_get_default();
	if (display == NULL) { return 0; }
	GListModel *monitors = gdk_display_get_monitors(display);
	if (monitors == NULL) { return 0; }

	guint count = g_list_model_get_n_items(monitors);
	int smallest = 0;
	for (guint index = 0; index < count; index++) {
		GdkMonitor *monitor = (GdkMonitor *)g_list_model_get_item(monitors, index);
		if (monitor == NULL) { continue; }

		GdkRectangle geometry;
		gdk_monitor_get_geometry(monitor, &geometry);
		if (geometry.height > 0 && (smallest == 0 || geometry.height < smallest)) {
			smallest = geometry.height;
		}
		g_object_unref(monitor);
	}
	return smallest;
}

// MARK: - Signals

/// `g_signal_connect` is itself a macro over `g_signal_connect_data`. Spelled
/// out here so a Swift caller passes a plain C function pointer and nothing
/// else.
///
/// `destroy_data` is exposed rather than hard-coded to NULL, and it is the
/// parameter that makes this callable from Swift at all. GLib documents it as
/// the notify "called when the signal handler is disconnected and no longer
/// used", which is the only moment a Swift caller can safely drop the
/// `Unmanaged.passRetained` handle it put in `data`: GTK decides when a widget
/// dies, so a caller releasing on its own schedule either releases too early
/// and leaves the handler holding freed memory, or never releases at all. Pass
/// NULL when `data` is not owned.
static inline unsigned long skrepka_connect(gpointer instance, const char *signal,
                                            GCallback handler, gpointer data,
                                            GClosureNotify destroy_data) {
	return g_signal_connect_data(instance, signal, handler, data, destroy_data,
	                             (GConnectFlags)0);
}
