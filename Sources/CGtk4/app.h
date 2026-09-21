// Helpers for the app shell — the GtkApplication that owns the tray, the picker
// and the Settings window. Included from shim.h — see the list there.

#pragma once

#include <gio/gio.h>

/// Prints to the terminal that ran this invocation of the app, which for a
/// second `skrepka-gui` is not this process's terminal: GApplication forwards
/// the text to it over the bus.
///
/// In C because both print calls take a printf format. Passing the text as the
/// `%s` argument rather than as the format keeps a `%` in it from being read as
/// a conversion. The `_literal` variants would say the same thing, and exist
/// only from GLib 2.80.
static inline void skrepka_command_line_print(GApplicationCommandLine *cmdline, const char *text,
                                              gboolean is_error) {
	if (is_error) {
		g_application_command_line_printerr(cmdline, "%s", text);
	} else {
		g_application_command_line_print(cmdline, "%s", text);
	}
}

static inline GApplicationCommandLine *skrepka_as_command_line(gpointer object) {
	return G_APPLICATION_COMMAND_LINE(object);
}
