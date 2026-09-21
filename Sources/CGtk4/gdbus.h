// GDBus helpers for the tray (StatusNotifierItem, com.canonical.dbusmenu) and
// the xdg-desktop-portal clients. Included from shim.h — see the list there.

#pragma once

#include <gio/gio.h>
#include <gtk/gtk.h>
#include <stdlib.h>
#include <string.h>

// Swift cannot initialize GDBusInterfaceVTable's reserved tuple reliably.
// Keep one immutable vtable in C and route its callbacks through a tiny owned
// context. GDBus destroys the context only after unregistering the object.
typedef void (*SkrepkaDBusMethodCall)(GDBusConnection *, const gchar *, const gchar *,
                                      const gchar *, const gchar *, GVariant *,
                                      GDBusMethodInvocation *, gpointer);
typedef GVariant *(*SkrepkaDBusGetProperty)(GDBusConnection *, const gchar *, const gchar *,
                                            const gchar *, const gchar *, GError **, gpointer);

typedef struct {
	SkrepkaDBusMethodCall method_call;
	SkrepkaDBusGetProperty get_property;
	GDestroyNotify destroy;
	gpointer data;
} SkrepkaDBusExport;

static void skrepka_dbus_method_call(GDBusConnection *connection, const gchar *sender,
                                     const gchar *object_path, const gchar *interface_name,
                                     const gchar *method_name, GVariant *parameters,
                                     GDBusMethodInvocation *invocation, gpointer user_data) {
	SkrepkaDBusExport *exported = user_data;
	exported->method_call(connection, sender, object_path, interface_name, method_name,
	                      parameters, invocation, exported->data);
}

// GDBus asserts that a get_property callback which returns NULL has set
// `error` — `g_assert (error != NULL)` in gdbusconnection.c's Properties.Get
// path — so a property the Swift handler does not answer would abort the
// process rather than fail the one call. Answer an error instead.
static GVariant *skrepka_dbus_get_property(GDBusConnection *connection, const gchar *sender,
                                           const gchar *object_path,
                                           const gchar *interface_name,
                                           const gchar *property_name, GError **error,
                                           gpointer user_data) {
	SkrepkaDBusExport *exported = user_data;
	GVariant *value = exported->get_property(connection, sender, object_path, interface_name,
	                                         property_name, error, exported->data);
	if (value == NULL && error != NULL && *error == NULL) {
		g_set_error(error, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_PROPERTY,
		            "No such property: %s", property_name);
	}
	return value;
}

static void skrepka_dbus_export_free(gpointer user_data) {
	SkrepkaDBusExport *exported = user_data;
	if (exported->destroy != NULL) { exported->destroy(exported->data); }
	free(exported);
}

static inline guint skrepka_dbus_register_object(
    GDBusConnection *connection, const gchar *object_path, GDBusInterfaceInfo *interface_info,
    SkrepkaDBusMethodCall method_call, SkrepkaDBusGetProperty get_property, gpointer data,
    GDestroyNotify destroy, GError **error) {
	static const GDBusInterfaceVTable vtable = {
	    skrepka_dbus_method_call, skrepka_dbus_get_property, NULL, {NULL}};
	SkrepkaDBusExport *exported = malloc(sizeof(SkrepkaDBusExport));
	if (exported == NULL) { return 0; }
	exported->method_call = method_call;
	exported->get_property = get_property;
	exported->destroy = destroy;
	exported->data = data;
	guint identifier = g_dbus_connection_register_object(
	    connection, object_path, interface_info, &vtable, exported, skrepka_dbus_export_free, error);
	if (identifier == 0) { skrepka_dbus_export_free(exported); }
	return identifier;
}

static inline const GVariantType *skrepka_variant_type(const gchar *signature) {
	return G_VARIANT_TYPE(signature);
}

static inline GVariant *skrepka_variant_new_object_path(const gchar *path) {
	return g_variant_new_object_path(path);
}

static inline GVariant *skrepka_variant_new_boolean(gboolean value) {
	return g_variant_new_boolean(value);
}

static inline GVariant *skrepka_variant_new_byte(guchar value) {
	return g_variant_new_byte(value);
}

static inline GVariant *skrepka_variant_new_uint32(guint32 value) {
	return g_variant_new_uint32(value);
}

static inline GVariant *skrepka_variant_new_uint64(guint64 value) {
	return g_variant_new_uint64(value);
}

static inline GVariant *skrepka_variant_new_double(gdouble value) {
	return g_variant_new_double(value);
}

/// GTK fallback used only when the Settings portal is absent.
static inline gboolean skrepka_gtk_prefers_dark(void) {
	GtkSettings *settings = gtk_settings_get_default();
	if (settings == NULL) { return FALSE; }
	gboolean preferred = FALSE;
	gchar *theme = NULL;
	g_object_get(settings, "gtk-application-prefer-dark-theme", &preferred,
	             "gtk-theme-name", &theme, NULL);
	if (!preferred && theme != NULL) {
		gchar *lower = g_ascii_strdown(theme, -1);
		preferred = strstr(lower, "dark") != NULL;
		g_free(lower);
	}
	g_free(theme);
	return preferred;
}
