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
#include <X11/extensions/Xfixes.h>
