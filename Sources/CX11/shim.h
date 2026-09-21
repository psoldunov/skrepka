// Xlib and the XFIXES extension, behind one header a module map can name.
//
// The module is `CX11` rather than anything narrower: XFIXES is the smallest
// of the three headers below and the least of what this carries, and a name
// promising only the extension would send the next reader looking for a
// separate Xlib module that does not exist.
//
// Three headers rather than one because the X11 clipboard needs all three and
// none of them includes the others:
//
//   Xlib.h    the display connection, the event loop, selections and properties
//   Xatom.h   the predefined atoms — XA_ATOM, XA_STRING, XA_INTEGER — which the
//             ICCCM replies for TARGETS and TIMESTAMP have to name
//   Xfixes.h  XFixesSelectSelectionInput and XFixesSelectionNotifyEvent, which
//             are what make the X11 backend event-driven rather than polled
//
// xfixes.pc lists x11 under `Requires.private`, which pkg-config expands only
// for a static link, so `pkg-config --libs xfixes` is `-lXfixes` alone.
// -lX11 therefore comes from a `.linkedLibrary` on the Swift target rather than
// from here — see Package.swift.

#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <X11/keysym.h>
#include <X11/extensions/Xfixes.h>

#if defined(linux)
#include <dlfcn.h>

typedef Bool (*SkrepkaXTestQueryExtension)(Display *, int *, int *, int *, int *);
typedef int (*SkrepkaXTestFakeKeyEvent)(Display *, unsigned int, Bool, unsigned long);

// Returns zero on success. libXtst is loaded at runtime so a desktop without it
// can still launch Skrepka and use copy-only mode.
static inline int skrepka_xtest_paste(const char *display_name) {
	void *library = dlopen("libXtst.so.6", RTLD_LAZY | RTLD_LOCAL);
	if (library == NULL) return 1;
	SkrepkaXTestQueryExtension query = (SkrepkaXTestQueryExtension)dlsym(library, "XTestQueryExtension");
	SkrepkaXTestFakeKeyEvent fake = (SkrepkaXTestFakeKeyEvent)dlsym(library, "XTestFakeKeyEvent");
	if (query == NULL || fake == NULL) {
		dlclose(library);
		return 2;
	}
	Display *display = XOpenDisplay(display_name);
	if (display == NULL) {
		dlclose(library);
		return 3;
	}
	int event_base = 0, error_base = 0, major = 0, minor = 0;
	if (!query(display, &event_base, &error_base, &major, &minor)) {
		XCloseDisplay(display);
		dlclose(library);
		return 4;
	}
	KeyCode control = XKeysymToKeycode(display, XK_Control_L);
	KeyCode v = XKeysymToKeycode(display, XK_v);
	if (control == 0 || v == 0 || !fake(display, control, True, 0)
		|| !fake(display, v, True, 0) || !fake(display, v, False, 0)
		|| !fake(display, control, False, 0)) {
		XCloseDisplay(display);
		dlclose(library);
		return 5;
	}
	XFlush(display);
	XCloseDisplay(display);
	dlclose(library);
	return 0;
}
#endif
