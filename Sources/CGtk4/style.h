// Stylesheets, and the Settings window's few widgets that need a C spelling.
//
// Included from shim.h. Split out so the style side of the app is found under
// its own name; see the "Feature headers" note there.

#include <gtk/gtk.h>

// MARK: - Stylesheets

/// Loads `css` into the display's provider for `slot`, creating the provider
/// and adding it above the theme the first time the slot is used.
///
/// One provider per slot rather than one per call: the picker and the Settings
/// window restyle on every appearance change, and a provider added each time
/// would leave every earlier stylesheet on the display beneath the new one —
/// matching every selector, forever. Reloading replaces the slot's rules in
/// place.
///
/// The provider is kept as data on the display itself, keyed by the slot's
/// name, so it lives exactly as long as the display does and there is no
/// global to guard. `g_object_set_data_full` hands the display the only
/// reference; it drops it when the display is finalised.
///
/// `gtk_css_provider_load_from_string` is GTK 4.12, which is the floor.
static inline void skrepka_css_load(const char *slot, const char *css) {
	GdkDisplay *display = gdk_display_get_default();
	if (display == NULL) { return; }
	GtkCssProvider *provider = g_object_get_data(G_OBJECT(display), slot);
	if (provider == NULL) {
		provider = gtk_css_provider_new();
		gtk_style_context_add_provider_for_display(display, GTK_STYLE_PROVIDER(provider),
		                                           GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
		g_object_set_data_full(G_OBJECT(display), slot, provider, g_object_unref);
	}
	gtk_css_provider_load_from_string(provider, css);
}

// MARK: - Casts

static inline GtkStack *skrepka_as_stack(GtkWidget *widget) { return GTK_STACK(widget); }

static inline GtkHeaderBar *skrepka_as_header_bar(GtkWidget *widget) {
	return GTK_HEADER_BAR(widget);
}

static inline GtkDropDown *skrepka_as_drop_down(GtkWidget *widget) {
	return GTK_DROP_DOWN(widget);
}

// MARK: - Drop-downs

/// A drop-down over an empty string list, for ``skrepka_drop_down_append``.
///
/// In C because `gtk_drop_down_new_from_strings` takes a NULL-terminated array
/// and `gtk_drop_down_new` wants `G_LIST_MODEL()`, a macro. The drop-down takes
/// the list's one reference.
static inline GtkWidget *skrepka_drop_down_new(void) {
	GtkStringList *list = gtk_string_list_new(NULL);
	return gtk_drop_down_new(G_LIST_MODEL(list), NULL);
}

/// Appends one choice. GTK copies the string.
static inline void skrepka_drop_down_append(GtkDropDown *drop_down, const char *label) {
	GListModel *model = gtk_drop_down_get_model(drop_down);
	if (model == NULL || !GTK_IS_STRING_LIST(model)) { return; }
	gtk_string_list_append(GTK_STRING_LIST(model), label);
}

/// Removes every choice, for a list about to be replaced.
static inline void skrepka_drop_down_clear(GtkDropDown *drop_down) {
	GListModel *model = gtk_drop_down_get_model(drop_down);
	if (model == NULL || !GTK_IS_STRING_LIST(model)) { return; }
	gtk_string_list_splice(GTK_STRING_LIST(model), 0, g_list_model_get_n_items(model), NULL);
}

// MARK: - Alerts

/// Three buttons, in the order they appear — the History pane's Clear…, whose
/// question has two answers besides Cancel. GTK copies the labels.
static inline void skrepka_alert_dialog_set_three_buttons(GtkAlertDialog *dialog,
                                                          const char *first,
                                                          const char *second,
                                                          const char *third) {
	const char *labels[] = {first, second, third, NULL};
	gtk_alert_dialog_set_buttons(dialog, labels);
}

// MARK: - Clipboard

/// Puts `text` on the clipboard of the display `widget` is on — the
/// Diagnostics pane's Copy Report.
static inline void skrepka_copy_text(GtkWidget *widget, const char *text) {
	gdk_clipboard_set_text(gtk_widget_get_clipboard(widget), text);
}
