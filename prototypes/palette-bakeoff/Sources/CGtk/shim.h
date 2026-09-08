// GTK4 and gtk4-layer-shell behind one header a module map can name, plus the
// handful of things that exist only as C macros and therefore cannot be reached
// from Swift at all.
//
// The macros matter more than they look. GTK's type system is macros — every
// GTK_WINDOW(), GTK_WIDGET(), GTK_BOX() is a checked downcast expanded by the
// preprocessor — and Swift imports no macro that expands to a statement. Every
// binding for GTK, in any language, has to reproduce this layer somehow; doing
// it as static inline functions in a shim is the same thing SwiftGtk's
// generator does, minus the generator.

#include <gtk/gtk.h>
#include <gtk4-layer-shell.h>

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

static inline GtkWidget *skrepka_row_as_widget(GtkListBoxRow *row) {
	return GTK_WIDGET(row);
}

static inline GtkWidget *skrepka_window_as_widget(GtkWindow *window) {
	return GTK_WIDGET(window);
}

// g_signal_connect is itself a macro over g_signal_connect_data. Spelled out
// here so a Swift caller passes a plain C function pointer and nothing else.
static inline unsigned long skrepka_connect(gpointer instance, const char *signal,
                                            GCallback handler, gpointer data) {
	return g_signal_connect_data(instance, signal, handler, data, NULL, (GConnectFlags)0);
}
