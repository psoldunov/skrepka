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

#include <errno.h>
#include <glib-unix.h>
#include <gtk/gtk.h>
#include <gtk4-layer-shell.h>
#include <sys/eventfd.h>

// MARK: - Casts

static inline GtkWindow *skrepka_as_window(GtkWidget *widget) {
	return GTK_WINDOW(widget);
}

static inline GtkBox *skrepka_as_box(GtkWidget *widget) { return GTK_BOX(widget); }

static inline GtkListBox *skrepka_as_list_box(GtkWidget *widget) {
	return GTK_LIST_BOX(widget);
}

static inline GtkListBoxRow *skrepka_as_list_box_row(GtkWidget *widget) {
	return GTK_LIST_BOX_ROW(widget);
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

static inline GApplication *skrepka_as_application(GtkApplication *application) {
	return G_APPLICATION(application);
}

static inline GtkButton *skrepka_as_button(GtkWidget *widget) { return GTK_BUTTON(widget); }

static inline GtkSwitch *skrepka_as_switch(GtkWidget *widget) { return GTK_SWITCH(widget); }

static inline GtkFrame *skrepka_as_frame(GtkWidget *widget) { return GTK_FRAME(widget); }

static inline GtkSpinner *skrepka_as_spinner(GtkWidget *widget) {
	return GTK_SPINNER(widget);
}

static inline GtkProgressBar *skrepka_as_progress_bar(GtkWidget *widget) {
	return GTK_PROGRESS_BAR(widget);
}

// MARK: - Style

// Stylesheets are installed through `skrepka_css_load`, in style.h.

/// Whether focusing a selectable label selects all of its text — GTK's
/// `gtk-label-select-on-focus` setting, for this process's default display.
///
/// In C because `g_object_set` is variadic. Setting it here overrides the
/// desktop's value for this process alone.
static inline void skrepka_set_label_select_on_focus(gboolean select) {
	GtkSettings *settings = gtk_settings_get_default();
	if (settings == NULL) { return; }
	g_object_set(settings, "gtk-label-select-on-focus", select, NULL);
}

// MARK: - Variadic and array-taking calls

// Swift imports no C variadic function and builds a NULL-terminated string
// array only with manual allocation, so the three calls below that need one of
// the two are spelled here, with the arguments Skrepka actually passes.

/// `gtk_alert_dialog_new` takes a printf format. Passing the message as the
/// `%s` argument rather than as the format is what keeps a `%` in a device's
/// name from being read as a conversion.
static inline GtkAlertDialog *skrepka_alert_dialog_new(const char *message) {
	return gtk_alert_dialog_new("%s", message);
}

/// Two buttons, in the order they appear. GTK copies the labels.
static inline void skrepka_alert_dialog_set_buttons(GtkAlertDialog *dialog, const char *first,
                                                    const char *second) {
	const char *labels[] = {first, second, NULL};
	gtk_alert_dialog_set_buttons(dialog, labels);
}

/// The name a screen reader announces for a control with no visible label of
/// its own — a switch beside a row title.
static inline void skrepka_set_accessible_label(GtkWidget *widget, const char *label) {
	gtk_accessible_update_property(GTK_ACCESSIBLE(widget), GTK_ACCESSIBLE_PROPERTY_LABEL, label,
	                               -1);
}

/// Escape closes the window through its built-in `window.close` action, which
/// runs the same close-request a click on the title bar's button does.
static inline void skrepka_close_on_escape(GtkWindow *window) {
	GtkEventController *controller = gtk_shortcut_controller_new();
	GtkShortcut *shortcut = gtk_shortcut_new(gtk_keyval_trigger_new(GDK_KEY_Escape, 0),
	                                         gtk_named_action_new("window.close"));
	gtk_shortcut_controller_add_shortcut(GTK_SHORTCUT_CONTROLLER(controller), shortcut);
	gtk_widget_add_controller(GTK_WIDGET(window), controller);
}

// MARK: - Waking the main loop from another thread

// An eventfd is the only thing that crosses threads between Swift's
// concurrency pool and GTK's main loop: the pool writes to it, and a
// `g_unix_fd_source` on the loop wakes when it becomes readable. No pointer to
// a widget or to anything that owns one ever leaves the loop's thread. See
// Sources/SkrepkaLinuxUI/Backend/MainLoopInbox.swift.

/// A non-blocking, close-on-exec eventfd, or -1 with `errno` set.
static inline int skrepka_wake_fd_new(void) { return eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK); }

/// Makes the descriptor readable. Retried on EINTR; the only other failure,
/// EAGAIN, needs the counter at 2^64 - 2 and cannot happen one write at a time.
static inline void skrepka_wake_fd_signal(int descriptor) {
	while (eventfd_write(descriptor, 1) < 0 && errno == EINTR) {
	}
}

/// Resets the descriptor so it is no longer readable. EAGAIN — nothing was
/// written since the last reset — is the ordinary answer and is not an error.
static inline void skrepka_wake_fd_clear(int descriptor) {
	eventfd_t value = 0;
	while (eventfd_read(descriptor, &value) < 0 && errno == EINTR) {
	}
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

// MARK: - Feature headers
//
// One module map names one header, so the helpers each feature needs live in a
// header of their own and are pulled in here. Split by feature rather than kept
// in this file so that each stays readable on its own, and so the C side of a
// feature is found next to its name.
//
//   app.h      the app shell: printing to the terminal that invoked it
//   gdbus.h    GDBus: the tray's StatusNotifierItem and menu, and the portals
//   picker.h   the picker window: X11 placement and the keyboard grab
//   style.h    stylesheets, and the Settings window's drop-downs and alerts
#include "app.h"
#include "gdbus.h"
#include "picker.h"
#include "style.h"
