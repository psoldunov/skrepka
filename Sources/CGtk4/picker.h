// Helpers for the picker window that GTK 4 does not expose to Swift: the type
// casts GTK's macros hide, a themed-icon builder that avoids marshalling a
// NULL-terminated array from Swift, and the X11 placement and keyboard grab a
// session without wlr-layer-shell needs. Included from shim.h — see the list
// there.

#pragma once

#include <gtk/gtk.h>
#include <string.h>

// MARK: - Appearance
//
// Reading a GtkSettings property is a `g_object_get`, which is variadic and so
// unreachable from Swift. Until the appearance portal reports a preference, the
// picker asks GTK's own settings whether the desktop wants a dark theme.

static inline gboolean skrepka_prefers_dark(void) {
	GtkSettings *settings = gtk_settings_get_default();
	if (settings == NULL) { return FALSE; }
	gboolean dark = FALSE;
	g_object_get(settings, "gtk-application-prefer-dark-theme", &dark, NULL);
	if (dark) { return TRUE; }
	char *theme = NULL;
	g_object_get(settings, "gtk-theme-name", &theme, NULL);
	gboolean named_dark = theme != NULL && strstr(theme, "dark") != NULL;
	g_free(theme);
	return named_dark;
}

// MARK: - Casts
//
// GTK's downcasts are preprocessor macros, which Swift imports none of, so each
// one the picker needs is a static inline line here — the same tax shim.h pays
// for the window and the list box.

static inline GtkImage *skrepka_as_image(GtkWidget *widget) { return GTK_IMAGE(widget); }

static inline GtkEntry *skrepka_as_entry(GtkWidget *widget) { return GTK_ENTRY(widget); }

static inline GtkPicture *skrepka_as_picture(GtkWidget *widget) { return GTK_PICTURE(widget); }

static inline GtkDrawingArea *skrepka_as_drawing_area(GtkWidget *widget) {
	return GTK_DRAWING_AREA(widget);
}

static inline GtkGestureSingle *skrepka_as_gesture_single(GtkGesture *gesture) {
	return GTK_GESTURE_SINGLE(gesture);
}

static inline GtkPopover *skrepka_as_popover(GtkWidget *widget) { return GTK_POPOVER(widget); }

static inline GtkNative *skrepka_window_as_native(GtkWindow *window) {
	return GTK_NATIVE(window);
}

static inline GtkOverlay *skrepka_as_overlay(GtkWidget *widget) { return GTK_OVERLAY(widget); }

static inline GdkPaintable *skrepka_texture_as_paintable(GdkTexture *texture) {
	return GDK_PAINTABLE(texture);
}

static inline GMenuModel *skrepka_menu_as_model(GMenu *menu) { return G_MENU_MODEL(menu); }

static inline GActionGroup *skrepka_actions_as_group(GSimpleActionGroup *actions) {
	return G_ACTION_GROUP(actions);
}

static inline GActionMap *skrepka_actions_as_map(GSimpleActionGroup *actions) {
	return G_ACTION_MAP(actions);
}

static inline GAction *skrepka_simple_action_as_action(GSimpleAction *action) {
	return G_ACTION(action);
}

static inline gpointer skrepka_action_as_object(GSimpleAction *action) {
	return G_OBJECT(action);
}

// MARK: - Themed icons
//
// `g_themed_icon_new_from_names` takes a NULL-terminated array, which Swift can
// only build with manual allocation. The picker's fallback chains are never
// longer than three, so they are passed as three arguments, the empty ones
// NULL, and the chain assembled here.

static inline void skrepka_image_set_icon_names(GtkImage *image, const char *first,
                                                const char *second, const char *third) {
	if (first == NULL) { return; }
	GIcon *icon = g_themed_icon_new(first);
	if (second != NULL) { g_themed_icon_append_name(G_THEMED_ICON(icon), second); }
	if (third != NULL) { g_themed_icon_append_name(G_THEMED_ICON(icon), third); }
	gtk_image_set_from_gicon(image, icon);
	g_object_unref(icon);
}

/// The tile icon for a file, guessed from its name with
/// `g_content_type_get_symbolic_icon`, with `fallback` appended so a host whose
/// theme lacks the guessed icon still draws a built-in rather than a
/// missing-image glyph. Falls back entirely to `fallback` when the type cannot
/// be guessed.
static inline void skrepka_image_set_file_icon(GtkImage *image, const char *filename,
                                               const char *fallback) {
	gboolean uncertain = FALSE;
	char *content_type = g_content_type_guess(filename, NULL, 0, &uncertain);
	GIcon *icon = content_type != NULL ? g_content_type_get_symbolic_icon(content_type) : NULL;
	g_free(content_type);
	if (icon == NULL) {
		skrepka_image_set_icon_names(image, fallback, NULL, NULL);
		return;
	}
	if (fallback != NULL && G_IS_THEMED_ICON(icon)) {
		g_themed_icon_append_name(G_THEMED_ICON(icon), fallback);
	}
	gtk_image_set_from_gicon(image, icon);
	g_object_unref(icon);
}

// MARK: - X11 fallback
//
// A session without wlr-layer-shell — every X11 session, and GNOME — cannot map
// the picker as an overlay. There the window is an ordinary undecorated
// toplevel, and on X11 it needs three things the compositor would otherwise
// give a layer surface: it must stay above, keep out of the taskbar and pager,
// and hold the keyboard so the first keystroke after the hotkey lands in the
// search field. Xlib is linked into SkrepkaLinuxUI already; the CX11 Swift
// module is deliberately not imported here, because two modules textually
// including Xlib.h collide.

#ifdef GDK_WINDOWING_X11

#include <X11/Xatom.h>
#include <gdk/x11/gdkx.h>

/// Whether `surface` is backed by X11, so the calls below apply.
static inline gboolean skrepka_surface_is_x11(GdkSurface *surface) {
	return surface != NULL && GDK_IS_X11_DISPLAY(gdk_surface_get_display(surface));
}

/// Marks the window above, skip-taskbar and skip-pager, the way rofi does, so a
/// window manager treats it as a transient palette rather than an application
/// window. Set before the window maps; a re-map keeps the property.
static inline void skrepka_x11_mark_utility(GdkSurface *surface) {
	if (!skrepka_surface_is_x11(surface)) { return; }
	Display *display = gdk_x11_display_get_xdisplay(gdk_surface_get_display(surface));
	Window xid = gdk_x11_surface_get_xid(surface);
	Atom state = XInternAtom(display, "_NET_WM_STATE", False);
	Atom above = XInternAtom(display, "_NET_WM_STATE_ABOVE", False);
	Atom skipTaskbar = XInternAtom(display, "_NET_WM_STATE_SKIP_TASKBAR", False);
	Atom skipPager = XInternAtom(display, "_NET_WM_STATE_SKIP_PAGER", False);
	Atom values[] = {above, skipTaskbar, skipPager};
	XChangeProperty(display, xid, state, XA_ATOM, 32, PropModeReplace, (unsigned char *)values, 3);
	XFlush(display);
}

/// Centres the window on the whole X screen. Per-monitor placement under the
/// pointer is left to the window manager; this only keeps a bare WM from
/// pinning the palette to a corner.
static inline void skrepka_x11_center(GdkSurface *surface, int width, int height) {
	if (!skrepka_surface_is_x11(surface)) { return; }
	Display *display = gdk_x11_display_get_xdisplay(gdk_surface_get_display(surface));
	Window xid = gdk_x11_surface_get_xid(surface);
	int screen = DefaultScreen(display);
	int x = (DisplayWidth(display, screen) - width) / 2;
	int y = (DisplayHeight(display, screen) - height) / 2;
	XMoveWindow(display, xid, x > 0 ? x : 0, y > 0 ? y : 0);
	XFlush(display);
}

/// Grabs the keyboard to the mapped window, so keys reach the search field
/// without a click. Silently does nothing off X11, or if the window is not yet
/// viewable — the caller grabs on `map`, when it is.
static inline void skrepka_x11_grab_keyboard(GdkSurface *surface) {
	if (!skrepka_surface_is_x11(surface)) { return; }
	Display *display = gdk_x11_display_get_xdisplay(gdk_surface_get_display(surface));
	Window xid = gdk_x11_surface_get_xid(surface);
	XGrabKeyboard(display, xid, True, GrabModeAsync, GrabModeAsync, CurrentTime);
	XFlush(display);
}

static inline void skrepka_x11_ungrab_keyboard(GdkSurface *surface) {
	if (!skrepka_surface_is_x11(surface)) { return; }
	Display *display = gdk_x11_display_get_xdisplay(gdk_surface_get_display(surface));
	XUngrabKeyboard(display, CurrentTime);
	XFlush(display);
}

#else

static inline gboolean skrepka_surface_is_x11(GdkSurface *surface) { return FALSE; }
static inline void skrepka_x11_mark_utility(GdkSurface *surface) {}
static inline void skrepka_x11_center(GdkSurface *surface, int width, int height) {}
static inline void skrepka_x11_grab_keyboard(GdkSurface *surface) {}
static inline void skrepka_x11_ungrab_keyboard(GdkSurface *surface) {}

#endif
